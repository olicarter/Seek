import SwiftData
import SwiftUI

/// Album art with a thumbnail cache, falling back to a placeholder.
struct ArtworkView: View {
    /// Identifies the artwork (a song's path, an album's key) so its decoded image can be found
    /// again without reading the data. Without one, the data itself is the key.
    private let key: String?
    private let load: () -> Data?
    /// For artwork passed in directly (the playing song's): which artwork it is, so a new song's
    /// cover loads at once rather than when the view happens to be rebuilt.
    private let dataIdentity: Int
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    init(data: Data?, cornerRadius: CGFloat = 6) {
        key = nil
        load = { data }
        var hasher = Hasher()
        hasher.combine(data?.count ?? -1)
        hasher.combine(data?.prefix(256))
        dataIdentity = hasher.finalize()
        self.cornerRadius = cornerRadius
    }

    /// Artwork read only when it isn't already decoded: reading it means a trip to disk, which
    /// lists and grids would otherwise make for every row on every redraw.
    init(key: String, cornerRadius: CGFloat = 6, load: @escaping () -> Data?) {
        self.key = key
        self.load = load
        dataIdentity = 0
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        let shown = key.flatMap(ArtworkImages.cached) ?? image
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let shown {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .task(id: key ?? "data-\(dataIdentity)") {
                if let key {
                    guard ArtworkImages.cached(key) == nil else { return }
                    let data = load()
                    let decoded = await ThumbnailCache.shared.image(for: data)
                    ArtworkImages.store(decoded, for: key)
                    image = decoded
                } else {
                    image = await ThumbnailCache.shared.image(for: load())
                }
            }
    }
}

/// Decoded artwork by song or album, so redraws show it without touching the data.
@MainActor
enum ArtworkImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()
    /// Artwork can change (tags read, a cover found); bumping this makes every key new.
    private(set) static var generation = 0

    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: "\(generation)|\(key)" as NSString)
    }

    static func store(_ image: UIImage?, for key: String) {
        guard let image else { return }
        cache.setObject(image, forKey: "\(generation)|\(key)" as NSString)
    }

    static func invalidate() {
        generation += 1
        cache.removeAllObjects()
    }

    /// Just these, when only they can have changed.
    static func forget(_ keys: [String]) {
        for key in keys { cache.removeObject(forKey: "\(generation)|\(key)" as NSString) }
    }
}

/// Values worked out from the whole library (album groups, what's owned), remembered until the
/// library's contents change, so views that redraw often don't redo them.
@MainActor
enum LibraryMemo {
    private static var values: [String: (version: String, value: Any)] = [:]

    static func value<T>(_ name: String, version: String, _ make: () -> T) -> T {
        if let entry = values[name], entry.version == version, let value = entry.value as? T { return value }
        let value = make()
        values[name] = (version, value)
        return value
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSData, UIImage>()

    func image(for data: Data?) async -> UIImage? {
        guard let data else { return nil }
        if let cached = cache.object(forKey: data as NSData) { return cached }
        guard let image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 600, height: 600)) else {
            return nil
        }
        cache.setObject(image, forKey: data as NSData)
        return image
    }
}

/// Apple Music's playing indicator: five bars moving with the music itself, resting as dots
/// while paused.
struct NowPlayingBars: View {
    @Environment(Player.self) private var player
    /// When playback paused, so the bars can fall from where they were rather than vanish.
    @State private var pausedAt: Date?
    @State private var falling = false

    /// How quickly bars fall, matching their fall while playing (about 200 ms).
    private static let fallTime = 0.22

    var body: some View {
        let playing = player.isPlaying
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing && !falling)) { context in
            let levels = levels(at: context.date, playing: playing)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<AudioLevels.bandCount, id: \.self) { band in
                    Capsule()
                        .frame(width: 2.5, height: 2.5 + CGFloat(levels[band]) * 11.5)
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
        .foregroundStyle(.primary)
        .accessibilityElement()
        .accessibilityLabel(playing ? "Playing" : "Paused")
        .onChange(of: playing) { _, isPlaying in
            pausedAt = isPlaying ? nil : .now
            falling = !isPlaying
        }
        .task(id: falling) {
            guard falling else { return }
            // Long enough for the bars to reach the bottom, then the timeline can rest.
            try? await Task.sleep(for: .seconds(Self.fallTime * 6))
            falling = false
        }
    }

    private func levels(at date: Date, playing: Bool) -> [Float] {
        // Paused, the player stays on the moment it stopped, so its levels are where to fall from.
        let measured = player.levels.levels(at: player.playbackTime)
        if playing { return measured }
        guard let pausedAt, falling else { return [Float](repeating: 0, count: AudioLevels.bandCount) }
        let remaining = Float(exp(-date.timeIntervalSince(pausedAt) / Self.fallTime))
        return measured.map { $0 * remaining }
    }
}

/// The small star left of a favourite song, like Apple Music's.
struct FavoriteStar: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.primary)
            .accessibilityLabel("Favourite")
    }
}

/// A song row's number column: the number, or the playing bars, with a star to its left for a
/// favourite.
struct TrackNumberColumn: View {
    let number: Int
    let isCurrent: Bool
    let isFavorite: Bool

