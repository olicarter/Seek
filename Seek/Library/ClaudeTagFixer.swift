import Foundation

/// Asks Claude to correct an album's tags, letting it read the release page and search the web.
/// Runs only when the user asks (Edit Info → Fix with Claude); the result is shown for review.
enum ClaudeTagFixer {
    struct Album: Sendable {
        var albumArtist: String
        var album: String
        var label: String
        var year: Int?
        var tracks: [Track]
        var sourceURL: String?
        var comment: String?
        var hasArtwork = true
    }

    struct Track: Sendable {
        var title: String
        var artist: String
        var trackNumber: Int
        var fileName: String
    }

    struct Suggestion: Sendable, Equatable {
        var albumArtist: String
        var album: String
        var label: String
        var year: Int?
        var tracks: [TrackSuggestion]
        /// The release's front cover, when Claude found one.
        var artworkURL: URL?
    }

    struct TrackSuggestion: Sendable, Equatable {
        var title: String
        var artist: String
        /// Position on the release; nil when unknown.
        var number: Int?
    }

    enum FixError: LocalizedError {
        case noKey
        case api(String, status: Int)
        case refused
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .noKey: "Add a Claude API key in Settings first."
            case .api(let message, _): "Claude: \(message)"
            case .refused: "Claude declined this request."
            case .noAnswer: "Claude didn't return corrections. Try again."
            }
        }

        /// Worth an automatic second attempt: the model didn't finish, or the API was busy.
        var isRetryable: Bool {
            switch self {
            case .noAnswer: true
            case .api(_, let status): status == 429 || status >= 500
            default: false
            }
        }
    }

    // MARK: - API key

    private static let keychain = KeychainItem(service: "dev.olicarter.seek.claude")

    static var apiKey: String? {
        keychain.load().flatMap { String(data: $0.data, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setAPIKey(_ key: String?) {
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            keychain.save(account: "Claude", data: Data(key.utf8))
        } else {
            keychain.clear()
        }
    }

    // MARK: - Model

    /// Haiku is the default: tag fixing is a small job, and it's far cheaper. Opus is there for
    /// releases Haiku gets wrong.
    enum Model: String, CaseIterable, Identifiable {
        case haiku = "claude-haiku-5-5"
        case sonnet = "claude-sonnet-5-5"
        case opus = "claude-opus-5-5"

        var id: String { rawValue }

        var name: String {
            switch self {
            case .haiku: "Haiku 5.5"
            case .sonnet: "Sonnet 5.5"
            case .opus: "Opus 5.5"
            }
        }

        var detail: String {
            switch self {
            case .haiku: "Fastest and cheapest"
            case .sonnet: "Balanced"
            case .opus: "Most capable, about 40× Haiku's price"
            }
        }

        /// The newer web tools (with result filtering) need Sonnet or Opus; Haiku uses the basic ones.
        var webTools: [[String: Any]] {
            switch self {
            case .haiku:
                [["type": "web_search_20250305", "name": "web_search", "max_uses": 3],
                 ["type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 3]]
            case .sonnet, .opus:
                [["type": "web_search_20260209", "name": "web_search", "max_uses": 3],
                 ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 3]]
            }
        }

        /// Server-side fallback after a declined request. Not offered for Haiku.
        var supportsFallback: Bool { self != .haiku }
    }

    static let modelDefaultsKey = "claudeModel"

    static var model: Model {
        UserDefaults.standard.string(forKey: modelDefaultsKey).flatMap(Model.init(rawValue:)) ?? .haiku
    }

    // MARK: - Request

    static let system = """
        You correct music tags for a DJ's library. Releases often come from Bandcamp, where labels sometimes \
        upload under their own page: the label then appears as artist, and the real artist may only appear in the \
        release title ("Artist - Album") or in track titles ("Artist - Track").

        Rules:
        - Change only what is wrong; otherwise return the current value exactly.
        - Labels are not artists unless the label really is the performer.
        - Keep featured artists and remix/edit/version notes in track titles exactly as written.
        - Track artist: who performs the track. For an edit/remix/bootleg of someone else's song, use the original \
        artist and keep the remix note in the title, e.g. "Xtal (nextdimensional club remix)".
        - Album artist: the main artist of the release; a producer's own edit pack belongs to that producer; use \
        "Various Artists" only for multi-artist compilations.
        - Track number: the track's position on the release, 1 for a standalone single; null only when unknown.
        - Label: the record label that released it (a Bandcamp page owner that isn't the artist is usually the label). \
        Use an empty string for self-released music or when unknown.
        - Artwork URL: a direct link to the release's front cover image file, the largest available (on Bandcamp, \
        the og:image of the release page). Prefer the release page, then Discogs. Null if you can't find the cover.
        - Use web_fetch on the release page and web_search when the current tags leave doubt. Prefer the release \
        page, Discogs and the artist's own pages over guesses.
        - Finish by calling submit_corrections once.
        """

    static let submitTool: [String: Any] = [
        "name": "submit_corrections",
        "strict": true,
        "description": "Submit the corrected tags for the whole album, one entry per track in the given order.",
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["album_artist", "album", "label", "year", "artwork_url", "tracks"],
            "properties": [
                "album_artist": ["type": "string"],
                "album": ["type": "string"],
                "label": ["type": "string"],
                "year": ["anyOf": [["type": "integer"], ["type": "null"]]],
                "artwork_url": ["anyOf": [["type": "string"], ["type": "null"]]],
                "tracks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["index", "title", "artist", "track_number"],
                        "properties": [
                            "index": ["type": "integer"],
                            "title": ["type": "string"],
                            "artist": ["type": "string"],
                            "track_number": ["anyOf": [["type": "integer"], ["type": "null"]]],
                        ],
                    ],
                ],
            ],
        ],
    ]

    static func prompt(for album: Album) -> String {
        let tracks = album.tracks.enumerated().map { index, track -> [String: Any] in
            ["index": index, "number": track.trackNumber, "title": track.title, "artist": track.artist, "file": track.fileName]
        }
        let current: [String: Any] = [
            "album_artist": album.albumArtist, "album": album.album, "label": album.label,
            "year": album.year ?? NSNull(), "has_artwork": album.hasArtwork, "tracks": tracks,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var lines = ["Current tags:", json]
        if let url = album.sourceURL { lines.append("Release page: \(url)") }
        if let comment = album.comment { lines.append("File comment: \(comment)") }
        return lines.joined(separator: "\n")
    }

    /// Tries twice: Claude occasionally ends without submitting, and the API can be briefly busy.
    static func suggest(for album: Album, apiKey: String) async throws -> Suggestion {
        do {
            return try await attempt(album, apiKey: apiKey)
        } catch let error as FixError where error.isRetryable {
            Log.debug("claude: retrying after \(error)")
        } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
            Log.debug("claude: retrying after \(error.code)")
        }
        return try await attempt(album, apiKey: apiKey)
    }

    private static func attempt(_ album: Album, apiKey: String) async throws -> Suggestion {
        var messages: [[String: Any]] = [["role": "user", "content": prompt(for: album)]]
        var nudged = false

        for _ in 0..<6 {
            let response = try await send(messages: messages, apiKey: apiKey)
            let content = response["content"] as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String

            if stopReason == "refusal" { throw FixError.refused }
            if let call = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "submit_corrections" }),
               let input = call["input"] as? [String: Any] {
                return try parse(input, current: album)
            }
            switch stopReason {
            case "pause_turn":
                // A long server-side search loop paused; send the turn back to let it continue.
                messages.append(["role": "assistant", "content": content])
            case "end_turn" where !nudged:
                nudged = true
                messages.append(["role": "assistant", "content": content])
                messages.append(["role": "user", "content": "Please call submit_corrections with your answer now."])
            default:
                throw FixError.noAnswer
            }
        }
        throw FixError.noAnswer
    }

    private static func send(messages: [[String: Any]], apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let model = Self.model
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "system": system,
            "tools": model.webTools + [submitTool],
            "messages": messages,
        ]
        if model.supportsFallback {
            // Lets a declined request be retried on Anthropic's recommended fallback model.
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await response(to: request)
    }

    /// Sends a Messages API request and returns the decoded response, turning API errors into
    /// `FixError.api` so callers can tell busy (retryable) from bad requests.
    static func response(to request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw FixError.api(message, status: http.statusCode)
        }
        return json
    }

    /// Accepts web image links only, upgrading Bandcamp's to its 1200-pixel size
    /// (e.g. a1234567890_5.jpg → a1234567890_10.jpg).
    static func artworkURL(_ text: String) -> URL? {
        guard var url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
        else { return nil }
        if url.host()?.hasSuffix("bcbits.com") == true,
           let match = url.lastPathComponent.firstMatch(of: /^(a\d+)_\d+\.(jpg|png)$/) {
            url = url.deletingLastPathComponent().appending(path: "\(match.1)_10.jpg")
        }
        return url
    }

    /// Reads the submitted corrections. A track Claude left out keeps its current tags rather than
    /// failing the whole answer.
    static func parse(_ input: [String: Any], current: Album) throws -> Suggestion {
        guard let albumArtist = input["album_artist"] as? String,
              let album = input["album"] as? String,
              let rawTracks = input["tracks"] as? [[String: Any]], !rawTracks.isEmpty
        else { throw FixError.noAnswer }
        var tracks = current.tracks.map {
            TrackSuggestion(title: $0.title, artist: $0.artist, number: $0.trackNumber > 0 ? $0.trackNumber : nil)
        }
        for raw in rawTracks {
            guard let index = raw["index"] as? Int, tracks.indices.contains(index),
                  let title = raw["title"] as? String, let artist = raw["artist"] as? String
            else { continue }
            let number = (raw["track_number"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? tracks[index].number
            tracks[index] = TrackSuggestion(title: title, artist: artist, number: number)
        }
        return Suggestion(
            albumArtist: albumArtist,
            album: album,
            label: input["label"] as? String ?? "",
            year: input["year"] as? Int,
            tracks: tracks,
            artworkURL: (input["artwork_url"] as? String).flatMap(artworkURL)
        )
    }
}
