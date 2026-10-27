import Foundation

/// Turns a song shared to Seek (from Shazam's or Apple Music's share sheet, or a Shortcut)
/// into a Soulseek search.
///
/// Links: `seek://search?q=Artist Title` runs that search; `seek://share?text=…` is what the
/// share extension sends, the shared message and links as they came.
enum SharedSong {
    static func query(for url: URL) async -> String? {
        guard url.scheme == "seek", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch url.host() {
        case "search": return value("q").flatMap { $0.isEmpty ? nil : $0 }
        case "share": return await query(forShared: value("text") ?? "")
        default: return nil
        }
    }

    /// The song's name from Apple's catalogue when a link gives its Apple ID, as that's
    /// spelled properly; otherwise the message, then the link's own words.
    static func query(forShared text: String) async -> String? {
        let links = links(in: text)
        for link in links {
            if let id = appleID(in: link), let song = await lookUp(id) { return song }
        }
        if let song = query(fromMessage: text) { return song }
        for link in links {
            if let words = slugQuery(link) { return words }
        }
        let rest = withoutLinks(text).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return rest.isEmpty ? nil : rest
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }

    static func withoutLinks(_ text: String) -> String {
        var rest = text
        for link in links(in: text).reversed() {
            rest = rest.replacingOccurrences(of: link.absoluteString, with: " ")
        }
        return rest
    }

    /// "I used Shazam to discover Blinding Lights by The Weeknd." → "The Weeknd Blinding Lights".
    /// The last " by " splits it, as titles have one more often than artists ("Stand by Me").
    static func query(fromMessage text: String) -> String? {
        var message = withoutLinks(text)
            .replacing(/(?i)^.*?\bshazam\b.*?\bdiscover(ed)?\s+/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = message.last, ".!:".contains(last) { message.removeLast() }
        guard let by = message.range(of: " by ", options: [.backwards, .caseInsensitive]) else { return nil }
        let title = CatalogRelease.cleanTitle(String(message[..<by.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        let artist = String(message[by.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return "\(artist) \(title)"
    }

    /// Shazam's song links carry the Apple Music ID (shazam.com/song/1488408568/blinding-lights),
    /// as do Apple Music's (…/album/after-hours/1499378108?i=1499378615, …/song/blinding-lights/1488408568).
    /// Shazam's older /track/ links use its own IDs, which Apple's lookup doesn't know.
    static func appleID(in url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        func numeric(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }
        if host.hasSuffix("shazam.com") {
            guard let song = parts.firstIndex(of: "song"), song + 1 < parts.count, numeric(parts[song + 1]) else { return nil }
            return parts[song + 1]
        }
        if host.hasSuffix("music.apple.com") || host.hasSuffix("itunes.apple.com") {
            if let i = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value,
               numeric(i) { return i }
            if parts.contains("song"), let id = parts.last, numeric(id) { return id }
        }
        return nil
    }

    /// The words of a Shazam link's name (…/track/20066955/blinding-lights → "blinding lights").
    static func slugQuery(_ url: URL) -> String? {
        guard url.host()?.lowercased().hasSuffix("shazam.com") == true,
              let slug = url.pathComponents.last, slug.contains(where: \.isLetter) else { return nil }
        let words = slug.split(separator: "-").joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private struct Lookup: Decodable {
        struct Result: Decodable {
            var kind: String?
            var artistName: String?
            var trackName: String?
        }
        var results: [Result]
    }

    private static func lookUp(_ id: String) async -> String? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let found = try? JSONDecoder().decode(Lookup.self, from: data),
              let song = found.results.first(where: { $0.kind == "song" }),
              let artist = song.artistName, let title = song.trackName else { return nil }
        return "\(artist) \(CatalogRelease.cleanTitle(title))"
    }
}
