import Foundation
import SwiftData

/// Seek on the web, served by the Mac app: the app's own objects (its Soulseek client, library,
/// tracklists, copy finding and adding), with a search of the web's own.
@MainActor
final class Core {
    let library: LibraryStore
    let client: SoulseekClient
    let bandcamp: BandcampClient
    let references: AlbumReferences
    let copyFinder: CopyFinder
    let storeVerifier: StoreVerifier
    let resolver: FolderResolver
    let adder: AlbumAdder
    let streamer: StreamService
    /// Album and artist descriptions (with their similar music), set by the app.
    var about: AlbumAbout?
    /// The web's search, apart from the app's Search tab (both use the one Soulseek client).
    let search = SearchModel()
    /// Searches run for an iPhone or iPad using this Mac (see AppAPI).
    let appSearches = AppSearches()
    let quality = QualityPreference.cd
    /// Listening together: the session, kept here.
    private(set) lazy var jam = JamHost(core: self)
    /// Bumped whenever anything a page shows may have changed; pages refetch when it does.
    private(set) var version = 0
    private var watching: Task<Void, Never>?

    /// Keys and passkeys for the web, kept with the app's data.
    nonisolated static var storeFolder: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Seek Server", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init(library: LibraryStore, client: SoulseekClient, bandcamp: BandcampClient, references: AlbumReferences,
         copyFinder: CopyFinder, storeVerifier: StoreVerifier, resolver: FolderResolver, adder: AlbumAdder, streamer: StreamService) {
        self.library = library
        self.client = client
        self.bandcamp = bandcamp
        self.references = references
        self.copyFinder = copyFinder
        self.storeVerifier = storeVerifier
        self.resolver = resolver
        self.adder = adder
        self.streamer = streamer
    }

    /// The library's folder, for serving its songs.
    var musicFolder: URL? { library.root }

    func start() {
        guard watching == nil else { return }
        watching = Task { await watch() }
    }

    func stop() {
        watching?.cancel()
        watching = nil
    }

    // MARK: - Search

    func search(_ query: String) async {
        await client.connectIfNeeded()
        search.submit(query, client: client)
        regroup()
        Task {
            await search.loadSources(bandcamp: bandcamp)
            regroup()
        }
    }

    private func regroup(_ timing: SearchResults.Timing = .now) {
        search.regroup(timing, client: client, bandcamp: bandcamp, resolver: resolver,
                       storeVerifier: storeVerifier, quality: quality)
    }

    // MARK: - Bandcamp

    private var watchingPurchase: Task<Void, Never>?

    /// Bought on Bandcamp's own page, in another tab: the collection is read again every half
    /// minute for a quarter of an hour, so the purchase turns up here once it's done.
    func watchForPurchase() {
        watchingPurchase?.cancel()
        let before = bandcamp.items.count
        watchingPurchase = Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await bandcamp.refresh()
                if bandcamp.items.count > before { return }
            }
        }
    }

    // MARK: - Watching

    /// What the search groups from: when any of it changes, it's grouped again (as SearchView's
    /// triggers do).
    private var searchInputs: [String] {
        [search.submitted, "\(search.storeFound.count - storeVerifier.rejected.count)", "\(search.catalogFound.count)",
         "\(search.folders(client: client).count)", "\(resolver.hints.count)", "\(client.folderContents.count)",
         "\(library.allTracks.count)"]
    }

    /// Everything pages show, roughly: a change bumps `version`.
    private var shown: [String] {
        let transfers = client.transfers.filter { !$0.forStreaming }
        return [
            "\(client.status)", client.savedUsername ?? "",
            "\(transfers.count)", "\(transfers.reduce(UInt64(0)) { $0 + $1.bytesReceived / 65536 })",
            transfers.map(\.state.label).joined(separator: ","),
            "\(search.results.result.releases.count)", search.results.result.releases.map(\.id).joined(separator: ","),
            "\(search.results.result.releases.reduce(0) { $0 + $1.folders.count })",
            "\(library.allTracks.count)", adder.checking.sorted().joined(separator: ","), adder.failure.map { "\($0.album)" } ?? "",
            "\(references.references.count)", "\(AppleCovers.shared.version)",
            bandcamp.username ?? "", "\(bandcamp.items.count)", "\(bandcamp.prices.count)",
            bandcamp.downloads.map { "\($0.state)\(Int(($0.ringProgress ?? 0) * 50))" }.joined(separator: ","),
            "\(streamer.progress.count)", "\(jam.jam?.version ?? -1)",
        ]
    }

    private func watch() async {
        var lastInputs: [String] = []
        var lastShown: [String] = []
        var lastArtists: [String] = []
        while !Task.isCancelled {
            let inputs = searchInputs
            if inputs != lastInputs {
                // A library change rebuilds the index of what's already there first.
                if search.needsIndex(trackCount: library.allTracks.count) { await search.indexLibrary(library.allTracks) }
                regroup(inputs.first == lastInputs.first ? .throttled : .now)
                lastInputs = inputs
            }
            let artists = search.resultArtists
            if artists != lastArtists {
                lastArtists = artists
                Task { await search.loadNamedReleases() }
            }
            let now = shown
            if now != lastShown {
                lastShown = now
                version += 1
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
