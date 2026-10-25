import Testing
@testable import Seek

@MainActor
struct ArrivingTrackTests {
    @Test func readsNumberAndTitleFromFileNames() {
        let name = "The Killers - Sam's Town  - 15 - Where the White Boys Dance.flac"
        #expect(ArrivingTrackRow.number(name) == 15)
        #expect(ArrivingTrackRow.title(name) == "Where the White Boys Dance")
        #expect(ArrivingTrackRow.number("15 Where the White Boys Dance.flac") == 15)
        #expect(ArrivingTrackRow.number("03 - Bones.mp3") == 3)
        #expect(ArrivingTrackRow.title("03 - Bones.mp3") == "Bones")
        #expect(ArrivingTrackRow.number("Bones.mp3") == nil)
    }
}
