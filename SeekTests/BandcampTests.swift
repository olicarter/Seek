import Foundation
import Testing
import ZIPFoundation
@testable import Seek

struct BandcampParsingTests {
    @Test func parsesFan() throws {
        let fan = try BandcampAPI.parseFan(Data(#"{"fan_id":4242,"collection_summary":{"username":"oli"}}"#.utf8))
        #expect(fan.id == 4242)
        #expect(fan.username == "oli")
    }

    @Test func fanErrorIsReadable() {
        #expect(throws: BandcampError.self) {
            try BandcampAPI.parseFan(Data(#"{"error":true,"error_message":"must be logged in"}"#.utf8))
        }
    }

    @Test func parsesCollectionPage() throws {
        let json = """
        {"items":[
          {"sale_item_type":"p","sale_item_id":111,"item_type":"album","item_title":"Retina Grains","band_name":"Boxcutter","item_art_id":123456},
          {"sale_item_type":"t","sale_item_id":222,"item_type":"track","item_title":"Single","band_name":"Calm Whale","item_art_id":null}
        ],
        "more_available":true,"last_token":"1700000000:111:p::",
        "redownload_urls":{"p111":"https://bandcamp.com/download?from=collection&payment_id=1&sig=abc&sitem_id=111"}}
        """
        let page = try BandcampAPI.parseCollectionPage(Data(json.utf8))
        #expect(page.items.count == 2)
        #expect(page.moreAvailable)
        #expect(page.lastToken == "1700000000:111:p::")
        let album = page.items[0]
        #expect(album.title == "Retina Grains")
        #expect(album.artist == "Boxcutter")
        #expect(!album.isTrack)
        #expect(album.redownloadURL?.absoluteString.contains("sitem_id=111") == true)
        #expect(album.artworkURL?.absoluteString == "https://f4.bcbits.com/img/a0000123456_2.jpg")
        #expect(page.items[1].isTrack)
        #expect(page.items[1].redownloadURL == nil)
        #expect(album.matches(["box", "retina"]))
        #expect(!album.matches(["box", "whale"]))
    }

    @Test func picksBestFormatFromDownloadPage() throws {
        let blob = #"{"download_items":[{"title":"Retina Grains","downloads":{"mp3-320":{"url":"https://p4.bcbits.com/download/album?enc=mp3-320&id=1"},"flac":{"url":"https://p4.bcbits.com/download/album?enc=flac&id=1&fsig=x"}}}]}"#
        let escaped = blob.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let html = #"<html><body><div id="pagedata" data-blob="\#(escaped)"></div></body></html>"#
        let url = try BandcampAPI.parseDownloadLink(html)
        #expect(url.absoluteString == "https://p4.bcbits.com/download/album?enc=flac&id=1&fsig=x")
    }

    @Test func missingPageDataThrows() {
        #expect(throws: BandcampError.self) { try BandcampAPI.parseDownloadLink("<html></html>") }
    }

    @Test func parsesStatusReply() {
        let reply = #"if ( window.Downloads ) { Downloads.statResult ( {"result":"ok","download_url":"//p4.bcbits.com/download/album?enc=flac&id=1&ts=2"} ) };"#
        let status = BandcampAPI.parseStatus(Data(reply.utf8))
        #expect(status?.result == "ok")
        #expect(status?.downloadURL?.absoluteString == "https://p4.bcbits.com/download/album?enc=flac&id=1&ts=2")
    }
}

@MainActor
struct BandcampImportTests {
    @Test func importsAudioFromZipIntoArtistAlbum() async throws {
        let work = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for name in ["Boxcutter - Retina Grains - 01 Glyph.flac", "Boxcutter - Retina Grains - 02 Moth.flac", "cover.jpg"] {
            try Data("x".utf8).write(to: work.appending(path: name))
        }
        let zip = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).zip")
        let archive = try Archive(url: zip, accessMode: .create)
        for name in try FileManager.default.contentsOfDirectory(atPath: work.path) {
            try archive.addEntry(with: name, relativeTo: work)
        }

        let client = BandcampClient()
        var imported: [(String, [String])] = []
        client.importFile = { _, folders, name in imported.append((name, folders)) }
        let item = BandcampItem(saleItemType: "a", saleItemId: 1, title: "Retina Grains", artist: "Boxcutter",
                                isTrack: false, artId: nil, redownloadURL: nil)
        try await client.importArchiveOrFile(zip, for: item)

        // Untagged files fall back to Bandcamp's file naming.
        #expect(imported.map(\.0) == ["01 Glyph.flac", "02 Moth.flac"])
        #expect(imported.allSatisfy { $0.1 == ["Boxcutter", "Retina Grains"] })
        #expect(!FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func downloadsWithSuggestedFileNameAndProgress() async throws {
        var reports: [Double] = []
        let file = try await BandcampClient.fetch(
            URL(string: "https://bandcamp.com/robots.txt")!, identity: "none"
        ) { reports.append($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.lastPathComponent.hasSuffix("robots.txt"))
        #expect(try Data(contentsOf: file).count > 0)
    }
}

struct BandcampReleasePageTests {
    @Test func readsCreditedArtistLabelYearAndTrackArtists() {
        let tralbum = #"{"artist":"Various Artists","trackinfo":[{"track_num":1,"artist":"Burial","title":"Archangel"},{"track_num":2,"artist":null,"title":"Intro"}]}"#
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
            <script type="application/ld+json">{"name":"Comp","byArtist":{"@type":"MusicGroup","name":"Various Artists"},\
            "publisher":{"name":"Hyperdub"},"datePublished":"06 May 2019 00:00:00 GMT"}</script>
            <div data-tralbum="\(tralbum)"></div>
            """
        let info = BandcampAPI.parseRelease(html)
        #expect(info?.artist == "Various Artists")
        #expect(info?.label == "Hyperdub")
        #expect(info?.year == 2019)
        #expect(info?.trackArtists == [1: "Burial"])
    }

    @Test func pageWithoutDataGivesNothing() {
        #expect(BandcampAPI.parseRelease("<html></html>") == nil)
    }
}

struct BandcampTagCorrectionTests {
    private func album(_ comments: [[String]]) throws -> (URL, [URL]) {
        let work = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let files = try comments.enumerated().map { index, fields in
            let url = work.appending(path: "Page - Album - 0\(index + 1) Song.flac")
            try FLACFixture.make(comments: fields).write(to: url)
            return url
        }
        return (work, files)
    }

    private let item = BandcampItem(saleItemType: "a", saleItemId: 1, title: "RETRO DESIRE EP", artist: "PLANETARIA SOUNDSYSTEM",
                                    isTrack: false, artId: nil, redownloadURL: nil,
                                    itemURL: URL(string: "https://planetariasoundsystem.bandcamp.com/album/retro-desire-ep"))

    @Test func creditedArtistReplacesLabel() throws {
        let (work, files) = try album([["TITLE=Retro desire", "ARTIST=PLANETARIA SOUNDSYSTEM", "ALBUM=RETRO DESIRE EP", "TRACKNUMBER=4"]])
        defer { try? FileManager.default.removeItem(at: work) }
        let release = BandcampAPI.ReleaseInfo(artist: "DJ これからの緊急災害", label: "PLANETARIA SOUNDSYSTEM", year: 2019)

        let placements = BandcampClient.correctTags(of: files, item: item, release: release)

        #expect(placements[0].folders == ["DJ これからの緊急災害", "RETRO DESIRE EP"])
        #expect(placements[0].name == "04 Retro desire.flac")
        let tags = try FLACTags.read(files[0])
        #expect(tags.artist == "DJ これからの緊急災害")
        #expect(tags.albumArtist == "DJ これからの緊急災害")
        #expect(tags.year == 2019)
        #expect(tags.label == "PLANETARIA SOUNDSYSTEM")
        #expect(tags.url == "https://planetariasoundsystem.bandcamp.com/album/retro-desire-ep")
    }

    @Test func labelCreditedAsArtistIsLeftForEditing() throws {
        let (work, files) = try album([["TITLE=Soul", "ARTIST=Diffuse Reality Records", "ALBUMARTIST=Diffuse Reality Records",
                                         "ALBUM=DreamKiller - Erotic Motion", "TRACKNUMBER=1", "DATE=2026"]])
        defer { try? FileManager.default.removeItem(at: work) }
        let page = BandcampItem(saleItemType: "a", saleItemId: 2, title: "DreamKiller - Erotic Motion", artist: "Diffuse Reality Records",
                                isTrack: false, artId: nil, redownloadURL: nil)
        let release = BandcampAPI.ReleaseInfo(artist: "Diffuse Reality Records", label: "Diffuse Reality Records", year: 2026)

        let placements = BandcampClient.correctTags(of: files, item: page, release: release)

        #expect(placements[0].folders == ["Diffuse Reality Records", "DreamKiller - Erotic Motion"])
        #expect(placements[0].name == "01 Soul.flac")
        let tags = try FLACTags.read(files[0])
        #expect(tags.artist == "Diffuse Reality Records")
        // Can't tell a label credited as artist from a self-release, so no label is guessed.
        #expect(tags.label == nil)
    }

    @Test func compilationTrackArtistsComeFromThePage() throws {
        let (work, files) = try album([
            ["TITLE=Archangel", "ARTIST=PLANETARIA SOUNDSYSTEM", "ALBUM=Comp", "TRACKNUMBER=1"],
            ["TITLE=Intro", "ARTIST=PLANETARIA SOUNDSYSTEM", "ALBUM=Comp", "TRACKNUMBER=2"],
        ])
        defer { try? FileManager.default.removeItem(at: work) }
        let release = BandcampAPI.ReleaseInfo(artist: "Various Artists", label: "PLANETARIA SOUNDSYSTEM", year: nil, trackArtists: [1: "Burial"])

        let placements = BandcampClient.correctTags(of: files, item: item, release: release)

        #expect(try FLACTags.read(files[0]).artist == "Burial")
        #expect(try FLACTags.read(files[1]).artist == "Various Artists")
        #expect(placements.allSatisfy { $0.folders == ["Various Artists", "Comp"] })
    }
}

extension BandcampTagCorrectionTests {
    @Test func standaloneSingleIsTrackOne() throws {
        let (work, files) = try album([["TITLE=Halftones", "ARTIST=Niontay, RealYungPhil, & SURF GANG"]])
        defer { try? FileManager.default.removeItem(at: work) }
        let single = BandcampItem(saleItemType: "t", saleItemId: 3, title: "Halftones", artist: "Niontay, RealYungPhil, & SURF GANG",
                                  isTrack: true, artId: nil, redownloadURL: nil)

        _ = BandcampClient.correctTags(of: files, item: single, release: nil)

        #expect(try FLACTags.read(files[0]).trackNumber == 1)
    }
}

struct ClaudeTagFixerTests {
    @Test func promptIncludesTagsAndSource() {
        let album = ClaudeTagFixer.Album(
            albumArtist: "Diffuse Reality Records", album: "DreamKiller - Erotic Motion", label: "", year: 2026,
            tracks: [.init(title: "Soul", artist: "Diffuse Reality Records", trackNumber: 1, fileName: "01 Soul.flac")],
            sourceURL: "https://diffusereality.bandcamp.com/album/dreamkiller-erotic-motion", comment: nil
        )
        let prompt = ClaudeTagFixer.prompt(for: album)
        #expect(prompt.contains("DreamKiller - Erotic Motion"))
        #expect(prompt.contains("Release page: https://diffusereality.bandcamp.com/album/dreamkiller-erotic-motion"))
        #expect(prompt.contains("01 Soul.flac"))
    }

    private let current = ClaudeTagFixer.Album(
        albumArtist: "Diffuse Reality Records", album: "DreamKiller - Erotic Motion", label: "", year: 2026,
        tracks: [.init(title: "Soul", artist: "Diffuse Reality Records", trackNumber: 1, fileName: "01 Soul.flac"),
                 .init(title: "Higher", artist: "Diffuse Reality Records", trackNumber: 2, fileName: "02 Higher.flac")],
        sourceURL: nil, comment: nil
    )

    @Test func parsesSubmittedCorrectionsInTrackOrder() throws {
        let input: [String: Any] = [
            "album_artist": "DreamKiller", "album": "Erotic Motion", "label": "Diffuse Reality Records", "year": 2026,
            "tracks": [["index": 1, "title": "Higher", "artist": "DreamKiller"], ["index": 0, "title": "Soul", "artist": "DreamKiller"]],
        ]
        let suggestion = try ClaudeTagFixer.parse(input, current: current)
        #expect(suggestion.albumArtist == "DreamKiller")
        #expect(suggestion.label == "Diffuse Reality Records")
        #expect(suggestion.year == 2026)
        #expect(suggestion.tracks.map(\.title) == ["Soul", "Higher"])
    }

    @Test func readsArtworkURLUpgradingBandcampSize() throws {
        let input: [String: Any] = [
            "album_artist": "DreamKiller", "album": "Erotic Motion", "label": "", "year": 2026,
            "artwork_url": "https://f4.bcbits.com/img/a1234567890_5.jpg",
            "tracks": [["index": 0, "title": "Soul", "artist": "DreamKiller", "track_number": 1]],
        ]
        let suggestion = try ClaudeTagFixer.parse(input, current: current)
        #expect(suggestion.artworkURL == URL(string: "https://f4.bcbits.com/img/a1234567890_10.jpg"))
        #expect(ClaudeTagFixer.artworkURL("https://i.discogs.com/abc/cover.jpeg") == URL(string: "https://i.discogs.com/abc/cover.jpeg"))
        #expect(ClaudeTagFixer.artworkURL("not a url") == nil)
        #expect(ClaudeTagFixer.artworkURL("file:///etc/passwd") == nil)
    }

    @Test func readsTrackNumbersKeepingCurrentWhenNull() throws {
        let input: [String: Any] = [
            "album_artist": "DreamKiller", "album": "Erotic Motion", "label": "", "year": 2026,
            "tracks": [["index": 0, "title": "Soul", "artist": "DreamKiller", "track_number": 3],
                       ["index": 1, "title": "Higher", "artist": "DreamKiller", "track_number": NSNull()]],
        ]
        let suggestion = try ClaudeTagFixer.parse(input, current: current)
        #expect(suggestion.tracks.map(\.number) == [3, 2])
    }

    @Test func tracksLeftOutKeepTheirCurrentTags() throws {
        let input: [String: Any] = [
            "album_artist": "DreamKiller", "album": "Erotic Motion", "label": "", "year": NSNull(),
            "tracks": [["index": 0, "title": "Soul", "artist": "DreamKiller"]],
        ]
        let suggestion = try ClaudeTagFixer.parse(input, current: current)
        #expect(suggestion.tracks.map(\.artist) == ["DreamKiller", "Diffuse Reality Records"])
        #expect(suggestion.year == nil)
    }

    @Test func noTracksAtAllIsNoAnswer() {
        let input: [String: Any] = ["album_artist": "A", "album": "B", "tracks": [] as [Any]]
        #expect(throws: ClaudeTagFixer.FixError.self) { try ClaudeTagFixer.parse(input, current: current) }
    }

    @Test func onlyTransientFailuresAreRetried() {
        #expect(ClaudeTagFixer.FixError.noAnswer.isRetryable)
        #expect(ClaudeTagFixer.FixError.api("Overloaded", status: 529).isRetryable)
        #expect(ClaudeTagFixer.FixError.api("Rate limited", status: 429).isRetryable)
        #expect(!ClaudeTagFixer.FixError.api("invalid x-api-key", status: 401).isRetryable)
        #expect(!ClaudeTagFixer.FixError.refused.isRetryable)
    }
}

struct FLACWriterTests {
    @Test func updatesCommentsAndKeepsEverythingElse() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixture.make(comments: ["TITLE=Soul", "ARTIST=Label", "ALBUM ARTIST=Label", "GENRE=Techno"], picture: true).write(to: url)

        try FLACTags.update(url, setting: ["ARTIST": "DreamKiller", "ALBUMARTIST": "DreamKiller"])

        let tags = try FLACTags.read(url)
        #expect(tags.title == "Soul")
        #expect(tags.artist == "DreamKiller")
        #expect(tags.albumArtist == "DreamKiller")
        #expect(tags.artwork == Data([1, 2, 3, 4]))
        let data = try Data(contentsOf: url)
        #expect(data.suffix(FLACFixture.audio.count) == FLACFixture.audio)
        #expect(String(decoding: data, as: UTF8.self).contains("GENRE=Techno"))
        #expect(!String(decoding: data, as: UTF8.self).contains("ALBUM ARTIST=Label"))
    }

    @Test func readsLabelFromEitherField() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixture.make(comments: ["TITLE=x", "ORGANIZATION=Hyperdub"]).write(to: url)
        #expect(try FLACTags.read(url).label == "Hyperdub")
        try FLACTags.update(url, setting: ["LABEL": "Warp", "ORGANIZATION": "Warp"])
        #expect(try FLACTags.read(url).label == "Warp")
    }

    @Test func replacesTheFrontCover() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixture.make(comments: ["TITLE=Soul"], picture: true).write(to: url)

        let cover = FLACTags.Picture(data: Data([9, 8, 7]), mimeType: "image/jpeg", width: 1200, height: 1200)
        try FLACTags.update(url, setting: [:], frontCover: cover)

        let tags = try FLACTags.read(url)
        #expect(tags.artwork == Data([9, 8, 7]))
        #expect(tags.title == "Soul")
        let data = try Data(contentsOf: url)
        #expect(data.suffix(FLACFixture.audio.count) == FLACFixture.audio)
        // The old cover is gone, not just shadowed.
        #expect(data.firstRange(of: Data([1, 2, 3, 4])) == nil)
    }

    @Test func addsAFrontCoverToAFileWithout() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixture.make(comments: ["TITLE=Soul"]).write(to: url)
        let cover = FLACTags.Picture(data: Data([5, 5]), mimeType: "image/png", width: 10, height: 10)
        try FLACTags.update(url, setting: ["ARTIST": "DreamKiller"], frontCover: cover)
        let tags = try FLACTags.read(url)
        #expect(tags.artwork == Data([5, 5]))
        #expect(tags.artist == "DreamKiller")
    }

    @Test func rejectsNonFLAC() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not flac".utf8).write(to: url)
        #expect(throws: FLACTags.WriteError.self) { try FLACTags.update(url, setting: ["TITLE": "x"]) }
    }
}

/// A tiny structurally valid FLAC file: STREAMINFO, comments, optional picture, fake audio.
enum FLACFixture {
    static let audio = Data("FAKE-AUDIO-FRAMES".utf8)

    static func make(comments: [String], picture: Bool = false) -> Data {
        var blocks: [(UInt8, Data)] = [(0, Data(count: 34))]
        var vorbis = MessageWriter()
        vorbis.string("test")
        vorbis.uint32(UInt32(comments.count))
        comments.forEach { vorbis.string($0) }
        blocks.append((4, vorbis.data))
        if picture {
            var body = Data()
            func be32(_ value: Int) {
                body.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
            }
            be32(3); be32(10); body.append(Data("image/jpeg".utf8)); be32(0)
            be32(1); be32(1); be32(24); be32(0); be32(4); body.append(contentsOf: [1, 2, 3, 4])
            blocks.append((6, body))
        }
        var file = Data("fLaC".utf8)
        for (index, (type, body)) in blocks.enumerated() {
            let flag: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            file.append(contentsOf: [flag | type, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
            file.append(body)
        }
        file.append(audio)
        return file
    }
}

struct BandcampStoreTests {
    @Test func readsAlbumsAndTracksAndSkipsArtists() {
        let json = """
        {"auto":{"results":[
          {"type":"a","id":477965531,"name":"Inferno","band_name":"Boards of Canada","art_id":74571247,
           "item_url_path":"https://boardsofcanada.bandcamp.com/album/inferno","img":"https://f4.bcbits.com/img/0074571247_3.jpg"},
          {"type":"t","id":12,"name":"Roygbiv","band_name":"Boards of Canada","item_url_path":"https://boardsofcanada.bandcamp.com/track/roygbiv"},
          {"type":"b","id":99,"name":"Boards of Canada","item_url_root":"https://boardsofcanada.bandcamp.com"}
        ]}}
        """
        let results = BandcampAPI.parseStoreResults(Data(json.utf8))
        #expect(results.map(\.title) == ["Inferno", "Roygbiv"])
        #expect(!results[0].isTrack)
        #expect(results[1].isTrack)
        #expect(results[0].artworkURL?.absoluteString == "https://f4.bcbits.com/img/a0074571247_2.jpg")
    }

    @Test func purchaseMatchesByIdOrReleaseURL() {
        let result = BandcampAPI.StoreResult(id: 477965531, isTrack: false, title: "Inferno", artist: "Boards of Canada",
                                             url: URL(string: "https://boardsofcanada.bandcamp.com/album/inferno")!, artworkURL: nil)
        let byId = BandcampItem(saleItemType: "a", saleItemId: 1, title: "Inferno", artist: "Boards of Canada",
                                isTrack: false, artId: nil, redownloadURL: nil, itemId: 477965531)
        let byURL = BandcampItem(saleItemType: "a", saleItemId: 2, title: "Inferno", artist: "Boards of Canada",
                                 isTrack: false, artId: nil, redownloadURL: nil,
                                 itemURL: URL(string: "https://BoardsOfCanada.bandcamp.com/album/inferno/"))
        let other = BandcampItem(saleItemType: "a", saleItemId: 3, title: "Geogaddi", artist: "Boards of Canada",
                                 isTrack: false, artId: nil, redownloadURL: nil, itemId: 1)
        #expect(BandcampClient.matches(byId, result))
        #expect(BandcampClient.matches(byURL, result))
        #expect(!BandcampClient.matches(other, result))
    }
}

struct BandcampWishlistTests {
    private func result(_ id: Int, _ title: String, _ artist: String = "Boards of Canada") -> BandcampAPI.StoreResult {
        BandcampAPI.StoreResult(id: id, isTrack: false, title: title, artist: artist,
                                url: URL(string: "https://example.bandcamp.com/album/\(id)")!, artworkURL: nil)
    }

    @Test func wishlistedReleasesComeFirst() {
        let found = [result(1, "Inferno"), result(2, "Geogaddi"), result(3, "Twoism")]
        let wishlist = [result(3, "Twoism"), result(9, "Tomorrow's Harvest"), result(7, "Unrelated", "Someone Else")]
        let ranked = BandcampClient.rank(found, query: "boards of canada", wishlist: wishlist)
        // Wishlist matches (including one the site search missed) lead, then the rest in search order.
        #expect(ranked.map(\.id) == [3, 9, 1, 2])
    }

    @Test func readsWishlistItems() {
        let json = #"{"items":[{"item_id":42,"item_type":"album","item_title":"Twoism","band_name":"Boards of Canada","item_url":"https://boardsofcanada.bandcamp.com/album/twoism","item_art_id":74571247}],"more_available":false,"last_token":"x"}"#
        let page = BandcampAPI.parseWishlistPage(Data(json.utf8))
        #expect(page.items.map(\.title) == ["Twoism"])
        #expect(page.items.first?.artworkURL?.absoluteString == "https://f4.bcbits.com/img/a0074571247_2.jpg")
        #expect(!page.moreAvailable)
    }
}

@Suite struct BandcampPriceTests {
    @Test func readsMinimumPriceAndCurrency() {
        let html = """
            <div data-band="{&quot;id&quot;:1,&quot;name&quot;:&quot;DreamKiller&quot;,&quot;currency&quot;:&quot;USD&quot;}"></div>
            <script data-tralbum="{&quot;artist&quot;:&quot;DreamKiller&quot;,&quot;current&quot;:{&quot;minimum_price&quot;:8.0,&quot;set_price&quot;:9.0}}"></script>
            """
        let info = BandcampAPI.parseRelease(html)
        #expect(info?.price == BandcampAPI.Price(amount: 8, currency: "USD"))
    }

    @Test func readsCurrencyFromSeller() {
        let html = """
            <div data-band="{&quot;id&quot;:1,&quot;name&quot;:&quot;10k&quot;}"></div>
            <script data-tralbum="{&quot;artist&quot;:&quot;Niontay&quot;,&quot;current&quot;:{&quot;minimum_price&quot;:2.0}}"></script>
            <div id="pagedata" data-pagedata-blob="{&quot;item_sellers&quot;:{&quot;3733157754&quot;:{&quot;name&quot;:&quot;10k&quot;,&quot;currency&quot;:&quot;USD&quot;}}}"></div>
            """
        #expect(BandcampAPI.parseRelease(html)?.price == BandcampAPI.Price(amount: 2, currency: "USD"))
    }

    @Test func noPriceWithoutCurrency() {
        let html = """
            <script data-tralbum="{&quot;artist&quot;:&quot;A&quot;,&quot;current&quot;:{&quot;minimum_price&quot;:0}}"></script>
            """
        #expect(BandcampAPI.parseRelease(html)?.price == nil)
    }
}

struct BandcampArtworkTests {
    @Test func padsIdsIncludingOnesPast32Bits() {
        #expect(BandcampAPI.artworkURL(992531817)?.absoluteString == "https://f4.bcbits.com/img/a0992531817_2.jpg")
        #expect(BandcampAPI.artworkURL(3024622907)?.absoluteString == "https://f4.bcbits.com/img/a3024622907_2.jpg")
    }

    @Test func repairsWrappedIdsFromOlderVersions() {
        let broken = URL(string: "https://f4.bcbits.com/img/a\(String(format: "%010d", 3024622907))_2.jpg")
        #expect(BandcampAPI.repaired(broken)?.absoluteString == "https://f4.bcbits.com/img/a3024622907_2.jpg")
        let fine = URL(string: "https://f4.bcbits.com/img/a0992531817_2.jpg")
        #expect(BandcampAPI.repaired(fine) == fine)
    }
}

struct SplitReleaseTitleTests {
    @Test func theArtistInFrontComesOff() {
        let split = BandcampAPI.songTitle("MIKE & SURF GANG - The Fall", artist: "MIKE & SURF GANG")
        #expect(split.title == "The Fall")
        #expect(split.artist == "MIKE & SURF GANG")
        #expect(BandcampAPI.songTitle("Earl Sweatshirt & SURF GANG - Don't Worry!", artist: "Earl Sweatshirt & SURF GANG").title == "Don't Worry!")
    }

    @Test func otherNamesStay() {
        #expect(BandcampAPI.songTitle("The Fall", artist: "MIKE").title == "The Fall")
        #expect(BandcampAPI.songTitle("Pressure - Dub", artist: "Burial").title == "Pressure - Dub")
        #expect(BandcampAPI.songTitle("MIKE - ", artist: "MIKE").title == "MIKE - ")
        #expect(BandcampAPI.songTitle("Archangel", artist: nil).artist == nil)
    }
}
