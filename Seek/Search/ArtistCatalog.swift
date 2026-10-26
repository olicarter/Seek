import Foundation

/// One release from an artist's catalogue in Apple Music, used to put their main and latest
/// releases first when a search is for the artist.
struct CatalogRelease: Sendable, Equatable, Codable {
    enum Kind: Int, Sendable, Comparable, Codable {
        /// DJ mixes, remixes, sped-up and slowed versions: not what an artist search is after.
        case other, single, ep, album

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .album: "Album"
            case .ep: "EP"
            case .single: "Single"
            case .other: "Release"
            }
        }
    }

    var artist: String
    /// Without Apple's " - EP" / " - Single" suffixes, so it matches other sources' names.
    var title: String
    var kind: Kind
    var released: Date
    var trackCount: Int
    var artworkURL: URL?
    /// "℗ 2015 Rise Records", as under the songs on the album's page.
    var copyright: String? = nil

    var year: Int { Calendar.current.component(.year, from: released) }

    /// Main releases count most, and newer ones more: an album out this year leads.
    func boost(now: Date = .now) -> Double {
        let years = max(0, now.timeIntervalSince(released) / (365 * 24 * 3600))
        let recency = max(0, 6 - years)
        switch kind {
        case .album: return 30 + recency
        case .ep: return 18 + recency
        case .single: return 6 + recency / 2
        case .other: return 0
        }
    }

    static func kind(of name: String, trackCount: Int) -> Kind {
        let folded = ReleaseText.fold(name)
        // Whole words, so "Credit" isn't taken for an edit.
        if folded.range(of: #"\b(dj mix|remix|remixes|slowed|sped up|edit|instrumentals?|mixed)\b"#, options: .regularExpression) != nil {
            return .other
        }
        if name.hasSuffix(" - Single") || trackCount <= 3 { return .single }
        if name.hasSuffix(" - EP") || trackCount <= 6 { return .ep }
        return .album
    }

    /// Also without a featured artist credit ("Iconicy (feat. MINIKINGZ)"): the library and
    /// Soulseek copies seldom have one.
    static func cleanTitle(_ name: String) -> String {
        var title = name
        for suffix in [" - Single", " - EP"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        let featuring = title.replacing(/(?i)\s*[\(\[](feat\.?|featuring|ft\.)\s[^\)\]]*[\)\]]/, with: "")
        return featuring.isEmpty ? title : featuring
    }
}

/// Looks up the artist a search is for in Apple Music's catalogue, once per search.
@MainActor
enum ArtistCatalog {
    private static var cache: [String: [CatalogRelease]] = [:]

    /// The artist's releases when the search is an artist's name, otherwise nothing.
    static func releases(for query: String) async -> [CatalogRelease] {
        let key = ReleaseText.fold(query)
        guard key.count >= 3 else { return [] }
        if let cached = cache[key] { return cached }
        let found = await fetch(query)
        cache[key] = found
        return found
    }

    /// A search's artists' releases that it names, for a search that isn't an artist's name
    /// ("copacetic"): the artists come from what the search found. They tell editions apart:
    /// without them a remaster's copies ("Copacetic (Remixed & Remastered)") read as the
    /// original with an edition note and joined it, so the remaster never showed.
    static func releases(named query: String, by artists: [String]) async -> [CatalogRelease] {
        var found: [CatalogRelease] = []
        for artist in artists {
            found += await releases(for: artist).filter { mentions(query, artist: $0.artist, title: $0.title) }
        }
        return found
    }

    /// Whether a release has every word searched for, in its artist or title.
    nonisolated static func mentions(_ query: String, artist: String, title: String) -> Bool {
        let named = Set(ReleaseText.fold("\(artist) \(title)").split(separator: " "))
        let words = ReleaseText.fold(query).split(separator: " ")
        return !words.isEmpty && words.allSatisfy(named.contains)
    }

    nonisolated private static func fetch(_ query: String) async -> [CatalogRelease] {
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = search.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let artists = try? JSONDecoder().decode(Response<Artist>.self, from: data).results,
              // Only when the search is the artist's name, not a song or album that mentions them.
              let artist = artists.first(where: { ReleaseText.fold($0.artistName) == ReleaseText.fold(query) }),
              let lookup = URL(string: "https://itunes.apple.com/lookup?id=\(artist.artistId)&entity=album&limit=200"),
              let (albumData, _) = try? await URLSession.shared.data(from: lookup),
              let albums = try? JSONDecoder().decode(Response<Album>.self, from: albumData).results
        else { return [] }
        let dates = ISO8601DateFormatter()
        return albums.compactMap { album in
            guard let name = album.collectionName, let count = album.trackCount,
                  let released = album.releaseDate.flatMap(dates.date) else { return nil }
            return CatalogRelease(
                artist: album.artistName ?? artist.artistName,
                title: CatalogRelease.cleanTitle(name),
                kind: CatalogRelease.kind(of: name, trackCount: count),
                released: released,
                trackCount: count,
                artworkURL: album.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
                copyright: album.copyright
            )
        }
    }

    private struct Response<T: Decodable>: Decodable {
        let results: [T]
    }

    private struct Artist: Decodable {
        let artistId: Int
        let artistName: String
    }

    /// Lookup results start with the artist itself, which has none of these, so all are optional.
    private struct Album: Decodable {
        let collectionName: String?
        let artistName: String?
        let trackCount: Int?
        let releaseDate: String?
        let artworkUrl100: String?
        let copyright: String?
    }
}

extension CatalogRelease {
    /// Whether a search result is this release, by title and artist (either may be a collaboration).
    func matches(_ release: SearchRelease) -> Bool {
        // A double A-side's copies are often named for the first side alone.
        let sides = AlbumIdentity.sides(title)
        guard ReleaseText.titlesMatch(release.title, title)
            || sides.count > 1 && ReleaseText.titlesMatch(release.title, sides[0]) else { return false }
        let mine = ReleaseText.fold(artist), theirs = ReleaseText.fold(release.artist)
        return ReleaseText.artistsMatch(release.artist, artist) || mine.contains(theirs) || theirs.contains(mine)
    }
}

extension CatalogRelease {
    /// The album in its artist's catalogue: the very release, or failing that the same recording.
    static func release(of title: String, in catalog: [CatalogRelease]) -> CatalogRelease? {
        catalog.first { AlbumIdentity.sameRelease($0.title, title) }
            ?? catalog.first { AlbumIdentity.sameRecording($0.title, title) }
    }

    /// The album's other releases, as Apple Music lists under "Other Versions": the same name
    /// remastered, remixed, live or in another edition, newest first, each once. Singles named
    /// after a song on it aren't versions of it.
    static func otherVersions(of title: String, in catalog: [CatalogRelease]) -> [CatalogRelease] {
        let album = AlbumIdentity.title(title)
        var seen: Set<String> = [album.releaseKey]
        return catalog
            .sorted { $0.released > $1.released }
            .filter { release in
                let name = AlbumIdentity.title(release.title)
                return release.kind != .single && name.core == album.core && seen.insert(name.releaseKey).inserted
            }
    }
}
