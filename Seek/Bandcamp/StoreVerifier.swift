import Foundation
import Observation

/// Checks Bandcamp store matches against Apple's tracklist. Bandcamp search turns up fan uploads
/// and bootlegs under an album's name ("whole lotta red", one song); where Apple's catalogue has
/// the album, a Bandcamp release whose songs don't agree with it isn't offered for sale.
@MainActor
@Observable
final class StoreVerifier {
    /// Store releases found not to be the album they matched.
    private(set) var rejected: Set<Int> = []
    @ObservationIgnored private var checked: Set<Int> = []

    /// Checks once per store release, for releases Apple's catalogue knows.
    func verify(_ store: BandcampAPI.StoreResult, as album: AlbumKey, references: AlbumReferences) {
        guard checked.insert(store.id).inserted else { return }
        Task { _ = await isGenuine(store, as: album, references: references) }
    }

    /// Whether the store release is the album, as far as Apple's tracklist can tell (true when
    /// Apple doesn't know the album or the page can't be read).
    func isGenuine(_ store: BandcampAPI.StoreResult, as album: AlbumKey, references: AlbumReferences) async -> Bool {
        if rejected.contains(store.id) { return false }
        checked.insert(store.id)
        guard let apple = await references.reference(for: album), apple.source == .itunes,
              let info = try? await BandcampAPI.release(at: store.url), !info.tracks.isEmpty,
              !Self.tracklistsAgree(apple: apple.tracks, bandcamp: info.tracks) else { return true }
        Log.debug("store: \(store.title) by \(store.artist) has \(info.tracks.count) songs unlike Apple's \(apple.tracks.count); not offering it")
        rejected.insert(store.id)
        return false
    }

    /// Most of Bandcamp's songs are on Apple's tracklist, and it has at least half of Apple's.
    /// (A deluxe edition with extra songs still agrees.)
    nonisolated static func tracklistsAgree(apple: [ReferenceTrack], bandcamp: [ReferenceTrack]) -> Bool {
        guard !apple.isEmpty, !bandcamp.isEmpty else { return true }
        let shared = bandcamp.filter { track in apple.contains { ReleaseText.titlesMatch($0.title, track.title) } }.count
        return shared * 2 >= bandcamp.count && bandcamp.count * 2 >= apple.count
    }
}
