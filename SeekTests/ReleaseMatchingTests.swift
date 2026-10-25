import Foundation
import Testing
@testable import Seek

struct FolderParserTests {
    private func parse(_ name: String, parent: String? = nil, files: [String] = []) -> ParsedFolder {
        FolderParser.parse(name: name, parent: parent, fileNames: files)
    }

    @Test func artistDashAlbumWithTags() {
        let p = parse("Paris, Texas - cyanide (feat. cryogeyser) (2022) [24B-44.1kHz]")
        #expect(p.artist == "Paris, Texas")
        #expect(p.title == "cyanide (feat. cryogeyser)")
        #expect(p.year == 2022)
        #expect(p.confidence >= 0.7)
    }

    @Test func albumUnderArtistFolder() {
        let p = parse("Love Is Land", parent: "Cryogeyser")
        #expect(p.artist == "Cryogeyser")
        #expect(p.title == "Love Is Land")
        #expect(p.confidence < 0.7)
    }

    @Test func yearAndCatalogueNumbersAreNotNames() {
        #expect(parse("2025 - Lux", parent: "DreamKiller").title == "Lux")
        #expect(parse("2025 - Lux", parent: "DreamKiller").artist == "DreamKiller")
        let catalogue = parse("DRR012 - DreamKiller - Erotic Motion [WEB FLAC]")
        #expect(catalogue.artist == "DreamKiller")
        #expect(catalogue.title == "Erotic Motion")
        let trailingYear = parse("DreamKiller - House Culture - 2024")
        #expect(trailingYear.title == "House Culture")
        #expect(trailingYear.year == 2024)
    }

    @Test func epAndDeluxeTagsAreDropped() {
        #expect(parse("Nite Fleit - Spinning Out EP").title == "Spinning Out")
        #expect(parse("Cryogeyser - Glitch (Deluxe Edition) [FLAC]").title == "Glitch")
        #expect(parse("VTSS - Projections (Remastered 2023)").title == "Projections")
        #expect(parse("Cryogeyser [24-44,1]", parent: "Music").title == "Cryogeyser")
        #expect(parse("Cryogeyser - Glitch (16/48)").title == "Glitch")
        // Brackets with words that aren't tags stay.
        #expect(parse("Paris, Texas - cyanide (feat. cryogeyser)").title == "cyanide (feat. cryogeyser)")
    }

    @Test func genericParentsAreIgnoredButFilesHelp() {
        let generic = parse("Love Is Land", parent: "Music")
        #expect(generic.artist == nil)
        let fromFiles = parse("Love Is Land", parent: "Downloads", files: ["01 - Cryogeyser - Intro.flac", "02 - Cryogeyser - Glitch.flac"])
        #expect(fromFiles.artist == "Cryogeyser")
    }

    @Test func sceneStyleNames() {
        let selfTitled = parse("Cryogeyser-Cryogeyser-WEB-2021-ENRiCH")
        #expect(selfTitled.artist == "Cryogeyser")
        #expect(selfTitled.title == "Cryogeyser")
        #expect(selfTitled.year == 2021)
        let underscores = parse("Paris_Texas-Cyanide_(feat._Cryogeyser)-WEB-2022-GROUP")
        #expect(underscores.artist == "Paris Texas")
        #expect(underscores.title == "Cyanide (feat. Cryogeyser)")
        let noTags = parse("DreamKiller-Lux-PERFECT")
        #expect(noTags.artist == "DreamKiller")
        #expect(noTags.title == "Lux")
        // Ordinary hyphenated names aren't scene releases.
        #expect(parse("Cryogeyser - Self-Titled").title == "Self-Titled")
    }

    @Test func discFoldersUseTheAlbumAbove() {
        let folder = RemoteFolder(username: "u", path: "Music\\Cryogeyser\\Love Is Land\\CD1", files: [], hasFreeSlot: true, averageSpeed: 0, queueLength: 0)
        let p = FolderParser.parse(folder)
        #expect(p.title == "Love Is Land")
        #expect(p.artist == "Cryogeyser")
    }
}

