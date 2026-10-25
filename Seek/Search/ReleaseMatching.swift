import Foundation

/// Text clean-up for comparing release names from Bandcamp and Soulseek folder names.
enum ReleaseText {
    /// Lower case, no accents, "&" as "and", punctuation as spaces, single spaces.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let spaced = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Words in brackets that describe a copy rather than name the release.
    private static let tagWords = [
        "flac", "mp3", "320", "v0", "wav", "aiff", "alac", "aac", "24bit", "16bit", "24 bit", "16 bit", "khz", "web",
        "vinyl", "cd", "lossless", "hi res", "hires", "remaster", "remastered", "deluxe", "edition", "expanded",
        "bonus", "bandcamp", "beatport", "qobuz", "vbr", "cbr", "kbps", "24b", "16b", "lp", "ep", "single",
        "explicit", "digital master", "mastered for itunes", "itunes", "apple music", "spotify", "tidal", "deezer",
        "amazon", "hdtracks",
    ]
    /// Tags short enough to turn up inside ordinary words ("ep" in "Reprod", "cd" in "abcd"),
    /// so they only count as whole words.
    private static let wholeWordTags: Set<String> = ["ep", "lp", "cd", "web", "v0", "aac", "wav", "vbr", "cbr", "24b", "16b", "320", "explicit"]

    private static func hasTag(_ inside: String) -> Bool {
        let words = Set(inside.split(separator: " ").map(String.init))
        return tagWords.contains { tag in
            wholeWordTags.contains(tag) ? words.contains(tag) : inside.contains(tag)
        }
    }

