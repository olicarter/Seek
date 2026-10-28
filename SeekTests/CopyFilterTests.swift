import Foundation
import Testing
@testable import Seek

/// A 2-song EP named for its first song: the single of that song, alone in a folder named the
/// same, isn't one of the EP's copies.
struct OneSongFolderTests {
    private func folder(_ path: String, user: String, files: [String]) -> RemoteFolder {
        RemoteFolder(username: user, path: path,
                     files: files.map { RemoteFile(username: user, path: "\(path)\\\($0)", size: 30_000_000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    private var ep: RemoteFolder {
        folder("music\\Cryogeyser\\Cryogeyser - Glitch EP", user: "u1", files: ["01 Glitch.flac", "02 Halftones.flac"])
    }
    private var single: RemoteFolder {
        folder("music\\Cryogeyser\\Cryogeyser - Glitch", user: "u2", files: ["01 Glitch.flac"])
    }

    @Test func isCopyNeedsMoreThanOneSongForALongerRelease() {
        #expect(!CopyFilter.isCopy(single, expectedTracks: 2))
        #expect(CopyFilter.isCopy(ep, expectedTracks: 2))
        // A single, or a release whose song count isn't known, takes any folder.
        #expect(CopyFilter.isCopy(single, expectedTracks: 1))
        #expect(CopyFilter.isCopy(single, expectedTracks: nil))
    }

    @Test func copyFinderLeavesOutOneSongFolders() async {
        let album = AlbumKey(artist: "Cryogeyser", title: "Glitch")
        let query = CopyFinder.query(for: album)
        let withCount = await CopyFinder.matching(album, query: query, in: [ep, single], expectedTracks: 2, quality: .cd)
        #expect(withCount.map(\.username) == ["u1"])
        let withoutCount = await CopyFinder.matching(album, query: query, in: [ep, single], quality: .cd)
        #expect(Set(withoutCount.map(\.username)) == ["u1", "u2"])
    }

    @Test func searchListsTheOneSongFolderAsASong() {
        let catalog = [CatalogRelease(artist: "Cryogeyser", title: "Glitch", kind: .single,
                                      released: .now, trackCount: 2)]
        let result = ReleaseGrouper.group(query: "cryogeyser glitch", owned: [], store: [], folders: [ep, single], catalog: catalog)
        let release = result.releases.first { $0.catalog != nil }
        #expect(release?.folders.map(\.username) == ["u1"])
        #expect(result.songs.map(\.username) == ["u2"])
    }
}