struct ReleaseTextTests {
    @Test func titleMatching() {
        #expect(ReleaseText.titlesMatch("Love Is Land", "love is land [FLAC 16-44]"))
        #expect(ReleaseText.titlesMatch("Glitch", "Glitch (Deluxe Edition)"))
        #expect(ReleaseText.titlesMatch("Lux", "Lux EP"))
        #expect(!ReleaseText.titlesMatch("Lux", "Luxury"))
        #expect(!ReleaseText.titlesMatch("Love Is Land", "Glitch"))
        #expect(!ReleaseText.titlesMatch("Closer", "Closer: The CVLT Nation Sessions"))
        #expect(ReleaseText.titlesMatch("Souvlaki", "Souvlaki 2005 Remaster"))
        #expect(ReleaseText.titlesMatch("Closer", "Closer (Collector's Edition)"))
        #expect(ReleaseText.titlesMatch("Unknown Pleasures", "Unknown Pleasures (40th Anniversary Remaster)"))
    }

    @Test func artistMatching() {
        #expect(ReleaseText.artistsMatch("DreamKiller", "dreamkiller"))
        #expect(ReleaseText.artistsMatch("DreamKiller", "DreamKiller & VTSS"))
        #expect(ReleaseText.artistsMatch("Niontay", "Niontay, RealYungPhil, & SURF GANG"))
        #expect(!ReleaseText.artistsMatch("Cryogeyser", "Paris, Texas"))
    }
}

struct ReleaseGrouperTests {
    private func folder(_ path: String, user: String = "u", files: [String] = ["01 a.flac", "02 b.flac"], free: Bool = true, speed: UInt32 = 100) -> RemoteFolder {
        RemoteFolder(
            username: user, path: path,
            files: files.map { RemoteFile(username: user, path: "\(path)\\\($0)", size: 1000) },
            hasFreeSlot: free, averageSpeed: speed, queueLength: 0
        )
    }

    private func store(_ title: String, by artist: String, id: Int) -> BandcampAPI.StoreResult {
        BandcampAPI.StoreResult(id: id, isTrack: false, title: title, artist: artist,
                                url: URL(string: "https://x.bandcamp.com/album/\(id)")!, artworkURL: nil)
    }

    @Test func soulseekFoldersJoinTheBandcampRelease() {
        let result = ReleaseGrouper.group(
            query: "cryogeyser",
            owned: [],
            store: [store("Love Is Land", by: "Cryogeyser", id: 1), store("Glitch", by: "Cryogeyser", id: 2)],
            folders: [
                folder("Music\\Cryogeyser\\Love Is Land", user: "EggyVevo"),
                folder("Cryogeyser - Love Is Land (2023) [MP3 320]", user: "b", files: ["01 a.mp3", "02 b.mp3", "03 c.mp3"]),
                folder("Cryogeyser - Glitch [FLAC]", user: "c"),
            ]
        )
        #expect(result.releases.count == 2)
        let land = result.releases.first { $0.title == "Love Is Land" }
        #expect(land?.folders.count == 2)
        #expect(land?.store?.id == 1)
        // Lossless first, even with fewer tracks.
        #expect(land?.bestFolder?.username == "EggyVevo")
        #expect(land?.year == 2023)
    }

    @Test func labelUploadsMatchArtistFolders() {
        let item = BandcampItem(saleItemType: "a", saleItemId: 9, title: "DreamKiller - Erotic Motion", artist: "Diffuse Reality Records",
                                isTrack: false, artId: nil, redownloadURL: nil)
        let result = ReleaseGrouper.group(query: "dreamkiller", owned: [item], store: [],
                                          folders: [folder("DreamKiller - Erotic Motion [WEB]")])
        #expect(result.releases.count == 1)
        #expect(result.releases[0].artist == "DreamKiller")
        #expect(result.releases[0].seller == "Diffuse Reality Records")
        #expect(result.releases[0].owned != nil)
        #expect(result.releases[0].folders.count == 1)
    }

