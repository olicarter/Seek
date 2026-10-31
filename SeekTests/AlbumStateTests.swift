import Foundation
import Testing
@testable import Seek

/// Album pages show one state per song, and only what that state allows: each case below is a
/// mix of sources that once left a page wrong.
@MainActor
struct AlbumStateTests {
    private let fairDinkum = [
        ReferenceTrack(number: 1, disc: 1, title: "Volitant", duration: 300),
        ReferenceTrack(number: 2, disc: 1, title: "Namerakana", duration: 330),
        ReferenceTrack(number: 3, disc: 1, title: "F303L", duration: 334),
        ReferenceTrack(number: 4, disc: 1, title: "Volitant (2 Step Mix)", duration: 272),
    ]

    private func have(_ title: String, _ number: Int, path: String? = nil, fromMac: Bool = false, duration: Double = 300) -> AlbumFacts.LibrarySong {
        AlbumFacts.LibrarySong(path: path ?? "Lemtom/Fair Dinkum/\(number) \(title).flac", title: title, number: number, disc: 1,
                               duration: duration, fromMac: fromMac)
    }

    private func download(_ name: String, user: String = "someone", _ state: Transfer.State, onItsWay: Bool = true,
                          replaces: Bool = false, progress: Double? = nil) -> AlbumFacts.Download {
        AlbumFacts.Download(id: UUID(), file: RemoteFile(username: user, path: "@@x\\Lemtom - Fair Dinkum\\\(name)", size: 1, duration: 300),
                            state: state, progress: progress, onItsWay: onItsWay, replacesExisting: replaces)
    }

    @Test func addedOnTheMacButNotHereYet() {
        // iCloud is minutes behind: the songs are listed from the Mac.
        let facts = AlbumFacts(tracklist: fairDinkum, library: fairDinkum.map { have($0.title, $0.number, fromMac: true) },
                               copies: .found([]))
        let (state, songs) = AlbumState.derive(facts)
        #expect(state == .complete)
        #expect(!state.canAdd)
        #expect(songs.count == 4)
        #expect(songs.allSatisfy { if case .onMac = $0.state { $0.isPlayable } else { false } })
    }

    @Test func songsNotReadYetArentShownTwice() {
        // Named after their files ("Fair Dinkum - 01 - Volitant"), beside the tracklist.
        let library = fairDinkum.map { track in
            have("Fair Dinkum - 0\(track.number) - \(track.title)", 0,
                 path: "Lemtom/Fair Dinkum (2023)/Lemtom - Fair Dinkum - 0\(track.number) - \(track.title).mp3", duration: 0)
        }
        let (state, songs) = AlbumState.derive(AlbumFacts(tracklist: fairDinkum, library: library))
        #expect(songs.count == 4)
        #expect(state == .complete)
        #expect(songs.map(\.title) == fairDinkum.map(\.title))
    }

    @Test func aRememberedSearchDoesntOverruleTheLibrary() {
        // The page's copy search found nothing, earlier: the album is here all the same.
        let facts = AlbumFacts(tracklist: fairDinkum, library: fairDinkum.map { have($0.title, $0.number) }, copies: .found([]))
        #expect(AlbumState.derive(facts).state == .complete)
    }

    @Test func addingNeverOffersAddAgain() {
        let facts = AlbumFacts(tracklist: fairDinkum,
                               downloads: [download("01 Volitant.flac", user: "a", .queued(place: 12)),
                                           download("02 Namerakana.flac", user: "a", .downloading, progress: 0.4),
                                           download("03 F303L.flac", user: "a", .connecting),
                                           download("04 Volitant (2 Step Mix).flac", user: "a", .queued(place: nil))],
                               copies: .found([]))
        let (state, songs) = AlbumState.derive(facts)
        #expect(state == .adding(arrived: 0, total: 4))
        #expect(!state.canAdd)
        #expect(songs[0].state == .arriving(.queued(user: "a", place: 12)))
        #expect(songs[1].progress == 0.4)
        #expect(songs.count == 4)
    }

    @Test func aSongMovedToAnotherUserIsOneSong() {
        let facts = AlbumFacts(tracklist: fairDinkum,
                               library: Array(fairDinkum.dropFirst()).map { have($0.title, $0.number) },
                               downloads: [download("01 Volitant.flac", user: "old", .cancelled, onItsWay: false),
                                           download("Lemtom - Volitant.flac", user: "new", .queued(place: 3))])
        let (state, songs) = AlbumState.derive(facts)
        #expect(songs.count == 4)
        #expect(songs[0].state == .arriving(.queued(user: "new", place: 3)))
        #expect(state == .adding(arrived: 3, total: 4))
    }

