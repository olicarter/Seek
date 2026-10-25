import Foundation
import Observation
import SwiftData

/// A few sentences about an album, like Apple Music's, written by Claude Haiku once per album
/// and kept in the synced store (as a `Discovery` entry keyed "about:…") for every device.
@MainActor
@Observable
final class AlbumAbout {
    private(set) var loading: Set<String> = []
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var failed: Set<String> = []

    init(container: ModelContainer) {
        context = container.mainContext
    }

    static func key(_ album: AlbumKey) -> String {
        "about:" + DiscoveryService.Subject.album(artist: album.artist, title: album.title).key.dropFirst("album:".count)
    }

    func text(for album: AlbumKey) -> String? {
        let key = Self.key(album)
        var descriptor = FetchDescriptor<Discovery>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        let text = String(decoding: entry.payload, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Asks Haiku the first time an album is shown. Does nothing without a Claude key, and
    /// doesn't retry a failure until the next launch.
    func load(_ album: AlbumKey, details: String) {
        let key = Self.key(album)
        guard text(for: album) == nil, !loading.contains(key), !failed.contains(key),
              let apiKey = ClaudeTagFixer.apiKey else { return }
        loading.insert(key)
        Task {
            defer { loading.remove(key) }
            do {
                let text = try await Self.ask(album, details: details, apiKey: apiKey)
                guard !text.isEmpty else { throw ClaudeTagFixer.FixError.noAnswer }
                context.insert(Discovery(key: key, payload: Data(text.utf8)))
                try? context.save()
            } catch {
                failed.insert(key)
                Log.debug("about: \(album.title) failed: \(error)")
            }
        }
    }

    static let system = """
        You write the short description shown on an album's page in a music app, like Apple Music's editorial notes. \
        Two or three sentences, about 60 words: the album's context, its sound, and one notable fact (how it was made, \
        its reception or influence). Plain prose: no markdown, no lists, no quotation of reviews, no hype words. If the \
        release is obscure, use web_search to learn about it; if you still can't find anything reliable, describe only \
        what the details given say. Reply with the description and nothing else.
        """

    static func prompt(_ album: AlbumKey, details: String) -> String {
        "Album: \(album.title)\nArtist: \(album.artist)" + (details.isEmpty ? "" : "\n\(details)")
    }

    private static func ask(_ album: AlbumKey, details: String, apiKey: String) async throws -> String {
        var messages: [[String: Any]] = [["role": "user", "content": prompt(album, details: details)]]
        for _ in 0..<4 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": ClaudeTagFixer.Model.haiku.rawValue,
                "max_tokens": 600,
                "system": system,
                "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 2]],
                "messages": messages,
            ] as [String: Any])
            let response = try await ClaudeTagFixer.response(to: request)
            let content = response["content"] as? [[String: Any]] ?? []
            if response["stop_reason"] as? String == "pause_turn" {
                messages.append(["role": "assistant", "content": content])
                continue
            }
            return cleaned(content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined())
        }
        throw ClaudeTagFixer.FixError.noAnswer
    }

    /// Plain text: no markdown emphasis or leftover whitespace.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
