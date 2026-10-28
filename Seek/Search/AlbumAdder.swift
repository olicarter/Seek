import SwiftUI

/// Adds an album from Soulseek. With its tracklist known, that's one copy that has every song
/// on it, and only those songs: a copy's bonus tracks and other editions' extras stay behind,
/// and a copy missing any song isn't used. Without a tracklist, the best copy whole.
@MainActor
@Observable
final class AlbumAdder {
    /// Albums whose tracklist and copies' full folders are being checked, by `AlbumReferences.key`.
    private(set) var checking: Set<String> = []
    /// The last album with no copy holding every song: nothing was added.
    var failure: (album: AlbumKey, songs: Int)?

    /// Copies whose full folders are fetched at once to find one with every song.
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
            if let (folder, songs) = await fullCopy(of: reference, in: folders, client: client) {
                // Filed under the tracklist's name, whatever the copy's tags call it.
                let listed = AlbumKey(artist: reference.artist, title: CatalogRelease.cleanTitle(reference.title))
                client.download(songs, in: folder, album: listed, others: folders)
            } else {
                failure = (album, reference.tracks.count)
            }
        }
    }

    /// The best copy with every song, by its full folder: a search lists only the files that
    /// matched, so copies' folders are fetched, a few at a time, until one has them all.
    private func fullCopy(of reference: AlbumReference, in folders: [RemoteFolder],
                          client: SoulseekClient) async -> (RemoteFolder, [RemoteFile])? {
        var remaining = folders[...]
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(Self.checkedAtOnce))
            remaining = remaining.dropFirst(batch.count)
            await withTaskGroup(of: Void.self) { group in
                for folder in batch where client.folderContents[folder.id] == nil {
                    group.addTask { _ = try? await client.contents(of: folder) }
                }
            }
            if let found = Self.fullCopy(of: reference, in: batch.map(client.complete)) { return found }
        }
        return nil
    }

    /// The first copy with a file for every song on the tracklist, with just those files.
    nonisolated static func fullCopy(of reference: AlbumReference, in folders: [RemoteFolder]) -> (RemoteFolder, [RemoteFile])? {
        for folder in folders {
            if let songs = songs(of: reference, in: folder) { return (folder, songs) }
        }
        return nil
    }

    /// Each song's file in the copy, or nil if any is missing. Two songs can't share a file.
    nonisolated static func songs(of reference: AlbumReference, in folder: RemoteFolder) -> [RemoteFile]? {
        var songs: [RemoteFile] = []
        for track in reference.tracks {
            guard let file = MissingTracks.file(for: track, in: folder.files),
                  !songs.contains(where: { $0.id == file.id }) else { return nil }
            songs.append(file)
        }
        return songs
    }
}

extension View {
    /// Says when an album wasn't added because no copy had every song. On the root view, and
    /// on sheets that can add albums, since an alert can't show from beneath a sheet.
    func albumAddFailureAlert() -> some View { modifier(AlbumAddFailureAlert()) }
}

private struct AlbumAddFailureAlert: ViewModifier {
    @Environment(AlbumAdder.self) private var adder

    func body(content: Content) -> some View {
        content.alert(
            "No Complete Copy",
            isPresented: Binding(get: { adder.failure != nil }, set: { if !$0 { adder.failure = nil } })
        ) {
            Button("OK") {}
        } message: {
            if let failure = adder.failure {
                Text("No copy of “\(failure.album.title)” on Soulseek has all \(failure.songs) songs, so nothing was added.")
            }
        }
    }
}
