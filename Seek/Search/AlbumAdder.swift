import Foundation
import Observation

/// Adds an album from Soulseek. With its tracklist known (Apple's or Bandcamp's), that's
/// exactly the songs on it: each from the best copy that has it (one copy when one has them
/// all), never a copy's bonus tracks or other editions' extras, and nothing at all when some
/// song isn't in any copy. Without a tracklist, the best copy whole.
@MainActor
@Observable
final class AlbumAdder {
    /// Albums whose tracklist and copies' full folders are being checked, by `AlbumReferences.key`.
    private(set) var checking: Set<String> = []
    /// The last album with a song no copy had: nothing was added.
    var failure: (album: AlbumKey, songs: Int)?

    /// Copies whose full folders are fetched at once while looking for every song.
    static let checkedAtOnce = 6

    func isChecking(_ album: AlbumKey) -> Bool { checking.contains(AlbumReferences.key(album)) }

    /// `folders`: the album's copies, best first.
    func add(_ album: AlbumKey, from folders: [RemoteFolder], client: SoulseekClient, references: AlbumReferences) {
        let key = AlbumReferences.key(album)
        guard !folders.isEmpty, checking.insert(key).inserted else { return }
        Task {
            defer { checking.remove(key) }
            guard let reference = await references.reference(for: album), !reference.tracks.isEmpty else {
                client.download(folders[0])
                return
            }
            guard let picks = await songs(of: reference, in: folders, client: client) else {
                failure = (album, reference.tracks.count)
                return
            }
            // Filed under the tracklist's name, whatever each copy's tags call it.
            let listed = AlbumKey(artist: reference.artist, title: CatalogRelease.cleanTitle(reference.title))
            for (folder, songs) in picks {
                client.download(songs, in: folder, album: listed, others: folders)
            }
        }
    }

    /// Every song, by copies' full folders: a search lists only the files that matched, so
    /// folders are fetched, a few at a time, until every song has turned up.
    private func songs(of reference: AlbumReference, in folders: [RemoteFolder],
                       client: SoulseekClient) async -> [(RemoteFolder, [RemoteFile])]? {
        var checked = 0
        while checked < folders.count {
            let batch = folders[checked..<min(checked + Self.checkedAtOnce, folders.count)]
            checked += batch.count
            await withTaskGroup(of: Void.self) { group in
                for folder in batch where client.folderContents[folder.id] == nil {
                    group.addTask { _ = try? await client.contents(of: folder) }
                }
            }
            if let picks = Self.songs(of: reference, in: folders.prefix(checked).map(client.complete)) { return picks }
        }
        return nil
    }

    /// Each song on the tracklist with the copy it comes from, grouped by copy, or nil when a
    /// song is in none of them. One copy with them all is taken whole (minus its extras);
    /// otherwise each song comes from the best copy that has it.
    nonisolated static func songs(of reference: AlbumReference, in folders: [RemoteFolder]) -> [(RemoteFolder, [RemoteFile])]? {
        for folder in folders {
            if let songs = files(for: reference, in: [folder]) { return [(folder, songs)] }
        }
        guard let songs = files(for: reference, in: folders) else { return nil }
        return folders.compactMap { folder in
            let own = songs.filter { $0.username == folder.username && $0.folder == folder.path }
            return own.isEmpty ? nil : (folder, own)
        }
    }

    /// Each song's file from the first of the copies that has it, or nil if any is missing.
    /// Two songs can't share a file.
    private nonisolated static func files(for reference: AlbumReference, in folders: [RemoteFolder]) -> [RemoteFile]? {
        var songs: [RemoteFile] = []
        for track in reference.tracks {
            let file = folders.lazy.compactMap { folder in
                MissingTracks.file(for: track, in: folder.files.filter { file in !songs.contains { $0.id == file.id } })
            }.first
            guard let file else { return nil }
            songs.append(file)
        }
        return songs
    }
}