    /// Drops bracketed tags like "[FLAC 24-44]", "(2025)", "{WEB}", "(Deluxe Edition)" and a
    /// trailing "EP"/"LP"/"Single", keeping brackets that are part of the name, like "(feat. X)".
    static func cleanTitle(_ text: String) -> String {
        var result = text
        let brackets = /\s*[\[\(\{]([^\]\)\}]*)[\]\)\}]/
        for match in text.matches(of: brackets).reversed() {
            let raw = String(match.output.1)
            let inside = fold(raw)
            // Only numbers and punctuation, like "[24-44,1]" or "(16/48)", describe the copy.
            let isTag = inside.isEmpty || !raw.contains(where: \.isLetter)
                || inside.firstMatch(of: /^(19|20)\d\d$/) != nil
                || hasTag(inside)
                || inside.firstMatch(of: /^[a-z]{2,6} ?\d{2,5}$/) != nil
                // A barcode or catalogue id: "{AWGE ∕ Interscope Records, 0602458440843}".
                || inside.firstMatch(of: /\d{8,}/) != nil
                // A database id: "(be3eabb0-0b23-40fa-a185-c127a4334e5b)".
                || raw.firstMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
            if isTag { result.removeSubrange(match.range) }
        }
        result = trimLooseTags(result)
        result = result.replacing(/(?i)\s+(ep|lp|single)$/, with: "")
        return result.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-–—_.")))
    }

    /// Formats and bitrates written outside brackets.
    private static let looseTags: Set<String> = [
        "mp3", "flac", "web", "wav", "alac", "aac", "m4a", "ogg", "opus", "v0", "v2", "320", "256", "lossless", "hires",
    ]

    /// Drops what trails a name without brackets: "MUSIC Mp3 320kbps [PMEDIA] ⭐️", "MUSIC - FLAC".
    /// A bracketed word right after such tags is the release group's, so it goes too.
    private static func trimLooseTags(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        func isLooseTag(_ word: String) -> Bool {
            let bare = String(word.filter { $0.isLetter || $0.isNumber }).lowercased()
            return looseTags.contains(bare) || bare.firstMatch(of: /^\d+(kbps|k|bit|khz)$/) != nil
        }
        while words.count > 1, let last = words.last {
            // Letters and numbers as people read them: an emoji's variation selector isn't one.
            let bare = last.filter { $0.isLetter || $0.isNumber }
            let bracketed = (last.hasPrefix("[") && last.hasSuffix("]")) || (last.hasPrefix("(") && last.hasSuffix(")"))
            if bare.isEmpty || isLooseTag(last) {
                words.removeLast()
            } else if bracketed, words.count > 2, isLooseTag(words[words.count - 2]) {
                words.removeLast()
            } else {
                break
            }
        }
        return words.joined(separator: " ")
    }

    static func year(in text: String) -> Int? {
        text.firstMatch(of: /(?:^|[^\d])((?:19|20)\d\d)(?:[^\d]|$)/).flatMap { Int($0.output.1) }
    }

    /// Words that name an edition of a release rather than a different one.
    static let editionWords: Set<String> = [
        "deluxe", "remaster", "remastered", "remasters", "edition", "editions", "expanded", "anniversary", "version",
        "bonus", "track", "tracks", "reissue", "special", "collector", "collectors", "complete", "digital", "original",
        "the", "s", "th", "and", "with", "album", "ep", "lp", "single", "mono", "stereo", "explicit", "clean",
    ]

    /// The same title, or the same with only edition words added ("Glitch (Deluxe Edition)",
    /// "Souvlaki 2005 Remaster"). Other extra words make a different release: "Closer: The
    /// CVLT Nation Sessions" is a tribute album, not Closer.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let (x, y) = (normalizedTitle(a), normalizedTitle(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        let extra: Substring
        if long.hasPrefix(short + " ") {
            extra = long.dropFirst(short.count + 1)
        } else if long.hasSuffix(" " + short) {
            extra = long.dropLast(short.count + 1)
        } else {
            return false
        }
        return extra.split(separator: " ").allSatisfy { word in
            editionWords.contains(String(word)) || word.allSatisfy(\.isNumber)
        }
    }

    /// The same artist, or one credited within the other ("DreamKiller" in "DreamKiller & VTSS").
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let (x, y) = (foldedName(a), foldedName(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        return !creditNames(a).isDisjoint(with: creditNames(b))
    }

    // Grouping compares every folder with every release found so far, thousands of times over
    // the same few hundred names, so each name is cleaned once and remembered.
    private static let titleCache = NSCache<NSString, NSString>()
    private static let nameCache = NSCache<NSString, NSString>()
    private static let creditCache = NSCache<NSString, NSSet>()

    /// The title as compared: tags dropped, folded.
    static func normalizedTitle(_ text: String) -> String {
        if let cached = titleCache.object(forKey: text as NSString) { return cached as String }
        let value = fold(cleanTitle(text))
        titleCache.setObject(value as NSString, forKey: text as NSString)
        return value
    }

    /// An artist's name as people write it: without notes in brackets at the end ("The Story So
    /// Far (CA)", "… (pop punk band from Walnut Creek, CA, 2007–present)"), and "Story So Far,
    /// The" turned round. Folders named either way are the same artist's.
    static func canonicalArtist(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces)
        // Notes in any brackets, possibly several: "Story So Far, The {MbId-bc303c9e-…}".
        while let note = result.firstMatch(of: /\s+[(\[{][^()\[\]{}]*[)\]}]$/) {
            let bare = String(result[..<note.range.lowerBound])
            guard !fold(bare).isEmpty else { break }
            result = bare
        }
        if let match = result.firstMatch(of: /^(.+),\s*(?i:(the|a|an))$/) {
            result = "\(match.output.2) \(match.output.1)"
        }
        return result
    }

    /// An artist's name as compared: tidied (`canonicalArtist`) and folded, remembered.
    static func artistMatchName(_ text: String) -> String { foldedName(text) }

    private static func foldedName(_ text: String) -> String {
        if let cached = nameCache.object(forKey: text as NSString) { return cached as String }
        let value = fold(canonicalArtist(text))
        nameCache.setObject(value as NSString, forKey: text as NSString)
        return value
    }

    /// Each name in a credit ("A & B feat. C"), split before folding, which would drop the
    /// commas and ampersands.
    private static func creditNames(_ text: String) -> Set<String> {
        if let cached = creditCache.object(forKey: text as NSString) as? Set<String> { return cached }
        let separators = /(?i)\s*(,|&|\+|\s(and|x|feat\.?|ft\.?|vs\.?|with)\s)\s*/
        let value = Set(text.split(separator: separators).map { fold(String($0)) }.filter { $0.count >= 3 })
        creditCache.setObject(value as NSSet, forKey: text as NSString)
        return value
    }
}

