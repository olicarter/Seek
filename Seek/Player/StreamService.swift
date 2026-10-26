import Foundation
import Network
import Observation

/// Where a song that isn't in the library can be played from: Soulseek files (best first) and,
/// as a last resort, the release's Bandcamp page, whose own player streams it.
struct StreamSource: Codable {
    var candidates: [RemoteFile]
    var bandcampPage: URL?
    var number: Int
    var title: String
    var artworkURL: URL?
}

extension Track {
    /// A song to play without adding it to the library. Not saved anywhere.
    static func streamed(_ reference: ReferenceTrack, artist: String, album: String, source: StreamSource) -> Track {
        let track = Track(path: "stream/\(ReleaseText.fold(artist))/\(ReleaseText.fold(album))/\(reference.disc)-\(reference.number)-\(ReleaseText.fold(reference.title))")
        track.title = reference.title
        track.artist = artist
        track.albumArtist = artist
        track.album = album
        track.trackNumber = reference.number
        track.discNumber = reference.disc
        track.duration = reference.duration ?? 0
        track.hasTags = true
        track.stream = source
        return track
    }

    var isStreamed: Bool { stream != nil }
}

/// How good a copy to stream.
enum StreamingQuality: String, CaseIterable, Identifiable {
    /// Whatever the library would get (Settings › Preferred Quality).
    case library
    /// MP3s where there are any: a tenth of the size, so they start sooner.
    case mp3

    var id: String { rawValue }
    static let defaultsKey = "streamingQuality"

    var name: String {
        switch self {
        case .library: "Same as Library"
        case .mp3: "MP3 for Faster Start"
        }
    }
}

/// Fetches songs to play into a cache on the device (not the library), keeping it under a size
/// limit by dropping the songs played longest ago. Tries each Soulseek copy in turn, moving on
/// from ones that don't start, and falls back to Bandcamp's stream when none work.
@MainActor
@Observable
final class StreamService {
    /// Download progress of songs being fetched, by track path.
    private(set) var progress: [String: Double] = [:]

    @ObservationIgnored private let client: SoulseekClient
    @ObservationIgnored private var fetches: [String: Task<Playable?, Never>] = [:]
    @ObservationIgnored private var index: [String: Entry] = [:]
    /// Players reading downloads still in progress, by Soulseek file. Held here because the
    /// player only keeps a weak reference.
    @ObservationIgnored private var loaders: [String: ProgressiveLoader] = [:]

    /// What the player gets for a streamed song.
    enum Playable {
        /// Fully downloaded, in the cache.
        case file(URL)
        /// Still downloading; play through the loader.
        case progressive(ProgressiveLoader, file: RemoteFile)
        /// Bandcamp's own stream.
        case remote(URL)
    }

    /// Enough of a file to start playing it: its header and the first few seconds.
    static let startBytes: UInt64 = 512 * 1024
    /// Formats the player reads while they download. WAV and AIFF need more of the file first,
    /// so those are played once they're all here.
    static let progressiveFormats: Set<String> = ["flac", "mp3", "m4a", "aac", "alac"]

    private struct Entry: Codable {
        var fileName: String
        var size: Int64
        var lastUsed: Date
    }