    var body: some View {
        Group {
            if isCurrent {
                NowPlayingBars()
            } else {
                Text(number > 0 ? "\(number)" : "")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, alignment: .trailing)
        .overlay(alignment: .leading) {
            if isFavorite { FavoriteStar().offset(x: -12) }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var showArtwork = true
    var showNumber = false
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            let isCurrent = player.current === track
            let isFavorite = library.isFavorite(track)
            if showNumber {
                TrackNumberColumn(number: track.trackNumber, isCurrent: isCurrent, isFavorite: isFavorite)
            } else if showArtwork {
                ArtworkView(key: track.path, cornerRadius: 4) { track.cover }
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45))
                            NowPlayingBars().foregroundStyle(.white).environment(\.colorScheme, .dark)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if isFavorite { FavoriteStar().offset(x: -12) }
                    }
            } else if isFavorite {
                FavoriteStar()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(player.current === track ? Color.accentColor : .primary)
                    .lineLimit(1)
                if !showNumber {
                    Text("\(track.displayArtist) · \(track.displayAlbum)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            switch library.availability(of: track) {
            case .cloudOnly:
                EmptyView()
            // Centred in the same column as the rings of songs still downloading into the album.
            case .downloading(let progress):
                ProgressRing(progress: progress, size: 14, lineWidth: 2)
                    .frame(width: 28)
            case .onDevice:
                // Like Apple Music: only songs kept for offline listening are marked.
                if library.usesICloud, track.keepOffline {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityLabel("Downloaded")
                }
            }
        }
        .contentShape(.rect)
    }
}

/// Context menu actions shared by every list of songs.
struct TrackMenu: View {
    let track: Track
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(track) }
        AddToPlaylistMenu(track: track)
        FavoriteButton(track: track)
        NavigationLink(value: track.albumKey) {
            Label("Go to Album", systemImage: "square.stack")
        }
        NavigationLink(value: ArtistKey(name: track.albumKey.artist)) {
            Label("Go to Artist", systemImage: "music.mic")
        }
        DownloadMenuItems(tracks: [track])
        Divider()
        Button("Delete from Library", systemImage: "trash", role: .destructive) { library.delete(track) }
    }
}

/// "Download" (from iCloud to this device) for songs not all kept here, "Remove Download" for
/// ones that are here.
struct DownloadMenuItems: View {
    let tracks: [Track]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.usesICloud, !tracks.isEmpty {
            let states = tracks.map { library.availability(of: $0) }
            if states.contains(.cloudOnly) || tracks.contains(where: { !$0.keepOffline }) {
                Button("Download", systemImage: "arrow.down.circle") { library.download(tracks) }
            }
            if states.contains(.onDevice) || tracks.contains(where: \.keepOffline) {
                Button("Remove Download", systemImage: "xmark.circle") { library.removeDownloads(tracks) }
            }
        }
    }
}

