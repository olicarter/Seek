import Foundation
import Observation

/// One song on a release as the release itself lists it.
struct ReferenceTrack: Codable, Hashable, Sendable {
    var number: Int
    var disc: Int
    var title: String
    var duration: Double?
    /// Bandcamp's own stream of the track, when the artist allows it. Short-lived; fetched fresh to play.
    var streamURL: URL?

    var matchTitle: String { ReferenceTitles.match(title) }

    /// The title as listed and without a leading "Artist - " (Bandcamp often lists songs as
    /// "Niontay featuring DORIS - 10/4", which imports as "10/4").
    var matchTitles: [String] { ReferenceTitles.matches(title) }
}

/// What a release really contains, from Bandcamp's release page or Apple's iTunes catalogue,
/// for spotting missing tracks and checking Soulseek copies against.
struct AlbumReference: Codable, Equatable, Sendable {
    enum Source: String, Codable { case bandcamp, itunes }

    var source: Source
    var artist: String
    var title: String
    var year: Int?
    var artworkURL: URL?
    var tracks: [ReferenceTrack]
}

/// Finds and keeps reference tracklists: Bandcamp first (its pages list the exact release),
/// then iTunes for music not sold there. Each album is looked up once; misses are retried after
/// a week.
@MainActor
@Observable
final class AlbumReferences {
    private(set) var references: [String: AlbumReference] = [:]
    @ObservationIgnored private var misses: [String: Date] = [:]
    @ObservationIgnored private var loading: [String: Task<AlbumReference?, Never>] = [:]

    private struct Saved: Codable {
        var references: [String: AlbumReference]
        var misses: [String: Date]
    }

    private static var cacheURL: URL {
        // v3: stricter title matching (tribute albums no longer count as the original).
        // v4: Apple's catalogue before Bandcamp, where anyone can upload an album's name.
        // v5: the album itself before an EP or single sharing its name.
        // v6: remasters, remixes and live albums keep their own tracklists.
        // v7: kept by AlbumIdentity's recording key.
        URL.applicationSupportDirectory.appending(path: "album-references-v7.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            references = saved.references
            misses = saved.misses
        }
    }

    /// Kept by recording (`AlbumIdentity`): a deluxe edition shares the standard one's tracklist,
    /// a remaster or live album has its own.
    static func key(_ album: AlbumKey) -> String {
        AlbumIdentity.recordingKey(album)
    }

    func cached(_ album: AlbumKey) -> AlbumReference? {
        references[Self.key(album)]
    }

    /// The album's tracklist. `page` is its Bandcamp release page when the files came from there.
    /// `page`: a Bandcamp page for the album. With `purchased`, it's the user's own purchase, so its
    /// tracklist describes their files and comes first; otherwise Apple's catalogue does.
    func reference(for album: AlbumKey, page: URL? = nil, purchased: Bool = false, trackCount: Int = 0) async -> AlbumReference? {
        let key = Self.key(album)
        if let found = references[key] { return found }
        if let missed = misses[key], missed.timeIntervalSinceNow > -7 * 86400 { return nil }
        if let pending = loading[key] { return await pending.value }
        let task = Task { await Self.lookUp(album, page: page, purchased: purchased, trackCount: trackCount) }
        loading[key] = task
        let found = await task.value
        loading[key] = nil
        if let found { references[key] = found } else { misses[key] = .now }
        save()
        return found
    }

    private func save() {
        try? JSONEncoder().encode(Saved(references: references, misses: misses)).write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Sources

    nonisolated static func lookUp(_ album: AlbumKey, page: URL?, purchased: Bool, trackCount: Int) async -> AlbumReference? {
        if purchased, let reference = await bandcamp(album, page: page) { return reference }
        // Apple's catalogue is curated; Bandcamp search finds fan uploads and bootlegs under
        // the same name, with the wrong tracklist.
        if let reference = await iTunes(album, trackCount: trackCount) { return reference }
        return purchased ? nil : await bandcamp(album, page: page)
    }

    nonisolated private static func bandcamp(_ album: AlbumKey, page: URL?) async -> AlbumReference? {
        var url = page
        if url == nil {
            let results = (try? await BandcampAPI.searchStore("\(album.artist) \(album.title)")) ?? []
            url = results.first { result in
                guard !result.isTrack else { return false }
                let split = ReleaseGrouper.splitLabelUpload(title: result.title, seller: result.artist)
                return ReleaseText.titlesMatch(split.title, album.title)
                    && (ReleaseText.artistsMatch(split.artist, album.artist) || ReleaseText.artistsMatch(result.artist, album.artist))
            }?.url
        }
        guard let url, let info = try? await BandcampAPI.release(at: url), !info.tracks.isEmpty else { return nil }
        return AlbumReference(source: .bandcamp, artist: info.artist ?? album.artist, title: album.title,
                              year: info.year, artworkURL: nil, tracks: info.tracks)
    }

    nonisolated private static func iTunes(_ album: AlbumKey, trackCount: Int) async -> AlbumReference? {
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [
            URLQueryItem(name: "term", value: "\(album.artist) \(album.title)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        func matching(_ results: [[String: Any]]) -> [String: Any]? {
            bestEdition(results.filter {
                ReleaseText.artistsMatch($0["artistName"] as? String ?? "", album.artist)
                    && ReleaseText.titlesMatch($0["collectionName"] as? String ?? "", album.title)
            }, title: album.title, atLeast: trackCount)
        }
        var found: [String: Any]?
        if let url = search.url, let (data, _) = try? await URLSession.shared.data(from: url),
           let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] {
            found = matching(results)
        }
        // Search can miss an artist's own album under songs of the same name by others ("Whole
        // Lotta Red"); the artist's catalogue has it.
        if found == nil { found = await artistAlbums(album.artist).flatMap(matching) }
        guard let match = found,
              let id = match["collectionId"] as? Int,
              let lookup = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=song"),
              let (songData, _) = try? await URLSession.shared.data(from: lookup),
              let songs = (try? JSONSerialization.jsonObject(with: songData) as? [String: Any])?["results"] as? [[String: Any]]
        else { return nil }
        let tracks = parseITunesTracks(songs)
        guard !tracks.isEmpty else { return nil }
        return AlbumReference(
            source: .itunes,
            artist: match["artistName"] as? String ?? album.artist,
            title: match["collectionName"] as? String ?? album.title,
            year: (match["releaseDate"] as? String).flatMap { Int($0.prefix(4)) },
            artworkURL: (match["artworkUrl100"] as? String)
                .map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }.flatMap(URL.init(string:)),
            tracks: tracks
        )
    }

