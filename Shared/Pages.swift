import Foundation

/// The pages the Mac app serves (Seek/WebServer) as JSON: what the site on 4n.studio and the
/// Apple TV app show. Built from the app's own models, so a page lists what the same page in
/// the app does; one copy of these types, for the server encoding them and the TV decoding them.
enum Pages {
    struct Status: Codable, Sendable {
        var soulseek: String
        var username: String?
        var signedIn: Bool
        var downloading: Int
        var failure: String?
        var bandcamp: String?
    }

    struct Release: Codable, Sendable {
        var id: String
        var artist: String
        var title: String
        var year: Int?
        var kind: String?
        var artwork: String?
        var copies: Int
        var lossless: Bool
        /// TIDAL's tier of the copy Seek would pick (SoundQuality).
        var quality: SoundQuality? = nil
        var bandcamp: Bool
        var inLibrary: Bool
        var adding: Bool
    }

    struct Search: Codable, Sendable {
        var query: String
        var searching: Bool
        var releases: [Release]
    }

    struct Song: Codable, Sendable {
        /// "have" (in the library), "missing" (on the tracklist, not here) or "arriving".
        var kind: String
        var number: Int?
        var disc: Int
        var title: String
        var artist: String?
        var duration: Double?
        /// What to play: the library's file, or for a song that isn't here, the server's stream of
        /// it from Soulseek (or Bandcamp's player).
        var file: String?
        /// For missing songs: some copy has it.
        var available: Bool
        /// 0–1 while downloading.
        var progress: Double?
        var lossless: Bool?
        var quality: SoundQuality? = nil
        /// "128 · 8A", for songs in the library (Camelot codes).
        var tempoAndKey: String? = nil
    }

    struct Album: Codable, Sendable {
        var artist: String
        var title: String
        var year: Int?
        var artwork: String?
        var preview: String? = nil
        var songs: [Song]
        var footer: String
        /// "2026-07-31", the release day (UTC, as Apple dates them), and the ℗ line.
        var released: String?
        var copyright: String?
        /// The page's colour from the cover, "#1e3f6e" (see ArtworkColor).
        var tint: String? = nil
        /// The album's tier (its lowest song's, or its best copy's) and "24-bit, 96 kHz".
        var quality: SoundQuality? = nil
        var qualityDetail: String? = nil
        /// Has a tracklist (Apple's or Bandcamp's): adding adds exactly it.
        var listed: Bool
        var inLibrary: Bool
        var canAdd: Bool
        var adding: Bool
        var lookingForCopies: Bool
        var copies: Int
        var bandcamp: Bandcamp?
    }

    struct Bandcamp: Codable, Sendable {
        /// In the collection: adding takes the purchase's own files.
        var owned: Bool
        /// The album's page, to buy it there.
        var page: String?
        var price: String?
        var downloading: Double?
    }

    struct CatalogEntry: Codable, Sendable {
        var title: String
        var year: Int
        var artwork: String?
        /// In the library: its album page is the library's, under `artist` (its own album artist).
        var inLibrary: Bool? = nil
        var artist: String? = nil
        var preview: String? = nil
    }

    struct ArtistSection: Codable, Sendable {
        var title: String
        var releases: [CatalogEntry]
    }

    struct Artist: Codable, Sendable {
        var name: String
        var albums: [LibraryAlbum]
        var sections: [ArtistSection]
    }

    struct LibraryAlbum: Codable, Sendable {
        var artist: String
        var title: String
        var year: Int?
        var artwork: String
        /// A tiny copy of the cover (a data: URL), shown pixelated until it's in.
        var preview: String? = nil
        var songs: Int
    }

    struct Download: Codable, Sendable {
        var id: String
        var name: String
        var album: String
        var user: String
        var state: String
        var active: Bool
        var progress: Double
        var speed: Double
    }
}
