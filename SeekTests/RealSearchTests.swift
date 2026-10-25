import Foundation
import Testing
@testable import Seek

/// Search grouping replayed against real Soulseek results saved with `-SeekSearchDump`.
struct RealSearchTests {
    private final class Bundle_ {}

    static func load(_ name: String) throws -> SearchDump {
        let url = try #require(Bundle(for: Bundle_.self).url(forResource: name, withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SearchDump.self, from: Data(contentsOf: url))
    }

    static func releases(_ dump: SearchDump) -> [SearchRelease] {
        ReleaseGrouper.group(query: dump.query, owned: [], store: [], folders: dump.folders, catalog: dump.catalog).releases
    }

    @Test func playboiCartiReleasesAreCleanAndMainOnesLead() throws {
        let releases = Self.releases(try Self.load("search-playboi-carti"))
        // No years, dates or "Album" left in titles: "2025 - MUSIC", "MUSIC - 2025-03-14" and
        // "08-29 - WLR Leaks and Beyond" were all the same releases under folder clutter.
        for release in releases {
            #expect(release.title.firstMatch(of: /^((19|20)\d\d|\d\d-\d\d)\s*-/) == nil, "\(release.title)")
            #expect(release.title.firstMatch(of: /-\s*(19|20)\d\d-\d\d-\d\d$/) == nil, "\(release.title)")
        }
        // What's left of MUSIC on its own is a different release (the clean edit, a fan
        // compilation, the working title), not folder clutter.
        let leftover = releases.filter { ReleaseText.fold($0.title).hasPrefix("music") && $0.catalog == nil }.map(\.title)
        #expect(Set(leftover) == ["Music [Edit]", "MUSIC Era", "MUSIC (I AM MUSIC) (IAMMUSIC)"])
        // The latest albums lead, each with copies, the deluxe edition separate from the standard.
        #expect(releases.prefix(5).map(\.title) == ["MUSIC - SORRY 4 DA WAIT", "MUSIC", "Whole Lotta Red", "Die Lit", "Playboi Carti"])
        #expect(releases.prefix(5).allSatisfy { $0.folders.count >= 10 })
        #expect(releases.contains { $0.title == "WLR Leaks and Beyond" && $0.year == 2019 })
    }
}
