import CoreData
import Foundation
import Observation
import SwiftData
import UIKit

/// Owns the music folder (in iCloud Drive when available) and keeps the Track index in step with it.
@MainActor
@Observable
final class LibraryStore {
    static let containerIdentifier = "iCloud.dev.olicarter.seek"

    /// "Automatic Downloads": music added on this device stays here for offline listening.
    /// Off, it's removed from this device once it's safely in iCloud.
    static let automaticDownloadsKey = "automaticDownloads"
    /// On for iPhone, where music you've just added is usually what you'll play next; off for
    /// iPad and Mac.
    static var defaultAutomaticDownloads: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var automaticDownloads: Bool {
        UserDefaults.standard.object(forKey: automaticDownloadsKey) as? Bool ?? defaultAutomaticDownloads
    }
    private static let pendingEvictionsKey = "pendingEvictions"
    private static let markedLocalKey = "markedLocalAsDownloaded"

    private(set) var root: URL?
    private(set) var usesICloud = false
    /// Songs whose file is in iCloud but not on this device.
    private(set) var cloudOnly: Set<String> = []
    /// Paths of favourited songs, for hearts in lists.
    private(set) var favoritePaths: Set<String> = []
    /// Songs downloading to this device, with progress from 0 to 1.
    private(set) var downloadProgress: [String: Double] = [:]
    /// File sizes by path, including files only in iCloud, for sharing.
    @ObservationIgnored private var fileSizes: [String: Int64] = [:]
    /// Files to remove from this device once they've finished uploading to iCloud.
    @ObservationIgnored private var pendingEvictions = Set(UserDefaults.standard.stringArray(forKey: LibraryStore.pendingEvictionsKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(pendingEvictions), forKey: Self.pendingEvictionsKey) }
    }
    @ObservationIgnored private var evictionRetry: Task<Void, Never>?
    /// Bumped whenever songs' details change (not on every save), so views can keep values they
    /// worked out from the whole library until then.
    @ObservationIgnored private var contentChanges = 0

    func contentVersion(trackCount: Int) -> String { "\(contentChanges)-\(trackCount)" }

    /// Songs' details (and maybe artwork) changed.
    private func contentChanged(artwork: Bool = false) {
        contentChanges += 1
        if artwork { ArtworkImages.invalidate() }
    }
    /// Whether a file is open right now (e.g. playing), so it isn't removed from under the player.
    @ObservationIgnored var isInUse: ((String) -> Bool)?
    /// Told when the set of songs or their files change, e.g. to update what's shared.
    @ObservationIgnored var onLibraryChanged: (() -> Void)?
    /// Told the folders of albums just deleted outright, so downloads still on their way into
    /// them stop instead of bringing the album back.
    @ObservationIgnored var onAlbumsDeleted: ((Set<String>) -> Void)?
    var cloudOnlyCount: Int { cloudOnly.count }

    @ObservationIgnored private let context: ModelContext
    /// Held so it lives as long as the store: work scheduled for later (refreshing the songs,
    /// syncing details) used a context whose container had gone, which crashed.
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The files as last reconciled with the library, to skip reconciling when only upload or
    /// download progress changed.
    @ObservationIgnored private var reconciledFiles: [String: FileState]?
    @ObservationIgnored private var reading: Set<String> = []
    /// Told about each album as downloads are added to it, e.g. to fetch suggestions early.
    @ObservationIgnored var onAlbumImported: ((AlbumKey) -> Void)?
    @ObservationIgnored private var infoSync: Task<Void, Never>?
    @ObservationIgnored private var coverQueue: [String] = []
    @ObservationIgnored private var coverWorker: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
        refreshAllTracks()
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self, weak container] note in
            // Only this library's saves (its own context, or the sync's on the same container).
            guard let saved = note.object as? ModelContext, let container, saved.container === container else { return }
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                (note.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []).filter { $0.entityName == "Track" }
            }
            let inserted = ids(.insertedIdentifiers), deleted = ids(.deletedIdentifiers)
            let fromMain = saved === self?.context
            MainActor.assumeIsolated {
                guard let self else { return }
                if fromMain {
                    self.patchAllTracks(inserted: inserted, deleted: deleted)
                } else if !(inserted.isEmpty && deleted.isEmpty) {
                    // Songs added or removed on another context: read them afresh. (Edits made
                    // there are merged into the songs here, so need nothing.)
                    self.refreshAllTracksSoon()
                }
            }
        }
    }

    /// Fetching every song took a fifth of a second per song arriving (more on a big library), so
    /// saves made here patch the list instead: new songs go on the front (they're the newest),
    /// removed ones come out, and edited ones are the same objects, already up to date.
    private func patchAllTracks(inserted: [PersistentIdentifier], deleted: [PersistentIdentifier]) {
        guard !inserted.isEmpty || !deleted.isEmpty else { return }
        var tracks = allTracks
        if !deleted.isEmpty {
            let gone = Set(deleted)
            tracks.removeAll { gone.contains($0.persistentModelID) }
        }
        let added = inserted.compactMap { context.model(for: $0) as? Track }
        guard added.count == inserted.count else {
            refreshAllTracks()
            return
        }
        allTracks = added.sorted { $0.dateAdded > $1.dateAdded } + tracks
    }

    /// Every song, newest first, shared by the views that show the whole library. Each holding
    /// its own query refetched them all on every save, several times for each song arriving,
    /// which made scrolling stutter while an album downloaded.
    private(set) var allTracks: [Track] = [] {
        didSet { tracksVersion += 1 }
    }
    @ObservationIgnored private var tracksVersion = 0
    @ObservationIgnored private var tracksRefresh: Task<Void, Never>?

    /// Every album, grouped once per change to the library rather than by each view that lists them.
    var albums: [Album] {
        LibraryMemo.value("allAlbums", version: "\(tracksVersion)-\(contentChanges)") { LibraryGrouping.albums(allTracks) }
    }

    /// Each album under every spelling its songs use, so a song's own spelling finds it too.
    var albumsByKey: [AlbumKey: Album] {
        LibraryMemo.value("albumsByKey", version: "\(tracksVersion)-\(contentChanges)") {
            var byKey: [AlbumKey: Album] = [:]
            for album in albums {
                byKey[album.key] = album
                for track in album.tracks where byKey[track.albumKey] == nil { byKey[track.albumKey] = album }
            }
            return byKey
        }
    }
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private func refreshAllTracks() {
        tracksRefresh?.cancel()
        tracksRefresh = nil
        allTracks = (try? context.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
    }

    private func refreshAllTracksSoon() {
        guard tracksRefresh == nil else { return }
        tracksRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            tracksRefresh = nil
            refreshAllTracks()
        }
    }

    static func makeContainer() -> ModelContainer {
        let schema = Schema([Track.self, Playlist.self, TrackInfo.self, Discovery.self, Favorite.self])
        let tracks = ModelConfiguration("Tracks", schema: Schema([Track.self]), cloudKitDatabase: .none)
        // Named for its first use; it now holds everything synced through CloudKit.
        let synced = Schema([Playlist.self, TrackInfo.self, Discovery.self, Favorite.self])
        let playlists = ModelConfiguration("Playlists", schema: synced, cloudKitDatabase: .private(containerIdentifier))
        if let container = try? ModelContainer(for: schema, configurations: tracks, playlists) {
            return container
        }
        // No CloudKit (e.g. unsigned simulator build): keep playlists and track details on this device.
        let localPlaylists = ModelConfiguration("Playlists", schema: synced, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: tracks, localPlaylists)
        } catch {
            fatalError("Couldn't open library: \(error)")
        }
    }

    // MARK: - Folder

    func start() async {
        guard root == nil else { return }
        let ubiquity = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: LibraryStore.containerIdentifier)
        }.value
        let base = ubiquity?.appending(path: "Documents", directoryHint: .isDirectory) ?? URL.documentsDirectory
        let music = base.appending(path: "Music", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        root = music.resolvingSymlinksInPath()
        usesICloud = ubiquity != nil
        if usesICloud { startMetadataQuery() } else { rescanLocalFolder() }
        // Details from other devices arrive through CloudKit at any time.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleInfoSync()
                self?.refreshFavorites()
            }
        })
        refreshFavorites()
    }

    /// Uses a plain folder, without iCloud or watching for changes (for tests).
    func useFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        usesICloud = false
    }

    func url(for track: Track) -> URL? {
        root?.appending(path: track.path)
    }

    /// iCloud files may not be on this device yet; fetch and wait (up to a minute).
    func ensureLocal(_ url: URL) async -> Bool {
        guard usesICloud else { return FileManager.default.fileExists(atPath: url.path) }
        if Self.isDownloaded(url) { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(500))
            if Self.isDownloaded(url) { return true }
        }
        return false
    }

    private static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        let status = values?.ubiquitousItemDownloadingStatus
        return status == .current || status == .downloaded
    }

    // MARK: - Sharing

    func url(forPath path: String) -> URL? {
        root?.appending(path: path)
    }

    func isOnDevice(_ path: String) -> Bool {
        !cloudOnly.contains(path) && downloadProgress[path] == nil
    }

    /// Every library file with what peers are told about it.
    /// Read on a context of its own away from the main thread: it goes through every song (and
    /// asks the disk for sizes the iCloud index hasn't given), which held up scrolling.
    func sharedFiles() async -> [SharedFile] {
        let container = context.container
        let sizes = fileSizes
        let root = root
        return await Task.detached(priority: .utility) {
            Self.sharedFiles(in: ModelContext(container), sizes: sizes, root: root)
        }.value
    }

    nonisolated private static func sharedFiles(in context: ModelContext, sizes: [String: Int64], root: URL?) -> [SharedFile] {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        return tracks.compactMap { track in
            var size = sizes[track.path]
            if size == nil, let url = root?.appending(path: track.path),
               let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size = Int64(bytes)
            }
            guard let size, size > 0 else { return nil }
            return SharedFile(
                virtualPath: ShareIndex.virtualPath(forLibraryPath: track.path),
                libraryPath: track.path,
                size: UInt64(size),
                duration: track.duration > 0 ? Int(track.duration) : nil,
                bitrate: track.bitrate > 0 ? track.bitrate : nil,
                sampleRate: track.sampleRate > 0 ? track.sampleRate : nil,
                bitDepth: track.bitDepth > 0 ? track.bitDepth : nil
            )
        }
    }

    // MARK: - Favourites

    func isFavorite(_ track: Track) -> Bool {
        favoritePaths.contains(track.path)
    }

    func isFavorite(path: String) -> Bool {
        favoritePaths.contains(path)
    }

    func toggleFavorite(_ track: Track) {
        toggleFavorite(path: track.path)
    }

    /// By library path, which may be one reserved for a song still downloading.
    func toggleFavorite(path: String) {
        let existing = (try? context.fetch(FetchDescriptor<Favorite>(predicate: #Predicate { $0.path == path }))) ?? []
        if existing.isEmpty {
            context.insert(Favorite(path: path))
        } else {
            existing.forEach(context.delete)
        }
        try? context.save()
        refreshFavorites()
    }

    /// Re-reads favourites (they can change on other devices), dropping duplicates that two
    /// devices made for the same song; the earliest favouriting wins.
    func refreshFavorites() {
        let all = (try? context.fetch(FetchDescriptor<Favorite>(sortBy: [SortDescriptor(\.favoritedAt)]))) ?? []
        var seen = Set<String>()
        for favorite in all where !seen.insert(favorite.path).inserted { context.delete(favorite) }
        if seen != favoritePaths { favoritePaths = seen }
    }

    /// Favourites and playlist entries made for a song on its way follow it to where it landed.
    private func movePending(from old: String, to new: String) {
        moveFavorites([old: new])
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for playlist in playlists where playlist.trackPaths.contains(old) {
            playlist.trackPaths = playlist.trackPaths.map { $0 == old ? new : $0 }
        }
        try? context.save()
    }

    /// Keeps favourites (and when they were made) when a song's file is swapped for another.
    private func moveFavorites(_ replacement: [String: String]) {
        guard !replacement.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        for favorite in all {
            if let new = replacement[favorite.path] { favorite.path = new }
        }
        refreshFavorites()
    }

    // MARK: - Duplicates

    /// The extra copies on an album: tracks with the same disc, number and title as another.
    /// Each group keeps its best copy; everything returned can go.
    static func duplicates(in tracks: [Track]) -> [(keep: Track, remove: [Track])] {
        let groups = Dictionary(grouping: tracks) { track in
            "\(track.discNumber)|\(track.trackNumber)|\(normalizedTitle(track.title))"
        }
        return groups.values.compactMap { group in
            guard group.count > 1 else { return nil }
            let ranked = group.sorted { a, b in
                let (qa, qb) = (formatRank(a), formatRank(b))
                if qa != qb { return qa > qb }
                let (ca, cb) = (isNumberedCopy(a.path), isNumberedCopy(b.path))
                if ca != cb { return !ca }
                return a.dateAdded < b.dateAdded
            }
            return (ranked[0], Array(ranked.dropFirst()))
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.replacing(/\s*\(\d+\)$/, with: "")
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func formatRank(_ track: Track) -> Int {
        switch track.fileExtension {
        case "flac": 4
        case "alac", "aiff", "aif", "wav": 3
        case "m4a", "aac": 2
        case "mp3": 1
        default: 0
        }
    }

    /// "01 Song (1).flac": a second copy saved next to the first.
    private static func isNumberedCopy(_ path: String) -> Bool {
        ((path as NSString).deletingPathExtension).contains(/\s\(\d+\)$/)
    }

    /// Deletes an album's extra copies, pointing playlists at the copy that's kept.
    @discardableResult
    func removeDuplicates(in tracks: [Track]) -> Int {
        let groups = Self.duplicates(in: tracks)
        var replacement: [String: String] = [:]
        for group in groups {
            for track in group.remove { replacement[track.path] = group.keep.path }
        }
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for playlist in playlists where playlist.trackPaths.contains(where: { replacement[$0] != nil }) {
            var seen = Set<String>()
            playlist.trackPaths = playlist.trackPaths
                .map { replacement[$0] ?? $0 }
                // A playlist holding both copies keeps just one.
                .filter { path in replacement.values.contains(path) ? seen.insert(path).inserted : true }
        }
        moveFavorites(replacement)
        for group in groups {
            group.remove.forEach(delete)
        }
        return replacement.count
    }

    // MARK: - Replacing with a purchase

    /// Swaps library files for a Bandcamp purchase's: each old track whose title matches one of the
    /// purchase's tracks is deleted, with playlists moved to the new copy. Tracks that don't match
    /// (bonus tracks, or a different release altogether) are kept, so nothing is lost on a bad match.
    @discardableResult
    func replace(_ oldPaths: [String], withPurchaseFrom page: URL?) -> (replaced: Int, kept: Int) {
        guard let page else { return (0, oldPaths.count) }
        let source = OwnedReleases.normalized(page.absoluteString)
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let new = tracks.filter { !$0.sourceURL.isEmpty && OwnedReleases.normalized($0.sourceURL) == source }
        return replace(oldPaths, with: new.map(\.path))
    }

    /// Swaps library files for newly added ones (e.g. a lossless copy), the same way: by title,
    /// keeping anything without a match.
    @discardableResult
    func replace(_ oldPaths: [String], with newPaths: [String]) -> (replaced: Int, kept: Int) {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let newSet = Set(newPaths)
        let new = tracks.filter { newSet.contains($0.path) }
        let old = tracks.filter { oldPaths.contains($0.path) && !newSet.contains($0.path) }
        let pairs = Self.pairs(old: old, new: new)
        let replacement = Dictionary(uniqueKeysWithValues: pairs.map { ($0.old.path, $0.new.path) })
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for playlist in playlists where playlist.trackPaths.contains(where: { replacement[$0] != nil }) {
            playlist.trackPaths = playlist.trackPaths.map { replacement[$0] ?? $0 }
        }
        moveFavorites(replacement)
        // A copy replacing downloaded songs is kept downloaded too.
        download(pairs.filter { $0.old.keepOffline }.map(\.new))
        delete(pairs.map(\.old))
        Log.debug("library: replaced \(pairs.count) of \(old.count) tracks with the Bandcamp copy")
        return (pairs.count, old.count - pairs.count)
    }

    /// Old tracks matched to new ones by title (ignoring case, accents, tags like "[FLAC]"), using
    /// track numbers to settle titles that appear twice.
    static func pairs(old: [Track], new: [Track]) -> [(old: Track, new: Track)] {
        var available = new
        var result: [(Track, Track)] = []
        for track in old.sorted(by: { $0.trackNumber < $1.trackNumber }) {
            let title = ReleaseText.fold(ReleaseText.cleanTitle(track.title))
            let candidates = available.filter { ReleaseText.fold(ReleaseText.cleanTitle($0.title)) == title }
            guard let match = candidates.first(where: { $0.trackNumber == track.trackNumber }) ?? candidates.first else { continue }
            result.append((track, match))
            available.removeAll { $0 === match }
        }
        return result
    }

    // MARK: - Offline

    enum Availability: Equatable {
        case onDevice
        case cloudOnly
        case downloading(Double)
    }

    func availability(of track: Track) -> Availability {
        if let progress = downloadProgress[track.path] { return .downloading(progress) }
        return cloudOnly.contains(track.path) ? .cloudOnly : .onDevice
    }

    /// Keeps songs on this device for offline listening, downloading any that are only in iCloud.
    func download(_ tracks: [Track]) {
        guard usesICloud else { return }
        for track in tracks {
            track.keepOffline = true
            pendingEvictions.remove(track.path)
            if cloudOnly.contains(track.path), let url = url(for: track) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        try? context.save()
    }

    /// Frees the space songs take on this device; they stay in iCloud and download again when played.
    func removeDownloads(_ tracks: [Track]) {
        guard usesICloud else { return }
        var urls: [URL] = []
        for track in tracks {
            track.keepOffline = false
            if !cloudOnly.contains(track.path), let url = url(for: track) {
                urls.append(url)
                // Anything still uploading is removed once it's in iCloud.
                pendingEvictions.insert(track.path)
            }
        }
        try? context.save()
        Task.detached {
            for url in urls {
                do {
                    try FileManager.default.evictUbiquitousItem(at: url)
                } catch {
                    // E.g. still uploading, or open because it's playing; it stays on the device.
                    Log.debug("library: couldn't remove download of \(url.lastPathComponent): \(error)")
                }
            }
        }
    }

    /// Moves a finished Soulseek download into Music/<Artist>/<Album>/ and indexes it.
    /// Returns the file's path in the library.
    @discardableResult
    func importDownload(at source: URL, remotePath: String, plannedPath: String? = nil) async throws -> String {
        let components = remotePath.split(separator: "\\").map(String.init)
        return try await importFile(at: source, folders: Array(components.dropLast().suffix(2)), name: components.last,
                                    plannedPath: plannedPath)
    }

    // MARK: - Reserved paths

    /// Library paths downloads will land at, reserved when they're added, so favourites and
    /// playlists can refer to songs that are still on their way.
    @ObservationIgnored private var reservedPaths: Set<String> = []
    /// Files being imported right now, which the iCloud index leaves alone.
    @ObservationIgnored private var importing: Set<String> = []
    /// Songs imported here that the iCloud index hasn't seen yet. It can take a few seconds to
    /// notice a new file; until it does, its reads mustn't count the song as gone (removing it
    /// and adding it back would lose details like being kept downloaded).
    @ObservationIgnored private var awaitingIndex: [String: Date] = [:]

    /// Where a Soulseek file will go in the library, reserved so nothing else takes it.
    func reservePath(forRemotePath remotePath: String) -> String? {
        guard root != nil else { return nil }
        let components = remotePath.split(separator: "\\").map(String.init)
        guard let name = components.last else { return nil }
        let folders = components.dropLast().suffix(2).map(Self.sanitize)
        let path = freePath(folders: Array(folders), fileName: Self.sanitize(name), allowing: nil)
        reservedPaths.insert(path)
        return path
    }

    /// Keeps a reservation made before the app last quit.
    func keepReserved(_ path: String) {
        reservedPaths.insert(path)
    }

    /// Lets a reserved path go. When the download was abandoned (cancelled, removed or failed for
    /// good), favourites and playlist entries made for the song on its way go too.
    func releaseReserved(_ path: String, abandoned: Bool) {
        reservedPaths.remove(path)
        guard abandoned, existingTrack(path) == nil else { return }
        let favorites = (try? context.fetch(FetchDescriptor<Favorite>(predicate: #Predicate { $0.path == path }))) ?? []
        favorites.forEach(context.delete)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for playlist in playlists where playlist.trackPaths.contains(path) {
            playlist.trackPaths.removeAll { $0 == path }
        }
        try? context.save()
        refreshFavorites()
    }

    func isReserved(_ path: String) -> Bool { reservedPaths.contains(path) }

    func hasTrack(path: String) -> Bool { existingTrack(path) != nil }

    /// Whether the folder `plannedPath` is in already has a song of that name (by its title:
    /// "Artist - Album - 05 - Song.flac" and "5. Song.flac" are the same), from any copy.
    func hasSong(named fileName: String, besides plannedPath: String) -> Bool {
        let folder = (plannedPath as NSString).deletingLastPathComponent
        guard !folder.isEmpty else { return false }
        let prefix = folder + "/"
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path.starts(with: prefix) })
        guard let tracks = try? context.fetch(descriptor), !tracks.isEmpty else { return false }
        let name = ReleaseText.fold(ReleaseDetailView.trackName(fileName))
        guard !name.isEmpty else { return false }
        return tracks.contains { track in
            // Only songs directly in the folder, not a disc folder below it.
            guard !track.path.dropFirst(prefix.count).contains("/") else { return false }
            let other = ReleaseText.fold(ReleaseDetailView.trackName((track.path as NSString).lastPathComponent))
            // "Artist - Album - 12 - Song" and "12 Song" leave different amounts before the title.
            return other == name || other.hasSuffix(" " + name) || name.hasSuffix(" " + other)
        }
    }

    /// A library path in the folders for the name, free of files and of other reservations
    /// ("Song (1).flac" if taken). `allowing` is the caller's own reservation.
    private func freePath(folders: [String], fileName: String, allowing: String?) -> String {
        let folder = folders.joined(separator: "/")
        let stem = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        var counter = 0
        while true {
            let name = counter == 0 ? fileName : "\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            let path = folder.isEmpty ? name : "\(folder)/\(name)"
            let taken = root.map { FileManager.default.fileExists(atPath: $0.appending(path: path).path) } ?? false
                || (reservedPaths.contains(path) && path != allowing)
            if !taken { return path }
            counter += 1
        }
    }

    /// Moves a file into Music/<folders…>/<name>, indexes it, and returns its library path. A
    /// `plannedPath` reserved for it is used when still free; otherwise the nearest free path,
    /// with favourites and playlist entries made for the planned one following the song there.
    @discardableResult
    func importFile(at source: URL, folders: [String], name: String? = nil, plannedPath: String? = nil) async throws -> String {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        let sanitizedFolders = folders.map(Self.sanitize)
        let fileName = Self.sanitize(name ?? source.lastPathComponent)
        let path: String
        if let plannedPath, !FileManager.default.fileExists(atPath: root.appending(path: plannedPath).path) {
            path = plannedPath
        } else {
            path = freePath(folders: sanitizedFolders, fileName: fileName, allowing: plannedPath)
        }
        let destination = root.appending(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Tags are read before the file moves in, so the song appears complete: added bare, it
        // showed for a moment as its file name at the bottom of the album.
        let metadata = await Task.detached { await MetadataReader.read(source) }.value
        // The iCloud index may see the file before this finishes; it leaves it to the import.
        importing.insert(path)
        defer { importing.remove(path) }

        let ubiquitous = usesICloud
        try await Task.detached {
            if ubiquitous {
                try FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }.value

        if let plannedPath {
            reservedPaths.remove(plannedPath)
            if plannedPath != path { movePending(from: plannedPath, to: path) }
        }
        let track = existingTrack(path) ?? insertTrack(path)
        track.apply(metadata)
        track.hasTags = true
        track.tagsVersion = Track.currentTagsVersion
        track.fileModified = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if ubiquitous {
            awaitingIndex[path] = .now
            keepOrRelease(track)
        } else {
            try? context.save()
        }
        // Only this song's album and label covers can have changed: clearing every cover made
        // each song arriving redraw all artwork on screen.
        contentChanged()
        ArtworkImages.forget(["album|\(track.albumKey.artist)|\(track.albumKey.title)", "label|\(track.label)", path])
        scheduleInfoSync()
        if !track.isDeleted, track.modelContext != nil { onAlbumImported?(track.albumKey) }
        return path
    }

    struct TagEdit {
        let track: Track
        var title: String
        var artist: String
        var albumArtist: String
        var album: String
        var label: String
        var trackNumber: Int
        var year: Int
    }

    /// Saves edited tags into the files (FLAC) and the library. Returns how many files couldn't
    /// be written (other formats keep the edit in Seek only).
    @discardableResult
    func save(_ edits: [TagEdit], frontCover: FLACTags.Picture? = nil) async throws -> Int {
        defer { contentChanged(artwork: true) }
        var libraryOnly = 0
        for edit in edits {
            let track = edit.track
            var changes: [String: String] = [:]
            if edit.title != track.title { changes["TITLE"] = edit.title }
            if edit.artist != track.artist { changes["ARTIST"] = edit.artist }
            if edit.albumArtist != track.albumArtist { changes["ALBUMARTIST"] = edit.albumArtist }
            if edit.album != track.album { changes["ALBUM"] = edit.album }
            if edit.label != track.label {
                // LABEL is what most taggers use; ORGANIZATION is the Vorbis spec's name for it.
                changes["LABEL"] = edit.label
                changes["ORGANIZATION"] = edit.label
            }
            if edit.trackNumber != track.trackNumber { changes["TRACKNUMBER"] = edit.trackNumber > 0 ? String(edit.trackNumber) : "" }
            if edit.year != track.year { changes["DATE"] = edit.year > 0 ? String(edit.year) : "" }
            guard !changes.isEmpty || frontCover != nil else { continue }

            if track.fileExtension == "flac", let url = url(for: track), await ensureLocal(url) {
                try await Task.detached {
                    var coordinationError: NSError?
                    var writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
                        do { try FLACTags.update(url, setting: changes, frontCover: frontCover) } catch { writeError = error }
                    }
                    if let error = coordinationError ?? writeError { throw error }
                }.value
                track.fileModified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } else {
                libraryOnly += 1
            }
            track.title = edit.title
            track.artist = edit.artist
            track.albumArtist = edit.albumArtist
            track.album = edit.album
            track.label = edit.label
            track.trackNumber = edit.trackNumber
            track.year = edit.year
            if let frontCover { track.artwork = frontCover.data }
            publishInfo(for: track, changedAt: .now)
        }
        try context.save()
        return libraryOnly
    }

    /// The release page or source recorded in a file's tags, for context when fixing tags.
    func sourceInfo(for track: Track) async -> (url: String?, comment: String?) {
        guard track.fileExtension == "flac", let url = url(for: track), await ensureLocal(url),
              let tags = try? FLACTags.read(url)
        else { return (nil, nil) }
        return (tags.url, tags.comment)
    }

    func delete(_ track: Track) {
        delete([track])
    }

    /// Deletes songs from the library and iCloud Drive (so from every device), takes them out of
    /// playlists, and removes album and artist folders left empty.
    func delete(_ tracks: [Track]) {
        let paths = Set(tracks.map(\.path))
        guard !paths.isEmpty else { return }
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for playlist in playlists where playlist.trackPaths.contains(where: paths.contains) {
            playlist.trackPaths.removeAll { paths.contains($0) }
        }
        let urls = tracks.compactMap { url(for: $0) }
        let root = root
        Task.detached {
            let coordinator = NSFileCoordinator()
            var folders = Set<URL>()
            for url in urls {
                var error: NSError?
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
                    try? FileManager.default.removeItem(at: url)
                }
                folders.insert(url.deletingLastPathComponent())
            }
            // Album folders, then their artist folders, once nothing is left in them.
            for folder in folders {
                var current = folder
                while let root, current.path.hasPrefix(root.path + "/"),
                      (try? FileManager.default.contentsOfDirectory(atPath: current.path).filter { !$0.hasPrefix(".") })?.isEmpty == true {
                    try? FileManager.default.removeItem(at: current)
                    current = current.deletingLastPathComponent()
                }
            }
        }
        let favorites = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        favorites.filter { paths.contains($0.path) }.forEach(context.delete)
        for track in tracks {
            if let info = existingInfo(track.path) { context.delete(info) }
            context.delete(track)
        }
        try? context.save()
        refreshFavorites()
        // Whole albums gone (no songs left in their folders): their downloads go too. Removing
        // one song leaves the rest of its album downloading.
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        let remaining = Set(((try? context.fetch(FetchDescriptor<Track>())) ?? []).map { ($0.path as NSString).deletingLastPathComponent })
        let emptied = folders.subtracting(remaining)
        if !emptied.isEmpty { onAlbumsDeleted?(emptied) }
    }

    // MARK: - Indexing

    /// One iCloud file as the metadata query sees it.
    struct CloudFile: Sendable {
        let path: String
        let isLocal: Bool
        let modified: Date?
        let size: Int64?
        let isUploaded: Bool
        /// 0 to 1 while downloading to this device.
        let progress: Double?
    }

    private func startMetadataQuery() {
        guard let root else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        // Results are read on this queue, not the main thread: a library's worth of items takes
        // long enough to drop frames.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        query.operationQueue = queue
        let center = NotificationCenter.default
        let unchecked = UncheckedQuery(query: query)
        let read: @Sendable () -> Void = { [weak self] in
            let gatheredAt = Date.now
            let files = Self.gather(unchecked.query, root: root)
            Task { @MainActor in self?.apply(files, gatheredAt: gatheredAt) }
        }
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue) { _ in read() })
        // Updates come several times a second while files upload: read at most once a second.
        let pending = PendingRead()
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: queue) { _ in
            guard !pending.scheduled else { return }
            pending.scheduled = true
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                queue.addOperation {
                    pending.scheduled = false
                    read()
                }
            }
        })
        self.query = query
        queue.addOperation { query.start() }
    }

    /// Reads the query's items. Runs on the query's own queue.
    nonisolated private static func gather(_ query: NSMetadataQuery, root: URL) -> [CloudFile] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let prefix = root.path + "/"
        var files: [CloudFile] = []
        files.reserveCapacity(query.resultCount)
        for case let item as NSMetadataItem in query.results {
            guard let url = (item.value(forAttribute: NSMetadataItemURLKey) as? URL)?.resolvingSymlinksInPath(),
                  url.path.hasPrefix(prefix),
                  AudioFormats.playable.contains(url.pathExtension.lowercased())
            else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            // Songs stay in iCloud until first played or downloaded for offline; ensureLocal fetches them.
            let isLocal = status != nil && status != NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
            let downloading = !isLocal && item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool == true
            files.append(CloudFile(
                path: String(url.path.dropFirst(prefix.count)),
                isLocal: isLocal,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                isUploaded: item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool == true,
                progress: downloading ? (item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double ?? 0) / 100 : nil
            ))
        }
        return files
    }

    /// Asks the query to read its items again (e.g. to retry removing files from this device).
    private func processQueryResults() {
        guard let query, let root, let queue = query.operationQueue else { return }
        let unchecked = UncheckedQuery(query: query)
        queue.addOperation { [weak self] in
            let gatheredAt = Date.now
            let files = Self.gather(unchecked.query, root: root)
            Task { @MainActor in self?.apply(files, gatheredAt: gatheredAt) }
        }
    }

    /// `gatheredAt`: when the query's items were read. Songs added since then aren't in them yet.
    private func apply(_ files: [CloudFile], gatheredAt: Date) {
        var found: [String: FileState] = [:]
        var progress: [String: Double] = [:]
        var uploaded: [String] = []
        for file in files {
            found[file.path] = FileState(isLocal: file.isLocal, modified: file.modified)
            if let size = file.size { fileSizes[file.path] = size }
            if file.isLocal, file.isUploaded, pendingEvictions.contains(file.path) { uploaded.append(file.path) }
            if let fraction = file.progress { progress[file.path] = fraction }
        }
        let cloud = Set(found.filter { !$0.value.isLocal }.map(\.key))
        // Only publish real changes, so views don't redraw on every query update.
        if cloud != cloudOnly { cloudOnly = cloud }
        if progress != downloadProgress { downloadProgress = progress }
        // While songs upload, the index updates several times a second with nothing but their
        // progress; going through the whole library each time made scrolling stutter.
        if found != reconciledFiles {
            reconcile(with: found, gatheredAt: gatheredAt)
            reconciledFiles = found
        }
        // Forget files that went away or are already off this device.
        let stale = pendingEvictions.filter { found[$0].map { !$0.isLocal } ?? true }
        if !stale.isEmpty { pendingEvictions.subtract(stale) }
        evict(uploaded)
    }

    // MARK: - Adding vs downloading

    /// A song just added on this device: kept for offline listening with Automatic Downloads on
    /// (or when the rest of its album is), otherwise removed from here once it's in iCloud.
    private func keepOrRelease(_ track: Track) {
        let folder = (track.path as NSString).deletingLastPathComponent + "/"
        let path = track.path
        let albumKept = ((try? context.fetchCount(FetchDescriptor<Track>(predicate: #Predicate {
            $0.keepOffline && $0.path != path && $0.path.starts(with: folder)
        }))) ?? 0) > 0
        if Self.automaticDownloads || albumKept {
            track.keepOffline = true
            pendingEvictions.remove(path)
        } else {
            track.keepOffline = false
            pendingEvictions.insert(path)
        }
        try? context.save()
    }

    /// Removes uploaded files from this device, leaving them in iCloud. Ones playing wait a minute.
    private func evict(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let kept = Set(tracks.filter(\.keepOffline).map(\.path))
        var busy = false
        var urls: [URL] = []
        for path in paths {
            if kept.contains(path) {
                pendingEvictions.remove(path)
            } else if isInUse?(path) == true {
                busy = true
            } else if let url = url(forPath: path) {
                pendingEvictions.remove(path)
                urls.append(url)
            }
        }
        if !urls.isEmpty {
            Task.detached {
                for url in urls {
                    do {
                        try FileManager.default.evictUbiquitousItem(at: url)
                    } catch {
                        Log.debug("library: couldn't remove \(url.lastPathComponent) from this device: \(error)")
                    }
                }
            }
        }
        if busy, evictionRetry == nil {
            evictionRetry = Task {
                try? await Task.sleep(for: .seconds(60))
                evictionRetry = nil
                processQueryResults()
            }
        }
    }

    /// The first time this runs on a device, everything already here counts as downloaded, so
    /// turning Automatic Downloads off never removes music you had.
    private func markLocalAsDownloaded(_ files: [String: FileState], tracks: [String: Track]) {
        guard usesICloud, !UserDefaults.standard.bool(forKey: Self.markedLocalKey) else { return }
        for (path, file) in files where file.isLocal { tracks[path]?.keepOffline = true }
        UserDefaults.standard.set(true, forKey: Self.markedLocalKey)
    }

    /// Songs here whose album is kept downloaded are kept too, however they arrived: added again
    /// after the index was slow to list them, or added on another device. Songs whose download
    /// was removed are on their way out of this device, so they're left alone.
    private func keepWithAlbum(_ files: [String: FileState], tracks: [String: Track]) {
        guard usesICloud else { return }
        var keptFolders = Set<String>()
        for (path, track) in tracks where track.keepOffline {
            keptFolders.insert((path as NSString).deletingLastPathComponent)
        }
        for (path, file) in files where file.isLocal && !pendingEvictions.contains(path) {
            guard let track = tracks[path], !track.keepOffline,
                  keptFolders.contains((path as NSString).deletingLastPathComponent) else { continue }
            track.keepOffline = true
        }
    }

    /// Bytes this device holds for music kept for offline listening.
    var downloadedBytes: Int64 {
        let tracks = (try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.keepOffline }))) ?? []
        return tracks.reduce(0) { $0 + (cloudOnly.contains($1.path) ? 0 : fileSizes[$1.path] ?? 0) }
    }

    private func rescanLocalFolder() {
        guard let root else { return }
        var found: [String: FileState] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            if AudioFormats.playable.contains(url.pathExtension.lowercased()) {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                found[relativePath(of: url.resolvingSymlinksInPath())] = FileState(isLocal: true, modified: modified)
            }
        }
        reconcile(with: found)
    }

    struct FileState: Equatable {
        let isLocal: Bool
        let modified: Date?
    }

    /// Adds tracks for new files, removes tracks whose files are gone, and reads tags once files
    /// are local, again whenever a file changes (e.g. its tags were fixed on another device).
    private func reconcile(with files: [String: FileState], gatheredAt: Date = .distantFuture) {
        // Imported songs the index has now seen are on their own from here.
        for path in awaitingIndex.keys where files[path] != nil { awaitingIndex[path] = nil }
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var byPath: [String: Track] = [:]
        for track in tracks {
            // A song added after the files were read isn't missing, just not in this read yet.
            // Removing it would bring it back moments later as a new song, losing its details
            // (e.g. being kept downloaded). With a big album uploading, the index can take well
            // over ten minutes to list a new file, so it waits however long that takes.
            let unseen = awaitingIndex[track.path] != nil
            let missing = files[track.path] == nil && track.dateAdded < gatheredAt && !unseen
            if missing || byPath[track.path] != nil {
                context.delete(track)
            } else {
                byPath[track.path] = track
            }
        }
        // Files mid-import are added by the import, already tagged.
        for (path, _) in files where byPath[path] == nil && !importing.contains(path) {
            byPath[path] = insertTrack(path)
        }
        markLocalAsDownloaded(files, tracks: byPath)
        keepWithAlbum(files, tracks: byPath)
        for (path, file) in files {
            guard let track = byPath[path] else { continue }
            let changed = file.modified.map { modified in
                track.fileModified.map { abs($0.timeIntervalSince(modified)) > 1 } ?? true
            } ?? false
            let outdated = track.tagsVersion < Track.currentTagsVersion
            if file.isLocal, !track.hasTags || changed || outdated, let url = root?.appending(path: path) {
                Task { await readTags(for: track, at: url) }
            }
            // Kept for offline but removed by the system to save space: fetch it again.
            if track.keepOffline, !file.isLocal, let url = root?.appending(path: path) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        try? context.save()
        scheduleInfoSync()
        onLibraryChanged?()
    }

    // MARK: - Synced details

    /// Coalesces the many triggers (tag reads, query updates, CloudKit imports) into one pass.
    private func scheduleInfoSync() {
        infoSync?.cancel()
        infoSync = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            syncInfo()
        }
    }

    /// Uploads details for tracks whose files this device has read, and fills in the rest from
    /// details other devices uploaded. A file read here is the truth unless the synced details
    /// are newer than it (an edit elsewhere whose file hasn't arrived yet).
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false

    func syncInfo() {
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        let container = context.container
        Task {
            // On its own context away from the main thread: it reads every song's details (and
            // checks covers, which come from disk), too slow to do while the UI is scrolling.
            let result = await Task.detached(priority: .utility) {
                Self.syncInfo(in: ModelContext(container))
            }.value
            for path in result.covers { queueCover(for: path) }
            if result.applied > 0 { contentChanged(artwork: true) }
            if result.uploaded + result.applied > 0 {
                Log.debug("library: shared details for \(result.uploaded) tracks, applied \(result.applied) from other devices (\(result.synced) synced)")
            }
            syncing = false
            if syncAgain {
                syncAgain = false
                scheduleInfoSync()
            }
        }
    }

    struct InfoSyncResult: Sendable {
        var uploaded = 0
        var applied = 0
        var synced = 0
        /// Songs whose synced details still need a cover.
        var covers: [String] = []
    }

    nonisolated static func syncInfo(in context: ModelContext) -> InfoSyncResult {
        context.autosaveEnabled = false
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let infos = (try? context.fetch(FetchDescriptor<TrackInfo>(sortBy: [SortDescriptor(\.changedAt, order: .reverse)]))) ?? []
        var byPath: [String: TrackInfo] = [:]
        for info in infos {
            // Two devices can create details for the same file at once; keep the newest.
            if byPath[info.path] == nil { byPath[info.path] = info } else { context.delete(info) }
        }
        var result = InfoSyncResult(synced: byPath.count)
        for track in tracks {
            let info = byPath[track.path]
            if track.hasTags {
                let readAt = track.fileModified ?? .distantPast
                if let info, info.changedAt > readAt.addingTimeInterval(1) {
                    if info.changedAt != track.infoUpdated, !info.matches(track) {
                        track.apply(info, includingCover: false)
                        result.applied += 1
                    }
                } else if info == nil || !info!.matches(track) {
                    let changedAt = readAt == .distantPast ? Date.now : readAt
                    let published = info ?? TrackInfo(path: track.path)
                    published.copy(from: track)
                    published.changedAt = changedAt
                    if info == nil { context.insert(published) }
                    track.infoUpdated = changedAt
                    if track.artwork != nil { result.covers.append(track.path) }
                    result.uploaded += 1
                } else if info?.cover == nil, track.artwork != nil {
                    result.covers.append(track.path)
                }
            } else if let info, info.changedAt != track.infoUpdated {
                track.apply(info, includingCover: true)
                result.applied += 1
            } else if let cover = info?.cover, track.artwork == nil {
                // Covers upload after the details, so they can arrive separately.
                track.artwork = cover
            }
        }
        if context.hasChanges { try? context.save() }
        return result
    }

    private func publishInfo(for track: Track, changedAt: Date, existing: TrackInfo? = nil) {
        let found = existing ?? existingInfo(track.path)
        let info = found ?? TrackInfo(path: track.path)
        info.copy(from: track)
        info.changedAt = changedAt
        if found == nil { context.insert(info) }
        track.infoUpdated = changedAt
        if track.artwork != nil { queueCover(for: track.path) }
    }

    private func existingInfo(_ path: String) -> TrackInfo? {
        var descriptor = FetchDescriptor<TrackInfo>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Shrinks artwork to synced covers one at a time, so a first upload of a big library
    /// doesn't hold every image in memory at once.
    private func queueCover(for path: String) {
        guard !coverQueue.contains(path) else { return }
        coverQueue.append(path)
        guard coverWorker == nil else { return }
        coverWorker = Task {
            defer { coverWorker = nil }
            while !coverQueue.isEmpty {
                let path = coverQueue.removeFirst()
                guard let track = existingTrack(path), let artwork = track.artwork,
                      let info = existingInfo(path) else { continue }
                let cover = await Task.detached { Self.cover(from: artwork) }.value
                guard let cover, info.cover != cover, info.modelContext != nil else { continue }
                // A replaced cover counts as a change, so devices that already took these details
                // take the new cover too.
                if info.cover != nil { info.changedAt = .now }
                info.cover = cover
                try? context.save()
            }
        }
    }

    nonisolated static func cover(from artwork: Data) -> Data? {
        guard let image = UIImage(data: artwork) else { return nil }
        let side: CGFloat = 600
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return (image.preparingThumbnail(of: size) ?? image).jpegData(compressionQuality: 0.8)
    }

    private func insertTrack(_ path: String) -> Track {
        let track = Track(path: path)
        context.insert(track)
        return track
    }

    private func existingTrack(_ path: String) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func readTags(for track: Track, at url: URL) async {
        guard !reading.contains(track.path) else { return }
        reading.insert(track.path)
        defer { reading.remove(track.path) }
        let metadata = await Task.detached { await MetadataReader.read(url) }.value
        guard !track.isDeleted else { return }
        track.apply(metadata)
        track.hasTags = true
        track.tagsVersion = Track.currentTagsVersion
        track.fileModified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try? context.save()
        contentChanged(artwork: true)
        scheduleInfoSync()
    }

    func relativePath(of url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    // MARK: - Helpers

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// NSMetadataQuery isn't Sendable, but it's only touched on its own operation queue here.
private struct UncheckedQuery: @unchecked Sendable {
    let query: NSMetadataQuery
}

/// Whether a read of the iCloud index is already on its way. Only touched on the query's queue.
private final class PendingRead: @unchecked Sendable {
    var scheduled = false
}
