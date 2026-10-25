import Foundation

/// The one place that decides whether two names are the same album. Every comparison of albums
/// across Soulseek folders, tags, Bandcamp and Apple's catalogue goes through here, so a rule
/// learnt from one source holds for all of them.
///
/// A title is read as its core words plus two kinds of marker:
/// - recording markers (remix, live, acoustic, …): another recording, with other songs or audio.
///   "Copacetic (Remixed/Remastered)" isn't Copacetic.
/// - edition markers (deluxe, remaster, anniversary, …): the same recording released again.
///   "Glitch (Deluxe Edition)" is Glitch with more songs.
/// Capitals, punctuation, accents and copy tags ("[FLAC]", "(2015)") don't count, and artists
/// are compared as `ReleaseText.canonicalArtist` writes them ("Story So Far, The").
enum AlbumIdentity {
    /// Words that make another recording, by the form they're compared in.
    static let recordingMarkers: [String: String] = [
        "remix": "remix", "remixed": "remix", "remixes": "remix",
        "live": "live", "acoustic": "acoustic", "unplugged": "unplugged",
        "instrumental": "instrumental", "instrumentals": "instrumental",
        "demo": "demo", "demos": "demo",
        "reimagined": "reimagined", "rerecorded": "rerecorded", "redux": "redux",
    ]

    /// Words that make another release of the same recording.
    static let editionMarkers: [String: String] = [
        "deluxe": "deluxe", "expanded": "expanded", "anniversary": "anniversary",
        "remaster": "remaster", "remastered": "remaster",
        "bonus": "bonus", "special": "special", "collector": "collector", "collectors": "collector",
        "complete": "complete", "extended": "extended", "platinum": "platinum", "limited": "limited",
    ]

    struct Title: Equatable {
        /// The name without markers or copy tags: "copacetic".
        var core: String
        var recording: Set<String>
        var edition: Set<String>

        /// Core and recording markers: what tracklists and copies are shared by.
        var recordingKey: String { ([core] + recording.sorted()).joined(separator: " ") }
        /// Everything: what tells one release from another.
        var releaseKey: String { ([core] + recording.sorted() + edition.sorted()).joined(separator: " ") }
    }

    private final class Box: NSObject {
        let title: Title
        init(_ title: Title) { self.title = title }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Words that go with markers without naming anything: "(Super Deluxe Edition)".
    private static let fillers: Set<String> = [
        "and", "the", "a", "an", "of", "edition", "version", "super", "year", "years", "s", "th", "cd", "lp", "vinyl",
    ]

    /// Markers clear enough to count at the end of a name without brackets ("Black Sands
    /// Remixed"). Others ("Special", "Complete") end ordinary names too, so only count bracketed.
    private static let trailingMarkers: Set<String> = [
        "remix", "remixed", "remixes", "live", "acoustic", "unplugged", "instrumentals", "demos",
        "reimagined", "rerecorded", "deluxe", "expanded", "remaster", "remastered",
    ]

    /// Markers count in brackets, after " - ", or as trailing words, never inside the name:
    /// "Live Through This" and "Complete Control" are names, not a live album and a complete
    /// edition. Brackets and segments holding markers leave the core; others ("(feat. X)",
    /// "(Original Soundtrack)") are part of the name and stay.
    static func title(_ text: String) -> Title {
        if let cached = cache.object(forKey: text as NSString) { return cached.title }
        var markers: [String] = []
        // Other words beside markers name which one ("(Live at Wembley)"), so they stay.
        var named: [String] = []
        func isMarker(_ word: String) -> Bool { recordingMarkers[word] != nil || editionMarkers[word] != nil }
        func take(_ part: String) -> Bool {
            let words = ReleaseText.fold(part).split(separator: " ").map(String.init)
            guard words.contains(where: isMarker) else { return false }
            markers += words.filter(isMarker)
            named += words.filter { !isMarker($0) && !fillers.contains($0) && !$0.contains(where: \.isNumber) }
            return true
        }
        var rest = text
        for match in text.matches(of: /\s*[\[\(\{]([^\]\)\}]*)[\]\)\}]/).reversed() where take(String(match.output.1)) {
            rest.removeSubrange(match.range)
        }
        var segments = rest.split(separator: /\s+[-–—]\s+/).map(String.init)
        while segments.count > 1, let last = segments.last, take(last) {
            segments.removeLast()
        }
        var words = ReleaseText.fold(ReleaseText.cleanTitle(segments.joined(separator: " - "))).split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last {
            if trailingMarkers.contains(last) {
                markers.append(words.removeLast())
            } else if last == "and", words.count > 2, trailingMarkers.contains(words[words.count - 2]) {
                words.removeLast()
            } else {
                break
            }
        }
        words += named.reversed()
        let title = Title(
            core: words.isEmpty ? ReleaseText.fold(text) : words.joined(separator: " "),
            recording: Set(markers.compactMap { recordingMarkers[$0] }),
            edition: Set(markers.compactMap { editionMarkers[$0] })
        )
        cache.setObject(Box(title), forKey: text as NSString)
        return title
    }

    // MARK: - Comparisons

    /// The same recording, editions aside: shares a tracklist and copies.
    static func sameRecording(_ a: String, _ b: String) -> Bool {
        title(a).recordingKey == title(b).recordingKey
    }

    /// The very same release, edition and all.
    static func sameRelease(_ a: String, _ b: String) -> Bool {
        title(a).releaseKey == title(b).releaseKey
    }

    /// For names that may have lost or gained an edition note along the way (a Soulseek folder's,
    /// tags): the same recording, and the same edition unless either gives none.
    static func sameReleaseLoosely(_ a: String, _ b: String) -> Bool {
        let (x, y) = (title(a), title(b))
        return x.recordingKey == y.recordingKey && (x.edition == y.edition || x.edition.isEmpty || y.edition.isEmpty)
    }

    // MARK: - Keys

    /// One key per release of an artist's: what library albums are grouped by.
    static func releaseKey(_ album: AlbumKey) -> String {
        "\(ReleaseText.artistMatchName(album.artist))|\(title(album.title).releaseKey)"
    }

    /// One key per recording of an artist's: what tracklists and copies are kept under.
    static func recordingKey(_ album: AlbumKey) -> String {
        "\(ReleaseText.artistMatchName(album.artist))|\(title(album.title).recordingKey)"
    }

    // MARK: - Soulseek folders

    /// Whether a Soulseek folder holds this recording: its path has the album's name, and its
    /// own name no other recording's markers ("Copacetic (Remixed-Remastered)" isn't Copacetic).
    static func folder(_ path: String, holds albumTitle: String) -> Bool {
        let album = title(albumTitle)
        let core = Set(album.core.split(separator: " ").map(String.init))
        let pathWords = Set(ReleaseText.fold(path).split(separator: " ").map(String.init))
        guard !core.isEmpty, core.isSubset(of: pathWords) else { return false }
        // The folder's own name; words of the album's name ("Live Through This") aren't markers.
        let name = path.split(separator: "\\").last.map(String.init) ?? path
        let recording = Set(ReleaseText.fold(name).split(separator: " ").map(String.init)
            .filter { !core.contains($0) }.compactMap { recordingMarkers[$0] })
        return recording == album.recording
    }
}
