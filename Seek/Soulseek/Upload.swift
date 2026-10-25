import Foundation
import Observation

/// A file being sent to another user.
@MainActor
@Observable
final class Upload: Identifiable {
    enum State: Equatable {
        case queued
        case preparing
        case sending
        case completed
        case failed(String)

        var isActive: Bool { self == .queued || self == .preparing || self == .sending }

        var label: String {
            switch self {
            case .queued: "Queued"
            case .preparing: "Starting…"
            case .sending: "Sending"
            case .completed: "Sent"
            case .failed(let reason): reason
            }
        }
    }

    let id = UUID()
    let username: String
    let file: SharedFile
    var state = State.queued
    var bytesSent: UInt64 = 0

    init(username: String, file: SharedFile) {
        self.username = username
        self.file = file
    }

    var progress: Double { file.size > 0 ? Double(bytesSent) / Double(file.size) : 0 }
}