/// The album or playlist toolbar's download button, like Apple Music's: an arrow to download,
/// progress while downloading, and a tick once everything is kept on this device.
struct DownloadToolbarMenu: View {
    let tracks: [Track]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.usesICloud, !tracks.isEmpty {
            let states = tracks.map { library.availability(of: $0) }
            let downloading = states.compactMap { state -> Double? in
                if case .downloading(let progress) = state { return progress } else { return nil }
            }
            let allKept = tracks.allSatisfy(\.keepOffline) && !states.contains(.cloudOnly)
            Menu {
                DownloadMenuItems(tracks: tracks)
            } label: {
                if !downloading.isEmpty {
                    // Songs already here count as done.
                    let done = Double(states.filter { $0 == .onDevice }.count) + downloading.reduce(0, +)
                    ProgressRing(progress: done / Double(tracks.count))
                } else if allKept {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

/// "Add to Playlist" submenu for song menus.
struct AddToPlaylistMenu: View {
    let title: String
    /// The song's library path if it has one yet (to tick playlists it's in).
    let currentPath: String?
    /// Its library path, made when needed: a song not in the library is added (and its path
    /// reserved) only once a playlist is chosen, not just by opening the menu.
    let path: () -> String?

    init(track: Track) {
        title = track.title
        currentPath = track.path
        path = { track.path }
    }

    init(title: String, currentPath: String?, path: @escaping () -> String?) {
        self.title = title
        self.currentPath = currentPath
        self.path = path
    }

    var body: some View {
        Menu("Add to Playlist", systemImage: "music.note.list") {
            AddToPlaylistItems(title: title, currentPath: currentPath, path: path)
        }
    }
}

/// Playlists to add a song to, with ticks on ones that already contain it, then "New Playlist…".
struct AddToPlaylistItems: View {
    let title: String
    let currentPath: String?
    let path: () -> String?
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Environment(NewPlaylistPrompt.self) private var newPlaylist

    init(track: Track) {
        self.init(title: track.title, currentPath: track.path, path: { track.path })
    }

    init(title: String, currentPath: String?, path: @escaping () -> String?) {
        self.title = title
        self.currentPath = currentPath
        self.path = path
    }

    var body: some View {
        ForEach(playlists) { playlist in
            if let currentPath, playlist.trackPaths.contains(currentPath) {
                Button(playlist.name, systemImage: "checkmark") {}
                    .disabled(true)
            } else {
                Button(playlist.name) {
                    if let path = path() { playlist.trackPaths.append(path) }
                }
            }
        }
        Divider()
        Button("New Playlist…", systemImage: "plus") {
            if let path = path() { newPlaylist.ask(adding: path, title: title) }
        }
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(key: "album|\(album.key.artist)|\(album.key.title)", cornerRadius: 8) { album.artwork }
            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    @Environment(Player.self) private var player
    @State private var deleting: PendingDelete?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
            ForEach(albums) { album in
                NavigationLink(value: album.key) {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
                .contextMenu { AlbumMenuItems(album: album, deleting: $deleting) }
            }
        }
        .deleteConfirmation($deleting)
    }
}

/// An album's long-press menu, in grids and lists alike.
struct AlbumMenuItems: View {
    let album: Album
    @Binding var deleting: PendingDelete?
    @Environment(Player.self) private var player

    var body: some View {
        Button("Play", systemImage: "play") { player.play(album.tracks, startingAt: 0) }
        Button("Shuffle", systemImage: "shuffle") { player.play(album.tracks.shuffled(), startingAt: 0) }
        DownloadMenuItems(tracks: album.tracks)
        Divider()
        DeleteFromLibraryButton {
            deleting = PendingDelete(name: album.title, tracks: album.tracks)
        }
    }
}

extension View {
    func libraryDestinations() -> some View {
        navigationDestination(for: AlbumKey.self) { AlbumDetailView(key: $0) }
            .navigationDestination(for: ArtistKey.self) { ArtistDetailView(name: $0.name) }
            .navigationDestination(for: LabelKey.self) { LabelDetailView(name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: LibrarySection.self) { $0.destination }
            .navigationDestination(for: RemoteFolder.self) { RemoteFolderView(folder: $0) }
            .navigationDestination(for: ExternalAlbum.self) { ExternalAlbumView(album: $0) }
    }
}

enum LibrarySection: String, CaseIterable, Hashable {
    case artists = "Artists"
    case albums = "Albums"
    case labels = "Labels"
    case songs = "Songs"
    case playlists = "Playlists"
    case favorites = "Favourites"
    case downloaded = "Downloaded"

    var systemImage: String {
        switch self {
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .labels: "building.columns"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .downloaded: "arrow.down.circle"
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .labels: LabelsView()
        case .songs: SongsView()
        case .playlists: PlaylistsView()
        case .favorites: FavoritesView()
        case .downloaded: DownloadedView()
        }
    }
}

extension Array where Element == Track {
    func matching(_ query: String) -> [Track] {
        guard !query.isEmpty else { return self }
        return filter {
            $0.title.localizedStandardContains(query)
                || $0.artist.localizedStandardContains(query)
                || $0.albumArtist.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query)
                || $0.label.localizedStandardContains(query)
        }
    }
}

/// Songs about to be deleted, waiting for the user to confirm.
struct PendingDelete: Identifiable {
    let id = UUID()
    /// "Glitch" or "Cryogeyser", for the question.
    let name: String
    let tracks: [Track]
}

extension View {
    /// Asks before deleting an album's or artist's songs, then deletes them and calls `onDeleted`
    /// (e.g. to leave the page that no longer exists).
    func deleteConfirmation(_ pending: Binding<PendingDelete?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(DeleteConfirmation(pending: pending, onDeleted: onDeleted))
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var pending: PendingDelete?
    let onDeleted: () -> Void
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            Button(pending.tracks.count == 1 ? "Delete Song" : "Delete \(pending.tracks.count) Songs", role: .destructive) {
                library.delete(pending.tracks)
                onDeleted()
            }
        } message: { pending in
            Text(pending.tracks.count == 1
                ? "The song is removed from your library and iCloud Drive, on all your devices, and from any playlists."
                : "Its \(pending.tracks.count) songs are removed from your library and iCloud Drive, on all your devices, and from any playlists.")
        }
    }
}

/// "Favourite" or "Unfavourite" for a song, for menus.
struct FavoriteButton: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let isFavorite = library.isFavorite(track)
        Button(isFavorite ? "Unfavourite" : "Favourite", systemImage: isFavorite ? "heart.slash" : "heart") {
            library.toggleFavorite(track)
            player.updateFavoriteCommand()
        }
    }
}

/// Removes an album, artist or song from the library, as Apple Music words it, in red even in
/// menus tinted white.
struct DeleteFromLibraryButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Delete from Library", systemImage: "trash")
        }
        .tint(.red)
    }
}

extension EnvironmentValues {
    /// Opens an artist's page in the navigation stack the view is in, as a link would. Pages
    /// open by value everywhere: one opened from state (`navigationDestination(isPresented:)`)
    /// is always drawn above those opened by value, so an album opened from that artist page
    /// ended up beneath it.
    @Entry var openArtist: ((ArtistKey) -> Void)? = nil
}
