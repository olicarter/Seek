import Foundation
import Testing
@testable import Seek

struct SongAnalysisTests {
    private let rate = SongAnalysis.sampleRate

    /// A kick every beat (a short decaying low thump), for `seconds`.
    private func clicks(bpm: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let beat = 60 / bpm * rate
        var at = 0.0
        while Int(at) < samples.count {
            for i in 0..<min(2000, samples.count - Int(at)) {
                let t = Double(i) / rate
                samples[Int(at) + i] += Float(sin(2 * .pi * 60 * t) * exp(-t * 30))
            }
            at += beat
        }
        return samples
    }

    /// Notes held together, as sine waves with a few overtones.
    private func chord(_ frequencies: [Double], seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return Float(frequencies.reduce(0.0) { sum, f in
                sum + sin(2 * .pi * f * t) + 0.5 * sin(4 * .pi * f * t) + 0.25 * sin(6 * .pi * f * t)
            } / Double(frequencies.count) * 0.3)
        }
    }

    @Test func tempoOfASteadyBeat() {
        for bpm in [90.0, 120, 128, 140, 174] {
            let found = SongAnalysis.tempo(clicks(bpm: bpm, seconds: 30))
            #expect(found.map { abs($0 - bpm) <= 1 } == true, "\(bpm) BPM read as \(found ?? 0)")
        }
    }

    @Test func keyOfAChordProgression() {
        // A minor: Am, Dm, E, Am (i–iv–V–i). Am–F–C–G wouldn't do: it's C major's vi–IV–I–V too,
        // the very same notes; E's G♯ is what only A minor has.
        let progression = [[220.0, 261.63, 329.63], [146.83, 174.61, 220.0], [164.81, 207.65, 246.94], [220.0, 261.63, 329.63]]
        let minor = progression.flatMap { chord($0, seconds: 3) }
        #expect(SongAnalysis.key(minor)?.camelot == "8A")
        // C major: C, F, G, C.
        let major = [[261.63, 329.63, 392.0], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66], [261.63, 329.63, 392.0]]
            .flatMap { chord($0, seconds: 3) }
        #expect(SongAnalysis.key(major)?.camelot == "8B")
    }

    @Test func keyNotation() {
        #expect(MusicalKey("Am")?.camelot == "8A")
        #expect(MusicalKey("A minor")?.camelot == "8A")
        #expect(MusicalKey("08A")?.musical == "A minor")
        #expect(MusicalKey("C")?.camelot == "8B")
        #expect(MusicalKey("F#m")?.camelot == "11A")
        #expect(MusicalKey("Gbm")?.camelot == "11A")
        #expect(MusicalKey("Bbmaj")?.camelot == "6B")
        #expect(MusicalKey("10A")?.musical == "B minor")
        #expect(MusicalKey("3B")?.musical == "D♭ major")
        #expect(MusicalKey("") == nil)
        #expect(MusicalKey("0") == nil)
    }
}
