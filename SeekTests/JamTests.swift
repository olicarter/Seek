import Foundation
import Testing
@testable import Seek

struct JamTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func song(_ title: String) -> Jam.Song {
        Jam.Song(title: title, artist: "Burial", album: "Untrue", albumArtist: "Burial", duration: 200, path: "Burial/Untrue/\(title).flac")
    }

    private func jam(guestsCanControl: Bool = true) -> Jam {
        var jam = Jam.start(hostName: "Oli", key: "secret", now: now)
        jam.guestsCanControl = guestsCanControl
        _ = jam.join(name: "Sam", id: "sam")
        return jam
    }

    @Test func theFirstSongAddedStarts() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        try jam.add(song("Near Dark"), by: Jam.host, id: "2", now: now)
        #expect(jam.nowPlaying?.id == "1")
        #expect(jam.playing)
        #expect(jam.upNext.map(\.id) == ["2"])
        #expect(jam.commands == 1)
    }

    @Test func strangersCantAdd() {
        var jam = jam()
        #expect(throws: Jam.Refusal.unknownPerson) { try jam.add(song("Archangel"), by: "nobody", id: "1") }
    }

    @Test func guestsControlOnlyWhenAllowed() throws {
        var jam = jam(guestsCanControl: false)
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        #expect(throws: Jam.Refusal.notAllowed) { try jam.control(.pause, by: "sam") }
        try jam.control(.pause, by: Jam.host, now: now)
        #expect(!jam.playing)
        try jam.setGuestsCanControl(true, by: Jam.host)
        try jam.control(.play, by: "sam", now: now)
        #expect(jam.playing)
        #expect(throws: Jam.Refusal.notAllowed) { try jam.setGuestsCanControl(false, by: "sam") }
    }

    @Test func guestsRemoveOnlyTheirOwn() throws {
        var jam = jam()
        _ = jam.join(name: "Alex", id: "alex")
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        try jam.add(song("Near Dark"), by: "sam", id: "2", now: now)
        try jam.add(song("Ghost Hardware"), by: "alex", id: "3", now: now)
        #expect(throws: Jam.Refusal.notAllowed) { try jam.remove("3", by: "sam") }
        #expect(throws: Jam.Refusal.playing) { try jam.remove("1", by: "sam") }
        try jam.remove("2", by: "sam")
        try jam.remove("3", by: Jam.host)
        #expect(jam.items.map(\.id) == ["1"])
    }

    @Test func removingAPlayedSongKeepsTheOnePlaying() throws {
        var jam = jam()
        for (id, title) in [("1", "Archangel"), ("2", "Near Dark"), ("3", "Endorphin")] { try jam.add(song(title), by: "sam", id: id, now: now) }
        try jam.control(.next, by: "sam", now: now)
        try jam.remove("1", by: Jam.host)
        #expect(jam.nowPlaying?.id == "2")
    }

    @Test func skippingPastTheEndFinishesAndTheNextSongStarts() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        try jam.control(.next, by: "sam", now: now)
        #expect(jam.finished && !jam.playing)
        try jam.add(song("Near Dark"), by: "sam", id: "2", now: now)
        #expect(jam.nowPlaying?.id == "2")
        #expect(jam.playing && !jam.finished)
    }

    @Test func previousRestartsAfterThreeSeconds() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        try jam.add(song("Near Dark"), by: "sam", id: "2", now: now)
        try jam.control(.next, by: "sam", now: now)
        try jam.control(.previous, by: "sam", now: now.addingTimeInterval(10))
        #expect(jam.nowPlaying?.id == "2")
        #expect(jam.restarts == 1)
        try jam.control(.previous, by: "sam", now: now.addingTimeInterval(10))
        #expect(jam.nowPlaying?.id == "1")
    }

    @Test func theSpeakerOverrulesOnlyOnceItHasCaughtUp() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        try jam.add(song("Near Dark"), by: "sam", id: "2", now: now)
        try jam.control(.pause, by: "sam", now: now)
        // Still playing: it hasn't had the pause yet.
        jam.report(Jam.Report(item: "1", playing: true, position: 5, commands: 1), now: now)
        #expect(!jam.playing)
        #expect(jam.position == 5)
        // The host skips on the speaker itself, having had the pause.
        jam.report(Jam.Report(item: "2", playing: true, position: 0, commands: jam.commands), now: now)
        #expect(jam.nowPlaying?.id == "2")
        #expect(jam.playing)
    }

    @Test func theLastSongEnding() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        jam.report(Jam.Report(item: "1", playing: false, position: 200, commands: jam.commands, ended: true), now: now)
        #expect(jam.finished)
        try jam.control(.play, by: "sam", now: now)
        #expect(jam.playing && jam.restarts == 1)
    }

    @Test func theHostReordersWhatsToCome() throws {
        var jam = jam()
        for (id, title) in [("1", "Archangel"), ("2", "Near Dark"), ("3", "Endorphin")] { try jam.add(song(title), by: "sam", id: id, now: now) }
        try jam.move("3", toUpNext: 0, by: Jam.host)
        #expect(jam.upNext.map(\.id) == ["3", "2"])
        #expect(throws: Jam.Refusal.notAllowed) { try jam.move("2", toUpNext: 0, by: "sam") }
        #expect(throws: Jam.Refusal.notFound) { try jam.move("1", toUpNext: 1, by: Jam.host) }
    }

    @Test func positionMovesOnWhilePlaying() throws {
        var jam = jam()
        try jam.add(song("Archangel"), by: "sam", id: "1", now: now)
        jam.report(Jam.Report(item: "1", playing: true, position: 30, commands: jam.commands), now: now)
        #expect(jam.position(at: now.addingTimeInterval(5)) == 35)
        #expect(!jam.isExpired(at: now.addingTimeInterval(11 * 3600)))
        #expect(jam.isExpired(at: now.addingTimeInterval(12 * 3600)))
    }
}
