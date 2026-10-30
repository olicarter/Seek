import Foundation
import Observation

/// Asks Claude Haiku what's in Soulseek folders Seek couldn't read confidently from their names,
/// like "Music\Love Is Land" or "2025 stuff". Only those folders are sent, in one batch per search,
/// and every answer is kept, so a folder is never asked about twice.
@MainActor
@Observable
final class FolderResolver {
    private(set) var hints: [String: FolderHint] = [:]
    private(set) var isResolving = false
    @ObservationIgnored private var asked: Set<String> = []

    private static var cacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "folder-hints.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let saved = try? JSONDecoder().decode([String: FolderHint].self, from: data) {
            hints = saved
        }
    }

    /// Sends the unsure folders not yet asked about. Does nothing without a Claude key.
    func resolve(_ folders: [RemoteFolder], releases: [SearchRelease]) {
        let pending = folders.filter { hints[$0.id] == nil && !asked.contains($0.id) }.prefix(30)
        guard !pending.isEmpty, !isResolving, let apiKey = ClaudeTagFixer.apiKey else { return }
        pending.forEach { asked.insert($0.id) }
        isResolving = true
        let batch = Array(pending)
        let known = releases.filter { $0.owned != nil || $0.store != nil }.prefix(30).map { "\($0.artist) – \($0.title)" }
        Task {
            defer { isResolving = false }
            do {
                let answers = try await Self.ask(batch, known: Array(known), apiKey: apiKey)
                for (index, hint) in answers where batch.indices.contains(index) {
                    hints[batch[index].id] = hint
                }
                save()
            } catch {
                Log.debug("folder resolver failed: \(error)")
            }
        }
    }

    private func save() {
        // Keep the file small.
        let trimmed = hints.count > 3000 ? Dictionary(uniqueKeysWithValues: hints.suffix(2000).map { ($0.key, $0.value) }) : hints
        try? JSONEncoder().encode(trimmed).write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Claude

    static let system = """
        You identify music releases from Soulseek shares. For each folder, given its path and some of its file \
        names, say whether it holds one release (album, EP or single) or a mix of unrelated songs (a playlist, \
        "singles" or genre folder). For a release, give its artist and title as officially named, without format, \
        year or source tags; use a known release's exact spelling when it's the same one. Year if it's clear. \
        Finish by calling submit_folders once.
        """

    static let tool: [String: Any] = [
        "name": "submit_folders",
        "strict": true,
        "description": "One entry per folder, by index.",
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["folders"],
            "properties": [
                "folders": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["index", "kind", "artist", "title", "year"],
                        "properties": [
                            "index": ["type": "integer"],
                            "kind": ["type": "string", "enum": ["release", "mixed"]],
                            "artist": ["anyOf": [["type": "string"], ["type": "null"]]],
                            "title": ["anyOf": [["type": "string"], ["type": "null"]]],
                            "year": ["anyOf": [["type": "integer"], ["type": "null"]]],
                        ],
                    ],
                ],
            ],
        ],
    ]

    static func prompt(_ folders: [RemoteFolder], known: [String]) -> String {
        var lines = ["Known releases: " + (known.isEmpty ? "none" : known.joined(separator: "; ")), "", "Folders:"]
        for (index, folder) in folders.enumerated() {
            let files = folder.files.prefix(8).map(\.name).joined(separator: " | ")
            lines.append("\(index). \(folder.path.replacingOccurrences(of: "\\", with: "/")) — \(files)")
        }
        return lines.joined(separator: "\n")
    }

    private static func ask(_ folders: [RemoteFolder], known: [String], apiKey: String) async throws -> [(Int, FolderHint)] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ClaudeTagFixer.Model.haiku.rawValue,
            "max_tokens": 4000,
            "system": system,
            "tools": [tool],
            // No web tools: this needs to be quick, and the names are usually enough.
            "tool_choice": ["type": "tool", "name": "submit_folders"],
            "messages": [["role": "user", "content": prompt(folders, known: known)]],
        ] as [String: Any])
        var response: [String: Any]
        do {
            response = try await ClaudeTagFixer.response(to: request, purpose: "Reading folder names")
        } catch let error as ClaudeTagFixer.FixError where error.isRetryable {
            response = try await ClaudeTagFixer.response(to: request, purpose: "Reading folder names")
        }
        let content = response["content"] as? [[String: Any]] ?? []
        guard let input = content.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
            throw ClaudeTagFixer.FixError.noAnswer
        }
        return parse(input)
    }

    static func parse(_ input: [String: Any]) -> [(Int, FolderHint)] {
        (input["folders"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let index = raw["index"] as? Int,
                  let kind = (raw["kind"] as? String).flatMap(FolderHint.Kind.init(rawValue:)) else { return nil }
            let text = { (key: String) in (raw[key] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            if kind == .release, text("title") == nil { return nil }
            return (index, FolderHint(kind: kind, artist: text("artist"), title: text("title"), year: raw["year"] as? Int))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
