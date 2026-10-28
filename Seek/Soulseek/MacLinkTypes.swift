import Foundation

/// What an iPhone or iPad and Seek on the Mac send each other while the Mac does the device's
/// Soulseek work (see MacLink and Seek/WebServer/AppAPI.swift). Soulseek's own types (folders,
/// files) go as they are; a transfer goes as what the device needs to mirror it.
enum MacLinkWire {
    /// The Mac's address and the key that lets this person's devices in, shared through iCloud
    /// Keychain: only their own devices have it (friends' don't, so they never use this Mac).
    static let keychainService = "dev.olicarter.seek.mac"

    struct Transfer: Codable, Sendable {
        var id: UUID
        var file: RemoteFile
        var state: String
        /// The failure's reason, or a queue place.
        var detail: String?
        var size: UInt64
        var bytesReceived: UInt64
        var bytesPerSecond: Double
        var album: AlbumKey?
        var addGroup: UUID?
        var plannedPath: String?
        var libraryPath: String?
        var retryAt: Date?
    }

    /// An album added as one that couldn't be (see SoulseekClient.checkAddGroups).
    struct FailedAdd: Codable, Sendable {
        var group: UUID
        var album: AlbumKey
        var songs: Int
    }

    struct Transfers: Codable, Sendable {
        var transfers: [Transfer]
        var failedAdds: [FailedAdd]
    }

    struct Search: Codable, Sendable {
        var folders: [RemoteFolder]
        var done: Bool
        /// Grouped into releases by the Mac, when the device asked it to.
        var grouped: ReleaseGrouper.Result?
    }

    struct Download: Codable, Sendable {
        var files: [RemoteFile]
        var folder: RemoteFolder
        var album: AlbumKey?
        var others: [RemoteFolder]
        var group: UUID?
    }

    /// A transfer's state as words, and back.
    static func encode(_ state: Seek.Transfer.State) -> (String, String?) {
        switch state {
        case .connecting: ("connecting", nil)
        case .queued(let place): ("queued", place.map(String.init))
        case .starting: ("starting", nil)
        case .downloading: ("downloading", nil)
        case .importing: ("importing", nil)
        case .completed: ("completed", nil)
        case .failed(let reason): ("failed", reason)
        case .cancelled: ("cancelled", nil)
        }
    }

    static func decode(_ state: String, _ detail: String?) -> Seek.Transfer.State {
        switch state {
        case "connecting": .connecting
        case "queued": .queued(place: detail.flatMap(Int.init))
        case "starting": .starting
        case "downloading": .downloading
        case "importing": .importing
        case "completed": .completed
        case "cancelled": .cancelled
        default: .failed(detail ?? "Failed on the Mac")
        }
    }
}
