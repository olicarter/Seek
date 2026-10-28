import Foundation
import Testing
@testable import Seek

struct ArtistCatalogTests {
    @Test func classifiesReleases() {
        #expect(CatalogRelease.kind(of: "ANYWHERE HERE IS PERFECT", trackCount: 12) == .album)
        #expect(CatalogRelease.kind(of: "UNDER THE ILLUSION - EP", trackCount: 4) == .ep)
        #expect(CatalogRelease.kind(of: "MORE! - Single", trackCount: 1) == .single)
        #expect(CatalogRelease.kind(of: "Elevator Music: Sam Gellaitry (DJ Mix)", trackCount: 27) == .other)
        #expect(CatalogRelease.kind(of: "Assumptions (Kaytranada Remix) - Single", trackCount: 2) == .other)
        // "Edit" only as a word.
        #expect(CatalogRelease.kind(of: "Credit Where Due", trackCount: 10) == .album)
        #expect(CatalogRelease.cleanTitle("Escapism - EP") == "Escapism")
        #expect(CatalogRelease.cleanTitle("Iconicy (feat. MINIKINGZ) - Single") == "Iconicy")
        #expect(CatalogRelease.cleanTitle("Glitch [ft. Someone]") == "Glitch")
        #expect(CatalogRelease.cleanTitle("Feat (Live)") == "Feat (Live)")
    }

    private func entry(_ title: String, _ kind: CatalogRelease.Kind, yearsAgo: Double) -> CatalogRelease {
        CatalogRelease(artist: "Sam Gellaitry", title: title, kind: kind,
                       released: Date.now.addingTimeInterval(-yearsAgo * 365 * 24 * 3600), trackCount: 10, artworkURL: nil)
    }

    @Test func mainAndLatestReleasesLead() {
        let store = [
            BandcampAPI.StoreResult(id: 1, isTrack: false, title: "MORE!", artist: "Sam Gellaitry", url: URL(string: "https://a.bandcamp.com/album/more")!),
            BandcampAPI.StoreResult(id: 2, isTrack: false, title: "Escapism", artist: "Sam Gellaitry", url: URL(string: "https://a.bandcamp.com/album/escapism")!),
        ]
        let catalog = [
            entry("ANYWHERE HERE IS PERFECT", .album, yearsAgo: 1),
            entry("Escapism", .ep, yearsAgo: 11),
            entry("MORE!", .single, yearsAgo: 2),
            entry("Elevator Music: Sam Gellaitry (DJ Mix)", .other, yearsAgo: 1),
        ]
        let result = ReleaseGrouper.group(query: "sam gellaitry", owned: [], store: store, folders: [], catalog: catalog)
        // The latest album leads though no source found it yet; DJ mixes aren't added.
        #expect(result.releases.map(\.title) == ["ANYWHERE HERE IS PERFECT", "Escapism", "MORE!"])
        #expect(result.releases[0].isCatalogOnly)
        #expect(result.releases[1].catalog?.kind == .ep)
    }
}

