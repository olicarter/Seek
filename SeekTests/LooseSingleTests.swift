import Foundation
import Testing
@testable import Seek

/// A single shared as a song among others: in a folder named for the artist, or a folder of
/// loose tracks. Its file is the copy; other versions and other songs aren't.
struct LooseSingleTests {
    private func folder(_ path: String, _ names: [String]) -> RemoteFolder {
        RemoteFolder(username: "someone", path: path,
                     files: names.map { RemoteFile(username: "someone", path: "\(path)\\\($0)", size: 1) },
                     hasFreeSlot: true, averageSpeed: 0, queueLength: 0)
    }

    private let album = AlbumKey(artist: "JAYC & Lemtom", title: "Starlight")

    @Test func songsInOtherFoldersAreCopies() {
        let found = CopyFinder.looseSingles(album, in: [
            folder("@@x\\Music\\JAYC", ["JAYC, Lemtom - Starlight.flac"]),
            folder("@@y\\Loose Music", ["114 - jayc, lemtom - starlight.flac", "128. Starlight - JAYC; Lemtom.mp3"]),
        ])
        #expect(found.count == 2)
        // The lossless file first, where both are there.
        #expect(found[1].files.first?.fileExtension == "flac")
    }

    @Test func otherVersionsAndSongsAreNot() {
        let found = CopyFinder.looseSingles(album, in: [
            folder("@@x\\Music\\JAYC", ["JAYC, Lemtom - Starlight (Someone Remix).flac"]),
            folder("@@y\\Mixed", ["Starlight Express - Someone.mp3"]),
            folder("@@z\\Mixed", ["Other Artist - Starlight.mp3"]),
        ])
        #expect(found.isEmpty)
        // "Original Mix" is the song itself.
        #expect(CopyFinder.looseSingles(album, in: [folder("@@x\\JAYC", ["02 JAYC - Starlight (Original Mix).flac"])]).count == 1)
    }
}