/// What a Soulseek folder seems to hold, read from its name, its parent folder and its files.
struct ParsedFolder: Equatable {
    var artist: String?
    var title: String
    var year: Int?
    /// 0–1: how sure the reading is. Low readings are worth asking Claude about.
    var confidence: Double
}

enum FolderParser {
    /// Parent folders that say nothing about the artist.
    private static let generic: Set<String> = [
        "music", "mp3", "flac", "albums", "album", "downloads", "download", "complete", "completed", "shared", "share",
        "my music", "audio", "soulseek", "slsk", "new", "incoming", "eps", "singles", "lossless", "vinyl", "rips",
        "electronic", "techno", "house", "ambient", "rock", "pop", "hip hop", "jazz", "music library", "itunes",
    ]

    /// Regrouping runs again every few hundred milliseconds while results arrive, over the same
    /// folders: each is read once. (Keyed by file count too, as opening a folder adds files.)
    private static let parsed = NSCache<NSString, ParsedBox>()

    static func parse(_ folder: RemoteFolder) -> ParsedFolder {
        let key = "\(folder.id)\u{0}\(folder.files.count)" as NSString
        if let cached = parsed.object(forKey: key) { return cached.value }
        let value = parseNow(folder)
        parsed.setObject(ParsedBox(value), forKey: key)
        return value
    }

    private final class ParsedBox {
        let value: ParsedFolder
        init(_ value: ParsedFolder) { self.value = value }
    }

    private static func parseNow(_ folder: RemoteFolder) -> ParsedFolder {
        var components = folder.components
        // "Album\CD1": the album is the folder above.
        if let last = components.last, ReleaseText.fold(last).firstMatch(of: /^(cd|disc|disk) ?\d+$/) != nil, components.count > 1 {
            components.removeLast()
        }
        let name = components.last ?? folder.path
        let parent = components.dropLast().last
        return parse(name: name, parent: parent, fileNames: folder.files.map(\.name))
    }

    /// Scene-style release names: "Artist-Album_Title-WEB-2021-GROUP", with underscores for spaces
    /// and source, year and group tags after the title.
    static func parseScene(_ name: String) -> ParsedFolder? {
        guard !name.contains(" "), name.filter({ $0 == "-" }).count >= 2 else { return nil }
        let parts = name.split(separator: "-").map { $0.replacingOccurrences(of: "_", with: " ") }
        let tags: Set<String> = ["web", "flac", "cd", "cdm", "cdr", "vinyl", "vls", "lp", "ep", "single", "mp3", "16bit", "24bit",
                                 "retail", "promo", "bootleg", "remastered", "deluxe", "advance", "dirfix", "proper", "bc", "bp"]
        guard let firstTag = parts.indices.dropFirst(2).first(where: { index in
            let part = parts[index].lowercased()
            return tags.contains(part) || part.firstMatch(of: /^(19|20)\d\d$/) != nil || part.hasPrefix("(")
        }) ?? (parts.count >= 3 ? parts.count - 1 : nil) else { return nil }
        let artist = parts[0]
        let title = parts[1..<firstTag].joined(separator: " - ")
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        let year = parts[firstTag...].lazy.compactMap { Int($0) }.first { (1900...2100).contains($0) }
        return ParsedFolder(artist: artist, title: ReleaseText.cleanTitle(title), year: year, confidence: 0.75)
    }

