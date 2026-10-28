import Foundation
import SwiftData

/// The app's own objects, wired together as SeekApp wires them, for the web version: the same
/// Soulseek client, search, tracklists, copy finding, adding and library.
@MainActor
final class Core {
    let container: ModelContainer
    let library: LibraryStore
    let client = SoulseekClient()
    let bandcamp = BandcampClient()
    let references = AlbumReferences()
    let copyFinder = CopyFinder()
    let storeVerifier = StoreVerifier()
    let resolver = FolderResolver()
    let adder = AlbumAdder()
    let search = SearchModel()
    let streamer: StreamService
    private(set) lazy var bandcampLogin = BandcampLogin(bandcamp: bandcamp)
    let quality = QualityPreference.cd
    /// Bumped whenever anything a page shows may have changed; pages refetch when it does.
    private(set) var version = 0

    /// The app's iCloud folder as iCloud Drive keeps it on this Mac, so the web and the phone
    /// share one library. A plain folder when this Mac doesn't have it.
    static var musicFolder: URL {
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~dev~olicarter~seek/Documents/Music", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: icloud.path) { return icloud }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Seek", directoryHint: .isDirectory)
    }

    /// The server's own song index, apart from the app's (which lives on the phone).
    static var storeFolder: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Seek Server", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init() {
        let schema = Schema([Track.self, Playlist.self, TrackInfo.self, Discovery.self, Favorite.self])
        let config = ModelConfiguration("Server", schema: schema, url: Self.storeFolder.appending(path: "Library.store"),
                                        cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Couldn't open the library index: \(error)")
        }
        library = LibraryStore(container: container)
        streamer = StreamService(client: client)
    }

    func start() async {
        library.start(folder: Self.musicFolder)
        client.importDownload = { [library] transfer, url in
            try await library.importDownload(at: url, remotePath: transfer.path, plannedPath: transfer.plannedPath,
                                             album: transfer.album)
        }
        client.reservePath = { [library] transfer in library.reservePath(forRemotePath: transfer.path) }
        client.keepReserved = { [library] path in library.keepReserved(path) }
        client.libraryHas = { [library] path in library.hasTrack(path: path) }
        client.libraryHasSong = { [library] name, path in library.hasSong(named: name, besides: path) }
        client.releaseReserved = { [library] path, abandoned in library.releaseReserved(path, abandoned: abandoned) }
        library.onAlbumsDeleted = { [client] folders in client.cancelDownloads(into: folders) }
        client.cacheStream = { [streamer] transfer, url in try streamer.store(transfer, from: url) }
        client.cachedFile = { [streamer] file in streamer.cachedURL(for: file) }
        bandcamp.importFile = { [library] url, folders, name in
            try await library.importFile(at: url, folders: folders, name: name)
        }
        bandcamp.replaceFiles = { [library] item, paths in
            library.replace(paths, withPurchaseFrom: item.itemURL)
        }
        client.restoreDownloads()
        bandcamp.restoreDownloads()
        Task { await bandcamp.refreshIfStale() }
        // Signed in for as long as the server runs: there's no app going into the background.
        client.searchViewAppeared()
        Task { await watch() }
        Task { await rescanNow() }
    }

    /// iCloud Drive brings the phone's additions here as files; read the folder for them now and then.
    private func rescanNow() async {
        while true {
            try? await Task.sleep(for: .seconds(60))
            library.rescan()
        }
    }

    // MARK: - Search

    func search(_ query: String) {
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
            "\(streamer.progress.count)", "\(bandcampLogin.isOpen)",
        ]
    }

    private func watch() async {
        var lastInputs: [String] = []
        var lastShown: [String] = []
        var lastArtists: [String] = []
        while true {
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
