import Foundation
import Testing
@testable import Seek

/// Now Playing says what's happening while a song loads: who it's coming from and how far along.
@MainActor
struct PlayerStatusTests {
    private func transfer(_ user: String, _ state: Transfer.State, received: UInt64 = 0, size: UInt64 = 10_000_000) -> Transfer {
        let transfer = Transfer(file: RemoteFile(username: user, path: "@@x\\Album\\01 Song.flac", size: size))
        transfer.state = state
        transfer.bytesReceived = received
        return transfer
    }

    @Test func waitingCopiesAndWhatsLeft() {
        let text = StreamService.describe([transfer("djpool", .queued(place: 12)), transfer("other", .connecting)],
                                          left: 3, startBytes: 512 * 1024)
        #expect(text == "In djpool's queue (place 12) · Connecting to other · 3 more copies")
    }

    @Test func theCopySendingComesFirst() {
        let text = StreamService.describe([transfer("slow", .queued(place: nil)), transfer("fast", .downloading, received: 100_000)],
                                          left: 0, startBytes: 512 * 1024)
        #expect(text.hasPrefix("From fast · "))
        #expect(text.contains("starts at 512 KB"))
        #expect(text.hasSuffix("In slow's queue"))
    }

    @Test func nothingAskedYet() {
        #expect(StreamService.describe([], left: 0, startBytes: 1) == "Looking for a copy")
        #expect(StreamService.describe([], left: 1, startBytes: 1) == "1 more copy")
    }
}
