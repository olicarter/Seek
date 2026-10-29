import Accelerate
import AVFoundation
import Foundation

/// A song's tempo and key, worked out from its audio for songs whose tags don't say (on the
/// Mac: see SongAnalysisStore). Tempo from how regularly the music's attacks repeat; key from
/// how strongly each note sounds across the song, matched against the shapes of major and minor
/// keys.
enum SongAnalysis {
    struct Result: Codable, Equatable, Sendable {
        var bpm: Double?
        var key: MusicalKey?
    }

    static let sampleRate = 22_050.0

    /// Up to `seconds` of the song from its middle (the intro and outro say least), as mono.
    static func samples(of url: URL, seconds: Double = 120) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let length = min(seconds, duration)
        let start = max(0, (duration - length) / 2)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        var samples: [Float] = []
        samples.reserveCapacity(Int(length * sampleRate))
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    static func analyse(_ url: URL) async -> Result? {
        guard let samples = try? await samples(of: url), samples.count > Int(sampleRate) * 10 else { return nil }
        return analyse(samples)
    }

    static func analyse(_ samples: [Float]) -> Result {
        Result(bpm: tempo(samples), key: key(samples))
    }

    // MARK: - Tempo

    /// Beats a minute, or nil when there's no steady beat. Half and double tempos look alike to
    /// the measure; the one nearer 120 wins, so 70 is read as 140 only if 140 fits better.
    static func tempo(_ samples: [Float]) -> Double? {
        let frame = 1024, hop = 256
        let envelope = onsets(samples, frame: frame, hop: hop)
        guard envelope.count > 400 else { return nil }
        let framesPerSecond = sampleRate / Double(hop)
        // Lags for 60–200 BPM.
        let shortest = Int(framesPerSecond * 60 / 200), longest = Int(framesPerSecond * 60 / 60)
        var scores = [Double](repeating: 0, count: longest + 2)
        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let centred = envelope.map { Double($0 - mean) }
        for lag in shortest...longest + 1 {
            var sum = 0.0
            for i in 0..<(centred.count - lag) { sum += centred[i] * centred[i + lag] }
            scores[lag] = sum / Double(centred.count - lag)
        }
        // Weighted towards common tempos, on a log scale around 125: half-time music (dubstep's
        // kick and snare a bar apart) repeats most strongly at half its tempo, and a triplet feel
        // at two thirds of it.
        func weight(_ lag: Double) -> Double {
            let bpm = 60 * framesPerSecond / lag
            return exp(-0.5 * pow(log2(bpm / 125) / 0.5, 2))
        }
        guard let best = (shortest...longest).max(by: { scores[$0] * weight(Double($0)) < scores[$1] * weight(Double($1)) }),
              scores[best] > 0 else { return nil }
        // Between frames: the peak of a parabola through the best lag and its neighbours.
        let (a, b, c) = (scores[best - 1], scores[best], scores[best + 1])
        let offset = (a - 2 * b + c) == 0 ? 0 : 0.5 * (a - c) / (a - 2 * b + c)
        var bpm = 60 * framesPerSecond / (Double(best) + max(-0.5, min(0.5, offset)))
        // More exactly from the repeat four beats on, where a frame's error is a quarter as much.
        let fourBeats = Int((Double(best) * 4).rounded())
        if fourBeats + 6 < centred.count / 2 {
            func score(_ lag: Int) -> Double {
                var sum = 0.0
                for i in 0..<(centred.count - lag) { sum += centred[i] * centred[i + lag] }
                return sum / Double(centred.count - lag)
            }
            let around = (fourBeats - 4)...(fourBeats + 4)
            if let peak = around.max(by: { score($0) < score($1) }), around.contains(peak - 1), around.contains(peak + 1) {
                let (a, b, c) = (score(peak - 1), score(peak), score(peak + 1))
                let shift = (a - 2 * b + c) == 0 ? 0 : 0.5 * (a - c) / (a - 2 * b + c)
                let refined = 4 * 60 * framesPerSecond / (Double(peak) + max(-0.5, min(0.5, shift)))
                // Only a refinement: the same tempo, give or take a little.
                if abs(refined - bpm) < 2 { bpm = refined }
            }
        }
        // Below 85 is almost always half the tempo a DJ would count.
        if bpm < 85 { bpm *= 2 }
        return bpm.rounded()
    }

