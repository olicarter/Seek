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

    static func cleanTitle(_ name: String) -> String {
        for suffix in [" - Single", " - EP"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
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
                artworkURL: album.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
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
    }
}

extension CatalogRelease {
    /// Whether a search result is this release, by title and artist (either may be a collaboration).
    func matches(_ release: SearchRelease) -> Bool {
        guard ReleaseText.titlesMatch(release.title, title) else { return false }
        let mine = ReleaseText.fold(artist), theirs = ReleaseText.fold(release.artist)
        return ReleaseText.artistsMatch(release.artist, artist) || mine.contains(theirs) || theirs.contains(mine)
    }
}