    static func parse(name: String, parent: String?, fileNames: [String] = []) -> ParsedFolder {
        if let scene = parseScene(name) { return scene }
        let year = ReleaseText.year(in: name)
        let cleaned = ReleaseText.cleanTitle(name)
        let parts = nameParts(cleaned)
        if parts.count >= 2 {
            // "Playboi Carti - Album - 2025 - MUSIC": the type and year between aren't the title.
            var title = Array(parts.dropFirst())
            while title.count > 1, isNoise(title[0]) { title.removeFirst() }
            return ParsedFolder(artist: parts[0], title: title.joined(separator: " - "), year: year, confidence: 0.9)
        }
        let title = parts.first ?? cleaned
        if let parent, !generic.contains(ReleaseText.fold(parent)), parent.count > 1, Int(parent) == nil {
            return ParsedFolder(artist: ReleaseText.cleanTitle(parent), title: title, year: year, confidence: 0.65)
        }
        if let artist = artistFromFiles(fileNames) {
            return ParsedFolder(artist: artist, title: title, year: year, confidence: 0.6)
        }
        return ParsedFolder(artist: nil, title: title, year: year, confidence: 0.3)
    }

    /// A folder name split at its dashes, without the dates, years, catalogue numbers and release
    /// types ("2025-03-14 - MUSIC", "MUSIC - 2025", "DRR012 - Artist - Album", "Album - …") that
    /// aren't part of the artist or title.
    static func nameParts(_ name: String) -> [String] {
        var parts = name.split(separator: /\s+[-–—]\s+/).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        while parts.count > 1, isNoise(parts[0]) { parts.removeFirst() }
        while parts.count > 1, isNoise(parts[parts.count - 1]) { parts.removeLast() }
        return parts
    }

    static func isNoise(_ part: String) -> Bool {
        part.firstMatch(of: /^((19|20)\d\d|[A-Za-z]{2,6} ?\d{2,5})$/) != nil
            || part.firstMatch(of: /^(19|20)\d\d[-.\/ ]\d{1,2}[-.\/ ]\d{1,2}$/) != nil
            || ["album", "single", "ep", "lp", "mixtape", "compilation"].contains(part.lowercased())
    }

    /// "01 - DreamKiller - Soul.flac" in most files names the artist.
    private static func artistFromFiles(_ names: [String]) -> String? {
        let artists = names.compactMap { name -> String? in
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.split(separator: /\s+[-–—]\s+/).map(String.init)
            guard parts.count >= 3, parts[0].trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard artists.count * 2 > names.count, let first = artists.first,
              artists.allSatisfy({ ReleaseText.fold($0) == ReleaseText.fold(first) }) else { return nil }
        return first
    }
}

/// Claude's reading of a folder Seek wasn't sure about.
struct FolderHint: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case release, mixed }
    var kind: Kind
    var artist: String?
    var title: String?
    var year: Int?
}

/// One release in search results, with every place it can come from.
struct SearchRelease: Identifiable, Equatable {
    var id: String
    var artist: String
    var title: String
    var year: Int?
    /// Bandcamp's seller when it isn't the artist, usually the label.
    var seller: String?
    var owned: BandcampItem?
    var store: BandcampAPI.StoreResult?
    /// Best first: lossless, complete, free slot, fast.
    var folders: [RemoteFolder] = []
    /// How well it matches the search, 0–1.
    var relevance: Double = 0
    /// The library album it already is, if any.
    var inLibrary: AlbumKey?
    /// Every Soulseek file in it, for spotting downloads in progress.
    var fileIDs: Set<String> = []

    /// Art from elsewhere (a suggestion, Apple's catalogue) when Bandcamp has none.
    var fallbackArtwork: URL?
    /// The release in the artist's Apple Music catalogue, when the search is for the artist.
    var catalog: CatalogRelease?

    /// Known only from the catalogue: no copy found anywhere yet.
    var isCatalogOnly: Bool { owned == nil && store == nil && folders.isEmpty }

    /// Art known to be this album's (Apple's catalogue, or what a suggestion came with), ahead of
    /// the Bandcamp store's.
    var trustedArtwork: URL?

