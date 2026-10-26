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

struct DoubleASideTests {
    static let album = AlbumKey(artist: "Peverelist", title: "Roll with the Punches / Die Brücke")

    /// Soulseek only finds folders with every word searched for: a "/" or one side's name in
    /// another spelling ("Brucke") finds nothing.
    @Test func theSearchUsesWordsCopiesAreNamedWith() {
        let words = CopyFinder.query(for: Self.album).split(separator: " ")
        #expect(!words.contains("/"))
        #expect(!words.contains { $0.lowercased().hasPrefix("br") })
    }

    @Test func copiesNamedForBothSidesOrTheFirstAreFound() async throws {
        let dump = try RealSearchTests.load("search-peverelist")
        let folders = await CopyFinder.matching(Self.album, query: CopyFinder.query(for: Self.album), in: dump.folders, quality: .cd)
        let names = Set(folders.map(\.name))
        #expect(names.contains { $0.contains("Roll With the Punches _ Die Brücke") })
        #expect(names.contains { $0.contains("Roll_With_The_Punches-(DRUNK005-WEB)") })
        // Remixes of the A-side are other releases.
        #expect(!names.contains { $0.contains("Kowton") || $0.contains("Jook") })
        #expect(folders.count >= 8)
    }
}

struct DoubleASideSearchTests {
    /// Searching the artist, every copy of the single is one result, however its folder or
    /// artist is written ("[DRUNK5] Peverelist", "… 320 WEB 2007", the first side alone).
    @Test func anArtistSearchGroupsEveryCopyOfTheSingle() throws {
        let releases = RealSearchTests.releases(try RealSearchTests.load("search-peverelist"))
        let single = releases.filter { AlbumIdentity.sameRelease($0.title, "Roll with the Punches / Die Brücke") }
        #expect(single.count == 1)
        #expect((single.first?.folders.count ?? 0) >= 11)
        #expect(!releases.contains { $0.artist.hasPrefix("[") })
    }

    @Test func namesLoseCatalogueNumbersAndTags() {
        #expect(ReleaseText.canonicalArtist("[DRUNK5] Peverelist") == "Peverelist")
        #expect(ReleaseText.cleanTitle("Roll With The Punches _ Die Brucke 320 WEB 2007") == "Roll With The Punches _ Die Brucke")
        #expect(ReleaseText.cleanTitle("Roll With the Punches _ Die Brücke [Digital Media]") == "Roll With the Punches _ Die Brücke")
    }
}
