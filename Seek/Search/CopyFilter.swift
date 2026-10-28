import Foundation

/// Which Soulseek copies to show first: the ones at the preferred quality that can be downloaded
/// right now (a free slot). The rest stay a tap away.
enum CopyFilter {
    static func meetsTarget(_ folder: RemoteFolder, quality: QualityPreference) -> Bool {
        quality == .cd ? folder.isLossless && !folder.isHiRes : folder.isLossless
    }

    /// Has (nearly) all the album: at least 80% of its songs, allowing for a bonus track missing
    /// or a stray extra. Some users share a single song in a folder named for the album.
    static func isComplete(_ folder: RemoteFolder, expectedTracks: Int?) -> Bool {
        guard let expectedTracks, expectedTracks > 1 else { return true }
        return folder.files.count * 5 >= expectedTracks * 4
    }

    /// One song isn't a copy of a release with several, however it's named: it's the single
    /// of the same name (a 2-song EP's title track on its own), or one song shared alone.
    static func isCopy(_ folder: RemoteFolder, expectedTracks: Int?) -> Bool {
        guard let expectedTracks, expectedTracks > 1 else { return true }
        return folder.files.count > 1
    }

    /// The preferred copies, or nil when none qualify (then everything is shown).
    static func preferred(_ folders: [RemoteFolder], quality: QualityPreference, expectedTracks: Int? = nil) -> [RemoteFolder]? {
        let good = folders.filter {
            $0.hasFreeSlot && meetsTarget($0, quality: quality) && isComplete($0, expectedTracks: expectedTracks)
        }
        return good.isEmpty ? nil : good
    }
}
