import AVFoundation
import Foundation
import Testing
@testable import Seek

/// Plays real files through the loader while the second part is still "downloading", to check
/// each format can start before it's all here.
@MainActor
struct ProgressiveLoaderTests {
    private final class Bundle_ {}

    // WAV isn't here: it's only played once fully downloaded (see StreamService.progressiveFormats).
    @Test(arguments: ["flac", "mp3", "m4a"])
    func playsWhileTheFileIsStillArriving(_ format: String) async throws {
        let source = try #require(Bundle(for: Bundle_.self).url(forResource: "tone", withExtension: format))
        let full = try Data(contentsOf: source)
        let partial = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format)")
        // A third of the file to start with; the rest arrives once playback has begun.
        try full.prefix(full.count / 3).write(to: partial)

        let loader = ProgressiveLoader(fileURL: partial, totalSize: Int64(full.count), fileExtension: format)
        let asset = AVURLAsset(url: loader.playerURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        #expect(try await asset.load(.isPlayable))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 8) < 0.5)

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.play()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: full.dropFirst(full.count / 3))
            try handle.close()
        }
        var reached = 0.0
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            reached = player.currentTime().seconds
            if reached > 1.5 { break }
        }
        player.pause()
        #expect(reached > 1.5, "\(format) only reached \(reached)s")
    }

    /// The bars measure a song while it streams as well as once it's in the library.
    @Test(arguments: [false, true])
    func levelsAreMeasuredWhileStreaming(_ streaming: Bool) async throws {
        let source = try #require(Bundle(for: Bundle_.self).url(forResource: "tone", withExtension: "flac"))
        let item: AVPlayerItem
        if streaming {
            let full = try Data(contentsOf: source)
            let partial = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
            // A third to start with, the rest arriving as it plays.
            try full.prefix(full.count / 3).write(to: partial)
            Task.detached {
                try? await Task.sleep(for: .milliseconds(800))
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                try handle.write(contentsOf: full.dropFirst(full.count / 3))
                try handle.close()
            }
            let loader = ProgressiveLoader(fileURL: partial, totalSize: Int64(full.count), fileExtension: "flac")
            let asset = AVURLAsset(url: loader.playerURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            #expect(try await asset.load(.isPlayable))
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: source)
        }
        let levels = AudioLevels()
        await levels.attach(to: item)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var loudest: Float = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            loudest = max(loudest, levels.levels(at: player.currentTime().seconds).max() ?? 0)
        }
        player.pause()
        #expect(loudest > 0.3, "streaming: \(streaming), reached \(player.currentTime().seconds)s, loudest \(loudest)")
    }
}
