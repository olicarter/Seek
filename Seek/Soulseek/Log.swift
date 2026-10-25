import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "dev.olicarter.seek", category: "soulseek")

    /// Goes to the unified log and to stdout, so `devicectl … launch --console` shows it.
    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        print("[seek] \(message)")
    }
}

/// A short record of Soulseek connection drops and retries, kept on the device so the cause of
/// an intermittent problem can be read afterwards (Application Support/soulseek-events.log).
enum SoulseekEvents {
    static var url: URL { URL.applicationSupportDirectory.appending(path: "soulseek-events.log") }

    static func record(_ message: String) {
        Log.debug("event: \(message)")
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(line.trimmingCharacters(in: .newlines))
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? lines.suffix(500).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

