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

@MainActor
struct RemasterFileNameTests {
    @Test func songNamesAfterArtistAndAlbum() {
        let name = "Knuckle Puck - Copacetic (Remixed-Remastered) - 02 Disdain (Remixed-Remastered).flac"
        #expect(ReleaseDetailView.trackName(name) == "Disdain (Remixed-Remastered)")
        #expect(ReleaseDetailView.trackName("Knuckle Puck - Copacetic - 02 - Disdain.flac") == "Disdain")
        #expect(ReleaseDetailView.trackName("02 - Disdain.flac") == "Disdain")
        #expect(ReleaseDetailView.trackName("Knuckle Puck - Disdain.flac") == "Disdain")
        #expect(MissingTracks.leadingNumber(name) == 2)

        let file = RemoteFile(username: "u", path: "Music\\Knuckle Puck\\\(name)", size: 1)
        let track = ReferenceTrack(number: 2, disc: 1, title: "Disdain (Remixed/Remastered)", duration: nil)
        #expect(MissingTracks.file(for: track, in: [file]) == file)
    }

    @Test func aRemasterKeepsItsOwnTracklist() {
        let original = AlbumReferences.key(AlbumKey(artist: "Knuckle Puck", title: "Copacetic"))
        #expect(AlbumReferences.key(AlbumKey(artist: "Knuckle Puck", title: "Copacetic (Remixed/Remastered)")) != original)
        #expect(AlbumReferences.key(AlbumKey(artist: "Knuckle Puck", title: "Copacetic [FLAC]")) == original)
        #expect(AlbumReferences.key(AlbumKey(artist: "Knuckle Puck", title: "Copacetic (Deluxe Edition)")) == original)
    }
}

@MainActor
struct RecordingFolderTests {
    @Test func aRemastersFolderIsntTheOriginals() {
        let remaster = "Music\\Knuckle Puck\\Copacetic (Remixed-Remastered) [2025]"
        #expect(!AlbumReferences.folder(remaster, holds: "Copacetic"))
        #expect(AlbumReferences.folder(remaster, holds: "Copacetic (Remixed/Remastered)"))
        #expect(AlbumReferences.folder("Music\\Knuckle Puck\\Copacetic (2015) [FLAC]", holds: "Copacetic"))
        #expect(!AlbumReferences.folder("Music\\Knuckle Puck\\20 20", holds: "Copacetic"))
    }
}
