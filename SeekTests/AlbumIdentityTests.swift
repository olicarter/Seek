import Foundation
import Testing
@testable import Seek

/// Every case met so far of names that are or aren't the same album, in one place.
struct AlbumIdentityTests {
    @Test func spellingsOfOneReleaseAreTheSame() {
        #expect(AlbumIdentity.sameRelease("I Want To Disappear", "I Want to Disappear"))
        #expect(AlbumIdentity.sameRelease("ICONICY", "Iconicy"))
        #expect(AlbumIdentity.sameRelease("Copacetic (Remixed/Remastered)", "Copacetic (Remixed / Remastered)"))
        #expect(AlbumIdentity.sameRelease("Copacetic (Remixed/Remastered)", "Copacetic (Remixed & Remastered)"))
        #expect(AlbumIdentity.sameRelease("Copacetic (Remixed/Remastered)", "Copacetic (Remixed-Remastered) [2025] [FLAC]"))
        #expect(AlbumIdentity.sameRelease("Proper Dose", "Proper Dose (2018)"))
        #expect(AlbumIdentity.releaseKey(AlbumKey(artist: "Story So Far, The {MbId-bc303c9e}", title: "Proper Dose"))
            == AlbumIdentity.releaseKey(AlbumKey(artist: "The Story So Far (CA)", title: "Proper Dose")))
    }

    @Test func otherRecordingsAreOtherAlbums() {
        #expect(!AlbumIdentity.sameRecording("Copacetic", "Copacetic (Remixed/Remastered)"))
        #expect(!AlbumIdentity.sameRecording("Black Sands", "Black Sands Remixed"))
        #expect(!AlbumIdentity.sameRecording("Love Is Land", "Love Is Land (Instrumentals)"))
        #expect(!AlbumIdentity.sameRelease("X (Live at Wembley)", "X (Live at Budokan)"))
        #expect(!ReleaseText.titlesMatch("Copacetic", "Copacetic (Remixed & Remastered)"))
        #expect(!ReleaseText.titlesMatch("Lazarus", "Lazarus (Adult Swim Original Series Soundtrack)"))
    }

    @Test func editionsShareARecordingButAreOtherReleases() {
        #expect(AlbumIdentity.sameRecording("Distance in Static", "Distance in Static (Deluxe)"))
        #expect(!AlbumIdentity.sameRelease("Distance in Static", "Distance in Static (Deluxe)"))
        #expect(AlbumIdentity.sameRecording("Souvlaki", "Souvlaki (2005 Remaster)"))
        #expect(!AlbumIdentity.sameRelease("From Under the Cork Tree", "From Under the Cork Tree (Limited \"Black Clouds and Underdogs\" Edition)"))
        #expect(!AlbumIdentity.sameRelease("Infinity on High", "Infinity on High (Platinum Edition)"))
        #expect(ReleaseText.titlesMatch("Glitch", "Glitch (Deluxe Edition)"))
        #expect(ReleaseText.titlesMatch("Souvlaki", "Souvlaki 2005 Remaster"))
    }

    @Test func wordsInsideANameArentMarkers() {
        #expect(AlbumIdentity.title("Live Through This").recording.isEmpty)
        #expect(AlbumIdentity.title("Complete Control").edition.isEmpty)
        #expect(AlbumIdentity.sameRelease("Live Through This", "Live Through This (1994)"))
        #expect(AlbumIdentity.folder("Music\\Hole\\Hole - Live Through This", holds: "Live Through This"))
    }

    @Test func foldersHoldTheirOwnRecording() {
        #expect(!AlbumIdentity.folder("Music\\Knuckle Puck\\Copacetic (Remixed-Remastered) [2025]", holds: "Copacetic"))
        #expect(AlbumIdentity.folder("Music\\Knuckle Puck\\Copacetic (Remixed-Remastered) [2025]", holds: "Copacetic (Remixed/Remastered)"))
        #expect(AlbumIdentity.folder("Music\\Knuckle Puck\\Copacetic (2015) [FLAC]", holds: "Copacetic"))
        #expect(AlbumIdentity.folder("music\\The Story So Far\\I Want to Disappear (2024)", holds: "I Want To Disappear"))
    }

    @Test func theLibraryHasWhatItHas() {
        let library = LibraryIndex(albums: [
            AlbumKey(artist: "Knuckle Puck", title: "Copacetic (Remixed/Remastered)"),
            AlbumKey(artist: "The Story So Far", title: "I Want to Disappear"),
            AlbumKey(artist: "Bonobo", title: "Distance in Static"),
        ])
        // Owning the remaster isn't owning the original, either way round.
        #expect(library.album(artist: "Knuckle Puck", title: "Copacetic", named: true) == nil)
        #expect(library.album(artist: "Knuckle Puck", title: "Copacetic", named: false) == nil)
        #expect(library.album(artist: "Knuckle Puck", title: "Copacetic (Remixed/Remastered)", named: true) != nil)
        // Artist written differently, a Soulseek folder's title.
        #expect(library.album(artist: "Story So Far, The", title: "I Want To Disappear", named: false) != nil)
        // Apple's deluxe edition isn't the standard one owned; a folder's title without its edition is.
        #expect(library.album(artist: "Bonobo", title: "Distance in Static (Deluxe)", named: true) == nil)
        #expect(library.album(artist: "Bonobo", title: "Distance in Static", named: false) != nil)
    }
}
