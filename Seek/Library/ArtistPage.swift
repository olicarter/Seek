import Foundation

/// What an artist's page shows, for the app's and the server's alike.
@MainActor
enum ArtistPage {
    /// Their albums, and their songs on other people's (e.g. compilations), but not the rest of those.
    static func tracks(of name: String, in tracks: [Track]) -> [Track] {
        tracks.filter { $0.albumKey.artist == name || $0.artist == name }
    }

    /// The headings the rest of an artist's catalogue goes under, as in Apple Music.
    enum Section: String, CaseIterable {
        case albums = "Albums"
        case singles = "Singles & EPs"
        case other = "Remixes & Mixes"

        var kinds: [CatalogRelease.Kind] {
            switch self {
            case .albums: [.album]
            case .singles: [.ep, .single]
            case .other: [.other]
            }
        }
    }

    /// Releases the library doesn't have, newest first, each once (Apple lists clean and explicit
    /// versions separately). Only the very release in the library is left out: its deluxe
    /// edition, or an EP sharing its name, is a release of its own and is listed.
    static func missing(from catalog: [CatalogRelease], owned: [Album]) -> [CatalogRelease] {
        let have = Set(owned.map { AlbumIdentity.title($0.title).releaseKey })
        var seen = Set<String>()
        return catalog
            .sorted { $0.released > $1.released }
            .filter { release in
                let name = AlbumIdentity.title(release.title).releaseKey
                return !have.contains(name) && seen.insert(name).inserted
            }
    }
}
