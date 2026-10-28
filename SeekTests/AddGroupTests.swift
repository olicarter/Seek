import Foundation
import Testing
@testable import Seek

/// An album added as one loses a song for good only once nothing else will bring it.
struct AddGroupTests {
    @Test func aSongRefusedWithNoOtherCopyIsLost() {
        #expect(SoulseekClient.hasLostSong([(.failed("File not shared."), nil, false), (.queued(place: 379), nil, false)]))
    }

    @Test func aSongStillBeingLookedForElsewhereIsNot() {
        #expect(!SoulseekClient.hasLostSong([(.failed("File not shared."), nil, true), (.downloading, nil, false)]))
    }

    @Test func aSongWaitingToBeTriedAgainIsNot() {
        #expect(!SoulseekClient.hasLostSong([(.failed("Connection lost"), Date.now.addingTimeInterval(30), false)]))
    }

    @Test func songsOnTheirWayAreNot() {
        #expect(!SoulseekClient.hasLostSong([(.downloading, nil, false), (.completed, nil, false), (.queued(place: nil), nil, false)]))
    }
}
