import Foundation
import Observation

/// One search across Soulseek, the Bandcamp store and purchases, and Apple's catalogue,
/// grouped into releases. The app's Search tab and the server both run their searches through
/// this, so they find and group the same things.
@MainActor
@Observable
final class SearchModel {
    /// The search last run (submitted), as opposed to what's being typed.
    private(set) var submitted = ""
    private(set) var storeFound: [BandcampAPI.StoreResult] = []
    /// The artist's Apple Music catalogue, when the search is an artist's name.
    private(set) var catalogFound: [CatalogRelease] = []
    var losslessOnly = false
    var freeSlotsOnly = false
    let results = SearchResults()
    /// What the store and catalogue results above are for, and how many songs the library index
    /// was built from. Coming back to the search reruns the loading; with these it keeps what
    /// it has, so the list doesn't briefly reorder without them.
    @ObservationIgnored private var storeLoadedFor: String?
    @ObservationIgnored private var indexedTrackCount: Int?
    /// Rebuilt only when the library changes, never while typing.
    @ObservationIgnored private var libraryIndex = LibraryIndex(albums: [])

    func submit(_ text: String, client: SoulseekClient) {
        begin(text)
        client.search(submitted)
    }

    /// The search to group, without starting it: for the Mac grouping a device's search, whose
    /// folders arrive by another way (see AppSearches).
    func begin(_ text: String) {
        submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Soulseek's results for the search run, opened folders showing every file.
    func folders(client: SoulseekClient) -> [RemoteFolder] {
        let search = client.currentSearch.flatMap { $0.query == submitted ? $0 : nil }
        return (search?.folders ?? []).map(client.complete)
            .filter { (!losslessOnly || $0.isLossless) && (!freeSlotsOnly || $0.hasFreeSlot) }
    }

    /// The Bandcamp store and Apple's catalogue for the search run, once per search.
    func loadSources(bandcamp: BandcampClient) async {
        let submitted = submitted
        guard storeLoadedFor != submitted else { return }
        storeFound = []
        catalogFound = []
        guard !submitted.isEmpty else { return }
        async let catalog = ArtistCatalog.releases(for: submitted)
        let found = await bandcamp.storeSearch(submitted)
        let releases = await catalog
        guard !Task.isCancelled, submitted == self.submitted else { return }
        storeFound = found
        catalogFound = releases
        storeLoadedFor = submitted
    }

    /// The artists of the top few releases found, whose catalogues can tell their editions apart.
    var resultArtists: [String] {
        var artists: [String] = []
        for release in results.result.releases where !release.folders.isEmpty && release.artist != "Unknown Artist" {
            if !artists.contains(where: { ReleaseText.artistsMatch($0, release.artist) }) { artists.append(release.artist) }
            if artists.count == 3 { break }
        }
        return artists
    }

    /// Not an artist's name: the catalogues of the artists found, for the releases named.
    func loadNamedReleases() async {
        let artists = resultArtists
        guard storeLoadedFor == submitted, !submitted.isEmpty, !artists.isEmpty,
              catalogFound.allSatisfy({ !ReleaseText.artistsMatch($0.artist, submitted) }) else { return }
        let named = await ArtistCatalog.releases(named: submitted, by: artists)
        guard !Task.isCancelled, !named.isEmpty else { return }
        let known = Set(catalogFound.map { "\($0.artist)|\($0.title)|\($0.released)" })
        catalogFound += named.filter { !known.contains("\($0.artist)|\($0.title)|\($0.released)") }
    }

    /// Whether the library index needs rebuilding for these songs.
    func needsIndex(trackCount: Int) -> Bool { indexedTrackCount != trackCount }

    /// The library's albums, so releases already there show as such.
    func indexLibrary(_ tracks: [Track]) async {
        let count = tracks.count
        let keys = Array(Set(tracks.map(\.albumKey)))
        libraryIndex = await Task.detached { LibraryIndex(albums: keys) }.value
        indexedTrackCount = count
    }

    /// Regroups everything found. `typing`: the search field's text, matched against what's been
    /// found so far until it's submitted.
    func regroup(_ timing: SearchResults.Timing = .now, typing: String = "", client: SoulseekClient,
                 bandcamp: BandcampClient, resolver: FolderResolver, storeVerifier: StoreVerifier,
                 quality: QualityPreference, folders found: [RemoteFolder]? = nil) {
        // Grouped by Seek on the Mac already, from the same sources: shown as it is, unless a
        // different search is being typed or the filters (which the Mac doesn't apply) are on.
        if found == nil, client.usingMac, !losslessOnly, !freeSlotsOnly, typing.isEmpty || typing == submitted,
           let grouped = client.currentSearch.flatMap({ $0.query == submitted ? $0.grouped : nil }) {
            results.show(grouped)
            return
        }
        results.update(
            query: submitted.isEmpty ? typing : submitted,
            owned: bandcamp.search(typing.isEmpty ? submitted : typing),
            store: bandcamp.storeResults(for: submitted, found: storeFound).filter { !storeVerifier.rejected.contains($0.id) },
            folders: found ?? folders(client: client),
            resolver: resolver,
            library: libraryIndex,
            wishlist: Set(bandcamp.wishlist.map(\.id)),
            quality: quality,
            // Only for the search it was looked up for, not one being typed.
            catalog: typing.isEmpty || typing == submitted ? catalogFound : [],
            timing: timing
        )
    }
}