    /// How much new sound starts in each moment: the rise in loudness across frequencies
    /// (spectral flux), which peaks on drums and other attacks.
    static func onsets(_ samples: [Float], frame: Int, hop: Int) -> [Float] {
        let magnitudes = spectrogram(samples, size: frame, hop: hop)
        var envelope = [Float](repeating: 0, count: magnitudes.count)
        for i in 1..<magnitudes.count {
            var rise: Float = 0
            for (now, before) in zip(magnitudes[i], magnitudes[i - 1]) where now > before { rise += now - before }
            envelope[i] = rise
        }
        return envelope
    }

    // MARK: - Key

    /// Krumhansl and Kessler's key profiles: how strongly each note belongs, from the tonic up.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func key(_ samples: [Float]) -> MusicalKey? {
        let chroma = chroma(samples)
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        var best: (score: Double, key: MusicalKey)?
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let rotated = (0..<12).map { chroma[($0 + tonic) % 12] }
                let score = correlation(rotated, profile)
                if best == nil || score > best!.score { best = (score, MusicalKey(pitchClass: tonic, isMinor: minor)) }
            }
        }
        return best?.key
    }

    /// How strongly each of the 12 notes sounds across the song, whatever the octave.
    static func chroma(_ samples: [Float]) -> [Double] {
        let size = 8192
        let magnitudes = spectrogram(samples, size: size, hop: size / 2)
        var chroma = [Double](repeating: 0, count: 12)
        let binWidth = sampleRate / Double(size)
        // Each note from 65 Hz to 2 kHz (semitones from A440), and the bins inside it. Low down a
        // note spans only a bin or two, unevenly; summing bins would weigh some notes more than
        // others every time, so each note is its bins' average.
        var notes: [Int: [Int]] = [:]
        for bin in 1..<(size / 2) {
            let frequency = Double(bin) * binWidth
            guard frequency >= 65, frequency <= 2000 else { continue }
            notes[Int((12 * log2(frequency / 440)).rounded()), default: []].append(bin)
        }
        let bands = notes.map { (pitch: (($0.key + 9) % 12 + 12) % 12, bins: $0.value) }
        for spectrum in magnitudes {
            for band in bands {
                let mean = band.bins.reduce(Float(0)) { $0 + spectrum[$1] } / Float(band.bins.count)
                chroma[band.pitch] += log1p(Double(mean))
            }
        }
        return chroma
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        var top = 0.0, sa = 0.0, sb = 0.0
        for (x, y) in zip(a, b) {
            top += (x - meanA) * (y - meanB)
            sa += (x - meanA) * (x - meanA)
            sb += (y - meanB) * (y - meanB)
        }
        return sa == 0 || sb == 0 ? 0 : top / sqrt(sa * sb)
    }

    // MARK: - Spectrum

    /// Magnitudes of each windowed frame (Hann), `size / 2` bins each.
    static func spectrogram(_ samples: [Float], size: Int, hop: Int) -> [[Float]] {
        guard samples.count >= size,
              let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .forward,
                                                            transformType: .complexComplex, ofType: Float.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: size)
        var frames: [[Float]] = []
        frames.reserveCapacity((samples.count - size) / hop + 1)
        var start = 0
        while start + size <= samples.count {
            let windowed = vDSP.multiply(samples[start..<(start + size)], window)
            let (real, imaginary) = dft.transform(real: windowed, imaginary: zeros)
            let half = size / 2
            var magnitudes = [Float](repeating: 0, count: half)
            for bin in 0..<half {
                let re: Float = real[bin], im: Float = imaginary[bin]
                magnitudes[bin] = (re * re + im * im).squareRoot()
            }
            frames.append(magnitudes)
            start += hop
        }
        return frames
    }
}
