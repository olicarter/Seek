import SwiftData
import SwiftUI

@main
struct SeekApp: App {
    private let container: ModelContainer
    @State private var library: LibraryStore
    @State private var player: Player
    @State private var client: SoulseekClient
    @State private var bandcamp = BandcampClient()
    @State private var newPlaylist = NewPlaylistPrompt()
    @State private var router = Router()
    @State private var discovery: DiscoveryService
    @State private var about: AlbumAbout
    @State private var folderResolver = FolderResolver()
    @State private var albumReferences = AlbumReferences()
    @State private var copyFinder = CopyFinder()
    @State private var albumAdder = AlbumAdder()
    @State private var storeVerifier = StoreVerifier()
    @State private var streamer: StreamService
    @State private var sharing: SharingService
    @State private var analysis: SongAnalysisStore
    #if targetEnvironment(macCatalyst)
    /// Seek on the web, served from this Mac (see WebServer).
    @State private var web: WebServer?
    #endif

    init() {
        SyncReport.start()
        let container = LibraryStore.makeContainer()
        let library = LibraryStore(container: container)
        self.container = container
        _library = State(initialValue: library)
        _player = State(initialValue: Player(library: library))
        _discovery = State(initialValue: DiscoveryService(container: container))
        _about = State(initialValue: AlbumAbout(container: container))
        let client = SoulseekClient()
        _client = State(initialValue: client)
        _streamer = State(initialValue: StreamService(client: client))
        let sharing = SharingService(library: library)
        client.sharing = sharing
        sharing.onChange = { [weak client] in client?.shareCountsChanged() }
        library.onLibraryChanged = { [weak sharing] in sharing?.libraryChanged() }
        _sharing = State(initialValue: sharing)
        _analysis = State(initialValue: SongAnalysisStore(library: library))
        #if !targetEnvironment(macCatalyst)
        // The person's Mac, when it's reachable, does the Soulseek work (see MacLink).
        client.macLink = MacLink(client: client)
        #endif
        AppleCovers.shared.onCoversChanged = { ArtworkImages.invalidate() }
        library.onArtworkChanged = { keys in
            if let keys { ArtworkImages.forget(keys) } else { ArtworkImages.invalidate() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // On Mac the system accent colour would replace Seek's own.
                .tint(Color("AccentColor"))
                // A song shared from Shazam or Apple Music, or a seek://search link.
                .onOpenURL { url in
                    Task {
                        if let query = await SharedSong.query(for: url) { router.search(query) }
                    }
                }
                .task {
                    // Developer tool: run one search, save it, quit. Nothing else starts.
                    if let query = SearchDump.requestedQuery {
                        await SearchDump.run(query, client: client)
                        exit(0)
                    }
                    await library.start()
                    await client.macLink?.check(force: true)
                    #if targetEnvironment(macCatalyst)
                    // The Mac works out tempo and key for the library; the others read its results.
                    analysis.run()
                    #else
                    analysis.load()
                    #endif
                    client.importDownload = { [library, albumReferences] transfer, url in
                        // Added as part of an album with a known tracklist: named from it.
                        let song = transfer.album.flatMap { albumReferences.cached($0) }
                            .flatMap { MissingTracks.song(for: transfer.file, in: $0) }
                        return try await library.importDownload(at: url, remotePath: transfer.path, plannedPath: transfer.plannedPath,
                                                                album: transfer.album, song: song)
                    }
                    client.reservePath = { [library] transfer in library.reservePath(forRemotePath: transfer.path) }
                    client.keepReserved = { [library] path in library.keepReserved(path) }
                    client.libraryHas = { [library] path in library.hasTrack(path: path) }
                    client.libraryHasSong = { [library] name, path in library.hasSong(named: name, besides: path) }
                    client.releaseReserved = { [library] path, abandoned in library.releaseReserved(path, abandoned: abandoned) }
                    bandcamp.importFile = { [library] url, folders, name in
                        try await library.importFile(at: url, folders: folders, name: name)
                    }
                    library.onAlbumImported = { [discovery] album in discovery.albumAdded(album) }
                    library.isInUse = { [player] path in player.current?.path == path }
                    library.onAlbumsDeleted = { [client] folders in client.cancelDownloads(into: folders) }
                    // An album added as one that couldn't be: what arrived goes, and the app says so.
                    client.onAddGroupFailed = { [library, albumAdder] album, songs, arrived in
                        let paths = Set(arrived)
                        library.delete(library.allTracks.filter { paths.contains($0.path) })
                        if let album { albumAdder.failure = (album, songs) }
                    }
                    player.streamer = streamer
                    client.cacheStream = { [streamer] transfer, url in try streamer.store(transfer, from: url) }
                    client.cachedFile = { [streamer] file in streamer.cachedURL(for: file) }
                    bandcamp.replaceFiles = { [library] item, paths in
                        library.replace(paths, withPurchaseFrom: item.itemURL)
                    }
                    discovery.resumePending()
                    #if DEBUG
                    if PerfHarness.requestedImports > 0 {
                        Task { await PerfHarness.run(PerfHarness.requestedImports, library: library) }
                    }
                    #endif
                    #if targetEnvironment(macCatalyst)
                    if web == nil {
                        let server = WebServer(core: Core(
                            library: library, client: client, bandcamp: bandcamp, references: albumReferences,
                            copyFinder: copyFinder, storeVerifier: storeVerifier, resolver: folderResolver,
                            adder: albumAdder, streamer: streamer))
                        web = server
                        server.start()
                    }
                    #endif
                    // Only once the library can take the files.
                    client.restoreDownloads()
                    bandcamp.restoreDownloads()
                    await bandcamp.refreshIfStale()
                }
        }
        .modelContainer(container)
        .environment(library)
        .environment(player)
        .environment(client)
        .environment(bandcamp)
        .environment(newPlaylist)
        .environment(router)
        .environment(discovery)
        .environment(about)
        .environment(folderResolver)
        .environment(albumReferences)
        .environment(copyFinder)
        .environment(storeVerifier)
        .environment(streamer)
        .environment(sharing)
        .environment(analysis)
        .environment(albumAdder)
        #if targetEnvironment(macCatalyst)
        .environment(web)
        #endif
        .commands {
            PlaybackCommands(player: player, router: router)
        }
    }
}

/// Menu bar commands (Mac and iPad with a keyboard), matching Apple Music's shortcuts.
struct PlaybackCommands: Commands {
    let player: Player
    let router: Router

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.current == nil)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.current == nil)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.current == nil)
            Divider()
            Button(player.shuffle ? "Turn Off Shuffle" : "Shuffle") { player.toggleShuffle() }
                .disabled(player.current == nil)
            Button(player.repeatMode == .off ? "Repeat All" : player.repeatMode == .all ? "Repeat One" : "Repeat Off") {
                player.repeatMode = player.repeatMode.next
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { router.selection = .soulseek }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}
