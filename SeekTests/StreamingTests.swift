import Foundation
import Testing
@testable import Seek

@MainActor
struct StreamingTests {
    private func folder(_ user: String, _ names: [String]) -> RemoteFolder {
        RemoteFolder(username: user, path: "Glitch",
                     files: names.map { RemoteFile(username: user, path: "Glitch\\\($0)", size: 1000) },
                     hasFreeSlot: true, averageSpeed: 1, queueLength: 0)
    }

    private let reference = AlbumReference(source: .bandcamp, artist: "Cryogeyser", title: "Glitch", tracks: [
        ReferenceTrack(number: 1, disc: 1, title: "Marie", duration: 161),
        ReferenceTrack(number: 2, disc: 1, title: "Focus", duration: 125),
        ReferenceTrack(number: 3, disc: 1, title: "Leach", duration: 233),
    ])

    @Test func buildsStreamsWithEveryCopyAndSkipsSongsWithNoSource() {
        let queue = StreamQueue.build(
            reference: reference, artist: "Cryogeyser", album: "Glitch",
            folders: [folder("a", ["01 Marie.flac", "02 Focus.flac"]), folder("b", ["01 - Marie.mp3"])],
            bandcampPage: nil, artworkURL: nil
        )
        #expect(queue.map(\.reference.title) == ["Marie", "Focus"])
        #expect(queue[0].track.stream?.candidates.map(\.username) == ["a", "b"])
        #expect(queue[0].track.isStreamed)
        #expect(queue[0].track.title == "Marie")
        #expect(queue[0].track.duration == 161)
    }

    @Test func bandcampPageMakesEverySongPlayable() {
        let queue = StreamQueue.build(reference: reference, artist: "Cryogeyser", album: "Glitch", folders: [],
                                      bandcampPage: URL(string: "https://cryogeyser.bandcamp.com/album/glitch"), artworkURL: nil)
        #expect(queue.count == 3)
        #expect(queue.allSatisfy { $0.track.stream?.candidates.isEmpty == true })
    }

    @Test func readsBandcampStreamLinks() {
        let html = """
            <script data-tralbum="{&quot;trackinfo&quot;:[{&quot;track_num&quot;:1,&quot;title&quot;:&quot;Marie&quot;,&quot;file&quot;:{&quot;mp3-128&quot;:&quot;https://t4.bcbits.com/stream/abc&quot;}}]}"></script>
            """
        #expect(BandcampAPI.parseRelease(html)?.tracks.first?.streamURL == URL(string: "https://t4.bcbits.com/stream/abc"))
    }

    @Test func cachesFetchedSongs() throws {
        let service = StreamService(client: SoulseekClient())
        let file = RemoteFile(username: "u", path: "Glitch\\\(UUID().uuidString).flac", size: 4)
        let transfer = Transfer(file: file)
        let partial = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try Data([1, 2, 3, 4]).write(to: partial)
        try service.store(transfer, from: partial)
        let cached = try #require(service.cachedURL(for: file))
        #expect(try Data(contentsOf: cached) == Data([1, 2, 3, 4]))
    }

    @Test func albumQueuesAreBuiltOnceAndReused() {
        let service = StreamService(client: SoulseekClient())
        let titles = (1...12).map { "Song Number \($0)" }
        let big = AlbumReference(source: .itunes, artist: "A", title: "B",
                                 tracks: titles.enumerated().map { ReferenceTrack(number: $0.offset + 1, disc: 1, title: $0.element) })
        let folders = (0..<10).map { user in folder("u\(user)", titles.enumerated().map { "\($0.offset + 1) - A - \($0.element) [FLAC].flac" }) }
        let start = Date.now
        let first = service.queue(reference: big, artist: "A", album: "B", folders: folders, bandcampPage: nil, artworkURL: nil)
        let built = Date.now.timeIntervalSince(start)
        let again = Date.now
        let second = service.queue(reference: big, artist: "A", album: "B", folders: folders, bandcampPage: nil, artworkURL: nil)
        let reused = Date.now.timeIntervalSince(again)
        #expect(first.count == 12)
        #expect(zip(first, second).allSatisfy { $0.track === $1.track })
        #expect(first[0].track.stream?.candidates.count == 10)
        print("TIMING queue built in \(Int(built * 1000)) ms, reused in \(Int(reused * 1000)) ms")
        #expect(reused < 0.01)
    }
}
