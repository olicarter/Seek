import SwiftUI

enum AppTab: Hashable {
    case library, artists, albums, labels, songs, playlists, favorites, downloaded, downloads, settings, soulseek
}

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Player.self) private var player
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DiscoveryService.self) private var discovery
    @Environment(SongAnalysisStore.self) private var analysis
    @State private var showingNowPlaying = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selection) {
            if sizeClass == .compact {
                Tab("Library", systemImage: "music.note.house", value: AppTab.library) {
                    LibraryHomeView()
                }
            } else {
                TabSection("Library") {
                    Tab("Artists", systemImage: "music.mic", value: AppTab.artists) {
                        NavigationStack(path: $router.artistsPath) { ArtistsView().libraryDestinations() }
                            .environment(\.openArtist) { router.artistsPath.append($0) }
                    }
                    Tab("Albums", systemImage: "square.stack", value: AppTab.albums) {
                        NavigationStack(path: $router.albumsPath) { AlbumsView().libraryDestinations() }
                            .environment(\.openArtist) { router.albumsPath.append($0) }
                    }
                    Tab("Labels", systemImage: "building.columns", value: AppTab.labels) {
                        NavigationStack(path: $router.labelsPath) { LabelsView().libraryDestinations() }
                            .environment(\.openArtist) { router.labelsPath.append($0) }
                    }
                    Tab("Songs", systemImage: "music.note", value: AppTab.songs) {
                        NavigationStack(path: $router.songsPath) { SongsView().libraryDestinations() }
                            .environment(\.openArtist) { router.songsPath.append($0) }
                    }
                    Tab("Playlists", systemImage: "music.note.list", value: AppTab.playlists) {
                        NavigationStack(path: $router.playlistsPath) { PlaylistsView().libraryDestinations() }
                            .environment(\.openArtist) { router.playlistsPath.append($0) }
                    }
                    Tab("Favourites", systemImage: "heart", value: AppTab.favorites) {
                        NavigationStack(path: $router.favoritesPath) { FavoritesView().libraryDestinations() }
                            .environment(\.openArtist) { router.favoritesPath.append($0) }
                    }
                    Tab("Downloaded", systemImage: "arrow.down.circle", value: AppTab.downloaded) {
                        NavigationStack { DownloadedView().libraryDestinations() }
                    }
                }
            }
            Tab("Activity", systemImage: "arrow.up.arrow.down.circle", value: AppTab.downloads) {
                DownloadsView()
            }
            .badge(client.activeTransferCount + bandcamp.activeDownloadCount)
            Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                SettingsView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.soulseek, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewBottomAccessory(isEnabled: player.current != nil) {
            MiniPlayer()
                .contentShape(.rect)
                .onTapGesture { showingNowPlaying = true }
        }
        .newPlaylistPrompt()
        .appUpdatePrompt()
        .albumAddFailureAlert()
        // Full screen everywhere, as in Apple Music; Now Playing handles the swipe down itself.
        .fullScreenCover(isPresented: $showingNowPlaying) { NowPlayingView() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                client.appDidEnterBackground()
                bandcamp.saveDownloads()
            case .active:
                client.appDidBecomeActive()
                discovery.resumePending()
                // The Mac's latest tempo and key results.
                analysis.load()
            default: break
            }
        }
        #if targetEnvironment(macCatalyst)
        .onAppear {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 620)
            }
        }
        #endif
        .onChange(of: sizeClass, initial: true) { _, newValue in
            router.isCompact = newValue == .compact
            if newValue == .compact, [.artists, .albums, .labels, .songs, .playlists, .favorites].contains(router.selection) {
                router.selection = .library
            } else if newValue != .compact, router.selection == .library {
                router.selection = .albums
            }
        }
    }
}
