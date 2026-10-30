import Foundation
import Testing
@testable import Seek

/// Songs added with a tracklist are named from it, in FLAC and MP3 files alike, including MP3s
/// named .flac and FLACs with an ID3 tag in front.
struct TagWritingTests {
    private func temporary(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// An ID3v2.3 tag holding one text frame, then a few bytes standing in for MPEG audio.
    private func mp3(title: String) -> Data {
        tag(title: title) + Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3])
    }

    private func tag(title: String) -> Data {
        var body = Data("TIT2".utf8)
        let text = Data([0]) + Data(title.utf8)
        body.append(contentsOf: [0, 0, 0, UInt8(text.count), 0, 0])
        body.append(text)
        var data = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, UInt8(body.count)])
        data.append(body)
        return data
    }

    @Test func mp3NamedFLACIsSeenAsMP3() throws {
        let url = try temporary(mp3(title: "ukg Lemtom - Volitant"), ext: "flac")
        #expect(AudioTags.container(of: url) == .mp3)
        #expect(FLACTags.streamStart(try Data(contentsOf: url).prefix(10)) == tag(title: "ukg Lemtom - Volitant").count)
    }

    @Test func mp3TagsAreReplacedAndAudioKept() throws {
        let original = mp3(title: "ukg Lemtom - Volitant")
        let updated = try ID3Tags.updated(original, setting: ["TITLE": "Volitant", "ARTIST": "Lemtom", "TRACKNUMBER": "1"])
        #expect(updated.suffix(7) == original.suffix(7))
        let text = String(decoding: updated, as: UTF8.self)
        #expect(!text.contains("ukg"))
        #expect(updated.range(of: "Volitant".data(using: .utf16LittleEndian)!) != nil)
        #expect(updated.range(of: Data("TRCK".utf8)) != nil)
        // Read back as a tag: its size covers exactly up to the audio.
        let size = ID3Tags.syncsafe([UInt8](updated[6...9])[...])
        #expect(updated[10 + size] == 0xFF)
    }

    @Test func flacAfterAnID3TagIsReadAndWritten() throws {
        // A minimal FLAC: STREAMINFO (34 bytes) as the last block, then "audio".
        var flac = Data("fLaC".utf8) + Data([0x80, 0, 0, 34]) + Data(count: 34)
        flac.append(contentsOf: [0xFF, 0xF8, 9, 9])
        let url = try temporary(tag(title: "junk") + flac, ext: "flac")
        #expect(AudioTags.container(of: url) == .flac)
        try AudioTags.update(url, setting: ["TITLE": "Volitant"])
        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data("fLaC".utf8))
        #expect(try FLACTags.read(url).title == "Volitant")
    }

    @Test func downloadedFileFindsItsSong() {
        let reference = AlbumReference(source: .itunes, artist: "Lemtom", title: "Fair Dinkum", tracks: [
            ReferenceTrack(number: 1, disc: 1, title: "Volitant", duration: 300),
            ReferenceTrack(number: 2, disc: 1, title: "Namerakana", duration: 300),
            ReferenceTrack(number: 3, disc: 1, title: "F303L", duration: 300),
            ReferenceTrack(number: 4, disc: 1, title: "Volitant (2 Step Mix)", duration: 300),
        ])
        func song(_ name: String) -> String? {
            MissingTracks.song(for: RemoteFile(username: "u", path: "Lemtom\\\(name)", size: 1, duration: 300), in: reference)?.title
        }
        #expect(song("01 - Volitant.flac") == "Volitant")
        #expect(song("Lemtom - Fair Dinkum - 04 - Volitant (2 Step mix).flac") == "Volitant (2 Step Mix)")
        #expect(song("03 F303L.mp3") == "F303L")
    }

    @Test func extensionsFollowContents() throws {
        #expect(AudioTags.correctedExtension(for: try temporary(mp3(title: "x"), ext: "flac")) == "mp3")
        #expect(AudioTags.correctedExtension(for: try temporary(mp3(title: "x"), ext: "mp3")) == nil)
        let m4a = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 20)
        #expect(AudioTags.correctedExtension(for: try temporary(m4a, ext: "mp3")) == "m4a")
        #expect(AudioTags.correctedExtension(for: try temporary(m4a, ext: "alac")) == nil)
        let flac = Data("fLaC".utf8) + Data(count: 40)
        #expect(AudioTags.correctedExtension(for: try temporary(flac, ext: "m4a")) == "flac")
        let wav = Data("RIFF".utf8) + Data(count: 4) + Data("WAVE".utf8) + Data(count: 20)
        #expect(AudioTags.correctedExtension(for: try temporary(wav, ext: "flac")) == "wav")
        // ADTS AAC isn't mistaken for MP3.
        #expect(AudioTags.correctedExtension(for: try temporary(Data([0xFF, 0xF1, 0x50, 0x80]) + Data(count: 20), ext: "mp3")) == "aac")
        // Not audio, or not recognised: left alone.
        #expect(AudioTags.correctedExtension(for: try temporary(Data("hello there".utf8), ext: "flac")) == nil)
        #expect(AudioTags.correctedExtension(for: try temporary(mp3(title: "x"), ext: "txt")) == nil)
    }

    @Test func tidalTiers() {
        #expect(SoundQuality(lossless: true, bitDepth: 16, sampleRate: 44_100) == .high)
        #expect(SoundQuality(lossless: true, bitDepth: 16, sampleRate: 48_000) == .max)
        #expect(SoundQuality(lossless: true, bitDepth: 24, sampleRate: 44_100) == .max)
        #expect(SoundQuality(lossless: true, bitDepth: nil, sampleRate: nil) == .high)
        #expect(SoundQuality(lossless: false, bitDepth: nil, sampleRate: 96_000) == .low)
        #expect(SoundQuality.detail(lossless: true, bitDepth: 24, sampleRate: 96_000, bitrate: nil) == "24-bit, 96 kHz")
        #expect(SoundQuality.detail(lossless: true, bitDepth: 16, sampleRate: 44_100, bitrate: nil) == "16-bit, 44.1 kHz")
        #expect(SoundQuality.detail(lossless: false, bitDepth: nil, sampleRate: nil, bitrate: 319) == "320 kbps")
        #expect(SoundQuality.low < .high && .high < .max)
    }

    @Test func theFilesNumberDecidesBetweenSongsOfOneName() {
        let reference = AlbumReference(source: .itunes, artist: "Flo Milli", title: "Fine Ho, Stay", tracks: [
            ReferenceTrack(number: 5, disc: 1, title: "Never Lose Me (feat. SZA & Cardi B)", duration: 166),
            ReferenceTrack(number: 14, disc: 1, title: "Never Lose Me", duration: 126),
        ])
        func song(_ name: String, duration: Int? = nil) -> Int? {
            MissingTracks.song(for: RemoteFile(username: "u", path: "Flo Milli\\\(name)", size: 1, duration: duration), in: reference)?.number
        }
        #expect(song("Flo Milli - Fine Ho, Stay - 05 - Never Lose Me.flac") == 5)
        #expect(song("Flo Milli - Fine Ho, Stay - 14 - Never Lose Me.flac") == 14)
        // No number: the length.
        #expect(song("Never Lose Me.flac", duration: 165) == 5)
    }
}
