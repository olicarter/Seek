import Foundation
import Observation
import SwiftData
import UIKit

/// "Similar artists" and "similar albums" from Claude Haiku. Each artist or album is asked about
/// once: answers are kept in the synced store, so other devices reuse them too.
@MainActor
@Observable
final class DiscoveryService {
    enum Subject: Hashable, Codable {
        case artist(String)
        case album(artist: String, title: String)

        var key: String {
            switch self {
            case .artist(let name): "artist:\(Self.fold(name))"
            case .album(let artist, let title): "album:\(Self.fold(artist))|\(Self.fold(title))"
            }
        }

        private static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    enum DiscoveryError: LocalizedError {
        case nothingFound

        var errorDescription: String? { "Claude didn't come up with suggestions this time." }
    }

    struct Suggestion: Codable, Hashable, Identifiable {
        var artist: String
        /// Set for album suggestions.
        var title: String?
        var year: Int?
        /// A few words on why it's similar.
        var reason: String
        /// Cover art from the closest Bandcamp match, looked up once when the suggestion is made.
        var artworkURL: URL?

        var id: String { "\(artist)|\(title ?? "")" }
        var searchText: String { [artist, title].compactMap { $0 }.joined(separator: " ") }
    }

    enum State: Equatable {
        case loading
        case failed(String)
    }

    /// Requests in flight or failed, by subject key; cached answers live in the store.
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private let context: ModelContext

    init(container: ModelContainer) {
        context = container.mainContext
    }

    static let model = ClaudeTagFixer.Model.haiku

    // MARK: - Cache