    static let cacheLimit: Int64 = 2_000_000_000
    /// How long a copy gets to start sending before the next one is tried.
    static let startTimeout: TimeInterval = 15

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "Stream", directoryHint: .isDirectory)
    }

    private static var indexURL: URL { directory.appending(path: "index.json") }

    init(client: SoulseekClient) {
        self.client = client
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.isUnmetered = unmetered }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // The system may have cleared some of the cache; forget what's gone.
            index = saved.filter { FileManager.default.fileExists(atPath: Self.directory.appending(path: $0.value.fileName).path) }
        }
    }

    // MARK: - Queues

    typealias Queue = [(reference: ReferenceTrack, track: Track)]
    @ObservationIgnored private var queues: [String: Queue] = [:]
    @ObservationIgnored private var queueOrder: [String] = []

    /// An album's streamable songs, built once and reused until its sources change. Album
    /// pages redraw often (search results arriving, downloads progressing), and rebuilding
    /// means matching every song against every copy.
    func queue(reference: AlbumReference?, artist: String, album: String, folders: [RemoteFolder],
               bandcampPage: URL?, artworkURL: URL?, artwork: Data? = nil) -> Queue {
        let signature = [
            artist, album, bandcampPage?.absoluteString ?? "",
            reference.map { $0.tracks.map(\.title).joined(separator: "|") } ?? "-",
            folders.map { "\($0.id)#\($0.files.count)" }.joined(separator: ","),
        ].joined(separator: "\u{1}")
        if let cached = queues[signature] { return cached }
        let built = StreamQueue.build(reference: reference, artist: artist, album: album, folders: folders,
                                      bandcampPage: bandcampPage, artworkURL: artworkURL)
        if let artwork { built.forEach { $0.track.artwork = artwork } }
        queues[signature] = built
        queueOrder.append(signature)
        if queueOrder.count > 30 { queues[queueOrder.removeFirst()] = nil }
        return built
    }

    // MARK: - Cache

    func cachedURL(for file: RemoteFile) -> URL? {
        guard let entry = index[file.id] else { return nil }
        let url = Self.directory.appending(path: entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        index[file.id]?.lastUsed = .now
        save()
        return url
    }

    /// Takes a finished streaming download into the cache.
    func store(_ transfer: Transfer, from url: URL) throws {
        let name = "\(UUID().uuidString).\(transfer.file.fileExtension)"
        try FileManager.default.moveItem(at: url, to: Self.directory.appending(path: name))
        index[transfer.file.id] = Entry(fileName: name, size: Int64(transfer.size), lastUsed: .now)
        // A player reading the download carries on from the cached copy.
        loaders[transfer.file.id]?.update(fileURL: Self.directory.appending(path: name))
        evict()
        save()
    }

    private func evict() {
        var total = index.values.reduce(0) { $0 + $1.size }
        for (id, entry) in index.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > Self.cacheLimit {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: entry.fileName))
            index[id] = nil
            total -= entry.size
        }
    }

    private func save() {
        try? JSONEncoder().encode(index).write(to: Self.indexURL, options: .atomic)
    }

    /// Bytes of streamed songs kept on the device.
    var cacheSize: Int64 { index.values.reduce(0) { $0 + $1.size } }

    func clearCache() {
        for entry in index.values { try? FileManager.default.removeItem(at: Self.directory.appending(path: entry.fileName)) }
        index = [:]
        save()
    }

    // MARK: - Fetching

    /// Starts fetching a song ahead of time, e.g. the next one in the queue.
    func prefetch(_ track: Track) {
        guard track.stream != nil else { return }
        Task { _ = await fetch(track) }
    }

    /// Something to play for the song as soon as possible: a cached file, a download that has
    /// started (played while it finishes), or Bandcamp's stream if no Soulseek copy works.
    func fetch(_ track: Track) async -> Playable? {
        guard let source = track.stream else { return nil }
        let key = track.path
        if let pending = fetches[key] { return await pending.value }
        let task = Task { await self.fetch(source, key: key) }
        fetches[key] = task
        let url = await task.value
        fetches[key] = nil
        progress[key] = nil
        return url
    }

    private func fetch(_ source: StreamSource, key: String) async -> Playable? {
        let candidates = ordered(source.candidates)
        for file in candidates { if let cached = cachedURL(for: file) { return .file(cached) } }
        var waiting = candidates[...]
        var asking: [(file: RemoteFile, transfer: Transfer, since: Date)] = []
        var lastAsked = Date.distantPast
        while true {
            // The best copy at once; another alongside when none has started within a few seconds.
            if let next = waiting.first,
               Self.asksAnother(asking: asking.count, anySending: asking.contains { Self.isSending($0.transfer) },
                                sinceLastAsk: Date.now.timeIntervalSince(lastAsked)) {
                waiting.removeFirst()
                if !asking.isEmpty { SoulseekEvents.record("stream: \(source.title) hasn't started; also asking \(next.username)") }
                asking.append((next, client.stream(next), .now))
                lastAsked = .now
            }
            if asking.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(200))
            progress[key] = asking.map(\.transfer.progress).max()
            for (file, transfer, _) in asking {
                if transfer.state == .completed, let cached = cachedURL(for: file) {
                    stopAsking(asking, except: transfer)
                    return .file(cached)
                }
                guard Self.isSending(transfer) else { continue }
                // One has started: the others are let go.
                if asking.count > 1 {
                    stopAsking(asking, except: transfer)
                    asking = asking.filter { $0.transfer === transfer }
                }
                if transfer.state == .downloading, Self.progressiveFormats.contains(file.fileExtension),
                   transfer.bytesReceived >= min(Self.startBytes, transfer.size) {
                    return .progressive(loader(for: transfer), file: file)
                }
                break
            }
            asking.removeAll { entry in
                if case .failed = entry.transfer.state { return true }
                if entry.transfer.state == .cancelled { return true }
                // Stuck in someone's queue or failing to connect: let it go.
                if !Self.isSending(entry.transfer), Date.now.timeIntervalSince(entry.since) > Self.startTimeout {
                    SoulseekEvents.record("stream: \(entry.file.username) didn't start within \(Int(Self.startTimeout))s")
                    if entry.transfer.forStreaming { client.cancel(entry.transfer) }
                    return true
                }
                return false
            }
        }
        return await bandcampStream(source).map(Playable.remote)
    }

    /// Seconds to wait for a copy to start before asking another alongside it.
    static let hedgeDelay: TimeInterval = 4
    /// Copies asked at once for one song: a second only while the first is slow to start.
    static let maxAsking = 2

    /// Whether to ask another copy for a song now: the first straight away; a second alongside
    /// only when nothing has started for a few seconds. A song is one user's single upload, so
    /// asking two briefly costs them little, unlike queueing a whole album with several.
    nonisolated static func asksAnother(asking: Int, anySending: Bool, sinceLastAsk: TimeInterval) -> Bool {
        asking == 0 || asking < maxAsking && !anySending && sinceLastAsk >= hedgeDelay
    }

    private static func isSending(_ transfer: Transfer) -> Bool {
        transfer.state == .downloading || transfer.state == .importing
    }

    /// Cancels the other copies asked for, but never a library download being shared with the player.
    private func stopAsking(_ asking: [(file: RemoteFile, transfer: Transfer, since: Date)], except kept: Transfer) {
        for entry in asking where entry.transfer !== kept && entry.transfer.forStreaming {
            client.cancel(entry.transfer)
        }
    }

    // MARK: - Starting early

    /// Whether the network is unmetered (Wi-Fi), where fetching ahead costs nothing.
    private(set) var isUnmetered = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    /// The first song of an album page left open a moment, on Wi-Fi: Play then starts from the
    /// phone rather than waiting on a peer.
    func warm(_ track: Track?) {
        guard isUnmetered, let track, track.isStreamed else { return }
        prefetch(track)
    }

    /// One loader per download, following it until it's in the cache (or gives up for good).
    private func loader(for transfer: Transfer) -> ProgressiveLoader {
        if let existing = loaders[transfer.file.id] { return existing }
        let loader = ProgressiveLoader(fileURL: transfer.partialURL, totalSize: Int64(transfer.size),
                                       fileExtension: transfer.file.fileExtension)
        loaders[transfer.file.id] = loader
        let id = transfer.file.id
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                if case .failed = transfer.state {
                    loader.update(failed: true)
                    break
                }
                if transfer.state == .cancelled {
                    loader.update(failed: true)
                    break
                }
                if transfer.state == .completed { break }
            }
            // Kept a while for a player still reading it, then let go.
            try? await Task.sleep(for: .seconds(600))
            if loaders[id] === loader { loaders[id] = nil }
        }
        return loader
    }

    /// The finished file, for formats the player can't read while they download.
    func waitForFile(_ file: RemoteFile) async -> URL? {
        for _ in 0..<1800 {
            if let cached = cachedURL(for: file) { return cached }
            let transfer = client.transfers.first { $0.file.id == file.id && $0.forStreaming }
            if transfer == nil || transfer?.state == .cancelled { return nil }
            if case .failed = transfer?.state { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Lossy copies first when streaming is set to favour a fast start.
    private func ordered(_ files: [RemoteFile]) -> [RemoteFile] {
        let preference = UserDefaults.standard.string(forKey: StreamingQuality.defaultsKey).flatMap(StreamingQuality.init) ?? .library
        guard preference == .mp3 else { return files }
        return files.filter { !$0.isLossless } + files.filter(\.isLossless)
    }

    /// The fallback: the release page's own stream of the song, fetched fresh since its links expire.
    private func bandcampStream(_ source: StreamSource) async -> URL? {
        guard let page = source.bandcampPage, let info = try? await BandcampAPI.release(at: page) else { return nil }
        let title = ReleaseText.fold(ReleaseText.cleanTitle(source.title))
        let track = info.tracks.first { $0.matchTitles.contains(title) } ?? info.tracks.first { $0.number == source.number }
        if track?.streamURL != nil { SoulseekEvents.record("stream: no Soulseek copy of \(source.title) worked; using Bandcamp's stream") }
        return track?.streamURL
    }
}

/// Turns a release's tracklist into songs the player can stream, each with every Soulseek copy
/// that has it (best first) and the Bandcamp page as a fallback. Songs with neither are left out.
enum StreamQueue {
    static func build(reference: AlbumReference?, artist: String, album: String, folders: [RemoteFolder],
                      bandcampPage: URL?, artworkURL: URL?) -> [(reference: ReferenceTrack, track: Track)] {
        let tracklist = reference?.tracks ?? (folders.first?.files ?? []).enumerated().map { index, file in
            ReferenceTrack(number: index + 1, disc: 1, title: ReleaseDetailView.trackName(file.name), duration: file.duration.map(Double.init))
        }
        return tracklist.compactMap { reference in
            let candidates = folders.compactMap { MissingTracks.file(for: reference, in: $0.files) }
            guard !candidates.isEmpty || bandcampPage != nil else { return nil }
            let source = StreamSource(candidates: candidates, bandcampPage: bandcampPage, number: reference.number,
                                      title: reference.title, artworkURL: artworkURL)
            return (reference, Track.streamed(reference, artist: artist, album: album, source: source))
        }
    }
}
