import Foundation
import SwiftData
import Testing
@testable import Seek

@MainActor
struct ReservedPathTests {
    let container: ModelContainer
    let library: LibraryStore
    let folder = URL.temporaryDirectory.appending(path: "reserved-\(UUID().uuidString)")

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        library = LibraryStore(container: container)
        library.useFolder(folder)
    }

    private func audioFile() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try Data("not really audio".utf8).write(to: url)
        return url
    }

    private let remote = "Music\\Playboi Carti\\Whole Lotta Red\\12 Vamp Anthem.flac"

    @Test func favouriteAndPlaylistWaitForTheSongThenFindIt() async throws {
        let path = try #require(library.reservePath(forRemotePath: remote))
        #expect(path == "Playboi Carti/Whole Lotta Red/12 Vamp Anthem.flac")
        library.toggleFavorite(path: path)
        let playlist = Playlist(name: "Rage")
        playlist.trackPaths = [path]
        container.mainContext.insert(playlist)

        let imported = try await library.importDownload(at: try audioFile(), remotePath: remote, plannedPath: path)
        #expect(imported == path)
        #expect(library.isFavorite(path: imported))
        #expect(playlist.trackPaths == [imported])
    }

    @Test func twoDownloadsOfTheSameNameGetTheirOwnPaths() throws {
        let first = try #require(library.reservePath(forRemotePath: remote))
        let second = try #require(library.reservePath(forRemotePath: remote))
        #expect(first != second)
        #expect(second == "Playboi Carti/Whole Lotta Red/12 Vamp Anthem (1).flac")
    }

    @Test func aTakenPathMovesWhatWasMadeForIt() async throws {
        let path = try #require(library.reservePath(forRemotePath: remote))
        library.toggleFavorite(path: path)
        // Something else got there first.
        try FileManager.default.createDirectory(at: folder.appending(path: "Playboi Carti/Whole Lotta Red"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: path))
        let imported = try await library.importDownload(at: try audioFile(), remotePath: remote, plannedPath: path)
        #expect(imported != path)
        #expect(library.isFavorite(path: imported))
        #expect(!library.isFavorite(path: path))
    }

    /// A download left over from a first try, after the album came in from another copy.
    @Test func songAlreadyInTheFolderFromAnotherCopyIsFound() async throws {
        let other = "share\\Playboi Carti\\Whole Lotta Red\\Playboi Carti - Whole Lotta Red - 12 - Vamp Anthem.flac"
        let leftover = try #require(library.reservePath(forRemotePath: other))
        _ = try await library.importDownload(at: try audioFile(), remotePath: remote)
        #expect(library.hasSong(named: "Playboi Carti - Whole Lotta Red - 12 - Vamp Anthem.flac", besides: leftover))
        #expect(!library.hasSong(named: "13 New Tank.flac", besides: leftover))
        #expect(!library.hasSong(named: "12 Vamp Anthem.flac", besides: "Playboi Carti/Die Lit/12 Vamp Anthem.flac"))
    }

    @Test func abandoningADownloadDropsWhatWasMadeForIt() throws {
        let path = try #require(library.reservePath(forRemotePath: remote))
        library.toggleFavorite(path: path)
        let playlist = Playlist(name: "Rage")
        playlist.trackPaths = [path, "Other/Song.flac"]
        container.mainContext.insert(playlist)
        library.releaseReserved(path, abandoned: true)
        #expect(!library.isFavorite(path: path))
        #expect(playlist.trackPaths == ["Other/Song.flac"])
        #expect(!library.isReserved(path))
    }

    private final class Bundle_ {}

    @Test func songsArriveAlreadyTagged() async throws {
        let fixture = try #require(Bundle(for: Bundle_.self).url(forResource: "tone", withExtension: "flac"))
        let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let path = try await library.importFile(at: copy, folders: ["Artist", "Album"], name: "01 Tone.flac")
        let track = try #require(try container.mainContext.fetch(FetchDescriptor<Track>()).first { $0.path == path })
        // Tags read before it was added: never shown as a bare file name.
        #expect(track.hasTags)
        #expect(track.duration > 0)
    }

    @Test func songsAddedAsPartOfAnAlbumAreFiledUnderIt() async throws {
        let fixture = try #require(Bundle(for: Bundle_.self).url(forResource: "tone", withExtension: "flac"))
        let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let album = AlbumKey(artist: "Knuckle Puck", title: "Copacetic (Remixed/Remastered)")
        let path = try await library.importFile(at: copy, folders: ["Knuckle Puck", "Copacetic"], name: "02 Disdain.flac", album: album)
        let track = try #require(try container.mainContext.fetch(FetchDescriptor<Track>()).first { $0.path == path })
        #expect(track.albumKey == album)
        // Written into the file too, so other devices read the same.
        let url = try #require(library.url(forPath: path))
        let tags = await MetadataReader.read(url)
        #expect(tags.album == album.title)
        #expect(tags.albumArtist == album.artist)
    }
}