    func cached(_ subject: Subject) -> [Suggestion]? {
        let key = subject.key
        var descriptor = FetchDescriptor<Discovery>(
            predicate: #Predicate { $0.key == key },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first,
              let suggestions = try? JSONDecoder().decode([Suggestion].self, from: entry.payload),
              // Empty answers saved by older versions count as not asked yet.
              !suggestions.isEmpty else { return nil }
        return suggestions
    }

    // MARK: - Asking Claude

    /// Fetches suggestions unless they're cached or already being fetched. Without an API key it
    /// does nothing, and the page just has no suggestions.
    func load(_ subject: Subject, refresh: Bool = false) {
        let key = subject.key
        guard states[key] != .loading, refresh || cached(subject) == nil,
              let apiKey = ClaudeTagFixer.apiKey else { return }
        states[key] = .loading
        remember(subject)
        let library = libraryContext(for: subject)
        let work = beginBackgroundWork()
        Task {
            defer { endBackgroundWork(work) }
            do {
                var suggestions = try await Self.ask(about: subject, library: library, apiKey: apiKey)
                // An empty answer never replaces suggestions already there.
                guard !suggestions.isEmpty else { throw DiscoveryError.nothingFound }
                suggestions = await Self.addArtwork(to: suggestions)
                let payload = try JSONEncoder().encode(suggestions)
                // Replace older answers for this page, including duplicates from other devices.
                let old = (try? self.context.fetch(FetchDescriptor<Discovery>(predicate: #Predicate { $0.key == key }))) ?? []
                old.forEach(self.context.delete)
                self.context.insert(Discovery(key: key, payload: payload))
                try? self.context.save()
                states[key] = nil
                forget(subject)
            } catch {
                Log.debug("discovery failed for \(key): \(error)")
                states[key] = .failed(error.localizedDescription)
                // A bad key or a refusal won't fix itself; anything else (no network, the app
                // being suspended) is tried again next launch.
                if let error = error as? ClaudeTagFixer.FixError, !error.isRetryable { forget(subject) }
                if error is DiscoveryError { forget(subject) }
            }
        }
    }

    // MARK: - Surviving the background

    @ObservationIgnored private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    /// Asks iOS for time to finish after the app is locked or left, usually about half a minute,
    /// which is enough for most requests. Anything cut off is resumed on the next launch.
    private func beginBackgroundWork() -> UUID {
        let id = UUID()
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "Finding similar music") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundWork(id) }
        }
        return id
    }

    private func endBackgroundWork(_ id: UUID) {
        guard let task = backgroundTasks.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    private static let pendingKey = "discoveryPending"

    /// Requests not yet answered, kept so they survive the app being closed.
    private var pending: [Subject] {
        get {
            (UserDefaults.standard.data(forKey: Self.pendingKey))
                .flatMap { try? JSONDecoder().decode([Subject].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.pendingKey) }
    }

    private func remember(_ subject: Subject) {
        if !pending.contains(subject) { pending.append(subject) }
    }

    private func forget(_ subject: Subject) {
        pending.removeAll { $0 == subject }
    }

    /// Picks up requests that were cut off, on launch and whenever the app comes back.
    func resumePending() {
        for subject in pending {
            if cached(subject) != nil { forget(subject) } else { load(subject) }
        }
    }

    // MARK: - New albums

    @ObservationIgnored private var pendingAlbums: [String: Task<Void, Never>] = [:]

    /// Called as files are added to the library. Similar albums, and similar artists for the
    /// album's artist, are fetched once the album has stopped growing for a while (Soulseek
    /// albums arrive a file at a time), so they're usually ready before either page is opened.
    func albumAdded(_ album: AlbumKey) {
        for subject in [Subject.album(artist: album.artist, title: album.title), .artist(album.artist)]
        where cached(subject) == nil {
            // Saved now, so a countdown cut short by the app closing still happens next launch.
            remember(subject)
            pendingAlbums[subject.key]?.cancel()
            let work = beginBackgroundWork()
            pendingAlbums[subject.key] = Task {
                defer { endBackgroundWork(work) }
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                pendingAlbums[subject.key] = nil
                load(subject)
            }
        }
    }

    /// What the library holds, for the prompt: the subject's own albums or tracks, and everything
    /// else so Claude doesn't suggest it.
    func libraryContext(for subject: Subject) -> LibraryContext {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let albums = LibraryGrouping.albums(tracks)
        var details = ""
        switch subject {
        case .artist(let name):
            let theirs = albums.filter { $0.artist == name }
            let labels = Set(theirs.map(\.label).filter { !$0.isEmpty })
            details = "In the library: " + theirs.map { "\($0.title)\($0.year > 0 ? " (\($0.year))" : "")" }.joined(separator: ", ")
            if !labels.isEmpty { details += ". Labels: " + labels.sorted().joined(separator: ", ") }
        case .album(let artist, let title):
            if let album = albums.first(where: { $0.artist == artist && $0.title == title }) {
                var parts: [String] = []
                if album.year > 0 { parts.append("released \(album.year)") }
                if !album.label.isEmpty { parts.append("on \(album.label)") }
                let songs = album.tracks.prefix(12).map(\.title).joined(separator: ", ")
                if !songs.isEmpty { parts.append("tracks: \(songs)") }
                details = parts.joined(separator: "; ")
            }
        }
        return LibraryContext(
            artists: Array(Set(albums.map(\.artist))).sorted(),
            albums: albums.map { "\($0.artist) – \($0.title)" },
            details: details
        )
    }

    /// What Claude is told about the library, so it can skip what's already there.
    struct LibraryContext: Sendable {
        var artists: [String]
        var albums: [String]
        /// About the subject itself: its albums, labels and years.
        var details: String
    }

    static let system = """
        You recommend music to a DJ. Suggest releases and artists they'd want to dig into next: same scene, \
        sound or labels, mixing a few well-known names with lesser-known ones. Only suggest artists and \
        releases that really exist; if the subject is obscure, use web_search to learn its scene first. \
        Never suggest anything listed as already in the library, or the subject itself. Keep each reason under \
        12 words, about the sound or connection (shared label, collaborators, scene). Finish by calling \
        submit_suggestions once.
        """

    static func tool(for subject: Subject) -> [String: Any] {
        // The reason shows under a card in a few lines, so it's kept to one short sentence.
        var item: [String: Any] = ["artist": ["type": "string"],
                                   "reason": ["type": "string", "description": "One short sentence, at most 12 words."]]
        var required = ["artist", "reason"]
        if case .album = subject {
            item["title"] = ["type": "string"]
            item["year"] = ["anyOf": [["type": "integer"], ["type": "null"]]]
            required += ["title", "year"]
        }
        return [
            "name": "submit_suggestions",
            "strict": true,
            "description": "Submit 8 suggestions, best first.",
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "required": ["suggestions"],
                "properties": [
                    "suggestions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": required,
                            "properties": item,
                        ],
                    ],
                ],
            ],
        ]
    }

