import Foundation
import Testing
@testable import Seek

struct SharingTests {
    private let files = [
        SharedFile(virtualPath: ShareIndex.virtualPath(forLibraryPath: "Cryogeyser/Glitch/02 Focus.flac"), libraryPath: "Cryogeyser/Glitch/02 Focus.flac",
                   size: 30_000_000, duration: 125, sampleRate: 44100, bitDepth: 16),
        SharedFile(virtualPath: ShareIndex.virtualPath(forLibraryPath: "Cryogeyser/Glitch/01 Marie.flac"), libraryPath: "Cryogeyser/Glitch/01 Marie.flac",
                   size: 35_000_000, duration: 161, sampleRate: 44100, bitDepth: 16),
        SharedFile(virtualPath: ShareIndex.virtualPath(forLibraryPath: "DreamKiller/Lux/01 Lux.mp3"), libraryPath: "DreamKiller/Lux/01 Lux.mp3",
                   size: 9_000_000, duration: 230, bitrate: 320),
    ]

    @Test func libraryPathsBecomeSoulseekPaths() {
        #expect(files[0].virtualPath == "Seek\\Cryogeyser\\Glitch\\02 Focus.flac")
        #expect(files[0].folder == "Seek\\Cryogeyser\\Glitch")
        #expect(files[0].name == "02 Focus.flac")
    }

    @Test func countsFoldersAndFiles() {
        let index = ShareIndex(files: files)
        #expect(index.folderCount == 2)
        #expect(index.fileCount == 3)
        #expect(index.folders.first?.files.map(\.name) == ["01 Marie.flac", "02 Focus.flac"])
    }

    @Test func folderContentsReadBackLikeAPeersWould() throws {
        let index = ShareIndex(files: files)
        let body = try index.folderContents(token: 9, folder: "Seek\\Cryogeyser\\Glitch")
        let parsed = try FolderContents.parse(compressed: body, username: "me")
        #expect(parsed.token == 9)
        #expect(parsed.files.map(\.path) == ["Seek\\Cryogeyser\\Glitch\\01 Marie.flac", "Seek\\Cryogeyser\\Glitch\\02 Focus.flac"])
        #expect(parsed.files.first?.bitDepth == 16)
        #expect(parsed.files.first?.duration == 161)
    }

    @Test func fileListListsEveryFolder() throws {
        let body = try ShareIndex(files: files).fileList()
        var reader = MessageReader(try Zlib.inflate(body))
        #expect(try reader.uint32() == 2)
        var names: [String] = []
        for _ in 0..<2 {
            names.append(try reader.string())
            let count = try reader.uint32()
            for _ in 0..<count {
                _ = try reader.uint8(); _ = try reader.string(); _ = try reader.uint64(); _ = try reader.string()
                let attributes = try reader.uint32()
                for _ in 0..<attributes { _ = try reader.uint32(); _ = try reader.uint32() }
            }
        }
        #expect(names == ["Seek\\Cryogeyser\\Glitch", "Seek\\DreamKiller\\Lux"])
        #expect(try reader.uint32() == 0)
        #expect(try reader.uint32() == 0)
    }
}
