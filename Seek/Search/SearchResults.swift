import Foundation
import Observation

/// The current search grouped into releases. Regrouped (throttled) as Soulseek results arrive,
/// and again when Claude answers about folders Seek wasn't sure of.
@MainActor
@Observable
final class SearchResults {
    enum Timing {
        /// Straight away, dropping any regroup on its way.
        case now
        /// Once typing pauses.
        case afterTyping
        /// At most every 300 ms, for Soulseek results that keep arriving: waiting for a pause
        /// would show nothing until a busy search went quiet.
        case throttled
    }

    private struct Inputs {
        let query: String
        let owned: [BandcampItem]
        let store: [BandcampAPI.StoreResult]
        let folders: [RemoteFolder]
        let library: LibraryIndex
        let wishlist: Set<Int>
        let quality: QualityPreference
        let catalog: [CatalogRelease]
    }

    private(set) var result = ReleaseGrouper.Result(releases: [], songs: [], unsure: [])
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingTiming: Timing?
    @ObservationIgnored private var resolveLater: Task<Void, Never>?
    @ObservationIgnored private var latest: Inputs?
    @ObservationIgnored private var generation = 0

    func release(_ id: SearchRelease.ID) -> SearchRelease? {
        result.releases.first { $0.id == id }
    }

    func update(query: String, owned: [BandcampItem], store: [BandcampAPI.StoreResult], folders: [RemoteFolder],
                resolver: FolderResolver, library: LibraryIndex, wishlist: Set<Int>, quality: QualityPreference,
                catalog: [CatalogRelease] = [], timing: Timing = .now) {
        latest = Inputs(query: query, owned: owned, store: store, folders: folders,
                        library: library, wishlist: wishlist, quality: quality, catalog: catalog)
        generation += 1
        // A throttled regroup already on its way picks up these inputs when it runs.
        if timing == .throttled, pending != nil, pendingTiming == .throttled { return }
        schedule(timing, resolver: resolver)
    }

    private func schedule(_ timing: Timing, resolver: FolderResolver) {
        pending?.cancel()
        pendingTiming = timing
        pending = Task {
            if timing != .now { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let inputs = latest else { return }
            let started = generation
            let hints = resolver.hints
            // All the matching happens off the main thread, so typing stays smooth.
            let grouped = await Task.detached {
                ReleaseGrouper.group(query: inputs.query, owned: inputs.owned, store: inputs.store,
                                     folders: inputs.folders, hints: hints, library: inputs.library,
                                     wishlist: inputs.wishlist, quality: inputs.quality, catalog: inputs.catalog)
            }.value
            guard !Task.isCancelled else { return }
            pending = nil
            pendingTiming = nil
            result = grouped
            // More arrived while grouping: go again shortly.
            if generation != started { schedule(.throttled, resolver: resolver) }
            // Once Soulseek goes quiet for a few seconds, ask Claude about the folders left unsure.
            resolveLater?.cancel()
            if !grouped.unsure.isEmpty {
                resolveLater = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    resolver.resolve(grouped.unsure, releases: grouped.releases)
                }
            }
        }
    }
}
