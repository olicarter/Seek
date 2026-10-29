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
        #expect(AudioTags.format(of: url) == .mp3)
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
        #expect(AudioTags.format(of: url) == .flac)
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
}
