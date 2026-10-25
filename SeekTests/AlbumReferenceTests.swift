import Foundation
import SwiftData
import Testing
@testable import Seek

@MainActor
struct AlbumReferenceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Discovery.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func track(_ title: String, number: Int) -> Track {
        let track = Track(path: "Cryogeyser/Glitch/\(number) \(title).mp3")
        track.title = title
        track.trackNumber = number
        context.insert(track)
        return track
    }

    private let reference = AlbumReference(source: .bandcamp, artist: "Cryogeyser", title: "Glitch", tracks: [
        ReferenceTrack(number: 1, disc: 1, title: "Marie", duration: 161),
        ReferenceTrack(number: 2, disc: 1, title: "Focus", duration: 125),
        ReferenceTrack(number: 3, disc: 1, title: "Private Part", duration: 142),
    ])

    @Test func spotsMissingTracksByTitle() {
        let have = [track("Marie", number: 1), track("private part [FLAC]", number: 3)]
        #expect(MissingTracks.missing(from: reference, have: have).map(\.title) == ["Focus"])
    }

    @Test func findsTheFileForATrack() {
        let files = ["01 - Cryogeyser - Marie.flac", "02 Focus.flac", "03. Private Part.flac"].map {
            RemoteFile(username: "u", path: "Glitch\\\($0)", size: 1)
        }
        #expect(MissingTracks.file(for: reference.tracks[1], in: files)?.name == "02 Focus.flac")
        #expect(MissingTracks.file(for: reference.tracks[0], in: files)?.name == "01 - Cryogeyser - Marie.flac")
        #expect(MissingTracks.file(for: ReferenceTrack(number: 9, disc: 1, title: "Leach"), in: files) == nil)
    }

    @Test func readsITunesTracklists() {
        let tracks = AlbumReferences.parseITunesTracks([
            ["wrapperType": "collection", "collectionName": "Souvlaki"],
            ["wrapperType": "track", "trackName": "Machine Gun", "trackNumber": 2, "discNumber": 1, "trackTimeMillis": 268680.0],
            ["wrapperType": "track", "trackName": "Alison", "trackNumber": 1, "discNumber": 1, "trackTimeMillis": 232733.0],
        ])
        #expect(tracks.map(\.title) == ["Alison", "Machine Gun"])
        #expect(tracks.first?.duration == 232.733)
    }

    @Test func readsBandcampTracklists() {
        let html = """
            <script data-tralbum="{&quot;artist&quot;:&quot;Cryogeyser&quot;,&quot;trackinfo&quot;:[{&quot;track_num&quot;:1,&quot;title&quot;:&quot;Marie&quot;,&quot;duration&quot;:161.4},{&quot;track_num&quot;:2,&quot;title&quot;:&quot;Focus&quot;,&quot;duration&quot;:125.4}]}"></script>
            """
        let info = BandcampAPI.parseRelease(html)
        #expect(info?.tracks.map(\.title) == ["Marie", "Focus"])
        #expect(info?.tracks.last?.number == 2)
    }

    @Test func upgradesReplaceMatchingTracks() {
        let library = LibraryStore(container: container)
        let old = [track("Marie", number: 1), track("Bonus", number: 9)]
        let new = Track(path: "Cryogeyser/Glitch/01 Marie.flac")
        new.title = "Marie"
        new.trackNumber = 1
        context.insert(new)
        let result = library.replace(old.map(\.path), with: [new.path])
        #expect(result.replaced == 1)
        #expect(result.kept == 1)
    }

    @Test func featuredArtistTitlesAndBandcampPurchasesArentMissing() {
        let titled = AlbumReference(source: .bandcamp, artist: "Niontay", title: "Dontay's Inferno", tracks: [
            ReferenceTrack(number: 5, disc: 1, title: "Niontay featuring DORIS - 10/4", duration: 162),
            ReferenceTrack(number: 6, disc: 1, title: "Something Else Entirely", duration: 142),
        ])
        let ten = track("10/4", number: 5)
        let six = track("WHEREDEYAT???", number: 6)
        six.duration = 142.4
        #expect(MissingTracks.missing(from: titled, have: [ten, six]).isEmpty)
        let gone = AlbumReference(source: .bandcamp, artist: "Niontay", title: "x", tracks: [ReferenceTrack(number: 9, disc: 1, title: "Bonus")])
        ten.sourceURL = "https://niontay.bandcamp.com/album/dontays-inferno"
        six.sourceURL = ten.sourceURL
        #expect(MissingTracks.missing(from: gone, have: [ten, six]).isEmpty)
    }

    @Test func readsFLACStreamInfo() {
        // 44.1 kHz, 2 channels, 16-bit: sample rate 0x0AC44 in 20 bits, then 001 (channels - 1), then 01111 (bits - 1).
        var block = Data(count: 34)
        block[10] = 0x0A; block[11] = 0xC4; block[12] = 0x42; block[13] = 0xF0
        var tags = FLACTags.Tags()
        FLACTags.parseStreamInfo(block, into: &tags)
        #expect(tags.sampleRate == 44100)
        #expect(tags.bitDepth == 16)
    }

    @Test func describesQuality() {
        let flac = track("Marie", number: 1)
        flac.codec = "FLAC"; flac.bitDepth = 24; flac.sampleRate = 96000
        #expect(AudioQuality(flac).label == "FLAC 24-bit/96 kHz")
        #expect(AudioQuality(flac).isHiRes)
        let mp3 = track("Focus", number: 2)
        mp3.codec = "MP3"; mp3.bitrate = 319
        #expect(AudioQuality(mp3).label == "MP3 320 kbps")
        #expect(AudioQuality.summary(of: [flac, mp3]) == "Mixed: FLAC, MP3")
        #expect(!AlbumDetailView.isLossless([flac, mp3]))
        #expect(AlbumDetailView.isLossless([flac]))
    }

    @Test func prefersTheStandardEdition() {
        let editions: [[String: Any]] = [
            ["collectionName": "Souvlaki (Deluxe)", "trackCount": 30],
            ["collectionName": "Souvlaki", "trackCount": 10],
            ["collectionName": "Souvlaki (Remastered)", "trackCount": 12],
        ]
        #expect(AlbumReferences.standardEdition(editions, atLeast: 1)?["trackCount"] as? Int == 10)
        #expect(AlbumReferences.standardEdition(editions, atLeast: 11)?["trackCount"] as? Int == 12)
        #expect(AlbumReferences.standardEdition(editions, atLeast: 40)?["trackCount"] as? Int == 30)
    }

    @Test func prefersTheAlbumOverAnEPOfTheSameName() {
        // As iTunes lists them.
        let editions: [[String: Any]] = [
            ["collectionName": "From Under the Cork Tree", "trackCount": 13],
            ["collectionName": "From Under the Cork Tree (Limited \"Black Clouds and Underdogs\" Edition) - EP", "trackCount": 8],
            ["collectionName": "From Under The Cork Tree (20th Anniversary Deluxe)", "trackCount": 31],
        ]
        let title = "From Under the Cork Tree"
        #expect(AlbumReferences.bestEdition(editions, title: title, atLeast: 0)?["trackCount"] as? Int == 13)
        #expect(AlbumReferences.bestEdition(editions, title: title, atLeast: 13)?["trackCount"] as? Int == 13)
        #expect(AlbumReferences.bestEdition(editions, title: title, atLeast: 20)?["trackCount"] as? Int == 31)
        // Only an EP by that name: it's what there is.
        #expect(AlbumReferences.bestEdition(Array(editions[1...1]), title: title, atLeast: 0)?["trackCount"] as? Int == 8)
    }

    @Test func bonusDiscsArentMissingUntilYouHaveSome() {
        let reference = AlbumReference(source: .itunes, artist: "Slowdive", title: "Souvlaki", tracks: [
            ReferenceTrack(number: 1, disc: 1, title: "Alison"),
            ReferenceTrack(number: 2, disc: 1, title: "Machine Gun"),
            ReferenceTrack(number: 1, disc: 2, title: "Some Velvet Morning"),
        ])
        #expect(MissingTracks.missing(from: reference, have: [track("Alison", number: 1)]).map(\.title) == ["Machine Gun"])
    }

    @Test func matchesFilesIgnoringBracketsOrByNumberAndLength() {
        let files = [
            RemoteFile(username: "u", path: "Closer\\20 - The Eternal (Live).flac", size: 1, duration: 390),
            RemoteFile(username: "u", path: "Closer\\21 - Digital (Encore).flac", size: 1, duration: 194),
            RemoteFile(username: "u", path: "Closer\\22 Untitled.flac", size: 1, duration: 300),
        ]
        let eternal = ReferenceTrack(number: 20, disc: 1, title: "The Eternal (Live) [Encore]", duration: 390)
        #expect(MissingTracks.file(for: eternal, in: files)?.name == "20 - The Eternal (Live).flac")
        let digital = ReferenceTrack(number: 21, disc: 1, title: "Digital (Live) [Encore]", duration: 194)
        #expect(MissingTracks.file(for: digital, in: files)?.name == "21 - Digital (Encore).flac")
        let byNumber = ReferenceTrack(number: 22, disc: 1, title: "Something Else", duration: 301)
        #expect(MissingTracks.file(for: byNumber, in: files)?.name == "22 Untitled.flac")
        let wrongLength = ReferenceTrack(number: 22, disc: 1, title: "Something Else", duration: 200)
        #expect(MissingTracks.file(for: wrongLength, in: files) == nil)
    }
}