    @Test func singlesFoldersBecomeSongs() {
        let result = ReleaseGrouper.group(query: "halftones", owned: [], store: [],
                                          folders: [folder("2025 Singles", files: ["Niontay - Halftones.flac", "Other - Track.flac"])])
        #expect(result.releases.isEmpty)
        #expect(result.songs.map(\.name) == ["Niontay - Halftones.flac"])
    }

    @Test func claudeHintsOverrideTheReading() {
        let unsure = folder("Music\\Love Is Land")
        let first = ReleaseGrouper.group(query: "love is land", owned: [], store: [store("Love Is Land", by: "Cryogeyser", id: 1)], folders: [unsure])
        #expect(first.unsure.map(\.id) == [unsure.id])
        let hinted = ReleaseGrouper.group(query: "love is land", owned: [], store: [store("Love Is Land", by: "Cryogeyser", id: 1)], folders: [unsure],
                                          hints: [unsure.id: FolderHint(kind: .release, artist: "Cryogeyser", title: "Love Is Land")])
        #expect(hinted.unsure.isEmpty)
        #expect(hinted.releases.count == 1)
        #expect(hinted.releases[0].folders.count == 1)
    }

    @Test func mixedHintsTurnIntoSongs() {
        let mixed = folder("Cryogeyser stuff", files: ["Cryogeyser - Glitch.flac", "Cryogeyser - Intro.flac"])
        let result = ReleaseGrouper.group(query: "glitch", owned: [], store: [], folders: [mixed],
                                          hints: [mixed.id: FolderHint(kind: .mixed)])
        #expect(result.releases.isEmpty)
        #expect(result.songs.count == 1)
    }
}

@MainActor
struct FolderResolverTests {
    @Test func parsesAnswersSkippingReleasesWithoutTitles() {
        let answers = FolderResolver.parse(["folders": [
            ["index": 0, "kind": "release", "artist": "Cryogeyser", "title": "Love Is Land", "year": 2023],
            ["index": 1, "kind": "mixed", "artist": NSNull(), "title": NSNull(), "year": NSNull()],
            ["index": 2, "kind": "release", "artist": "X", "title": " ", "year": NSNull()],
            ["index": 3, "kind": "other", "artist": NSNull(), "title": "x", "year": NSNull()],
        ]])
        #expect(answers.map(\.0) == [0, 1])
        #expect(answers[0].1 == FolderHint(kind: .release, artist: "Cryogeyser", title: "Love Is Land", year: 2023))
        #expect(answers[1].1.kind == .mixed)
    }

    @Test func promptListsFoldersWithFiles() {
        let folder = RemoteFolder(username: "u", path: "Music\\Love Is Land",
                                  files: [RemoteFile(username: "u", path: "Music\\Love Is Land\\01 Intro.flac", size: 1)],
                                  hasFreeSlot: true, averageSpeed: 0, queueLength: 0)
        let prompt = FolderResolver.prompt([folder], known: ["Cryogeyser – Love Is Land"])
        #expect(prompt.contains("0. Music/Love Is Land — 01 Intro.flac"))
        #expect(prompt.contains("Known releases: Cryogeyser – Love Is Land"))
    }
}

@MainActor
struct TrackNameTests {
    @Test func stripsNumbersAndArtists() {
        #expect(ReleaseDetailView.trackName("01 - Cryogeyser - Glitch.flac") == "Glitch")
        #expect(ReleaseDetailView.trackName("01 Glitch.flac") == "Glitch")
        #expect(ReleaseDetailView.trackName("02. Love Is Land.mp3") == "Love Is Land")
        #expect(ReleaseDetailView.trackName("Glitch.flac") == "Glitch")
    }
}