    /// A purchase's own art, then Apple's (curated), then the Bandcamp store's (anyone can upload
    /// an album's name).
    var artworkURL: URL? { owned?.artworkURL ?? catalog?.artworkURL ?? trustedArtwork ?? store?.artworkURL ?? fallbackArtwork }
    var bestFolder: RemoteFolder? { folders.first }
    var isTrack: Bool { owned?.isTrack ?? store?.isTrack ?? false }
    var trackCount: Int? { bestFolder?.files.count }
    var isLossless: Bool { folders.contains(where: \.isLossless) }
}

/// Merges Bandcamp purchases, Bandcamp store results and Soulseek folders into one list of releases.
enum ReleaseGrouper {
    struct Result: Equatable {
        var releases: [SearchRelease]
        /// Files from folders that aren't a single release (e.g. "2025 Singles") but match the search.
        var songs: [RemoteFile]
        /// Folders worth asking Claude about.
        var unsure: [RemoteFolder]
    }

    static func group(
        query: String,
        owned: [BandcampItem],
        store: [BandcampAPI.StoreResult],
        folders: [RemoteFolder],
        hints: [String: FolderHint] = [:],
        library: LibraryIndex = LibraryIndex(albums: []),
        wishlist: Set<Int> = [],
        quality: QualityPreference = .cd,
        catalog: [CatalogRelease] = []
    ) -> Result {
        var releases: [SearchRelease] = []
        var songs: [RemoteFile] = []
        var unsure: [RemoteFolder] = []
        let words = ReleaseText.fold(query).split(separator: " ").map(String.init)

        // The same artist and title, the common case, is a lookup; only the rest are compared
        // one by one (edition words, credits, labels).
        var exact: [String: Int] = [:]
        func key(_ artist: String, _ title: String) -> String {
            "\(ReleaseText.normalizedTitle(title))|\(ReleaseText.fold(artist))"
        }
        func add(_ release: SearchRelease) {
            if exact[key(release.artist, release.title)] == nil { exact[key(release.artist, release.title)] = releases.count }
            releases.append(release)
        }
        func index(artist: String, title: String, seller: String?) -> Int? {
            if let i = exact[key(artist, title)] { return i }
            return releases.firstIndex { release in
                ReleaseText.titlesMatch(release.title, title)
                    && (ReleaseText.artistsMatch(release.artist, artist)
                        || release.seller.map { ReleaseText.artistsMatch($0, artist) } == true
                        || seller.map { ReleaseText.artistsMatch(release.artist, $0) } == true)
            }
        }

        // Bandcamp first: its names are clean. Labels selling "Artist - Album" are split up.
        for item in owned {
            let (artist, title, seller) = splitLabelUpload(title: item.title, seller: item.artist)
            if let i = index(artist: artist, title: title, seller: seller) {
                releases[i].owned = item
            } else {
                add(SearchRelease(id: "bc-\(item.id)", artist: artist, title: title, seller: seller, owned: item))
            }
        }
        for result in store {
            let (artist, title, seller) = splitLabelUpload(title: result.title, seller: result.artist)
            if let i = releases.firstIndex(where: { $0.owned?.itemId == result.id }) ?? index(artist: artist, title: title, seller: seller) {
                if releases[i].store == nil { releases[i].store = result }
            } else {
                add(SearchRelease(id: "bs-\(result.id)", artist: artist, title: title, seller: seller, store: result))
            }
        }

        for folder in folders {
            var parsed = FolderParser.parse(folder)
            if let hint = hints[folder.id] {
                if hint.kind == .mixed {
                    songs += matchingFiles(folder, words: words)
                    continue
                }
                parsed = ParsedFolder(artist: hint.artist ?? parsed.artist, title: hint.title.map(ReleaseText.cleanTitle) ?? parsed.title,
                                      year: hint.year ?? parsed.year, confidence: 1)
            }
            let named = ReleaseText.fold("\(parsed.artist ?? "") \(parsed.title) \(folder.parentName ?? "")")
            // A folder named for something else that holds a matching song, e.g. a singles folder.
            if !words.isEmpty, !words.contains(where: { named.contains($0) }) {
                songs += matchingFiles(folder, words: words)
                continue
            }
            if hints[folder.id] == nil, let fixed = Self.parentIsArtist(folder, parsed: parsed, words: words) { parsed = fixed }
            if parsed.confidence < 0.7, hints[folder.id] == nil { unsure.append(folder) }

            let artist = parsed.artist.map(ReleaseText.canonicalArtist) ?? ""
            let match = artist.isEmpty
                ? releases.firstIndex { ReleaseText.fold(ReleaseText.cleanTitle($0.title)) == ReleaseText.fold(parsed.title) && parsed.title.count >= 6 }
                : index(artist: artist, title: parsed.title, seller: nil)
            if let i = match {
                releases[i].folders.append(folder)
                if releases[i].year == nil { releases[i].year = parsed.year }
            } else {
                add(SearchRelease(
                    id: "sk-\(ReleaseText.fold(artist))|\(ReleaseText.fold(parsed.title))",
                    artist: artist.isEmpty ? "Unknown Artist" : artist,
                    title: parsed.title,
                    year: parsed.year,
                    folders: [folder]
                ))
            }
        }

        // An artist search: match releases to the artist's catalogue, and list main releases
        // that nothing else found, so the artist's albums lead whatever the sources return.
        var matchedCatalog = Set<Int>()
        for i in releases.indices {
            let candidates = catalog.indices.filter { catalog[$0].matches(releases[i]) }
            // The exact title first: "Album (Deluxe)" is the deluxe entry, not the standard one.
            let exact = candidates.first { ReleaseText.fold(ReleaseText.cleanTitle(catalog[$0].title)) == ReleaseText.fold(ReleaseText.cleanTitle(releases[i].title)) }
            guard let c = exact ?? candidates.first else { continue }
            matchedCatalog.insert(c)
            // A single Bandcamp track named like an album ("whole lotta red", a fan upload) isn't
            // the album: it goes back to being its own result.
            if catalog[c].kind >= .ep, let store = releases[i].store, store.isTrack {
                releases[i].store = nil
                // The album row may have been made from that track; it takes the catalogue's id
                // so the two rows don't share one.
                releases[i].id = "it-\(ReleaseText.fold(catalog[c].artist))|\(ReleaseText.fold(catalog[c].title))"
                let (artist, title, seller) = splitLabelUpload(title: store.title, seller: store.artist)
                releases.append(SearchRelease(id: "bs-\(store.id)", artist: artist, title: title, seller: seller, store: store))
            }
            releases[i].catalog = catalog[c]
            // The catalogue's name is the clean one; folders' vary ("MUSIC", "MUSIC (2025)", …).
            releases[i].title = catalog[c].title
            if releases[i].year == nil { releases[i].year = catalog[c].year }
            if releases[i].fallbackArtwork == nil { releases[i].fallbackArtwork = catalog[c].artworkURL }
        }
        // Standard and deluxe editions match each other's names, so their copies land together.
        // Where the catalogue has both, the deluxe copies (named so, or with its track count) move
        // to their own release.
        for (c, entry) in catalog.enumerated() where !matchedCatalog.contains(c) && entry.kind >= .ep {
            guard let i = releases.firstIndex(where: {
                guard let standard = $0.catalog else { return false }
                return standard != entry && ReleaseText.titlesMatch(standard.title, entry.title)
            }), let standard = releases[i].catalog else { continue }
            let standardWords = Set(ReleaseText.fold(standard.title).split(separator: " "))
            let editionWords = ReleaseText.fold(entry.title).split(separator: " ").filter { !standardWords.contains($0) }.map(String.init)
            let moving = releases[i].folders.filter { folder in
                let named = ReleaseText.fold("\(folder.parentName ?? "") \(folder.name)")
                let longer = entry.trackCount > standard.trackCount && folder.files.count >= entry.trackCount - 1
                return editionWords.contains { named.contains($0) } || longer
            }
            guard !moving.isEmpty else { continue }
            let ids = Set(moving.map(\.id))
            releases[i].folders.removeAll { ids.contains($0.id) }
            matchedCatalog.insert(c)
            releases.append(SearchRelease(
                id: "it-\(ReleaseText.fold(entry.artist))|\(ReleaseText.fold(entry.title))",
                artist: entry.artist, title: entry.title, year: entry.year, folders: moving,
                fallbackArtwork: entry.artworkURL, catalog: entry
            ))
        }
        for (c, entry) in catalog.enumerated() where !matchedCatalog.contains(c) && entry.kind >= .ep {
            releases.append(SearchRelease(
                id: "it-\(ReleaseText.fold(entry.artist))|\(ReleaseText.fold(entry.title))",
                artist: entry.artist, title: entry.title, year: entry.year,
                fallbackArtwork: entry.artworkURL, catalog: entry
            ))
        }

        var scores: [SearchRelease.ID: Double] = [:]
        for i in releases.indices {
            releases[i].folders = sortedBest(releases[i].folders, quality: quality, expectedTracks: releases[i].catalog?.trackCount)
            let text = ReleaseText.fold("\(releases[i].artist) \(releases[i].title) \(releases[i].seller ?? "")")
            releases[i].relevance = words.isEmpty ? 0 : Double(words.filter { text.contains($0) }.count) / Double(words.count)
            releases[i].inLibrary = library.album(for: releases[i])
            releases[i].fileIDs = Set(releases[i].folders.flatMap(\.files).map(\.id))
            scores[releases[i].id] = score(releases[i], wishlist: wishlist)
        }
        releases.sort {
            let (a, b) = (scores[$0.id, default: 0], scores[$1.id, default: 0])
            // Equal otherwise, newer first.
            return a != b ? a > b : ($0.year ?? 0) > ($1.year ?? 0)
        }
        return Result(releases: releases, songs: songs, unsure: unsure)
    }

