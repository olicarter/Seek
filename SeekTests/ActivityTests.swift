import Foundation
import Testing
@testable import Seek

/// Activity lists downloads by release, each song saying where it could come from.
@MainActor
struct ActivityTests {
    private func transfer(_ path: String, user: String = "someone", album: AlbumKey? = nil) -> Transfer {
        let transfer = Transfer(file: RemoteFile(username: user, path: path, size: 1))
        transfer.album = album
        return transfer
    }

    @Test func downloadsAreGroupedByRelease() {
        let album = AlbumKey(artist: "Flo Milli", title: "Fine Ho, Stay")
        let groups = ReleaseDownloads.group([
            transfer("@@a\\Flo Milli\\Fine Ho, Stay\\02 New Me.flac", album: album),
            transfer("@@b\\Lemtom\\Fair Dinkum (2023)\\01 Volitant.flac"),
            transfer("@@a\\Flo Milli\\Fine Ho, Stay\\01 Understand.flac", user: "other", album: album),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].title == "Fine Ho, Stay")
        // In track order, whoever each comes from.
        #expect(groups[0].transfers.map { ReleaseText.songNumber($0.file.name) } == [1, 2])
    }

    @Test func sourcesSummary() {
        var sources = SongSources(found: ["a", "b", "c", "d"], asked: ["a", "b"])
        sources.failed["a"] = "File not shared."
        #expect(SongSourcesSummary.text(sources) == "4 copies · asked 2 · 1 failed · 2 not asked")
        #expect(SongSourcesSummary.text(SongSources(found: ["a"], asked: ["a"])) == "1 copy · asked 1")
    }

    @Test func aSongKeepsItsKeyAcrossCopies() {
        let album = AlbumKey(artist: "Flo Milli", title: "Fine Ho, Stay")
        let first = transfer("@@a\\Flo Milli - Fine Ho, Stay\\06 - Toast.flac", album: album)
        let second = transfer("@@b\\FINE HO STAY [FLAC]\\Flo Milli - Toast.flac", user: "other", album: album)
        #expect(SoulseekClient.songKey(first) == SoulseekClient.songKey(second))
    }
}
