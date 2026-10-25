import Accelerate
import AVFoundation
import CoreAudio
import MediaToolbox

/// How loud each part of the spectrum is right now, for the now-playing bars beside a song.
/// Measured with a tap on the player's audio, so the bars move with the music itself.
final class AudioLevels: @unchecked Sendable {
    static let bandCount = 5
    /// Low to high, roughly kick, bass, vocals, presence and cymbals.
    static let bandEdges: [Float] = [40, 120, 400, 1500, 5000, 14000]

    private let lock = NSLock()
    /// Levels by position in the song: each measurement's time, and its band levels one after
    /// another in `values`. The player decodes ahead of what you hear (by a few seconds over
    /// Bluetooth, and by most of the song when it's streaming and the file is already in), so
    /// measurements are kept until playback passes them and the bars look up the moment that's
    /// actually playing.
    private var times: [Double] = []
    private var values: [Float] = []
    /// Far more than a song needs; only reached if nothing reads the levels.
    static let maxFrames = 200_000
    /// Each band's recent peak, falling slowly, so loud hits reach the top whatever the mix.
    private var ceiling = [Float](repeating: 0, count: bandCount)
    private var shown = [Float](repeating: 0, count: bandCount)

    /// 0 to 1 per band, for this moment in the song (seconds).
    /// 0 to 1 per band, for this moment in the song (seconds).
    func levels(at time: Double) -> [Float] {
        lock.withLock {
            // The measurements either side of `time`, blended, so the bars move smoothly between
            // them rather than stepping whenever a screen refresh lands on a new one.
            var low = 0, high = times.count
            while low < high {
                let middle = (low + high) / 2
                if times[middle] <= time { low = middle + 1 } else { high = middle }
            }
            // What's been played (bar a second, for a short skip back) won't be asked for again.
            let played = times[..<low].lastIndex { $0 < time - 1 } ?? -1
            if played > 0 {
                times.removeFirst(played)
                values.removeFirst(played * Self.bandCount)
                low -= played
            }
            guard low > 0, time - times[low - 1] < 0.3 else { return [Float](repeating: 0, count: Self.bandCount) }
            let before = frame(low - 1)
            guard low < times.count else { return before }
            let fraction = Float((time - times[low - 1]) / max(times[low] - times[low - 1], 0.001))
            return zip(before, frame(low)).map { $0 + ($1 - $0) * fraction }
        }
    }

    private func frame(_ index: Int) -> [Float] {
        Array(values[(index * Self.bandCount)..<((index + 1) * Self.bandCount)])
    }

    func reset() {
        lock.withLock {
            times.removeAll()
            values.removeAll()
            ceiling = [Float](repeating: 0, count: Self.bandCount)
            shown = [Float](repeating: 0, count: Self.bandCount)
        }
    }

    /// Records one measurement, scaled against each band's recent peak: a band at its peak fills
    /// the bar, 30 dB below it is a dot. In between the bar follows a curve, not a straight
    /// line: music spends most of its time within a few dB of its peak, so that's where the bar
    /// gets most of its height (6 dB below the peak is already down to about half). Smoothed like a level meter: rises almost at once (about
    /// 25 ms) and falls slowly (about 200 ms), so the bars follow the music without twitching.
    func record(_ measured: [Float], at time: Double) {
        lock.withLock {
            // A seek: what was measured before no longer lines up.
            if let last = times.last, time < last - 0.05 || time > last + 1 {
                times.removeAll(keepingCapacity: true)
                values.removeAll(keepingCapacity: true)
            }
            for band in shown.indices {
                let level = measured[band]
                // About 43 measurements a second; the peak falls about 3 dB a second.
                ceiling[band] = max(level, ceiling[band] - 0.0012)
                let relative = (level - (ceiling[band] - 0.5)) / 0.5
                // Near-silence stays low, however it compares with the peak.
                let target = pow(min(max(relative, 0), 1), 3) * min(level * 4, 1)
                let response: Float = target > shown[band] ? 0.7 : 0.1
                shown[band] += (target - shown[band]) * response
            }
            if times.count >= Self.maxFrames {
                times.removeFirst(Self.maxFrames / 2)
                values.removeFirst(Self.maxFrames / 2 * Self.bandCount)
            }
            times.append(time)
            values.append(contentsOf: shown)
        }
    }