    /// In the library first, then purchases, then the best matches, wishlist items and well-shared releases.
    private static func score(_ r: SearchRelease, wishlist: Set<Int>) -> Double {
        var score = r.relevance * 10
        if r.inLibrary != nil { score += 40 }
        if r.owned != nil { score += 20 }
        if let store = r.store, wishlist.contains(store.id) { score += 8 }
        if r.store != nil { score += 2 }
        score += min(Double(r.folders.count), 10) * 0.3
        if r.isTrack { score -= 3 }
        if let catalog = r.catalog { score += catalog.boost() }
        // Found somewhere beats known only from the catalogue, among releases alike.
        if r.isCatalogOnly { score -= 2 }
        return score
    }

    /// "Playboi Carti\\MUSIC - SORRY 4 DA WAIT" read as an album "SORRY 4 DA WAIT" by "MUSIC":
    /// when the folder sits in a folder named for the artist being searched for, and what was read
    /// as the artist isn't them, the parent is the artist and the whole name is the title.
    static func parentIsArtist(_ folder: RemoteFolder, parsed: ParsedFolder, words: [String]) -> ParsedFolder? {
        guard !words.isEmpty, let parent = folder.parentName, let artist = parsed.artist,
              folder.name.contains(" - ") else { return nil }
        let parentFolded = ReleaseText.fold(parent), artistFolded = ReleaseText.fold(artist)
        guard words.allSatisfy({ parentFolded.contains($0) }),
              !words.allSatisfy({ artistFolded.contains($0) }) else { return nil }
        // Dates and years ("2025 - MUSIC - …") belong to the copy, not the title.
        let title = FolderParser.nameParts(ReleaseText.cleanTitle(folder.name)).joined(separator: " - ")
        return ParsedFolder(artist: parent, title: title, year: parsed.year ?? ReleaseText.year(in: folder.name),
                            confidence: parsed.confidence)
    }

