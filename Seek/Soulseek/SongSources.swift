import Foundation

/// Where a song being downloaded could come from, and how each user went: shown in Activity, so
/// a song waiting on one user isn't a black box ("4 copies · asked 2 · 1 failed").
struct SongSources: Codable, Sendable, Equatable {
    /// Users found with a copy: the one it was added from, the album's other copies, and those a
    /// search for another copy turned up.
    var found: Set<String> = []
    /// Users it's been asked from.
    var asked: Set<String> = []
    /// Users it didn't come from, and why ("File not shared.", "Left after 6 minutes in the queue").
    var failed: [String: String] = [:]

    /// Copies not asked yet.
    var untried: Int { found.subtracting(asked).count }
}

extension SoulseekClient {
    /// The song a download is for, the same when it moves to another copy: where it's going in
    /// the library, otherwise its album (or folder) and name.
    static func songKey(_ transfer: Transfer) -> String {
        if let path = transfer.plannedPath { return path }
        let song = ReleaseText.fold(ReleaseText.trackName(transfer.file.name))
        if let album = transfer.album { return "\(AlbumIdentity.releaseKey(album))|\(song)" }
        return "\(transfer.username)\u{0}\(transfer.file.folder)|\(song)"
    }
}