    /// Puts a tap on the item's audio so its levels show here. Call before the item plays.
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in
                // The analyser lives in the tap's storage, so the audio thread never looks elsewhere.
                let levels = Unmanaged<AudioLevels>.fromOpaque(clientInfo!).takeRetainedValue()
                storageOut.pointee = UnsafeMutableRawPointer(Unmanaged.passRetained(SpectrumAnalyser(levels: levels)).toOpaque())
            },
            finalize: { tap in
                Unmanaged<SpectrumAnalyser>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let analyser = Unmanaged<SpectrumAnalyser>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                analyser.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                let analyser = Unmanaged<SpectrumAnalyser>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let start = range.isValid && range.start.isNumeric ? range.start.seconds : nil
                analyser.analyse(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee), startTime: start)
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        await MainActor.run { item.audioMix = mix }
    }
}

/// Turns blocks of audio into band levels with an FFT. Buffers are made once, up front, so the
/// audio thread doesn't allocate.
final class SpectrumAnalyser {
    static let size = 1024
    private let levels: AudioLevels
    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var samples = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var magnitudes = [Float](repeating: 0, count: size / 2)
    private var sampleRate: Float = 44100
    private var isFloat = true
    private var isInterleaved = false
    private var channels = 2
    /// How much of `samples` is filled, and the song time the current chunk began.
    private var filled = 0
    private var chunkStart: Double = 0
    /// Where the next block should start, for blocks that come without a time.
    private var clock: Double = 0

    init(levels: AudioLevels) {
        self.levels = levels
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = Float(format.mSampleRate)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = max(Int(format.mChannelsPerFrame), 1)
    }

    /// Measures every 1024 samples (about 43 times a second), each stamped with its time in the
    /// song. One channel is plenty for a picture of the music.
    func analyse(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, startTime: Double?) {
        guard isFloat, frames > 0, let first = buffers.first?.mData else { return }
        let rate = Double(sampleRate)
        let blockStart = startTime ?? clock
        // A seek or a gap: start the chunk afresh rather than splice two places together.
        if abs(blockStart - clock) > 0.05 { filled = 0 }
        clock = blockStart + Double(frames) / rate
        let data = first.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            if filled == 0 { chunkStart = blockStart + Double(frame) / rate }
            samples[filled] = isInterleaved ? data[frame * channels] : data[frame]
            filled += 1
            if filled == Self.size {
                // Stamped at the chunk's middle.
                levels.record(bands(), at: chunkStart + Double(Self.size) / 2 / rate)
                filled = 0
            }
        }
    }

    /// Band levels for whatever is in `samples` (exposed for tests).
    func bands() -> [Float] {
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(Self.size))
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                samples.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.size / 2))
            }
        }
        let binWidth = sampleRate / Float(Self.size)
        let edges = AudioLevels.bandEdges
        var result = [Float](repeating: 0, count: AudioLevels.bandCount)
        for band in 0..<AudioLevels.bandCount {
            // Edges rounded to the nearest bin: at about 43 Hz a bin, truncating left the lowest
            // band a single bin wide, and a 60 Hz kick spilled into the next band.
            let low = max(Int((edges[band] / binWidth).rounded()), 1)
            let high = min(max(Int((edges[band + 1] / binWidth).rounded()), low + 1), magnitudes.count)
            // The band's average energy: its single loudest bin flickers from one block to the next.
            var peak: Float = 0
            magnitudes.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + low, 1, &peak, vDSP_Length(high - low)) }
            // Scaled back to the sine amplitude (the real FFT doubles, the normalised Hann window
            // halves), then decibels from -60 (silent) to 0 (full scale), leaving headroom so loud
            // bass isn't flattened at the top. Higher bands carry less energy in most music, so
            // they get a lift.
            let amplitude = sqrt(peak) * 2 / Float(Self.size)
            let decibels = 20 * log10(max(amplitude, 1e-7)) + Float(band) * 2
            result[band] = min(max((decibels + 60) / 60, 0), 1)
        }
        return result
    }

    /// Loads samples directly, for tests.
    func load(_ values: [Float]) {
        for index in 0..<min(values.count, Self.size) { samples[index] = values[index] }
    }

    func setSampleRate(_ rate: Float) { sampleRate = rate }
}
