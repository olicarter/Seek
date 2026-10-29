import Foundation
import SwiftData

/// One row of an album page: a song in the library, one on the tracklist that isn't, or one
/// downloading that has no row of its own.
enum AlbumRow: Identifiable {
    case have(Int, Track)
    case missing(ReferenceTrack)
    /// A song on its way that the tracklist doesn't list (a bonus track, or no tracklist).
    case arriving(Transfer)

    var id: String {
        switch self {
        case .have(_, let track): "have-\(track.persistentModelID.hashValue)"
        case .missing(let track): "missing-\(track.disc)-\(track.number)-\(track.title)"
        case .arriving(let transfer): "arriving-\(transfer.id)"
        }
    }

    var order: (Int, Int) {
        switch self {
        case .have(_, let track): (max(track.discNumber, 1), track.trackNumber > 0 ? track.trackNumber : 999)
        case .missing(let track): (max(track.disc, 1), track.number > 0 ? track.number : 999)
        case .arriving(let transfer): (1, ReleaseText.songNumber(transfer.file.name) ?? 999)
        }
    }
}

/// How an album page lists its songs, for the app's album page and the server's alike.
@MainActor
enum AlbumRows {
    /// The album's songs with the ones it's missing, and ones still downloading, slotted in by
    /// track number.
    static func rows(_ album: Album, missing: [ReferenceTrack], arriving: [Transfer] = []) -> [AlbumRow] {
        let have = album.tracks.enumerated().map { AlbumRow.have($0.offset, $0.element) }
        let gaps = missing.map(AlbumRow.missing)
        return (have + gaps + arriving.map(AlbumRow.arriving)).enumerated().sorted { a, b in
            a.element.order == b.element.order ? a.offset < b.offset : a.element.order < b.element.order
        }.map(\.element)
    }

    /// Downloads going now for songs that have no row yet: not a gap in the tracklist (those show
    /// their own progress) and not already in the library.
    static func arriving(_ album: Album, missing: [ReferenceTrack], client: SoulseekClient) -> [Transfer] {
        let downloads = downloads(for: album, client: client)
        let claimed = Set(missing.compactMap { MissingTracks.download(for: $0, in: downloads)?.id })
            .union(replacing(album, client: client).values.map(\.id))
        let paths = Set(album.tracks.map(\.path))
        return downloads.filter {
            client.isOnItsWay($0) && !claimed.contains($0.id) && !($0.plannedPath.map(paths.contains) ?? false)
        }
    }

    /// Downloads on their way to replace songs already here (a better copy, see CopyFinder.upgrade),
    /// by the song each replaces: they show on its row, not as songs of their own named after
    /// their files.
    static func replacing(_ album: Album, client: SoulseekClient) -> [PersistentIdentifier: Transfer] {
        let paths = Set(album.tracks.map(\.path))
        var going = downloads(for: album, client: client).filter {
            client.isOnItsWay($0) && !($0.plannedPath.map(paths.contains) ?? false)
        }
        var result: [PersistentIdentifier: Transfer] = [:]
        for track in album.tracks where !going.isEmpty {
            let song = ReferenceTrack(number: track.trackNumber, disc: max(track.discNumber, 1), title: track.title,
                                      duration: track.duration > 0 ? track.duration : nil)
            guard let download = MissingTracks.download(for: song, in: going) else { continue }
            result[track.persistentModelID] = download
            going.removeAll { $0.id == download.id }
        }
        return result
    }

    /// This album's Soulseek downloads, from whichever copies, going or done or failed.
    static func downloads(for album: Album, client: SoulseekClient) -> [Transfer] {
        // A finished download whose song was since deleted doesn't count.
        client.transfers.filter {
            !$0.forStreaming && $0.state != .cancelled && ($0.state != .completed || client.isDone($0))
                && isFor(album, $0)
        }
    }

    /// Songs for this album still arriving from Soulseek: judge its quality once they're in.
    static func isBeingAdded(_ album: Album, client: SoulseekClient) -> Bool {
        client.transfers.contains { $0.state.isActive && !$0.forStreaming && isFor(album, $0) }
    }

    /// A download for this album: filed under it when added from its page, otherwise from a folder
    /// named for it (and not for a remaster or live recording of it).
    static func isFor(_ album: Album, _ transfer: Transfer) -> Bool {
        if let target = transfer.album { return AlbumIdentity.releaseKey(target) == AlbumIdentity.releaseKey(album.key) }
        return AlbumIdentity.folder(transfer.file.folder, holds: album.title)
    }
}