    /// "DreamKiller - Erotic Motion" sold by "Diffuse Reality Records": artist DreamKiller, seller the label.
    static func splitLabelUpload(title: String, seller: String) -> (artist: String, title: String, seller: String?) {
        let parts = title.split(separator: /\s+[-–—]\s+/).map(String.init)
        if parts.count >= 2, !ReleaseText.artistsMatch(parts[0], seller) {
            return (parts[0], parts.dropFirst().joined(separator: " - "), seller)
        }
        return (seller, title, nil)
    }

    private static func matchingFiles(_ folder: RemoteFolder, words: [String]) -> [RemoteFile] {
        guard !words.isEmpty else { return [] }
        return folder.files.filter { file in
            let name = ReleaseText.fold((file.name as NSString).deletingPathExtension)
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// Lossless beats lossy (at CD quality first, if that's the preference, since hi-res is several
    /// times bigger), then more tracks (a complete copy), then a free slot, then speed.
    /// Best first, as `better` orders them, with each folder's quality worked out once rather
    /// than on every comparison.
    static func sortedBest(_ folders: [RemoteFolder], quality: QualityPreference = .cd, expectedTracks: Int? = nil) -> [RemoteFolder] {
        guard folders.count > 1 else { return folders }
        let keyed = folders.map { folder in
            let lossless = folder.isLossless
            return (folder: folder, lossless: lossless, hiRes: lossless && folder.isHiRes,
                    complete: CopyFilter.isComplete(folder, expectedTracks: expectedTracks),
                    banned: BannedUsers.contains(folder.username))
        }
        return keyed.sorted { a, b in
            // A user who's banned this account won't send anything, however good their copy.
            if a.banned != b.banned { return !a.banned }
            // The whole album before any partial copy, however good its quality.
            if a.complete != b.complete { return a.complete }
            if a.lossless != b.lossless { return a.lossless }
            if quality == .cd, a.lossless, a.hiRes != b.hiRes { return !a.hiRes }
            if a.folder.files.count != b.folder.files.count { return a.folder.files.count > b.folder.files.count }
            if a.folder.hasFreeSlot != b.folder.hasFreeSlot { return a.folder.hasFreeSlot }
            return a.folder.averageSpeed > b.folder.averageSpeed
        }.map(\.folder)
    }

    static func better(_ a: RemoteFolder, _ b: RemoteFolder, quality: QualityPreference = .cd) -> Bool {
        if a.isLossless != b.isLossless { return a.isLossless }
        if quality == .cd, a.isLossless, a.isHiRes != b.isHiRes { return !a.isHiRes }
        if a.files.count != b.files.count { return a.files.count > b.files.count }
        if a.hasFreeSlot != b.hasFreeSlot { return a.hasFreeSlot }
        return a.averageSpeed > b.averageSpeed
    }
}

/// The library's albums, cleaned up once for quick matching against search results.
struct LibraryIndex: Sendable {
    private let byTitle: [String: [(key: AlbumKey, artist: String)]]

    init(albums: [AlbumKey]) {
        var byTitle: [String: [(AlbumKey, String)]] = [:]
        for key in albums {
            byTitle[ReleaseText.fold(ReleaseText.cleanTitle(key.title)), default: []].append((key, key.artist))
        }
        self.byTitle = byTitle
    }

    /// `named`: the release's title names exactly which release it is (an album page opened from
    /// Apple's catalogue or a suggestion), so an edition in it counts as with the catalogue.
    func album(for release: SearchRelease, named: Bool = false) -> AlbumKey? {
        let candidates = byTitle[ReleaseText.fold(ReleaseText.cleanTitle(release.title))] ?? []
        // A release Apple names as an edition ("Copacetic (Remixed/Remastered)") is only the
        // library's album when that names the edition too: owning the original isn't owning it.
        let full = ReleaseText.fold(release.title)
        let edition = (release.catalog != nil || named) && full != ReleaseText.fold(ReleaseText.cleanTitle(release.title))
            ? Set(full.split(separator: " ")) : nil
        return candidates.first { candidate in
            if let edition, !edition.isSubset(of: Set(ReleaseText.fold(candidate.key.title).split(separator: " "))) { return false }
            return ReleaseText.artistsMatch(candidate.artist, release.artist)
                || release.seller.map { ReleaseText.artistsMatch(candidate.artist, $0) } == true
        }?.key
    }
}