    /// Every album in the artist's catalogue, for the artist named exactly.
    nonisolated private static func artistAlbums(_ artist: String) async -> [[String: Any]]? {
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = search.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let artists = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]],
              let id = artists.first(where: { ReleaseText.fold($0["artistName"] as? String ?? "") == ReleaseText.fold(artist) })?["artistId"] as? Int,
              let lookup = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=album&limit=200"),
              let (albumData, _) = try? await URLSession.shared.data(from: lookup),
              let results = (try? JSONSerialization.jsonObject(with: albumData) as? [String: Any])?["results"] as? [[String: Any]]
        else { return nil }
        return results.filter { $0["collectionId"] != nil }
    }

    /// The album itself among releases sharing its name. An EP or single under the album's name
    /// ("From Under the Cork Tree (Limited … Edition) - EP", 8 remixes and live songs) only when
    /// there's nothing else; then the edition named exactly as the album, if it has enough
    /// tracks; otherwise the smallest edition that does.
    nonisolated static func bestEdition(_ editions: [[String: Any]], title: String, atLeast count: Int) -> [String: Any]? {
        func name(_ edition: [String: Any]) -> String { edition["collectionName"] as? String ?? "" }
        func isShort(_ edition: [String: Any]) -> Bool { name(edition).hasSuffix(" - EP") || name(edition).hasSuffix(" - Single") }
        let albums = editions.filter { !isShort($0) }
        let pool = albums.isEmpty ? editions : albums
        let exact = pool.filter { AlbumIdentity.sameRelease(CatalogRelease.cleanTitle(name($0)), title) }
        if let edition = standardEdition(exact, atLeast: count), (edition["trackCount"] as? Int ?? 0) >= count {
            return edition
        }
        return standardEdition(pool, atLeast: count)
    }

    /// Of several editions (standard, deluxe, anniversary), the one with the fewest tracks that
    /// still has at least as many as the library: bonus discs aren't "missing".
    nonisolated static func standardEdition(_ editions: [[String: Any]], atLeast count: Int) -> [String: Any]? {
        let sized = editions.map { ($0, $0["trackCount"] as? Int ?? .max) }
        return (sized.filter { $0.1 >= count }.min { $0.1 < $1.1 } ?? sized.max { $0.1 < $1.1 })?.0
    }

    nonisolated static func parseITunesTracks(_ results: [[String: Any]]) -> [ReferenceTrack] {
        results.compactMap { item -> ReferenceTrack? in
            guard item["wrapperType"] as? String == "track", let title = item["trackName"] as? String else { return nil }
            return ReferenceTrack(
                number: item["trackNumber"] as? Int ?? 0,
                disc: item["discNumber"] as? Int ?? 1,
                title: title,
                duration: (item["trackTimeMillis"] as? Double).map { $0 / 1000 }
            )
        }
        .sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }
}

/// Which of a release's songs the library is missing, matched by title.
enum MissingTracks {
    static func missing(from reference: AlbumReference, have tracks: [Track]) -> [ReferenceTrack] {
        // Albums bought on Bandcamp are the official release, whatever their titles say.
        if !tracks.isEmpty, tracks.allSatisfy({ $0.sourceURL.contains("bandcamp.com") }) { return [] }
        let have = Set(tracks.map { ReleaseText.fold(ReleaseText.cleanTitle($0.title)) })
        // Extra discs (bonus material) only count once the library has something from them.
        let discs = Set(tracks.map { max($0.discNumber, 1) })
        return reference.tracks.filter { track in
            guard track.disc == 1 || discs.contains(track.disc) else { return false }
            let titled = track.matchTitles.contains { title in
                have.contains(title) || have.contains(where: { $0.count >= 4 && (title.hasPrefix($0 + " ") || $0.hasPrefix(title + " ")) })
            }
            // Same place on the album and the same length is the same song under another name.
            let placed = tracks.contains { have in
                have.trackNumber == track.number && max(have.discNumber, 1) == track.disc
                    && track.duration.map { abs($0 - have.duration) < 3 } == true
            }
            return !titled && !placed
        }
    }

