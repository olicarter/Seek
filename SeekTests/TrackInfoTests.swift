import Foundation
import SwiftData
import Testing
@testable import Seek

@MainActor
struct TrackInfoSyncTests {
    let container: ModelContainer
    let library: LibraryStore
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        library = LibraryStore(container: container)
    }

    private func track(_ path: String, artist: String, read: Date?) -> Track {
        let track = Track(path: path)
        track.title = "Halftones"
        track.artist = artist
        track.hasTags = read != nil
        track.fileModified = read
        context.insert(track)
        return track
    }

    private func infos() throws -> [TrackInfo] { try context.fetch(FetchDescriptor<TrackInfo>()) }

    @Test func readTracksAreUploaded() throws {
        let read = Date(timeIntervalSince1970: 1000)
        _ = track("A/Singles/Halftones.flac", artist: "Niontay", read: read)
        _ = LibraryStore.syncInfo(in: context)
        let info = try #require(try infos().first)
        #expect(info.artist == "Niontay")
        #expect(info.changedAt == read)
    }

    @Test func unreadTracksTakeSyncedDetails() throws {
        let unread = track("A/Singles/Halftones.flac", artist: "A", read: nil)
        let info = TrackInfo(path: unread.path)
        info.artist = "Niontay"
        info.trackNumber = 1
        info.cover = Data([1, 2, 3])
        info.changedAt = .now
        context.insert(info)
        _ = LibraryStore.syncInfo(in: context)
        #expect(unread.artist == "Niontay")
        #expect(unread.trackNumber == 1)
        #expect(unread.artwork == Data([1, 2, 3]))
    }

    @Test func newerEditElsewhereWinsOverAnOlderFile() throws {
        let local = track("A/B/01 Soul.flac", artist: "Old", read: Date(timeIntervalSince1970: 1000))
        local.artwork = Data([9])
        let info = TrackInfo(path: local.path)
        info.copy(from: local)
        info.artist = "New"
        info.cover = Data([1])
        info.changedAt = Date(timeIntervalSince1970: 2000)
        context.insert(info)
        _ = LibraryStore.syncInfo(in: context)
        #expect(local.artist == "New")
        // The file's own full-size artwork stays.
        #expect(local.artwork == Data([9]))
        #expect(try infos().first?.artist == "New")
    }

    @Test func newerFileOverwritesOlderDetails() throws {
        let local = track("A/B/01 Soul.flac", artist: "Fixed", read: Date(timeIntervalSince1970: 3000))
        let info = TrackInfo(path: local.path)
        info.artist = "Old"
        info.changedAt = Date(timeIntervalSince1970: 2000)
        context.insert(info)
        _ = LibraryStore.syncInfo(in: context)
        #expect(try infos().first?.artist == "Fixed")
        #expect(local.artist == "Fixed")
    }

    @Test func duplicateDetailsKeepTheNewest() throws {
        for (artist, time) in [("Older", 1000.0), ("Newer", 2000.0)] {
            let info = TrackInfo(path: "A/B/01 Soul.flac")
            info.artist = artist
            info.changedAt = Date(timeIntervalSince1970: time)
            context.insert(info)
        }
        _ = LibraryStore.syncInfo(in: context)
        #expect(try infos().map(\.artist) == ["Newer"])
    }
}

