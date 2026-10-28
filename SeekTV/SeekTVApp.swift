import SwiftUI

/// Seek on the Apple TV: a client of Seek on the Mac, like the site on 4n.studio. Library, search,
/// album pages and playback all come from the Mac; signing in is approved from a phone.
@main
struct SeekTVApp: App {
    @State private var connection = Connection()
    @State private var player = TVPlayer()

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.server == nil {
                    ContentUnavailableView("No Mac to connect to", systemImage: "desktopcomputer",
                                           description: Text("This build of Seek wasn't given the Mac's address."))
                } else if connection.isSignedIn {
                    RootView()
                } else {
                    SignInView()
                }
            }
            .environment(connection)
            .environment(player)
        }
    }
}

struct RootView: View {
    @Environment(TVPlayer.self) private var player
    @State private var libraryPath = NavigationPath()
    @State private var tab = "library"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "music.note.house", value: "library") { NavigationStack(path: $libraryPath) { LibraryView().pages() } }
            Tab("Search", systemImage: "magnifyingglass", value: "search") { NavigationStack { SearchView().pages() } }
            Tab("Now Playing", systemImage: "play.circle", value: "nowPlaying") { NowPlayingView() }
            Tab("Settings", systemImage: "gear", value: "settings") { SettingsView() }
        }
        // The Siri Remote's play/pause, wherever focus is.
        .onPlayPauseCommand { player.toggle() }
        #if DEBUG
        // For checking in the simulator: -SeekTVOpen "Artist|Album" opens that album's page.
        .onAppear {
            // -SeekTVTab nowPlaying: moves to that tab a few seconds in (after the album has started).
            if let later = UserDefaults.standard.string(forKey: "SeekTVTab") {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    tab = later
                }
            }
            if let open = UserDefaults.standard.string(forKey: "SeekTVOpen"), let bar = open.firstIndex(of: "|") {
                libraryPath.append(AlbumRef(artist: String(open[..<bar]), title: String(open[open.index(after: bar)...])))
            }
        }
        #endif
    }
}

extension View {
    /// Album and artist pages, opened by value from anywhere in a stack.
    func pages() -> some View {
        navigationDestination(for: AlbumRef.self) { AlbumView(ref: $0) }
            .navigationDestination(for: ArtistRef.self) { ArtistView(name: $0.name) }
    }
}

/// A page from the Mac, loaded when it appears and again whenever the Mac says things changed.
struct Live<Value: Decodable, Content: View>: View {
    let path: String
    @ViewBuilder let content: (Value) -> Content
    @Environment(Connection.self) private var connection
    @State private var value: Value?
    @State private var failed = false

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if failed {
                ContentUnavailableView("Can't reach Seek on the Mac", systemImage: "wifi.exclamationmark",
                                       description: Text("Check Seek is open on the Mac, with Web turned on in its Settings."))
            } else {
                ProgressView()
            }
        }
        .task(id: "\(path)#\(connection.changes)") {
            do {
                value = try await connection.get(path)
                failed = false
            } catch {
                // Keeps what it has; only an empty page says the Mac can't be reached.
                if value == nil { failed = true }
            }
        }
    }
}

enum Paths {
    static func query(_ items: [String: String?]) -> String {
        var components = URLComponents()
        components.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        return components.percentEncodedQuery ?? ""
    }

    static func album(_ ref: AlbumRef) -> String {
        "/api/album?" + query(["artist": ref.artist, "title": ref.title, "release": ref.release])
    }
}

/// "4:05".
func duration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
    let s = Int(seconds.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}
