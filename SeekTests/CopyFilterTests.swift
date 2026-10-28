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

/// Adding an album takes one copy with every song on its tracklist, and only those songs.
struct FullCopyTests {
    private let reference = AlbumReference(source: .itunes, artist: "Cryogeyser", title: "Glitch", tracks: [
        ReferenceTrack(number: 1, disc: 1, title: "Glitch"),
        ReferenceTrack(number: 2, disc: 1, title: "Halftones"),
        ReferenceTrack(number: 3, disc: 1, title: "Love Is Land"),
    ])

    private func folder(_ user: String, files: [String]) -> RemoteFolder {
        RemoteFolder(username: user, path: "music\\Cryogeyser - Glitch",
                     files: files.map { RemoteFile(username: user, path: "music\\Cryogeyser - Glitch\\\($0)", size: 30_000_000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func aCopyMissingASongIsNotUsed() {
        let partial = folder("u1", files: ["01 Glitch.flac", "02 Halftones.flac"])
        #expect(AlbumAdder.songs(of: reference, in: partial) == nil)
        #expect(AlbumAdder.fullCopy(of: reference, in: [partial]) == nil)
    }

    @Test func bonusTracksStayBehind() {
        let withBonus = folder("u1", files: ["01 Glitch.flac", "02 Halftones.flac", "03 Love Is Land.flac", "04 Glitch (Demo).flac"])
        let songs = AlbumAdder.songs(of: reference, in: withBonus)
        #expect(songs?.map(\.name) == ["01 Glitch.flac", "02 Halftones.flac", "03 Love Is Land.flac"])
    }

    @Test func theFirstFullCopyIsTaken() {
        let partial = folder("u1", files: ["01 Glitch.flac", "02 Halftones.flac"])
        let full = folder("u2", files: ["01 Glitch.flac", "02 Halftones.flac", "03 Love Is Land.flac"])
        let other = folder("u3", files: ["1. Glitch.flac", "2. Halftones.flac", "3. Love Is Land.flac"])
        #expect(AlbumAdder.fullCopy(of: reference, in: [partial, full, other])?.0.username == "u2")
    }
}