struct LibraryIndexTests {
    @Test func findsLibraryAlbumsAndPutsThemFirst() {
        let index = LibraryIndex(albums: [AlbumKey(artist: "DreamKiller", title: "Erotic Motion")])
        let item = BandcampItem(saleItemType: "a", saleItemId: 9, title: "DreamKiller - Erotic Motion", artist: "Diffuse Reality Records",
                                isTrack: false, artId: nil, redownloadURL: nil)
        let other = BandcampAPI.StoreResult(id: 2, isTrack: false, title: "Lux", artist: "DreamKiller",
                                            url: URL(string: "https://x.bandcamp.com/album/lux")!, artworkURL: nil)
        let result = ReleaseGrouper.group(query: "dreamkiller", owned: [], store: [other],
                                          folders: [], library: index, wishlist: [])
        #expect(result.releases.first?.inLibrary == nil)
        let withOwned = ReleaseGrouper.group(query: "dreamkiller", owned: [item], store: [other], folders: [], library: index)
        #expect(withOwned.releases.first?.title == "Erotic Motion")
        #expect(withOwned.releases.first?.inLibrary == AlbumKey(artist: "DreamKiller", title: "Erotic Motion"))
    }
}

struct QualityPreferenceTests {
    private func folder(_ user: String, files: [RemoteFile]) -> RemoteFolder {
        RemoteFolder(username: user, path: "Cryogeyser - Glitch", files: files, hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func hiResIsSpottedFromAttributesOrSize() {
        var cd = RemoteFile(username: "u", path: "a.flac", size: 30_000_000, duration: 240, sampleRate: 44100, bitDepth: 16)
        #expect(!cd.isHiRes)
        cd.bitDepth = 24
        #expect(cd.isHiRes)
        // 100 MB for 4 minutes is about 3.3 Mbit/s: hi-res.
        #expect(RemoteFile(username: "u", path: "b.flac", size: 100_000_000, duration: 240).isHiRes)
        #expect(!RemoteFile(username: "u", path: "c.flac", size: 30_000_000, duration: 240).isHiRes)
        #expect(!RemoteFile(username: "u", path: "d.mp3", size: 100_000_000, duration: 240).isHiRes)
    }

    @Test func cdQualityIsPreferredUnlessHighestIsChosen() {
        let hiRes = folder("hi", files: [RemoteFile(username: "hi", path: "1.flac", size: 1, sampleRate: 96000, bitDepth: 24),
                                         RemoteFile(username: "hi", path: "2.flac", size: 1, sampleRate: 96000, bitDepth: 24)])
        let cd = folder("cd", files: [RemoteFile(username: "cd", path: "1.flac", size: 1, sampleRate: 44100, bitDepth: 16)])
        let mp3 = folder("mp3", files: [RemoteFile(username: "mp3", path: "1.mp3", size: 1, bitrate: 320)])
        #expect([mp3, hiRes, cd].sorted { ReleaseGrouper.better($0, $1, quality: .cd) }.map(\.username) == ["cd", "hi", "mp3"])
        #expect([mp3, cd, hiRes].sorted { ReleaseGrouper.better($0, $1, quality: .highest) }.map(\.username) == ["hi", "cd", "mp3"])
    }
}

struct CopyFilterTests {
    private func folder(_ user: String, ext: String, bitDepth: Int? = 16, free: Bool) -> RemoteFolder {
        RemoteFolder(username: user, path: "x", files: [RemoteFile(username: user, path: "x\\1.\(ext)", size: 1, sampleRate: 44100, bitDepth: bitDepth)],
                     hasFreeSlot: free, averageSpeed: 1, queueLength: 0)
    }

    @Test func showsReadyCopiesAtTargetQualityFirst() {
        let folders = [folder("cd", ext: "flac", free: true), folder("busy", ext: "flac", free: false),
                       folder("hires", ext: "flac", bitDepth: 24, free: true), folder("mp3", ext: "mp3", bitDepth: nil, free: true)]
        #expect(CopyFilter.preferred(folders, quality: .cd)?.map(\.username) == ["cd"])
        #expect(CopyFilter.preferred(folders, quality: .highest)?.map(\.username) == ["cd", "hires"])
        #expect(CopyFilter.preferred([folder("mp3", ext: "mp3", bitDepth: nil, free: true)], quality: .cd) == nil)
    }
}
