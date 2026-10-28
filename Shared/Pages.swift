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
    }

    struct Album: Codable, Sendable {
        var artist: String
        var title: String
        var year: Int?
        var artwork: String?
        var songs: [Song]
        var footer: String
        /// "2026-07-31", the release day (UTC, as Apple dates them), and the ℗ line.
        var released: String?
        var copyright: String?
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
