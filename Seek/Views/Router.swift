import SwiftUI

/// Tab selection and the library navigation stacks, so screens outside a stack (like Now
/// Playing) can open an album or artist.
@MainActor
@Observable
final class Router {
    var selection: AppTab = .library
    var isCompact = true

    /// The iPhone Library tab.
    var libraryPath = NavigationPath()
    /// The iPad library tabs.
    var artistsPath = NavigationPath()
    var albumsPath = NavigationPath()
    var songsPath = NavigationPath()
    var playlistsPath = NavigationPath()
    var labelsPath = NavigationPath()
    var favoritesPath = NavigationPath()

    /// A search for the Search tab to run, e.g. from a discovery suggestion.
    var pendingSearch: String?

    func search(_ text: String) {
        pendingSearch = text
        selection = .soulseek
    }

    func show(_ album: AlbumKey) {
        if isCompact {
            selection = .library
            libraryPath = NavigationPath([album])
        } else {
            selection = .albums
            albumsPath = NavigationPath([album])
        }
    }

    /// An album that isn't in the library, e.g. one playing from Soulseek.
    func show(_ album: ExternalAlbum) {
        if isCompact {
            selection = .library
            libraryPath = NavigationPath([album])
        } else {
            selection = .albums
            albumsPath = NavigationPath([album])
        }
    }

    func show(_ artist: ArtistKey) {
        if isCompact {
            selection = .library
            libraryPath = NavigationPath([artist])
        } else {
            selection = .artists
            artistsPath = NavigationPath([artist])
        }
    }
}
