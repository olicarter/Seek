import Foundation
import Testing
@testable import Seek

struct SharedSongTests {
    @Test func shazamMessage() {
        let text = "I used Shazam to discover Blinding Lights by The Weeknd. https://www.shazam.com/track/20066955/blinding-lights"
        #expect(SharedSong.query(fromMessage: text) == "The Weeknd Blinding Lights")
    }

    @Test func plainMessageSplitsOnTheLastBy() {
        #expect(SharedSong.query(fromMessage: "Stand by Me by Ben E. King") == "Ben E. King Stand by Me")
        #expect(SharedSong.query(fromMessage: "Iconicy (feat. MINIKINGZ) by Dimension") == "Dimension Iconicy")
        #expect(SharedSong.query(fromMessage: "https://www.shazam.com/track/20066955/blinding-lights") == nil)
    }

    @Test func appleIDs() {
        func id(_ s: String) -> String? { SharedSong.appleID(in: URL(string: s)!) }
        #expect(id("https://www.shazam.com/song/1488408568/blinding-lights") == "1488408568")
        #expect(id("https://www.shazam.com/track/20066955/blinding-lights") == nil)
        #expect(id("https://music.apple.com/gb/album/after-hours/1499378108?i=1499378615") == "1499378615")
        #expect(id("https://music.apple.com/gb/song/blinding-lights/1488408568") == "1488408568")
        #expect(id("https://music.apple.com/gb/album/after-hours/1499378108") == nil)
    }

    @Test func slugWords() {
        #expect(SharedSong.slugQuery(URL(string: "https://www.shazam.com/track/20066955/blinding-lights")!) == "blinding lights")
        #expect(SharedSong.slugQuery(URL(string: "https://example.com/blinding-lights")!) == nil)
    }

    @Test func links() async {
        #expect(await SharedSong.query(for: URL(string: "seek://search?q=The%20Weeknd%20Blinding%20Lights")!) == "The Weeknd Blinding Lights")
        #expect(await SharedSong.query(for: URL(string: "seek://search?q=")!) == nil)
        #expect(await SharedSong.query(for: URL(string: "https://example.com")!) == nil)
        // An old Shazam link alone: its words.
        let shared = "seek://share?text=" + "https://www.shazam.com/track/20066955/blinding-lights"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(await SharedSong.query(for: URL(string: shared)!) == "blinding lights")
    }
}
