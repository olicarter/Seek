import Foundation
import Testing
@testable import Seek

struct AudioLevelsTests {
    private func bands(forTone frequency: Float, amplitude: Float = 0.5) -> [Float] {
        let analyser = SpectrumAnalyser(levels: AudioLevels())
        analyser.setSampleRate(44100)
        analyser.load((0..<SpectrumAnalyser.size).map { amplitude * sin(2 * .pi * frequency * Float($0) / 44100) })
        return analyser.bands()
    }

    @Test func lowToneLightsTheFirstBar() {
        let levels = bands(forTone: 60)
        #expect(levels.firstIndex(of: levels.max()!) == 0)
        #expect(levels[0] > 0.7)
    }

    @Test func midToneLightsAMiddleBar() {
        let levels = bands(forTone: 440)
        #expect(levels.firstIndex(of: levels.max()!) == 2)
    }

    @Test func silenceLightsNothing() {
        #expect(bands(forTone: 440, amplitude: 0).allSatisfy { $0 == 0 })
    }

    @Test func barsShowTheMomentPlayingNotTheLatestMeasured() {
        let levels = AudioLevels()
        // Measured ahead of playback, as the player decodes before you hear it.
        levels.record([0.9, 0.1, 0.1, 0.1, 0.1], at: 1.0)
        levels.record([0.1, 0.1, 0.1, 0.1, 0.9], at: 1.5)
        #expect(levels.levels(at: 1.2)[0] > levels.levels(at: 1.2)[4])
        #expect(levels.levels(at: 1.6)[4] > 0)
        // Nothing measured yet for this moment.
        #expect(levels.levels(at: 0.5).allSatisfy { $0 == 0 })
    }

    /// Streaming, the player decodes most of the song before you hear it: those measurements
    /// must still be there when playback reaches them.
    @Test func barsKeepUpWhenThePlayerDecodesFarAhead() {
        let levels = AudioLevels()
        // A minute measured (about 43 times a second) while playback is still at the start.
        for index in 0..<2_600 {
            levels.record(index.isMultiple(of: 2) ? [0.9, 0.9, 0.9, 0.9, 0.9] : [0.8, 0.8, 0.8, 0.8, 0.8], at: Double(index) / 43)
        }
        for second in [1.0, 20, 45, 59] {
            #expect(levels.levels(at: second).max()! > 0.3, "at \(second)s")
        }
    }
}
