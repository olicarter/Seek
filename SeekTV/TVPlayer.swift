import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// A song the TV can play: a file in the Mac's library, or the Mac's stream of one that isn't.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String
    var artist: String
    var album: String
    var artwork: URL?
}

/// Plays an album's songs in order, with the Siri Remote and Control Center's Now Playing.
@MainActor
@Observable
final class TVPlayer {
    private(set) var queue: [QueueItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                if let length = self.player.currentItem?.duration.seconds, length.isFinite { self.duration = length }
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.next()
            }
        }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
    }

    func play(_ items: [QueueItem], startingAt start: Int = 0) {
        guard !items.isEmpty else { return }
        queue = items
        load(min(max(start, 0), items.count - 1))
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        if index + 1 < queue.count { load(index + 1) } else { pause(); player.seek(to: .zero) }
    }

    func previous() {
        // Back to the start, unless it's only just begun (as in Apple Music).
        if time > 3 || index == 0 { player.seek(to: .zero) } else { load(index - 1) }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func load(_ i: Int) {
        index = i
        time = 0
        duration = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: queue[i].url))
        resume()
        loadArtwork(queue[i].artwork)
    }

    private func loadArtwork(_ url: URL?) {
        artwork = nil
        guard let url else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album, MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
