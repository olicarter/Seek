import Foundation
import Observation

@MainActor
@Observable
final class Transfer: Identifiable {
    enum State: Equatable {
        case connecting
        case queued(place: Int?)
        case starting
        case downloading
        case importing
        case completed
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .completed, .failed, .cancelled: false
            default: true
            }
        }

        /// Asked for and not yet started: can still be moved to another user.
        var isWaiting: Bool {
            switch self {
            case .connecting, .queued: true
            default: false
            }
        }

        var label: String {
            switch self {
            case .connecting: "Connecting…"
            case .queued(let place?): "Queued (#\(place))"
            case .queued: "Queued"
            case .starting: "Starting…"
            case .downloading: "Downloading"
            case .importing: "Adding to library…"
            case .completed: "Done"
            case .failed(let reason): reason
            case .cancelled: "Cancelled"
            }
        }
    }

    let id: UUID
    let file: RemoteFile
    var state: State = .connecting
    var size: UInt64
    var bytesReceived: UInt64 = 0
    var bytesPerSecond: Double = 0
    /// Assigned by the peer when it's ready to send.
    var token: UInt32?
    /// Where the finished file went in the library.
    var libraryPath: String?
    /// Automatic retries after the connection dropped mid-download.
    var retries = 0
    /// Fetched to play, into the stream cache rather than the library, and kept out of Downloads.
    var forStreaming = false
    /// Where in the library the file will go, reserved when the download was added, so the song
    /// can be favourited and put in playlists before it arrives.
    var plannedPath: String?
    /// When it'll be tried again by itself, after failing for a reason that may pass.
    var retryAt: Date?
    /// When the user put it in their queue, to notice one that isn't moving.
    @ObservationIgnored var queuedSince: Date?
    /// The album it was added as part of, when that's known for sure (named by Apple). Songs of
    /// one album can come from several copies whose tags spell it differently ("Copacetic" in
    /// a remaster's), so each is filed under this name instead.
    var album: AlbumKey?
    /// A library download that's also being played: it leaves a copy in the stream cache for the
    /// player before moving into the library.
    @ObservationIgnored var alsoStreaming = false
    /// A better copy of a song already in the library, meant to replace it.
    var replacesExisting = false

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var socket: Socket?

    init(file: RemoteFile, id: UUID = UUID()) {
        self.id = id
        self.file = file
        self.size = file.size
    }

    var username: String { file.username }
    var path: String { file.path }
    var progress: Double { size > 0 ? Double(bytesReceived) / Double(size) : 0 }

    /// What a progress ring shows: nothing yet while waiting, then the download, staying full
    /// while the song goes into the library rather than dropping back to empty.
    var ringProgress: Double? {
        switch state {
        case .downloading: progress
        case .importing: 1
        default: nil
        }
    }

    /// In Application Support rather than Caches, so the system doesn't clear a half-finished
    /// download before it resumes.
    var partialURL: URL {
        let directory = URL.applicationSupportDirectory.appending(path: "Partial", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(id.uuidString).\(file.fileExtension)")
    }
}

/// A transfer as saved between launches.
struct SavedTransfer: Codable {
    enum Outcome: String, Codable { case active, completed, failed, cancelled }

    var id: UUID
    var file: RemoteFile
    var outcome: Outcome
    var reason: String?
    var plannedPath: String?
    var replacesExisting: Bool?
    var album: AlbumKey?

    @MainActor
    init(_ transfer: Transfer) {
        id = transfer.id
        file = transfer.file
        album = transfer.album
        plannedPath = transfer.plannedPath
        replacesExisting = transfer.replacesExisting ? true : nil
        switch transfer.state {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        case .failed(let reason): outcome = .failed; self.reason = reason
        default: outcome = .active
        }
    }

    @MainActor
    func restore() -> Transfer {
        let transfer = Transfer(file: file, id: id)
        transfer.album = album
        transfer.plannedPath = plannedPath
        transfer.replacesExisting = replacesExisting ?? false
        switch outcome {
        case .completed: transfer.state = .completed
        case .cancelled: transfer.state = .cancelled
        case .failed: transfer.state = .failed(reason ?? "Failed")
        case .active: transfer.state = .connecting
        }
        if outcome == .completed { transfer.bytesReceived = transfer.size }
        return transfer
    }
}
