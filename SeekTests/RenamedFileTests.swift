import Foundation
import SwiftData
import Testing
@testable import Seek

/// A song whose file another device renamed for what it holds (an MP3 named .flac) stays the
/// same song: its details, favourite and playlists, not a new one named after its file.
@MainActor
struct RenamedFileTests {
    let container: ModelContainer
    let library: LibraryStore
    let folder = URL.temporaryDirectory.appending(path: "renamed-\(UUID().uuidString)")

    init() throws {
        container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        library = LibraryStore(container: container)
    }

    @Test func aRenamedFileKeepsItsSong() throws {
        let album = folder.appending(path: "Lemtom/Fair Dinkum (2023)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let old = album.appending(path: "Lemtom - Fair Dinkum - 01 - Volitant.flac")
        try Data("not really audio".utf8).write(to: old)
        library.start(folder: folder)
        let track = try #require(library.allTracks.first)
        track.title = "Volitant"
        track.trackNumber = 1
        library.toggleFavorite(path: track.path)

        try FileManager.default.moveItem(at: old, to: album.appending(path: "Lemtom - Fair Dinkum - 01 - Volitant.mp3"))
        library.rescan()

        let tracks = try container.mainContext.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks.first?.path == "Lemtom/Fair Dinkum (2023)/Lemtom - Fair Dinkum - 01 - Volitant.mp3")
        #expect(tracks.first?.title == "Volitant")
        #expect(tracks.first?.trackNumber == 1)
        #expect(library.isFavorite(path: "Lemtom/Fair Dinkum (2023)/Lemtom - Fair Dinkum - 01 - Volitant.mp3"))
    }
}

/// A download that's an MP3 named .flac comes into the library as .mp3.
@MainActor
struct DisguisedImportTests {
    @Test func anMP3NamedFLACIsImportedAsMP3() async throws {
        let container = try ModelContainer(for: Track.self, TrackInfo.self, Playlist.self, Favorite.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let library = LibraryStore(container: container)
        library.useFolder(URL.temporaryDirectory.appending(path: "disguised-\(UUID().uuidString)"))
        let fixture = try #require(Bundle(for: BundleMarker.self).url(forResource: "mp3-named-flac", withExtension: "flac"))
        let source = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        try FileManager.default.copyItem(at: fixture, to: source)
        let path = try await library.importDownload(at: source, remotePath: "@@x\\Lemtom-Fair_Dinkum\\01-lemtom-volitant_(original_mix).flac",
                                                    plannedPath: library.reservePath(forRemotePath: "@@x\\Lemtom-Fair_Dinkum\\01-lemtom-volitant_(original_mix).flac"))
        #expect(path.hasSuffix(".mp3"))
    }
}

private final class BundleMarker {}

@MainActor
struct MisnamedTests {
    @Test func formatAndExtensionDisagreeing() {
        let mp3 = Track(path: "a/01 Song.flac")
        mp3.codec = "MP3"
        #expect(LibraryStore.isMisnamed(mp3))
        let flac = Track(path: "a/01 Song.flac")
        flac.codec = "FLAC"
        #expect(!LibraryStore.isMisnamed(flac))
        let aac = Track(path: "a/01 Song.m4a")
        aac.codec = "AAC"
        #expect(!LibraryStore.isMisnamed(aac))
        let unread = Track(path: "a/01 Song.flac")
        #expect(!LibraryStore.isMisnamed(unread))
    }
}