@MainActor
struct DuplicateTests {
    let container: ModelContainer
    let library: LibraryStore
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        library = LibraryStore(container: container)
    }

    private func track(_ path: String, title: String, number: Int, added: TimeInterval = 0) -> Track {
        let track = Track(path: path)
        track.title = title
        track.trackNumber = number
        track.dateAdded = Date(timeIntervalSince1970: added)
        context.insert(track)
        return track
    }

    @Test func keepsLosslessThenOriginalCopy() {
        let mp3 = track("A/B/01 Soul.mp3", title: "Soul", number: 1)
        let flac = track("A/B/01 Soul.flac", title: "Soul", number: 1, added: 10)
        let copy = track("A/B/01 Soul (1).flac", title: "soul", number: 1)
        let other = track("A/B/02 Higher.flac", title: "Higher", number: 2)
        let groups = LibraryStore.duplicates(in: [mp3, flac, copy, other])
        #expect(groups.count == 1)
        #expect(groups.first?.keep === flac)
        #expect(Set(groups.first?.remove.map(\.path) ?? []) == [mp3.path, copy.path])
    }

    @Test func playlistsMoveToTheKeptCopy() throws {
        let flac = track("A/B/01 Soul.flac", title: "Soul", number: 1)
        let copy = track("A/B/01 Soul (1).flac", title: "Soul", number: 1)
        let playlist = Playlist(name: "Set")
        playlist.trackPaths = [copy.path, "X/Y/other.flac", flac.path]
        context.insert(playlist)

        let removed = library.removeDuplicates(in: [flac, copy])

        #expect(removed == 1)
        #expect(playlist.trackPaths == [flac.path, "X/Y/other.flac"])
        #expect(try context.fetch(FetchDescriptor<Track>()).map(\.path) == [flac.path])
    }

    @Test func deletingRemovesSongsFromPlaylists() throws {
        let keep = track("A/B/01 Soul.flac", title: "Soul", number: 1)
        let gone = [track("C/D/01 X.flac", title: "X", number: 1), track("C/D/02 Y.flac", title: "Y", number: 2)]
        let playlist = Playlist(name: "Set")
        playlist.trackPaths = [gone[0].path, keep.path, gone[1].path]
        context.insert(playlist)

        library.delete(gone)

        #expect(playlist.trackPaths == [keep.path])
        #expect(try context.fetch(FetchDescriptor<Track>()).map(\.path) == [keep.path])
    }

    @Test func purchaseReplacesMatchingTracksOnly() throws {
        let old = [track("Cryogeyser/Glitch/01 Intro.flac", title: "Intro", number: 1),
                   track("Cryogeyser/Glitch/02 Glitch.flac", title: "Glitch [FLAC]", number: 2),
                   track("Cryogeyser/Glitch/03 Hidden.flac", title: "Hidden Bonus", number: 3)]
        let page = URL(string: "https://cryogeyser.bandcamp.com/album/glitch")!
        let new = [track("Cryogeyser/Glitch/01 Intro (1).flac", title: "Intro", number: 1),
                   track("Cryogeyser/Glitch/02 Glitch (1).flac", title: "Glitch", number: 2)]
        new.forEach { $0.sourceURL = page.absoluteString + "/" }
        let playlist = Playlist(name: "Set")
        playlist.trackPaths = [old[1].path, old[2].path]
        context.insert(playlist)

        let result = library.replace(old.map(\.path), withPurchaseFrom: page)

        #expect(result.replaced == 2)
        #expect(result.kept == 1)
        #expect(playlist.trackPaths == [new[1].path, old[2].path])
        let paths = Set(try context.fetch(FetchDescriptor<Track>()).map(\.path))
        #expect(paths == Set(new.map(\.path) + [old[2].path]))
    }

    @Test func nothingIsReplacedWithoutThePurchasedFiles() throws {
        let old = [track("A/B/01 Soul.flac", title: "Soul", number: 1)]
        let result = library.replace(old.map(\.path), withPurchaseFrom: URL(string: "https://x.bandcamp.com/album/other"))
        #expect(result.replaced == 0)
        #expect(try context.fetch(FetchDescriptor<Track>()).count == 1)
    }

    @Test func favouritesToggleAndSurviveReplacementButNotDeletion() throws {
        let song = track("A/B/01 Soul.mp3", title: "Soul", number: 1)
        library.toggleFavorite(song)
        #expect(library.isFavorite(song))
        let stamped = try #require(try context.fetch(FetchDescriptor<Favorite>()).first?.favoritedAt)

        let lossless = track("A/B/01 Soul.flac", title: "Soul", number: 1)
        library.replace([song.path], with: [lossless.path])
        #expect(library.isFavorite(lossless))
        #expect(try context.fetch(FetchDescriptor<Favorite>()).first?.favoritedAt == stamped)

        library.delete([lossless])
        #expect(try context.fetch(FetchDescriptor<Favorite>()).isEmpty)
        #expect(library.favoritePaths.isEmpty)
    }

    @Test func duplicateFavouritesFromTwoDevicesKeepTheEarliest() throws {
        context.insert(Favorite(path: "A/B/x.flac", favoritedAt: Date(timeIntervalSince1970: 2000)))
        context.insert(Favorite(path: "A/B/x.flac", favoritedAt: Date(timeIntervalSince1970: 1000)))
        library.refreshFavorites()
        let left = try context.fetch(FetchDescriptor<Favorite>())
        #expect(left.map(\.favoritedAt) == [Date(timeIntervalSince1970: 1000)])
        #expect(library.favoritePaths == ["A/B/x.flac"])
    }

    @Test func savedTransfersComeBackUnfinished() throws {
        let file = RemoteFile(username: "milksop", path: "Music\\Album\\01 Song.flac", size: 1000)
        let transfer = Transfer(file: file)
        transfer.state = .downloading
        let data = try JSONEncoder().encode([SavedTransfer(transfer)])
        let restored = try JSONDecoder().decode([SavedTransfer].self, from: data).map { $0.restore() }
        #expect(restored.first?.id == transfer.id)
        #expect(restored.first?.state == .connecting)
        #expect(restored.first?.partialURL == transfer.partialURL)
    }
}

@MainActor
struct OwnedReleasesTests {
    let container: ModelContainer

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func track(artist: String, album: String, title: String, source: String = "") -> Track {
        let track = Track(path: "\(artist)/\(album)/\(title).flac")
        track.artist = artist
        track.albumArtist = artist
        track.album = album
        track.title = title
        track.sourceURL = source
        container.mainContext.insert(track)
        return track
    }

    private func item(_ title: String, by artist: String, url: String? = nil, track: Bool = false) -> BandcampItem {
        BandcampItem(saleItemType: track ? "t" : "a", saleItemId: 1, title: title, artist: artist, isTrack: track,
                     artId: nil, redownloadURL: nil, itemURL: url.flatMap(URL.init(string:)))
    }

    @Test func matchesByReleasePage() {
        let owned = OwnedReleases(tracks: [track(artist: "Someone", album: "Renamed", title: "Soul",
                                                 source: "https://diffusereality.bandcamp.com/album/erotic-motion")])
        #expect(owned.contains(item("Anything", by: "Label", url: "https://diffusereality.bandcamp.com/album/erotic-motion/")))
    }

    @Test func matchesLabelUploadsAfterTagsWereFixed() {
        let owned = OwnedReleases(tracks: [track(artist: "DreamKiller", album: "Erotic Motion", title: "Soul")])
        #expect(owned.contains(item("DreamKiller - Erotic Motion", by: "Diffuse Reality Records")))
        #expect(!owned.contains(item("DreamKiller - House Culture", by: "DreamKiller")))
        #expect(!owned.contains(item("Erotic Motion", by: "Someone Else")))
    }

    @Test func matchesSingles() {
        let owned = OwnedReleases(tracks: [track(artist: "Niontay", album: "", title: "Halftones")])
        #expect(owned.contains(item("Halftones", by: "Niontay, RealYungPhil, & SURF GANG", track: true)))
    }
}
