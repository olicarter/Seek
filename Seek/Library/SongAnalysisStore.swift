import Foundation
import Observation

/// Every song's tempo and key, shared through the app's iCloud folder (Seek/analysis.json): the
/// Mac fills it in, from the songs' tags where they have them and by analysing the audio where
/// they don't (SongAnalysis); the iPhone and iPad read it, so they get both without opening the
/// files (they often only have the songs' details, not the songs). A file rather than CloudKit
/// fields: a new field would need the CloudKit schema deployed before the ad hoc builds could sync.
@MainActor
@Observable
final class SongAnalysisStore {
    struct Entry: Codable, Equatable {
        var bpm: Double?
        /// Camelot code.
        var key: String?
    }

    /// Songs analysed so far this run, for Settings.
    private(set) var analysed = 0
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var running: Task<Void, Never>?

    init(library: LibraryStore) {
        self.library = library
    }

    private var file: URL? {
        library.root?.deletingLastPathComponent().appending(path: "Seek/analysis.json")
    }

    /// Reads what's there and gives the songs here any tempo and key they lack.
    func load() {
        guard let file else { return }
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                var data: Data?
                var error: NSError?
                // Coordinated: iCloud may be writing a newer copy from the Mac.
                NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
                    data = try? Data(contentsOf: url)
                }
                return data
            }.value
            guard let data, let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
            entries.merge(saved) { mine, _ in mine }
            library.applyTempoAndKey(entries)
        }
    }

    /// On the Mac: works through the library, a song at a time, quietly, and again now and then
    /// for songs that have arrived since.
    func run() {
        guard running == nil else { return }
        running = Task {
            load()
            while !Task.isCancelled {
                // Soon again while songs wait for their tags to be read; otherwise now and then.
                let waiting = await pass()
                try? await Task.sleep(for: .seconds(waiting ? 20 : 600))
            }
        }
    }

    /// True when songs were left for their tags to be read first.
    private func pass() async -> Bool {
        var unsaved = 0
        var waiting = false
        for track in library.allTracks where !track.isDeleted && track.modelContext != nil {
            guard entries[track.path] == nil else { continue }
            // Its tags read for tempo and key first (they win over analysis); next time round.
            guard track.tagsVersion >= Track.currentTagsVersion else {
                waiting = true
                continue
            }
            let path = track.path
            var entry = Entry(bpm: track.bpm > 0 ? track.bpm : nil, key: track.musicalKey.isEmpty ? nil : track.musicalKey)
            if entry.bpm == nil || entry.key == nil, let url = library.url(for: track), await library.ensureLocal(url) {
                let result = await Task.detached(priority: .background) { await SongAnalysis.analyse(url) }.value
                entry.bpm = entry.bpm ?? result?.bpm
                entry.key = entry.key ?? result?.key?.camelot
                analysed += 1
            }
            entries[path] = entry
            unsaved += 1
            if unsaved >= 10 {
                save()
                unsaved = 0
            }
            if Task.isCancelled { break }
        }
        if unsaved > 0 { save() }
        return waiting
    }

    private func save() {
        library.applyTempoAndKey(entries)
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
