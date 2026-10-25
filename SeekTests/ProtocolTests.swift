import Foundation
import Testing
@testable import Seek

struct WireTests {
    @Test func loginMessageLayout() throws {
        var reader = MessageReader(Messages.login(username: "user", password: "pass"))
        let length = try reader.uint32()
        #expect(Int(length) == reader.remaining)
        #expect(try reader.uint32() == ServerCode.login)
        #expect(try reader.string() == "user")
        #expect(try reader.string() == "pass")
        #expect(try reader.uint32() == 160)
        // md5("userpass")
        #expect(try reader.string() == "63e780c3f321d13109c71bf81805476e")
        #expect(try reader.uint32() == 1)
        #expect(reader.remaining == 0)
    }

    @Test func peerInitLayout() throws {
        var reader = MessageReader(Messages.peerInit(username: "me", type: "P"))
        #expect(try reader.uint32() == 1 + 4 + 2 + 4 + 1 + 4)
        #expect(try reader.uint8() == PeerInitCode.peerInit)
        #expect(try reader.string() == "me")
        #expect(try reader.string() == "P")
        #expect(try reader.uint32() == 0)
    }

    @Test func ipAddressIsReversed() throws {
        var reader = MessageReader(Data([4, 3, 2, 1]))
        #expect(try reader.ipAddress() == "1.2.3.4")
    }

    @Test func truncatedMessageThrows() {
        var reader = MessageReader(Data([5, 0, 0, 0, 65]))
        #expect(throws: ProtocolError.self) { try reader.string() }
    }

    @Test func zlibRoundTrip() throws {
        let original = Data((0..<5000).map { UInt8($0 % 7) })
        let compressed = try Zlib.deflate(original)
        #expect(compressed.prefix(2) == Data([0x78, 0x9C]))
        #expect(try Zlib.inflate(compressed) == original)
    }

    @Test func parsesSearchResponse() throws {
        var body = MessageWriter()
        body.string("peer")
        body.uint32(42)
        body.uint32(2)
        for (name, size) in [("@@abc\\Music\\Artist\\Album\\01 - Song.flac", UInt64(30_000_000)), ("@@abc\\Music\\Artist\\Album\\02 - Other.mp3", 8_000_000)] {
            body.uint8(1)
            body.string(name)
            body.uint64(size)
            body.string("")
            body.uint32(2)
            body.uint32(0); body.uint32(320)
            body.uint32(1); body.uint32(245)
        }
        body.bool(true)
        body.uint32(1_000_000)
        body.uint32(3)

        let response = try SearchResponse.parse(compressed: try Zlib.deflate(body.data))
        #expect(response.username == "peer")
        #expect(response.token == 42)
        #expect(response.hasFreeSlot)
        #expect(response.queueLength == 3)
        #expect(response.files.count == 2)
        #expect(response.files[0].name == "01 - Song.flac")
        #expect(response.files[0].folder == "@@abc\\Music\\Artist\\Album")
        #expect(response.files[0].duration == 245)
        #expect(response.files[1].quality == "MP3 320")
    }
}

struct PathMetadataTests {
    @Test func artistAlbumTrackLayout() {
        let metadata = PathMetadata.parse("Boards of Canada/Geogaddi (2002)/03 - Music Is Math.flac")
        #expect(metadata.artist == "Boards of Canada")
        #expect(metadata.album == "Geogaddi")
        #expect(metadata.year == 2002)
        #expect(metadata.trackNumber == 3)
        #expect(metadata.title == "Music Is Math")
    }

    @Test func artistDashAlbumFolder() {
        let metadata = PathMetadata.parse("Music/Aphex Twin - Drukqs [FLAC]/1-02 Vordhosbn.flac")
        #expect(metadata.artist == "Aphex Twin")
        #expect(metadata.album == "Drukqs")
        #expect(metadata.trackNumber == 2)
        #expect(metadata.title == "Vordhosbn")
    }

    @Test func artistInFileName() {
        let metadata = PathMetadata.parse("Burial/Untrue/05. Burial - Archangel.mp3")
        #expect(metadata.artist == "Burial")
        #expect(metadata.title == "Archangel")
        #expect(metadata.trackNumber == 5)
    }

    @Test func plainFileName() {
        let metadata = PathMetadata.parse("Song.mp3")
        #expect(metadata.title == "Song")
        #expect(metadata.trackNumber == nil)
    }
}

struct FLACTagTests {
    @Test func parsesVorbisComments() throws {
        var comments = MessageWriter()
        comments.string("reference libFLAC")
        let fields = ["TITLE=Roygbiv", "ARTIST=Boards of Canada", "ALBUM=Music Has the Right to Children", "TRACKNUMBER=7/18", "DATE=1998-04-20"]
        comments.uint32(UInt32(fields.count))
        fields.forEach { comments.string($0) }

        var file = Data("fLaC".utf8)
        let length = comments.data.count
        file.append(contentsOf: [0x84, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        file.append(comments.data)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).flac")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = try FLACTags.read(url)
        #expect(tags.title == "Roygbiv")
        #expect(tags.artist == "Boards of Canada")
        #expect(tags.album == "Music Has the Right to Children")
        #expect(tags.trackNumber == 7)
        #expect(tags.year == 1998)
    }
}

struct FolderContentsTests {
    @Test func parsesEveryFileInEachDirectory() throws {
        var body = MessageWriter()
        body.uint32(77)
        body.string("Music\\Cryogeyser\\Glitch")
        body.uint32(2)
        for (directory, names) in [("Music\\Cryogeyser\\Glitch\\CD1", ["01 Intro.flac", "cover.jpg"]),
                                   ("Music\\Cryogeyser\\Glitch\\CD2", ["01 Outro.flac"])] {
            body.string(directory)
            body.uint32(UInt32(names.count))
            for name in names {
                body.uint8(1)
                body.string(name)
                body.uint64(1000)
                body.string("")
                body.uint32(2)
                body.uint32(4); body.uint32(44100)
                body.uint32(5); body.uint32(16)
            }
        }
        let contents = try FolderContents.parse(compressed: try Zlib.deflate(body.data), username: "milksop")
        #expect(contents.token == 77)
        #expect(contents.files.map(\.path) == [
            "Music\\Cryogeyser\\Glitch\\CD1\\01 Intro.flac",
            "Music\\Cryogeyser\\Glitch\\CD1\\cover.jpg",
            "Music\\Cryogeyser\\Glitch\\CD2\\01 Outro.flac",
        ])
        #expect(contents.files.first?.bitDepth == 16)
        #expect(contents.files.first?.username == "milksop")
    }
}
