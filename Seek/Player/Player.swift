import AVFoundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class Player {
    enum RepeatMode: CaseIterable {
        case off, all, one

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    var repeatMode: RepeatMode = .off {
        didSet { remember() }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// Where playback is right now, read straight from the player (not the twice-a-second
    /// `currentTime`), for the playing bars.
    var playbackTime: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }
    var upNext: ArraySlice<Track> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    @ObservationIgnored private let library: LibraryStore
    /// The music's levels as it plays, for the bars beside the playing song.
    @ObservationIgnored let levels = AudioLevels()
    /// Fetches songs that aren't in the library. Set by the app.
    @ObservationIgnored var streamer: StreamService?

    /// How much of the current song has arrived, while a streamed song is being fetched.
    var fetchProgress: Double? {
        guard isLoading, let track = current, track.isStreamed else { return nil }
        return streamer?.progress[track.path]
    }
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isSeeking = false
    /// Where to start the current song when it's first played: the position it was left at
    /// before the app last closed (an update, or the system ending it).
    @ObservationIgnored private var resumeAt: Double?
    /// When the position was last saved, so it's saved every few seconds rather than twice a second.
    @ObservationIgnored private var rememberedTime: Double = 0

    init(library: LibraryStore) {
        self.library = library
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // While the next song is being fetched, the old one's position would show.
                // Nor before a restored song has loaded, whose place was kept from last time.
                guard let self, !self.isSeeking, !self.isLoading, self.player.currentItem != nil else { return }
                self.currentTime = time.seconds
                if abs(self.currentTime - self.rememberedTime) >= 5 { self.remember() }
            }
        }
        setUpRemoteCommands()
        restore()
    }

    // MARK: - Queue

    func play(_ tracks: [Track], startingAt start: Int = 0) {
        guard tracks.indices.contains(start) else { return }
        originalQueue = tracks
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: start)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = start
        }
        load(autoplay: true)
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        play(tracks, startingAt: Int.random(in: tracks.indices))
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { return play([track]) }
        queue.insert(track, at: index + 1)
        originalQueue.append(track)
        remember()
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { return play([track]) }
        queue.append(track)
        originalQueue.append(track)
        remember()
    }

    func jump(to track: Track) {
        guard let position = queue.firstIndex(where: { $0 === track }) else { return }
        index = position
        load(autoplay: true)
    }

    func removeFromQueue(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        queue.remove(atOffsets: absolute)
        remember()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        var rest = Array(upNext)
        rest.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + rest
        remember()
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let current else { return }
        if shuffle {
            queue = [current] + queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = queue.firstIndex(where: { $0 === current }) ?? 0
        }
        remember()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        activateSession()
        if player.currentItem == nil { return load(autoplay: true, from: resumeAt ?? 0) }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
        remember()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            pause()
            seek(to: 0)
            return
        }
        load(autoplay: true)
    }

    /// What `next()` would play.
    var nextTrack: Track? {
        if queue.indices.contains(index + 1) { return queue[index + 1] }
        return repeatMode == .all && !queue.isEmpty ? queue[0] : nil
    }

    /// The song before this one in the queue.
    var previousTrack: Track? { queue.indices.contains(index - 1) ? queue[index - 1] : nil }

    /// Back to the song before, however far into this one (swiping, unlike the back button,
    /// never restarts the song).
    func skipBack() {
        guard index > 0 else { return }
        index -= 1
        load(autoplay: isPlaying)
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load(autoplay: isPlaying)
        }
    }

    func seek(to seconds: Double) {
        // A song restored from last time, not loaded yet: it starts here once played.
        if player.currentItem == nil, !isLoading, current != nil {
            resumeAt = seconds
            currentTime = seconds
            updateNowPlaying()
            return remember()
        }
        isSeeking = true
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlaying()
            }
        }
    }

    private func load(autoplay: Bool, from start: Double = 0) {
        guard let track = current else { return }
        loadTask?.cancel()
        resumeAt = nil
        player.pause()
        // Let go of the previous song straight away, so nothing of it lingers while this one loads.
        player.replaceCurrentItem(with: nil)
        currentTime = start
        duration = track.duration
        isLoading = true
        isPlaying = autoplay
        updateNowPlaying()
        remember()

        // Fetch the next song while this one plays, so they follow on without a wait.
        if let next = upNext.first, next.isStreamed { streamer?.prefetch(next) }
        fetchArtwork(for: track)

        loadTask = Task {
            let resolved = await playableItem(for: track)
            guard !Task.isCancelled, current === track else { return }
            isLoading = false
            guard let item = resolved else {
                isPlaying = false
                return
            }
            levels.reset()
            await levels.attach(to: item)
            guard !Task.isCancelled, current === track else { return }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.itemFinished() }
            }
            player.replaceCurrentItem(with: item)
            if start > 0 {
                await player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                guard !Task.isCancelled, current === track else { return }
            }
            if let loaded = try? await item.asset.load(.duration), loaded.isNumeric {
                duration = loaded.seconds
            }
            if autoplay {
                activateSession()
                player.play()
            }
            updateNowPlaying()
        }
    }

    /// A streamed song's cover, which only its release page has.
    private func fetchArtwork(for track: Track) {
        guard track.isStreamed, track.artwork == nil, let art = track.stream?.artworkURL else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: art) {
                track.artwork = data
                if current === track { updateNowPlaying() }
            }
        }
    }

    /// A library song's file (fetched from iCloud if needed), or a streamed song: played while
    /// it downloads where the format allows, otherwise once it's all here.
    /// A library song's file on the Mac, when it's reachable (see MacLink.fileURL).
    @ObservationIgnored var fileOnMac: ((String) -> URL?)?

    private func playableItem(for track: Track) async -> AVPlayerItem? {
        guard track.isStreamed else {
            guard let url = library.url(for: track) else { return nil }
            // Not here yet (just added on the Mac, still coming through iCloud): played from the
            // Mac while this device's copy downloads, rather than waiting for it.
            if library.usesICloud, !LibraryStore.isDownloaded(url), let remote = fileOnMac?(track.path) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                Log.debug("player: \(track.title) isn't here yet; playing it from the Mac")
                return AVPlayerItem(url: remote)
            }
            guard await library.ensureLocal(url) else { return nil }
            return AVPlayerItem(url: url)
        }
        switch await streamer?.fetch(track) {
        case .file(let url), .remote(let url):
            return AVPlayerItem(url: url)
        case .progressive(let loader, let file):
            let asset = AVURLAsset(url: loader.playerURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            if (try? await asset.load(.isPlayable)) == true {
                return AVPlayerItem(asset: asset)
            }
            Log.debug("player: \(file.fileExtension) can't play while downloading; waiting for the whole file")
            return await streamer?.waitForFile(file).map(AVPlayerItem.init(url:))
        case nil:
            return nil
        }
    }

    private func itemFinished() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - System integration

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        // The lock screen's and Control Center's favourite button.
        center.likeCommand.localizedTitle = "Favourite"
        center.likeCommand.localizedShortTitle = "Favourite"
        center.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let track = self.current else { return }
                self.library.toggleFavorite(track)
                self.updateFavoriteCommand()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Shows the lock screen's favourite button as on or off for the current song.
    func updateFavoriteCommand() {
        let command = MPRemoteCommandCenter.shared().likeCommand
        command.isEnabled = current != nil
        command.isActive = current.map(library.isFavorite) ?? false
    }

    private func updateNowPlaying() {
        updateFavoriteCommand()
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let data = track.cover, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Remembering what was playing

/// The queue and where it was up to, saved as it changes so an update (or the system closing
/// the app) picks up where it was left, paused.
private struct PlayerMemory: Codable {
    /// A library song by its path; a streamed one with everything needed to fetch it again.
    struct Item: Codable {
        var path: String
        var streamed: Streamed?
    }

    struct Streamed: Codable {
        var title: String
        var artist: String
        var album: String
        var number: Int
        var disc: Int
        var duration: Double
        var source: StreamSource
    }

    var queue: [Item]
    var original: [Item]
    var index: Int
    var time: Double
    var shuffle: Bool
    var repeatMode: Int

    static var url: URL { URL.applicationSupportDirectory.appending(path: "now-playing.json") }
}

extension Player {
    fileprivate func remember() {
        rememberedTime = currentTime
        guard !queue.isEmpty else {
            try? FileManager.default.removeItem(at: PlayerMemory.url)
            return
        }
        // Streamed songs are the same objects in both lists: each is saved once per list.
        func item(_ track: Track) -> PlayerMemory.Item {
            PlayerMemory.Item(path: track.path, streamed: track.stream.map {
                PlayerMemory.Streamed(title: track.title, artist: track.artist, album: track.album,
                                      number: track.trackNumber, disc: track.discNumber,
                                      duration: track.duration, source: $0)
            })
        }
        let memory = PlayerMemory(queue: queue.map(item), original: originalQueue.map(item), index: index,
                                  time: currentTime, shuffle: shuffle,
                                  repeatMode: RepeatMode.allCases.firstIndex(of: repeatMode) ?? 0)
        try? JSONEncoder().encode(memory).write(to: PlayerMemory.url, options: .atomic)
    }

    /// Puts back what was playing, paused at the same place. Nothing loads until it's played,
    /// so opening the app doesn't start fetching a streamed song.
    fileprivate func restore() {
        guard let data = try? Data(contentsOf: PlayerMemory.url),
              let memory = try? JSONDecoder().decode(PlayerMemory.self, from: data) else { return }
        let library = Dictionary(self.library.allTracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // One object per song, so the shuffled and original lists still find each other.
        var streamed: [String: Track] = [:]
        func track(_ item: PlayerMemory.Item) -> Track? {
            guard let saved = item.streamed else { return library[item.path] }
            if let made = streamed[item.path] { return made }
            let made = Track.streamed(ReferenceTrack(number: saved.number, disc: saved.disc, title: saved.title, duration: saved.duration),
                                      artist: saved.artist, album: saved.album, source: saved.source)
            streamed[item.path] = made
            return made
        }
        let restored = memory.queue.map(track)
        // Songs deleted since are skipped, keeping the place on the same song.
        guard memory.queue.indices.contains(memory.index), let playing = restored[memory.index] else { return }
        queue = restored.compactMap { $0 }
        originalQueue = memory.original.compactMap(track)
        index = queue.firstIndex { $0 === playing } ?? 0
        shuffle = memory.shuffle
        duration = playing.duration
        currentTime = min(memory.time, max(playing.duration - 1, 0))
        resumeAt = currentTime
        fetchArtwork(for: playing)
        // Last: setting it saves, which should save the place just restored.
        repeatMode = RepeatMode.allCases.indices.contains(memory.repeatMode) ? RepeatMode.allCases[memory.repeatMode] : .off
        updateNowPlaying()
    }
}
