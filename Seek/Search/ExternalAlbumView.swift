import SwiftData
import SwiftUI

/// An album known only by name, e.g. a suggestion: opened like any album page.
struct ExternalAlbum: Hashable {
    var artist: String
    var title: String
    var artworkURL: URL?

    var key: AlbumKey { AlbumKey(artist: artist, title: title) }
}

/// The album page for music that isn't in the library yet. It gathers every source Seek can
/// match the album to (Bandcamp purchases and store, the reference tracklist, Soulseek copies)
/// and shows them as one release, filling in as each answers. Albums already in the library
/// open their library page instead.
struct ExternalAlbumView: View {
    let album: ExternalAlbum
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(SoulseekClient.self) private var client
    @Environment(AlbumReferences.self) private var references
    @Environment(CopyFinder.self) private var copyFinder
    @Environment(StoreVerifier.self) private var storeVerifier
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd
    @Environment(LibraryStore.self) private var library
    @State private var store: BandcampAPI.StoreResult?
    @State private var buying: StorePurchase?
    /// The library's album, if it was already there when the page opened. One added while the
    /// page is open keeps this page (its songs show their downloads), rather than swapping to the
    /// library's page, which jumped back to the top.
    @State private var openedOwned: AlbumKey??

    var body: some View {
        let release = self.release
        let ownedNow = library.index.album(for: release, named: true)
        Group {
            if let owned = openedOwned ?? ownedNow {
                AlbumDetailView(key: owned)
            } else {
                ReleaseDetailView(release: { self.release }, buying: $buying, soulseekStatus: copyFinder.copies(of: album.key)?.status)
                    .fullScreenCover(item: $buying) { BandcampStoreView(result: $0.result, buyNow: $0.price, replacing: $0.replacing) }
            }
        }
        .onAppear { if openedOwned == nil { openedOwned = .some(ownedNow) } }
        .task(id: album) {
            async let found = bandcamp.storeRelease(artist: album.artist, title: album.title)
            _ = await references.reference(for: album.key)
            // Not a fan upload of the same name: its songs must agree with Apple's tracklist.
            if let candidate = await found, await storeVerifier.isGenuine(candidate, as: album.key, references: references) {
                store = candidate
            }
            if client.savedUsername != nil { copyFinder.find(album.key, client: client, quality: quality) }
        }
    }

    /// Everything known so far, as one release.
    private var release: SearchRelease {
        let reference = references.cached(album.key)
        let owned = store.flatMap(bandcamp.owned) ?? bandcamp.ownedRelease(artist: album.artist, title: album.title)
        return SearchRelease(
            id: "ext-\(AlbumReferences.key(album.key))",
            artist: album.artist,
            title: album.title,
            year: reference?.year,
            owned: owned,
            store: store,
            folders: copyFinder.copies(of: album.key)?.folders ?? [],
            fallbackArtwork: album.artworkURL ?? reference?.artworkURL,
            trustedArtwork: album.artworkURL ?? (reference?.source == .itunes ? reference?.artworkURL : nil)
        )
    }
}