    @Test func anUpgradeReplacesInPlace() {
        let facts = AlbumFacts(tracklist: fairDinkum, library: fairDinkum.map { have($0.title, $0.number) },
                               downloads: [download("01-lemtom-volitant_(original_mix).flac", .downloading, replaces: true, progress: 0.5)])
        let (state, songs) = AlbumState.derive(facts)
        #expect(songs.count == 4)
        #expect(state == .complete)
        #expect(songs[0].state == .replacing(path: "Lemtom/Fair Dinkum/1 Volitant.flac", progress: 0.5))
    }

    @Test func aSongArrivingUnderAnotherNameIsItsSong() {
        let facts = AlbumFacts(tracklist: fairDinkum,
                               downloads: [download("01-lemtom-volitant_(original_mix).flac", .downloading, progress: 0.2)])
        let (_, songs) = AlbumState.derive(facts)
        #expect(songs.count == 4)
        #expect(songs[0].progress == 0.2)
    }

    @Test func aStoppedAddCanBeTriedAgain() {
        let facts = AlbumFacts(tracklist: fairDinkum, copies: .found([]), addFailure: "Volitant couldn't be downloaded from anyone.")
        let (state, _) = AlbumState.derive(facts)
        #expect(state == .addFailed("Volitant couldn't be downloaded from anyone."))
        #expect(state.canAdd)
    }

    @Test func stillLookingIsntUnavailable() {
        let (state, songs) = AlbumState.derive(AlbumFacts(tracklist: fairDinkum, copies: .looking))
        #expect(state == .looking)
        #expect(songs.allSatisfy { $0.state == .looking })
        let found = AlbumState.derive(AlbumFacts(tracklist: fairDinkum, copies: .found([
            RemoteFile(username: "u", path: "@@x\\Fair Dinkum\\01 Volitant.flac", size: 1),
        ])))
        #expect(found.state == .available)
        #expect(found.songs[0].state == .available && found.songs[1].state == .unavailable)
    }

    @Test func partlyInTheLibrary() {
        let facts = AlbumFacts(tracklist: fairDinkum, library: [have("Volitant", 1)],
                               copies: .found([RemoteFile(username: "u", path: "@@x\\Fair Dinkum\\02 Namerakana.flac", size: 1)]))
        let (state, _) = AlbumState.derive(facts)
        #expect(state == .partial(missing: 3, canAdd: true))
    }

    @Test func noTracklistIsTheLibrarysSongs() {
        let (state, songs) = AlbumState.derive(AlbumFacts(library: [have("Volitant", 1), have("Namerakana", 2)]))
        #expect(state == .complete)
        #expect(songs.map(\.title) == ["Volitant", "Namerakana"])
    }

    @Test func songsOfOneNameGoByTheirPlace() {
        let tracklist = [ReferenceTrack(number: 5, disc: 1, title: "Never Lose Me (feat. SZA & Cardi B)", duration: 166),
                         ReferenceTrack(number: 14, disc: 1, title: "Never Lose Me", duration: 126)]
        let library = [have("Never Lose Me (feat. SZA & Cardi B)", 5, duration: 166), have("Never Lose Me", 14, duration: 126)]
        let (state, songs) = AlbumState.derive(AlbumFacts(tracklist: tracklist, library: library))
        #expect(state == .complete)
        #expect(songs.map(\.libraryPath) == library.map(\.path))
    }

    @Test func aSongFinishedOnTheMacIsntOfferedAgain() {
        // Downloaded on the Mac; this device's library doesn't have it yet.
        let facts = AlbumFacts(tracklist: fairDinkum,
                               library: Array(fairDinkum.dropFirst()).map { have($0.title, $0.number, fromMac: true) },
                               downloads: [download("01 Volitant.flac", .completed, onItsWay: false)],
                               copies: .found([RemoteFile(username: "u", path: "@@x\\Fair Dinkum\\01 Volitant.flac", size: 1)]))
        let (state, songs) = AlbumState.derive(facts)
        #expect(songs[0].state == .arriving(.importing))
        #expect(!state.canAdd)
    }

    @Test func aFinishedSongInTheLibraryIsShownOnce() {
        // Finished on the Mac, and now in this device's library too.
        let facts = AlbumFacts(tracklist: fairDinkum,
                               library: fairDinkum.map { have($0.title, $0.number, fromMac: true) },
                               downloads: [download("01 Volitant.flac", .completed, onItsWay: false),
                                           download("05 Bonus Track.flac", .completed, onItsWay: false)],
                               copies: .found([]))
        let (state, songs) = AlbumState.derive(facts)
        #expect(songs.count == fairDinkum.count + 1)
        #expect(songs.filter { $0.title == "Volitant" }.count == 1)
        #expect(songs.last?.title == "Bonus Track")
        #expect(songs.last?.state == .arriving(.importing))
        #expect(state == .adding(arrived: 4, total: 5))
    }
}
