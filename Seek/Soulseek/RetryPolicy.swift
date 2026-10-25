import Foundation

/// When to try a failed download again by itself: after growing gaps, then not at all. Most
/// failures pass (a dropped connection, a user briefly offline); some answers won't change.
enum RetryPolicy {
    static let delays: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]

    /// How long to wait before the next try, given how many have been made; nil to give up.
    /// A queue limit ("Too many files") is waited out with the longer gaps.
    static func delay(after attempts: Int, reason: String) -> Duration? {
        guard !isPermanent(reason) else { return nil }
        let step = isQueueLimit(reason) ? max(attempts, 3) : attempts
        return step < delays.count ? delays[step] : nil
    }

    /// What a user says that asking again won't change.
    static func isPermanent(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return ["not shared", "banned", "file not", "cancelled", "disallowed extension"].contains { text.contains($0) }
    }

    static func isQueueLimit(_ reason: String) -> Bool {
        reason.lowercased().contains("too many")
    }

    static func countdown(to date: Date, now: Date = .now) -> String {
        let seconds = max(Int(date.timeIntervalSince(now).rounded()), 0)
        return seconds < 60 ? "retrying in \(seconds)s" : "retrying in \(seconds / 60) min"
    }
}