    /// Cleaned-up song names of Soulseek files, worked out once per file: the clean-up uses
    /// regular expressions, and album pages match every song against every file.
    private static let names = NSCache<NSString, NSString>()

    static func matchName(of file: RemoteFile) -> String {
        if let cached = names.object(forKey: file.id as NSString) { return cached as String }
        let name = ReleaseText.fold(ReleaseText.trackName(file.name))
        names.setObject(name as NSString, forKey: file.id as NSString)
        return name
    }

    private static let bareNames = NSCache<NSString, NSString>()

    /// The name with everything in brackets dropped: "The Eternal (Live)" → "the eternal".
    static func bareName(of file: RemoteFile) -> String {
        if let cached = bareNames.object(forKey: file.id as NSString) { return cached as String }
        let name = ReferenceTitles.bare(ReleaseText.trackName(file.name))
        bareNames.setObject(name as NSString, forKey: file.id as NSString)
        return name
    }

    /// The file in a Soulseek folder that holds a song: by title in its name, then with anything
    /// in brackets ignored on both sides ("The Eternal (Live) [Encore]" is "20 The Eternal (Live)"),
    /// then by track number and length.
    static func file(for track: ReferenceTrack, in files: [RemoteFile]) -> RemoteFile? {
        let named = files.map { (file: $0, name: matchName(of: $0)) }
        for title in track.matchTitles where !title.isEmpty {
            if let match = named.first(where: { $0.name == title })
                ?? named.first(where: { $0.name.hasSuffix(" " + title) || $0.name.hasPrefix(title + " ") }) {
                return match.file
            }
        }
        let bare = ReferenceTitles.bare(track.title)
        if bare.count >= 3, let match = files.first(where: { bareName(of: $0) == bare }) {
            return match
        }
        guard track.number > 0, let duration = track.duration else { return nil }
        return files.first { file in
            leadingNumber(file.name) == track.number && file.duration.map { abs(Double($0) - duration) <= 4 } == true
        }
    }

    /// The download of a song among an album's downloads, wherever each came from: one going
    /// now first, then one that finished, then one that failed.
    @MainActor
    static func download(for track: ReferenceTrack, in transfers: [Transfer]) -> Transfer? {
        func rank(_ transfer: Transfer) -> Int {
            if transfer.state.isActive { return 0 }
            if transfer.state == .completed { return 1 }
            return 2
        }
        let ordered = transfers.sorted { rank($0) < rank($1) }
        guard let file = Self.file(for: track, in: ordered.map(\.file)) else { return nil }
        return ordered.first { $0.file.id == file.id }
    }

    /// "20 - The Eternal.flac" → 20.
    /// "Artist - Album - 02 Song.flac" → 2 as well.
    static func leadingNumber(_ name: String) -> Int? {
        if let number = name.firstMatch(of: /^\s*(\d{1,3})(?!\d)/).flatMap({ Int($0.output.1) }) { return number }
        return name.matches(of: /\s[-–—]\s+(\d{1,3})(?=[\s.\-_])/).last.flatMap { Int($0.output.1) }
    }
}

/// Cleaned-up reference titles, worked out once per title (the clean-up uses regular expressions).
enum ReferenceTitles {
    private static let single = NSCache<NSString, NSString>()
    private static let both = NSCache<NSString, NSArray>()

    static func match(_ title: String) -> String {
        if let cached = single.object(forKey: title as NSString) { return cached as String }
        let value = ReleaseText.fold(ReleaseText.cleanTitle(title))
        single.setObject(value as NSString, forKey: title as NSString)
        return value
    }

    /// The title as listed and without a leading "Artist - " (Bandcamp often lists songs as
    /// "Niontay featuring DORIS - 10/4", which imports as "10/4").
    private static let bares = NSCache<NSString, NSString>()

    /// Folded, with every bracketed part removed.
    static func bare(_ title: String) -> String {
        if let cached = bares.object(forKey: title as NSString) { return cached as String }
        let value = ReleaseText.fold(title.replacing(/\s*[\[\(\{][^\]\)\}]*[\]\)\}]/, with: ""))
        bares.setObject(value as NSString, forKey: title as NSString)
        return value
    }

    static func matches(_ title: String) -> [String] {
        if let cached = both.object(forKey: title as NSString) as? [String] { return cached }
        let parts = title.split(separator: /\s+[-–—]\s+/, maxSplits: 1).map(String.init)
        let value = parts.count == 2 ? [match(title), match(parts[1])] : [match(title)]
        both.setObject(value as NSArray, forKey: title as NSString)
        return value
    }
}
