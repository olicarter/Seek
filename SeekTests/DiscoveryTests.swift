import Foundation
import SwiftData
import Testing
@testable import Seek

@MainActor
struct DiscoveryTests {
    @Test func cacheKeysIgnoreCaseAndAccents() {
        #expect(DiscoveryService.Subject.artist("Amélie Lens").key == DiscoveryService.Subject.artist("amelie lens ").key)
        #expect(DiscoveryService.Subject.album(artist: "DreamKiller", title: "Lux").key == "album:dreamkiller|lux")
        #expect(DiscoveryService.Subject.artist("Lux").key != DiscoveryService.Subject.album(artist: "Lux", title: "").key)
    }

    @Test func parsesSuggestionsDroppingDuplicatesAndBlanks() {
        let input: [String: Any] = ["suggestions": [
            ["artist": "Nite Fleit", "title": "Spinning Out", "year": 2022, "reason": "Hypnotic hardgroove"],
            ["artist": "nite fleit", "title": "spinning out", "year": NSNull(), "reason": "dup"],
            ["artist": " ", "title": "x", "year": NSNull(), "reason": "blank"],
            ["artist": "VTSS", "title": "", "year": NSNull(), "reason": "Same scene"],
        ]]
        let suggestions = DiscoveryService.parse(input)
        #expect(suggestions.map(\.artist) == ["Nite Fleit", "VTSS"])
        #expect(suggestions.first?.year == 2022)
        #expect(suggestions.last?.title == nil)
    }

    @Test func promptListsWhatToSkip() {
        let context = DiscoveryService.LibraryContext(artists: ["DreamKiller", "VTSS"], albums: ["DreamKiller – Lux"], details: "released 2025")
        let artist = DiscoveryService.prompt(for: .artist("DreamKiller"), library: context)
        #expect(artist.contains("similar to DreamKiller"))
        #expect(artist.contains("VTSS"))
        let album = DiscoveryService.prompt(for: .album(artist: "DreamKiller", title: "Lux"), library: context)
        #expect(album.contains("DreamKiller – Lux"))
        #expect(album.contains("released 2025"))
    }

    @Test func albumToolAsksForTitles() throws {
        let tool = DiscoveryService.tool(for: .album(artist: "A", title: "B"))
        let schema = try #require(tool["input_schema"] as? [String: Any])
        let items = try #require(((schema["properties"] as? [String: Any])?["suggestions"] as? [String: Any])?["items"] as? [String: Any])
        #expect((items["required"] as? [String]) == ["artist", "reason", "title", "year"])
        let artistTool = DiscoveryService.tool(for: .artist("A"))
        let artistItems = ((((artistTool["input_schema"] as? [String: Any])?["properties"] as? [String: Any])?["suggestions"] as? [String: Any])?["items"] as? [String: Any])
        #expect((artistItems?["required"] as? [String]) == ["artist", "reason"])
    }

    @Test func homeRowTakesTopAlbumsFromEachPage() throws {
        func entry(_ key: String, _ names: [String]) throws -> Discovery {
            let suggestions = names.map { DiscoveryService.Suggestion(artist: $0, title: "\($0) LP", reason: "") }
            return Discovery(key: key, payload: try JSONEncoder().encode(suggestions))
        }
        let entries = [
            try entry("album:a|x", ["A1", "A2", "A3", "A4", "A5"]),
            try entry("artist:b", ["B1"]),
            try entry("album:c|y", ["A1", "C1"]),
        ]
        #expect(DiscoverHomeRow.albums(from: entries).map(\.artist) == ["A1", "A2", "A3", "A4", "C1"])
    }

    @Test func subjectsSurviveBeingSaved() throws {
        let subjects: [DiscoveryService.Subject] = [.artist("Cryogeyser"), .album(artist: "Cryogeyser", title: "Glitch")]
        let data = try JSONEncoder().encode(subjects)
        #expect(try JSONDecoder().decode([DiscoveryService.Subject].self, from: data) == subjects)
    }

    @Test func coverMatchingNeedsTheTitleForAlbums() {
        let results = ["Girl, so confusing - Single", "Pop 2", "Brat"]
        #expect(DiscoveryService.pick(results, title: "Pop 2") { $0 } == "Pop 2")
        #expect(DiscoveryService.pick(results, title: "Sucker") { $0 } == nil)
        #expect(DiscoveryService.pick(results, title: nil) { $0 } == "Girl, so confusing - Single")
    }
}

@MainActor
struct DiscoveryCacheTests {
    @Test func emptyAnswersCountAsNotAsked() throws {
        let container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Discovery.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = DiscoveryService(container: container)
        let subject = DiscoveryService.Subject.album(artist: "Playboi Carti", title: "Unreleased")
        container.mainContext.insert(Discovery(key: subject.key, payload: Data("[]".utf8)))
        #expect(service.cached(subject) == nil)
        let one = [DiscoveryService.Suggestion(artist: "Ken Carson", title: "A Great Chaos", reason: "")]
        container.mainContext.insert(Discovery(key: subject.key, payload: try JSONEncoder().encode(one)))
        #expect(service.cached(subject)?.count == 1)
    }
}