struct EditionSplitTests {
    private func folder(_ path: String, tracks: Int) -> RemoteFolder {
        RemoteFolder(username: "u", path: path,
                     files: (1...tracks).map { RemoteFile(username: "u", path: "\(path)\\\($0) song.flac", size: 1000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func deluxeCopiesGetTheirOwnRelease() {
        let catalog = [
            CatalogRelease(artist: "Sam Gellaitry", title: "ANYWHERE HERE IS PERFECT", kind: .album,
                           released: .now, trackCount: 12, artworkURL: nil),
            CatalogRelease(artist: "Sam Gellaitry", title: "ANYWHERE HERE IS PERFECT (DELUXE)", kind: .album,
                           released: .now, trackCount: 17, artworkURL: nil),
        ]
        let folders = [
            folder("Music\\Sam Gellaitry - ANYWHERE HERE IS PERFECT (2025)", tracks: 12),
            folder("Music\\Sam Gellaitry - ANYWHERE HERE IS PERFECT (Deluxe) [FLAC]", tracks: 17),
            // Not named deluxe, but it has the deluxe's tracks.
            folder("Music\\Sam Gellaitry - Anywhere Here Is Perfect", tracks: 17),
        ]
        let releases = ReleaseGrouper.group(query: "sam gellaitry", owned: [], store: [], folders: folders, catalog: catalog).releases
        let deluxe = releases.first { $0.catalog?.title == "ANYWHERE HERE IS PERFECT (DELUXE)" }
        let standard = releases.first { $0.catalog?.title == "ANYWHERE HERE IS PERFECT" }
        #expect(deluxe?.folders.count == 2)
        #expect(standard?.folders.count == 1)
    }
}

struct TagWordTests {
    @Test func shortTagsOnlyCountAsWholeWords() {
        // "ep" inside "Reprod" isn't a format tag: this is a different release.
        #expect(ReleaseText.cleanTitle("Under the Illusion (Dyzzy Reprod)") == "Under the Illusion (Dyzzy Reprod)")
        #expect(!ReleaseText.titlesMatch("Under the Illusion (Dyzzy Reprod)", "UNDER THE ILLUSION"))
        // Real tags still go.
        #expect(ReleaseText.cleanTitle("Glitch (EP)") == "Glitch")
        #expect(ReleaseText.cleanTitle("Glitch [FLAC 24bit]") == "Glitch")
        #expect(ReleaseText.cleanTitle("Glitch [WEB]") == "Glitch")
    }
}

struct MixedFolderTests {
    private func folder(_ names: [String]) -> RemoteFolder {
        RemoteFolder(username: "u", path: "Music\\Album",
                     files: names.map { RemoteFile(username: "u", path: "Music\\Album\\\($0)", size: 1000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func aFewFlacsAmongMP3sIsntLossless() {
        // Like the deluxe album added as "Lossless" that came in as 15 MP3s and 2 FLACs.
        let mixed = folder((1...15).map { "\($0).mp3" } + ["16.flac", "17.flac"])
        #expect(!mixed.isLossless)
        #expect(folder((1...12).map { "\($0).flac" }).isLossless)
    }
}

struct ParentArtistTests {
    private func folder(_ path: String) -> RemoteFolder {
        RemoteFolder(username: "u", path: path,
                     // Two songs: one alone would be a single, not a copy of the album.
                     files: ["01 POP OUT.flac", "02 crush.flac"].map { RemoteFile(username: "u", path: "\(path)\\\($0)", size: 1000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func deluxeInsideArtistFolderGoesToTheArtist() {
        let catalog = [
            CatalogRelease(artist: "Playboi Carti", title: "MUSIC", kind: .album, released: .now, trackCount: 30, artworkURL: nil),
            CatalogRelease(artist: "Playboi Carti", title: "MUSIC - SORRY 4 DA WAIT", kind: .album, released: .now, trackCount: 36, artworkURL: nil),
        ]
        let folders = [
            folder("Music\\Playboi Carti\\MUSIC - SORRY 4 DA WAIT"),
            folder("Music\\Playboi Carti\\2025 - MUSIC - SORRY 4 DA WAIT [FLAC]"),
            folder("Music\\Playboi Carti - MUSIC (2025) [FLAC]"),
        ]
        let releases = ReleaseGrouper.group(query: "playboi carti", owned: [], store: [], folders: folders, catalog: catalog).releases
        let deluxe = releases.first { $0.catalog?.title == "MUSIC - SORRY 4 DA WAIT" }
        #expect(deluxe?.folders.count == 2)
        #expect(deluxe?.year == 2025)
        #expect(releases.first { $0.catalog?.title == "MUSIC" }?.folders.count == 1)
        // An ordinary "Artist - Album" folder in a collection is left alone.
        let other = ReleaseGrouper.group(query: "playboi carti", owned: [], store: [],
                                         folders: [folder("Music\\Playboi Carti\\Playboi Carti - Die Lit")]).releases
        #expect(other.first?.title == "Die Lit")
    }
}

struct LooseTagTests {
    @Test func realFolderNamesClean() {
        #expect(ReleaseText.cleanTitle("Playboi Carti - MUSIC (2025) Mp3 320kbps [PMEDIA] ⭐️") == "Playboi Carti - MUSIC")
        #expect(ReleaseText.cleanTitle("MUSIC - FLAC (24bit-48kHz)") == "MUSIC")
        #expect(ReleaseText.cleanTitle("Playboi Carti - MUSIC (2025) [FLAC 24-48] {AWGE ∕ Interscope Records, 0602458440843}") == "Playboi Carti - MUSIC")
        #expect(ReleaseText.cleanTitle("2025 - MUSIC [Apple Digital Master] [Explicit] [768Kbps ATMOS]") == "2025 - MUSIC")
        // Names that only look like tags stay.
        #expect(ReleaseText.cleanTitle("Music for Airports") == "Music for Airports")
        #expect(ReleaseText.cleanTitle("Blue (Da Ba Dee)") == "Blue (Da Ba Dee)")
    }
}

struct StoreVerifierTests {
    private func tracks(_ titles: [String]) -> [ReferenceTrack] {
        titles.enumerated().map { ReferenceTrack(number: $0.offset + 1, disc: 1, title: $0.element, duration: nil) }
    }

    @Test func fanUploadDisagreesWithApple() {
        let apple = tracks(["Rockstar Made", "Go2DaMoon (feat. Kanye West)", "Stop Breathing", "Beno!", "JumpOutTheHouse",
                            "M3tamorphosis", "Slay3r", "No Sl33p", "New Tank", "Teen X", "Meh", "Vamp Anthem"])
        #expect(!StoreVerifier.tracklistsAgree(apple: apple, bandcamp: tracks(["whole lotta red"])))
        // The real release, or a deluxe with more songs, agrees.
        #expect(StoreVerifier.tracklistsAgree(apple: apple, bandcamp: apple))
        #expect(StoreVerifier.tracklistsAgree(apple: apple, bandcamp: apple + tracks(["Bonus 1", "Bonus 2"])))
    }
}

struct StoreTrackTests {
    @Test func aBandcampTrackIsntTheAlbum() {
        let store = [BandcampAPI.StoreResult(id: 9, isTrack: true, title: "whole lotta red", artist: "Playboi Carti",
                                             url: URL(string: "https://fan.bandcamp.com/track/whole-lotta-red")!)]
        let catalog = [CatalogRelease(artist: "Playboi Carti", title: "Whole Lotta Red", kind: .album,
                                      released: .now, trackCount: 24, artworkURL: nil)]
        let releases = ReleaseGrouper.group(query: "playboi carti", owned: [], store: store, folders: [], catalog: catalog).releases
        let album = releases.first { $0.catalog?.kind == .album }
        #expect(album != nil && album?.store == nil)
        #expect(releases.contains { $0.store?.id == 9 && $0.catalog == nil })
        // Every row its own id, or lists drop one.
        #expect(Set(releases.map(\.id)).count == releases.count)
    }
}

struct RetryPolicyTests {
    @Test func passingFailuresRetryWithGrowingGaps() {
        #expect(RetryPolicy.delay(after: 0, reason: "Connection reset by peer") == .seconds(5))
        #expect(RetryPolicy.delay(after: 3, reason: "Connection reset by peer") == .seconds(60))
        #expect(RetryPolicy.delay(after: 6, reason: "Connection reset by peer") == nil)
    }

    @Test func someAnswersDontChange() {
        #expect(RetryPolicy.delay(after: 0, reason: "File not shared.") == nil)
        #expect(RetryPolicy.delay(after: 0, reason: "Banned") == nil)
        // A queue limit is waited out with the longer gaps.
        #expect(RetryPolicy.delay(after: 0, reason: "Too many files") == .seconds(60))
    }
}

struct LetterSectionsTests {
    @Test func namesFileUnderTheirLetters() {
        #expect(LetterSections.letter(for: "Aden & Creepy Autograph") == "A")
        #expect(LetterSections.letter(for: "Étienne de Crécy") == "E")
        #expect(LetterSections.letter(for: "¥$") == "#")
        #expect(LetterSections.letter(for: "2 Chainz") == "#")
        #expect(LetterSections.letter(for: "\"Heroes\"") == "H")
    }

    @Test func sectionsRunAToZThenHash() {
        let sections = LetterSections.group(["2 Chainz", "Afro-Mystik", "aden", "Mosca", "Ejeca"]) { $0 }
        #expect(sections.map(\.letter) == ["A", "E", "M", "#"])
        #expect(sections[0].items == ["Afro-Mystik", "aden"])
    }
}

struct CompleteCopyTests {
    private func folder(_ name: String, tracks: Int, ext: String, free: Bool = true) -> RemoteFolder {
        RemoteFolder(username: name, path: "Music\\[2023] Niontay - Demon Muppy",
                     files: (1...tracks).map { RemoteFile(username: name, path: "Music\\[2023] Niontay - Demon Muppy\\0\($0) Song.\(ext)", size: 1000) },
                     hasFreeSlot: free, averageSpeed: 100, queueLength: 0)
    }

    @Test func wholeAlbumBeatsOneLosslessSong() {
        // Like Demon Muppy: one user shares a single FLAC in an album-named folder.
        let single = folder("Durealist", tracks: 1, ext: "flac")
        let whole = folder("other", tracks: 6, ext: "mp3")
        #expect(ReleaseGrouper.sortedBest([single, whole], expectedTracks: 6).first?.username == "other")
        // Not counted as ready at CD quality.
        #expect(CopyFilter.preferred([single], quality: .cd, expectedTracks: 6) == nil)
        // Without a tracklist, quality decides as before.
        #expect(ReleaseGrouper.sortedBest([single, whole]).first?.username == "Durealist")
    }
}

struct RescueMatchingTests {
    private func files(_ user: String, _ folder: String, _ names: [String]) -> [RemoteFile] {
        names.map { RemoteFile(username: user, path: "Music\\\(folder)\\\($0)", size: 1000) }
    }

    @Test func stalledSongsFindTheirCounterparts() {
        // The first user named files "NN - Artist - Song", the second "NN. Song".
        let stalled = files("gone", "Niontay - Demon Muppy", ["03 - Niontay - 2AM Pete's.flac", "05 - Niontay - In my UA sweater.flac"])
        let other = files("here", "Demon Muppy (2023)", ["01. YATKAMAN3000.flac", "02. Ridewimmie (I95er).flac", "03. 2AM Pete's.flac",
                                                          "04. Supa Bowl LVIII.flac", "05. In my UA sweater.flac", "cover.jpg"])
        let matches = SoulseekClient.counterparts(of: stalled, in: other)
        #expect(matches[stalled[0].id]?.name == "03. 2AM Pete's.flac")
        #expect(matches[stalled[1].id]?.name == "05. In my UA sweater.flac")
    }

    @Test func fallsBackToTrackNumber() {
        let stalled = files("gone", "Album", ["04 Track Four.flac"])
        let other = files("here", "Album", ["04 - Different Spelling.flac", "05 - Five.flac"])
        #expect(SoulseekClient.counterparts(of: stalled, in: other)[stalled[0].id]?.name == "04 - Different Spelling.flac")
    }
}

@MainActor
struct ArtistPageCatalogTests {
    private func release(_ title: String, year: Int) -> CatalogRelease {
        CatalogRelease(artist: "Fall Out Boy", title: CatalogRelease.cleanTitle(title), kind: CatalogRelease.kind(of: title, trackCount: 13),
                       released: Calendar.current.date(from: DateComponents(year: year))!, trackCount: 13)
    }

    @Test func listsEveryEditionButTheOneInTheLibrary() {
        let catalog = [
            release("From Under the Cork Tree", year: 2005),
            release("From Under the Cork Tree (Limited \"Black Clouds and Underdogs\" Edition) - EP", year: 2006),
            release("From Under The Cork Tree (20th Anniversary Deluxe)", year: 2025),
            release("Infinity On High", year: 2007),
            release("Infinity On High", year: 2007),
        ]
        let owned = [Album(key: AlbumKey(artist: "Fall Out Boy", title: "From Under the Cork Tree"), tracks: [])]
        let titles = ArtistPage.missing(from: catalog, owned: owned).map(\.title)
        #expect(titles == [
            "From Under The Cork Tree (20th Anniversary Deluxe)",
            "Infinity On High",
            "From Under the Cork Tree (Limited \"Black Clouds and Underdogs\" Edition)",
        ])
    }
}

struct RemasterTests {
    private func folder(_ path: String, user: String) -> RemoteFolder {
        RemoteFolder(username: user, path: path,
                     files: (1...11).map { RemoteFile(username: user, path: "\(path)\\\(String(format: "%02d", $0)) Song.flac", size: 1000) },
                     hasFreeSlot: true, averageSpeed: 100, queueLength: 0)
    }

    @Test func aRemasterIsItsOwnReleaseOnceTheCatalogueKnowsIt() {
        let folders = [
            folder("Music\\Knuckle Puck\\Copacetic (2015)", user: "a"),
            folder("Music\\Knuckle Puck\\Copacetic (Remixed & Remastered) (2025)", user: "b"),
            folder("Music\\Knuckle Puck - Copacetic (Remixed-Remastered) [2025] FLAC", user: "c"),
        ]
        let date = { (year: Int) in Calendar.current.date(from: DateComponents(year: year))! }
        let remaster = "Copacetic (Remixed/Remastered)"
        let catalog = [
            CatalogRelease(artist: "Knuckle Puck", title: "Copacetic", kind: .album, released: date(2015), trackCount: 11),
            CatalogRelease(artist: "Knuckle Puck", title: CatalogRelease.cleanTitle(remaster),
                           kind: CatalogRelease.kind(of: remaster, trackCount: 11), released: date(2025), trackCount: 11),
        ]
        let releases = ReleaseGrouper.group(query: "copacetic", owned: [], store: [], folders: folders, catalog: catalog).releases
        #expect(releases.first { $0.title == "Copacetic" }?.folders.map(\.username) == ["a"])
        #expect(Set(releases.first { $0.title == remaster }?.folders.map(\.username) ?? []) == ["b", "c"])
    }

    @Test func onlyReleasesWithEveryWordSearchedForCount() {
        #expect(ArtistCatalog.mentions("copacetic", artist: "Knuckle Puck", title: "Copacetic (Remixed/Remastered)"))
        #expect(ArtistCatalog.mentions("knuckle puck copacetic", artist: "Knuckle Puck", title: "Copacetic"))
        #expect(!ArtistCatalog.mentions("copacetic", artist: "Knuckle Puck", title: "20/20"))
    }
}

struct EditionInLibraryTests {
    private func release(_ title: String, catalog: Bool) -> SearchRelease {
        var release = SearchRelease(id: title, artist: "Knuckle Puck", title: title)
        if catalog {
            release.catalog = CatalogRelease(artist: "Knuckle Puck", title: title, kind: .album, released: .now, trackCount: 11)
        }
        return release
    }

    @Test func owningTheOriginalIsntOwningTheRemaster() {
        let original = LibraryIndex(albums: [AlbumKey(artist: "Knuckle Puck", title: "Copacetic")])
        #expect(original.album(for: release("Copacetic (Remixed/Remastered)", catalog: true)) == nil)
        #expect(original.album(for: release("Copacetic", catalog: true)) != nil)
        // Without the catalogue to say it's another release, an edition note is still ignored.
        #expect(original.album(for: release("Copacetic (Remastered)", catalog: false)) != nil)
        // An album page opened for the remaster by name.
        #expect(original.album(for: release("Copacetic (Remixed/Remastered)", catalog: false), named: true) == nil)

        let remaster = LibraryIndex(albums: [AlbumKey(artist: "Knuckle Puck", title: "Copacetic (Remixed / Remastered)")])
        #expect(remaster.album(for: release("Copacetic (Remixed/Remastered)", catalog: true)) != nil)
    }
}

struct OtherVersionsTests {
    private func release(_ name: String, year: Int, count: Int = 11) -> CatalogRelease {
        CatalogRelease(artist: "Knuckle Puck", title: CatalogRelease.cleanTitle(name),
                       kind: CatalogRelease.kind(of: name, trackCount: count),
                       released: Calendar.current.date(from: DateComponents(year: year))!, trackCount: count)
    }

    private var catalog: [CatalogRelease] {
        [release("Copacetic", year: 2015), release("Copacetic", year: 2015),
         release("Copacetic (Remixed/Remastered)", year: 2025), release("Copacetic - Single", year: 2015, count: 1),
         release("Shapeshifter", year: 2017)]
    }

    @Test func eachEditionListsTheOthersOnce() {
        #expect(CatalogRelease.otherVersions(of: "Copacetic", in: catalog).map(\.title) == ["Copacetic (Remixed/Remastered)"])
        // Tags spell the remaster their own way.
        #expect(CatalogRelease.otherVersions(of: "Copacetic (Remixed & Remastered)", in: catalog).map(\.title) == ["Copacetic"])
        #expect(CatalogRelease.otherVersions(of: "Shapeshifter", in: catalog).isEmpty)
    }

    @Test func theFooterUsesTheVeryRelease() {
        #expect(CatalogRelease.release(of: "Copacetic (Remixed & Remastered)", in: catalog)?.year == 2025)
        #expect(CatalogRelease.release(of: "Copacetic", in: catalog)?.year == 2015)
    }
}
