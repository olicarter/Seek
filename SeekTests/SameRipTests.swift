import Foundation
import Testing
@testable import Seek

struct SameRipTests {
    static func flac(_ user: String, _ folder: String, _ sizes: [UInt64], name: (Int) -> String = { "\($0) - Song \($0).flac" }) -> [RemoteFile] {
        sizes.enumerated().map { index, size in
            RemoteFile(username: user, path: "\(folder)\\\(name(index + 1))", size: size,
                       duration: 180 + index, sampleRate: 44100, bitDepth: 16)
        }
    }

    static let sizes: [UInt64] = [31_000_000, 27_500_000, 40_200_000, 22_100_000, 35_900_000]

    @Test func retaggedCopyMatchesSongBySong() throws {
        let mine = Self.flac("a", "Music\\Album", Self.sizes)
        // Renamed and re-tagged: every file a few KB bigger.
        let theirs = Self.flac("b", "Shared\\Artist - Album (2020) [FLAC]", Self.sizes.map { $0 + 4_096 + UInt64.random(in: 0...2_000) }) {
            String(format: "%02d. Artist - Song %d.flac", $0, $0)
        }
        let match = try #require(SameRip.match(mine, in: theirs))
        for (song, other) in zip(mine, theirs) { #expect(match[song.id] == other) }
    }

    @Test func differentMasterDoesNotMatch() {
        let mine = Self.flac("a", "Album", Self.sizes)
        // Same lengths, but each song compresses differently.
        let remaster = Self.flac("b", "Album (Remastered)", zip(Self.sizes, [900_000, -400_000, 1_300_000, 200_000, -700_000]).map { UInt64(Int64($0) + $1) })
        #expect(SameRip.match(mine, in: remaster) == nil)
    }

    @Test func differentTracklistsOrFormatsDoNotMatch() {
        let mine = Self.flac("a", "Album", Self.sizes)
        #expect(SameRip.match(mine, in: Self.flac("b", "Album", Array(Self.sizes.dropLast()))) == nil)
        let mp3 = Self.sizes.enumerated().map { index, size in
            RemoteFile(username: "b", path: "Album\\\(index + 1) - Song.mp3", size: size, bitrate: 320, duration: 180 + index)
        }
        #expect(SameRip.match(mine, in: mp3) == nil)
    }

    @Test func constantBitrateMP3sMustBeByteIdentical() {
        func mp3(_ user: String, extra: UInt64) -> [RemoteFile] {
            Self.sizes.enumerated().map { index, size in
                RemoteFile(username: user, path: "Album\\\(index + 1) - Song.mp3", size: size / 4 + extra, bitrate: 320, duration: 180 + index)
            }
        }
        // Any two 320 MP3s of the same lengths come out the same size bar their tags.
        #expect(SameRip.match(mp3("a", extra: 0), in: mp3("b", extra: 3_000)) == nil)
        #expect(SameRip.match(mp3("a", extra: 0), in: mp3("b", extra: 0)) != nil)
    }

    /// Real results: the most shared rip of each album has several users to spread it over.
    @Test func realAlbumsHaveSeveralUsersWithTheSameRip() throws {
        let dump = try RealSearchTests.load("search-playboi-carti")
        let copies = dump.folders.filter { ReleaseText.fold($0.name).contains("whole lotta red") && $0.files.count == 24 }
        let best = copies.map { copy in
            Set(copies.filter { $0.username != copy.username && SameRip.match(copy.files, in: $0.files) != nil }.map(\.username)).count
        }.max() ?? 0
        #expect(best >= 8)
    }
}

struct SameRipSubsetTests {
    private func copy(_ user: String, names: [String], tagBytes: UInt64) -> [RemoteFile] {
        names.enumerated().map { index, name in
            var file = RemoteFile(username: user, path: "Music\\Album\\\(name)", size: 30_000_000 + UInt64(index) * 1_000_000 + tagBytes)
            file.duration = 200 + index
            file.sampleRate = 44100
            file.bitDepth = 16
            return file
        }
    }

    @Test func someSongsMatchAFolderWithMore() {
        let album = (1...11).map { String(format: "%02d Song %d.flac", $0, $0) }
        let owner = copy("owner", names: album, tagBytes: 0)
        // The other copy names songs another way and holds a bonus track at the end.
        let renamed = (1...11).map { String(format: "%02d - Artist - Song %d.flac", $0, $0) } + ["12 - Artist - Bonus.flac"]
        var helper = copy("helper", names: renamed, tagBytes: 4096)
        helper[11].duration = 99
        // The ten songs being added, not the whole album.
        let adding = Array(owner.prefix(10))
        let match = SameRip.match(adding, in: helper)
        #expect(match?.count == 10)
        #expect(match?[adding[2].id]?.name == "03 - Artist - Song 3.flac")
        // A different master: sizes differ by different amounts per song.
        var other = copy("other", names: album, tagBytes: 0)
        let changed = other[3]
        other[3] = RemoteFile(username: changed.username, path: changed.path, size: changed.size + 900_000,
                              duration: changed.duration, sampleRate: changed.sampleRate, bitDepth: changed.bitDepth)
        #expect(SameRip.match(adding, in: other) == nil)
    }
}
