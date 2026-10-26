import Foundation
import Observation

/// Apple Music's cover for each library album, shown in place of the files' own art (often a
/// scan with borders, or another edition's), as search and album pages from the catalogue show.
/// Looked up once per album and kept on this device; the files aren't changed. Albums Apple
/// doesn't have keep their own art.
@MainActor
@Observable
final class AppleCovers {
    static let shared = AppleCovers()

    /// Bumped as covers arrive, so views showing artwork draw them.
    private(set) var version = 0

    private struct Entry: Codable {
        /// The cover's file in the folder, or nil when Apple has no such release.
        var file: String?
        var checked: Date
    }

    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var queue: [AlbumKey] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Artists already asked about this session: the catalogue answers those from memory.
    @ObservationIgnored private var askedArtists: Set<String> = []
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private let images: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 60
        return cache
    }()

    private static var folder: URL { URL.applicationSupportDirectory.appending(path: "apple-covers", directoryHint: .isDirectory) }
    private static var indexURL: URL { folder.appending(path: "index.json") }
    /// Albums Apple didn't have are asked about again after this long, in case they're added.
    private static let retryAfter: TimeInterval = 30 * 86400

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// The album's Apple cover if it has been found; otherwise nil, and it's looked for.
    func cover(for album: AlbumKey) -> Data? {
        _ = version
        let key = AlbumIdentity.releaseKey(album)
        guard let entry = entries[key] else {
            lookUp(album, key: key)
            return nil
        }
        guard let file = entry.file else {
            if entry.checked.timeIntervalSinceNow < -Self.retryAfter { lookUp(album, key: key) }
            return nil
        }
        if let data = images.object(forKey: file as NSString) { return data as Data }
        guard let data = try? Data(contentsOf: Self.folder.appending(path: file)) else { return nil }
        images.setObject(data as NSData, forKey: file as NSString)
        return data
    }

    private func lookUp(_ album: AlbumKey, key: String) {
        guard !album.artist.isEmpty, album.artist != "Unknown Artist", queued.insert(key).inserted else { return }
        queue.append(album)
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while !queue.isEmpty {
                let album = queue.removeFirst()
                await find(album)
            }
        }
    }

    private func find(_ album: AlbumKey) async {
        let key = AlbumIdentity.releaseKey(album)
        defer { queued.remove(key) }
        // Apple's search allows about 20 requests a minute; each new artist costs two.
        if askedArtists.insert(ReleaseText.fold(album.artist)).inserted {
            try? await Task.sleep(for: .seconds(4))
        }
        let catalog = await ArtistCatalog.releases(for: album.artist)
        // The release itself, or one whose name gives no edition where the library's doesn't either.
        let release = catalog.first { AlbumIdentity.sameRelease($0.title, album.title) }
            ?? catalog.first { AlbumIdentity.sameReleaseLoosely($0.title, album.title) }
        if let url = release?.artworkURL {
            await save(url, for: key)
        } else {
            entries[key] = Entry(file: nil, checked: .now)
            saveIndex()
        }
    }

    /// Takes the cover an album page already showed from Apple's catalogue, so an album added
    /// from it has Apple's cover from the first song, rather than the files' own until a lookup.
    func prime(_ album: AlbumKey, artworkURL: URL) {
        let key = AlbumIdentity.releaseKey(album)
        guard entries[key]?.file == nil, queued.insert(key).inserted else { return }
        Task {
            defer { queued.remove(key) }
            await save(artworkURL, for: key)
        }
    }

    private func save(_ artworkURL: URL, for key: String) async {
        let large = URL(string: artworkURL.absoluteString.replacingOccurrences(of: "600x600bb", with: "1000x1000bb")) ?? artworkURL
        guard let (data, response) = try? await URLSession.shared.data(from: large),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
        let file = "\(UUID().uuidString).jpg"
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard (try? data.write(to: Self.folder.appending(path: file), options: .atomic)) != nil else { return }
        images.setObject(data as NSData, forKey: file as NSString)
        entries[key] = Entry(file: file, checked: .now)
        saveIndex()
        coverArrived()
    }

    private func saveIndex() {
        try? JSONEncoder().encode(entries).write(to: Self.indexURL, options: .atomic)
    }

    /// Redraws artwork once a few covers have come in, rather than for each.
    private func coverArrived() {
        guard refresh == nil else { return }
        refresh = Task {
            try? await Task.sleep(for: .seconds(1))
            refresh = nil
            ArtworkImages.invalidate()
            version += 1
        }
    }
}

extension Track {
    /// The cover to show: Apple's for the album when it has one, otherwise the file's own.
    @MainActor var cover: Data? {
        AppleCovers.shared.cover(for: albumKey) ?? artwork
    }
}