    static func prompt(for subject: Subject, library: LibraryContext) -> String {
        var lines: [String] = []
        switch subject {
        case .artist(let name):
            lines.append("Suggest 8 artists similar to \(name).")
        case .album(let artist, let title):
            lines.append("Suggest 8 albums or EPs similar to \(title) by \(artist), each by a different artist where you can.")
        }
        if !library.details.isEmpty { lines.append("About it: \(library.details)") }
        lines.append("Already in the library (don't suggest): " + (library.albums.isEmpty ? "nothing else" : library.albums.prefix(300).joined(separator: "; ")))
        if case .artist = subject {
            lines.append("Artists already in the library (don't suggest): " + library.artists.prefix(300).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private static func ask(about subject: Subject, library: LibraryContext, apiKey: String) async throws -> [Suggestion] {
        do {
            return try await attempt(subject, library: library, apiKey: apiKey)
        } catch let error as ClaudeTagFixer.FixError where error.isRetryable {
            Log.debug("discovery: retrying after \(error)")
            return try await attempt(subject, library: library, apiKey: apiKey)
        }
    }

    private static func attempt(_ subject: Subject, library: LibraryContext, apiKey: String) async throws -> [Suggestion] {
        var messages: [[String: Any]] = [["role": "user", "content": prompt(for: subject, library: library)]]
        var nudged = false
        var retriedSubmission = false
        for _ in 0..<5 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let tools = [["type": "web_search_20250305", "name": "web_search", "max_uses": 2] as [String: Any], tool(for: subject)]
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model.rawValue,
                "max_tokens": 4000,
                "system": system,
                "tools": tools,
                "messages": messages,
            ] as [String: Any])
            let response = try await ClaudeTagFixer.response(to: request)
            let content = response["content"] as? [[String: Any]] ?? []
            if response["stop_reason"] as? String == "refusal" { throw ClaudeTagFixer.FixError.refused }
            if let call = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "submit_suggestions" }),
               let input = call["input"] as? [String: Any] {
                let suggestions = parse(input)
                if suggestions.count >= 3 || retriedSubmission { return suggestions }
                // Too few usable entries (e.g. missing artists): say what was wrong and ask again.
                Log.debug("discovery: only \(suggestions.count) usable suggestions in \(input)")
                retriedSubmission = true
                messages.append(["role": "assistant", "content": content])
                messages.append(["role": "user", "content": [[
                    "type": "tool_result",
                    "tool_use_id": call["id"] as? String ?? "",
                    "is_error": true,
                    "content": "Only \(suggestions.count) of those were usable. Each suggestion needs a real artist name, a release title and a short reason. Please call submit_suggestions again with 8.",
                ] as [String: Any]]])
                continue
            }
            switch response["stop_reason"] as? String {
            case "pause_turn":
                messages.append(["role": "assistant", "content": content])
            case "end_turn" where !nudged:
                nudged = true
                messages.append(["role": "assistant", "content": content])
                messages.append(["role": "user", "content": "Please call submit_suggestions now."])
            default:
                throw ClaudeTagFixer.FixError.noAnswer
            }
        }
        throw ClaudeTagFixer.FixError.noAnswer
    }

    static func parse(_ input: [String: Any]) -> [Suggestion] {
        let raw = input["suggestions"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return raw.compactMap { item in
            guard let artist = (item["artist"] as? String)?.trimmingCharacters(in: .whitespaces), !artist.isEmpty else { return nil }
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespaces)
            let suggestion = Suggestion(
                artist: artist,
                title: title?.isEmpty == true ? nil : title,
                year: item["year"] as? Int,
                reason: (item["reason"] as? String) ?? ""
            )
            return seen.insert(suggestion.id.lowercased()).inserted ? suggestion : nil
        }
    }

    /// Finds cover art for each suggestion without one: the matching release (or for artists,
    /// their first release) on Bandcamp, then in Apple's iTunes catalogue for music that isn't on
    /// Bandcamp. Misses are fine; the card falls back to a placeholder.
    static func addArtwork(to suggestions: [Suggestion]) async -> [Suggestion] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, suggestion) in suggestions.enumerated() where suggestion.artworkURL == nil {
                group.addTask {
                    if let url = await bandcampArtwork(for: suggestion) { return (index, url) }
                    if let url = await iTunesArtwork(for: suggestion) { return (index, url) }
                    return (index, await catalogArtwork(for: suggestion))
                }
            }
            var result = suggestions
            for await (index, url) in group { result[index].artworkURL = url }
            return result
        }
    }

    private static func bandcampArtwork(for suggestion: Suggestion) async -> URL? {
        let results = (try? await BandcampAPI.searchStore(suggestion.searchText)) ?? []
        let byArtist = results.filter { ReleaseText.artistsMatch($0.artist, suggestion.artist) }
        return pick(byArtist, title: suggestion.title, titleOf: \.title)?.artworkURL
    }

    /// For an album, the result with its title (another of the artist's covers would mislead);
    /// for an artist, any of theirs.
    static func pick<T>(_ byArtist: [T], title: String?, titleOf: (T) -> String) -> T? {
        guard let title else { return byArtist.first }
        return byArtist.first { ReleaseText.titlesMatch(titleOf($0), title) }
    }

    /// Apple's free iTunes Search API, which covers most commercially released music.
    static func iTunesArtwork(for suggestion: Suggestion) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: suggestion.searchText),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
        else { return nil }
        let byArtist = results.filter { ReleaseText.artistsMatch($0["artistName"] as? String ?? "", suggestion.artist) }
        let match = pick(byArtist, title: suggestion.title) { $0["collectionName"] as? String ?? "" }
        // The 100-pixel thumbnail's address works at any size.
        return (match?["artworkUrl100"] as? String)
            .map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }
            .flatMap(URL.init(string:))
    }

    /// The artist's own catalogue in Apple Music, for albums iTunes search misses: punctuation
    /// throws it ("Panic! at the Disco A Fever You Can't Sweat Out" finds R. Kelly and Glee).
    static func catalogArtwork(for suggestion: Suggestion) async -> URL? {
        let releases = await ArtistCatalog.releases(for: suggestion.artist)
        guard let title = suggestion.title else {
            return releases.filter { $0.kind == .album }.max { $0.released < $1.released }?.artworkURL
        }
        let wanted = ReleaseText.fold(title)
        return (releases.first { ReleaseText.fold($0.title) == wanted }
            ?? releases.first { ReleaseText.titlesMatch($0.title, title) })?.artworkURL
    }

    // MARK: - Filling in missing covers

    /// Covers found for cards on screen, so each is looked up once per launch.
    private static var foundCovers: [String: URL] = [:]

    /// A cover for one suggestion shown without one, straight away rather than waiting for its
    /// page's saved suggestions to be updated.
    /// A cover already looked up this launch, without waiting.
    static func knownCover(for suggestion: Suggestion) -> URL? {
        BandcampAPI.repaired(suggestion.artworkURL) ?? foundCovers[suggestion.id]
    }

    /// Fetches every cover a row will show, looking up missing ones first, so none pop in later.
    static func prefetchCovers(_ suggestions: [Suggestion]) async {
        RemoteImages.prefetch(suggestions.compactMap(knownCover))
        await withTaskGroup(of: Void.self) { group in
            for suggestion in suggestions where knownCover(for: suggestion) == nil {
                group.addTask { @MainActor in
                    if let url = await cover(for: suggestion) { RemoteImages.prefetch([url]) }
                }
            }
        }
    }

    static func cover(for suggestion: Suggestion) async -> URL? {
        if let url = foundCovers[suggestion.id] { return url }
        let url = await addArtwork(to: [suggestion]).first?.artworkURL
        if let url { foundCovers[suggestion.id] = url }
        return url
    }

    @ObservationIgnored private var coversTried: Set<String> = []

    /// Looks again for covers missing from saved suggestions, once per page per launch, and saves
    /// any found so other devices get them too.
    func fillMissingArtwork(_ entry: Discovery) {
        guard coversTried.insert(entry.key).inserted,
              var suggestions = try? JSONDecoder().decode([Suggestion].self, from: entry.payload) else { return }
        let original = suggestions
        // Addresses saved by older versions with a wrapped id are fixed for good, too.
        for index in suggestions.indices { suggestions[index].artworkURL = BandcampAPI.repaired(suggestions[index].artworkURL) }
        let toFill = suggestions
        Task {
            let filled = await Self.addArtwork(to: toFill)
            let suggestions = original
            guard filled != suggestions, entry.modelContext != nil,
                  let payload = try? JSONEncoder().encode(filled) else { return }
            entry.payload = payload
            try? context.save()
        }
    }
}
