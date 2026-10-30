import Foundation
import Observation

/// What Seek's requests to Claude have used, and roughly what they cost: counted from each
/// answer's `usage`, by month, model and purpose. Each device keeps its own file in the app's
/// iCloud folder (Seek/Claude Usage/<device>.json), so no two write the same one, and Settings
/// adds them all up.
@MainActor
@Observable
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    struct Tally: Codable, Equatable, Sendable {
        var requests = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheWriteTokens = 0
        var cacheReadTokens = 0
        var webSearches = 0
        /// Estimated, in US dollars (see Price).
        var cost = 0.0

        var tokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }

        static func + (a: Tally, b: Tally) -> Tally {
            Tally(requests: a.requests + b.requests, inputTokens: a.inputTokens + b.inputTokens,
                  outputTokens: a.outputTokens + b.outputTokens, cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
                  cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens, webSearches: a.webSearches + b.webSearches,
                  cost: a.cost + b.cost)
        }
    }

    /// One device's record: by month ("2026-10"), then by purpose and by model.
    struct Record: Codable, Sendable {
        var device: String
        var months: [String: [String: Tally]] = [:]
        var models: [String: Tally] = [:]
    }

    /// Estimated prices, per million tokens, and per thousand web searches: Anthropic's console
    /// has the exact bill. Cache writes cost 1.25× input, cache reads 0.1×.
    enum Price {
        static func perMillion(_ model: String) -> (input: Double, output: Double) {
            if model.contains("opus") { return (15, 75) }
            if model.contains("sonnet") { return (3, 15) }
            return (1, 5)
        }
        static let perThousandSearches = 10.0

        static func cost(_ tally: Tally, model: String) -> Double {
            let price = perMillion(model)
            return (Double(tally.inputTokens) * price.input + Double(tally.cacheWriteTokens) * price.input * 1.25
                + Double(tally.cacheReadTokens) * price.input * 0.1 + Double(tally.outputTokens) * price.output) / 1_000_000
                + Double(tally.webSearches) * perThousandSearches / 1000
        }
    }

    /// The folder every device's file is in, set once the library knows where iCloud is.
    var folder: URL? {
        didSet { load() }
    }
    private(set) var record: Record
    /// Every device's records, this one's included (read from the folder).
    private(set) var all: [Record] = []

    private static let deviceKey = "ClaudeUsageDevice"
    private let device: String

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.deviceKey)
        device = saved ?? UUID().uuidString
        if saved == nil { UserDefaults.standard.set(device, forKey: Self.deviceKey) }
        record = Record(device: device)
    }

    private var file: URL? { folder?.appending(path: "\(device).json") }

    static func month(_ date: Date = .now) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Counts one answer (the Messages API's JSON).
    func record(_ answer: [String: Any], purpose: String) {
        guard let usage = answer["usage"] as? [String: Any] else { return }
        let model = answer["model"] as? String ?? "claude"
        let server = usage["server_tool_use"] as? [String: Any]
        var tally = Tally(requests: 1, inputTokens: usage["input_tokens"] as? Int ?? 0,
                          outputTokens: usage["output_tokens"] as? Int ?? 0,
                          cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                          cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                          webSearches: server?["web_search_requests"] as? Int ?? 0)
        tally.cost = Price.cost(tally, model: model)
        let month = Self.month()
        record.months[month, default: [:]][purpose] = (record.months[month]?[purpose] ?? Tally()) + tally
        record.models[model] = (record.models[model] ?? Tally()) + tally
        save()
    }

    // MARK: - Totals, across devices

    func total(month: String? = nil) -> Tally {
        all.reduce(Tally()) { sum, record in
            let months = month.map { record.months[$0].map { [$0] } ?? [] } ?? Array(record.months.values)
            return months.flatMap(\.values).reduce(sum, +)
        }
    }

    func byPurpose(month: String? = nil) -> [(purpose: String, tally: Tally)] {
        var sums: [String: Tally] = [:]
        for record in all {
            let months = month.map { record.months[$0].map { [$0] } ?? [] } ?? Array(record.months.values)
            for entry in months { for (purpose, tally) in entry { sums[purpose] = (sums[purpose] ?? Tally()) + tally } }
        }
        return sums.map { ($0.key, $0.value) }.sorted { $0.tally.cost > $1.tally.cost }
    }

    var byModel: [(model: String, tally: Tally)] {
        var sums: [String: Tally] = [:]
        for record in all { for (model, tally) in record.models { sums[model] = (sums[model] ?? Tally()) + tally } }
        return sums.map { ($0.key, $0.value) }.sorted { $0.tally.cost > $1.tally.cost }
    }

    // MARK: - Files

    /// Reads every device's file again (other devices' may have changed).
    func load() {
        guard let folder else { all = [record]; return }
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var records: [Record] = []
        for url in files where url.pathExtension == "json" || url.lastPathComponent.hasSuffix(".json.icloud") {
            if url.lastPathComponent.hasPrefix(".") {
                // Not downloaded yet: asked for, and read next time.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url), let read = try? decoder.decode(Record.self, from: data) else { continue }
            if read.device == device {
                // Kept on disk from before this launch: carried on from.
                if record.months.isEmpty, record.models.isEmpty { record = read }
            } else {
                records.append(read)
            }
        }
        all = records + [record]
    }

    private func save() {
        all = all.filter { $0.device != device } + [record]
        guard let folder, let file, let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
