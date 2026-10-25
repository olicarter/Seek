import Foundation
import Observation

/// Other copies of library albums on Soulseek: found with a quiet search (not the Search tab's),
/// matched to the album the same way search groups releases, with full folder contents fetched
/// so missing tracks can be mapped to files. Also runs upgrades to a better copy.
@MainActor
@Observable
final class CopyFinder {
    enum Status: Equatable {
        case searching
        case found
        /// Not signed in to Soulseek, or it couldn't connect.
        case unavailable
    }

    struct Copies {
        var status: Status
        /// Best first, with every file in the top few.
        var folders: [RemoteFolder] = []
        var searchedAt = Date.now
    }

    private(set) var copies: [String: Copies] = [:]
    /// Albums being upgraded, by `AlbumReferences.key`.
    private(set) var upgrading: Set<String> = []

    func copies(of album: AlbumKey) -> Copies? {
        copies[AlbumReferences.key(album)]
    }

    /// Looks for the album on Soulseek, at most every half hour.
    func find(_ album: AlbumKey, client: SoulseekClient, quality: QualityPreference) {
        let key = AlbumReferences.key(album)
        if let existing = copies[key], existing.status == .searching || existing.searchedAt.timeIntervalSinceNow > -1800 { return }
        copies[key] = Copies(status: .searching)
        Task {
            let query = "\(album.artist) \(ReleaseText.cleanTitle(album.title))"
            // Copies show (and can play) as they're found, rather than after the whole search.
            let found = await client.quietSearch(query) { [weak self] soFar in
                let matched = await Self.matching(album, query: query, in: soFar, quality: quality)
                self?.copies[key] = Copies(status: .searching, folders: matched)
                // Plenty of good copies with a free slot: no need to wait for the rest.
                return (CopyFilter.preferred(matched, quality: quality)?.count ?? 0) >= Self.enoughCopies
            }
            guard let found else {
                copies[key] = Copies(status: .unavailable)
                return
            }
            var folders = await Self.matching(album, query: query, in: found, quality: quality)
            copies[key] = Copies(status: .found, folders: folders)
            // A search only lists matching files; fetch the rest for the best few copies.
            for folder in folders.prefix(3) { _ = try? await client.contents(of: folder) }
            folders = folders.map(client.complete).sorted { ReleaseGrouper.better($0, $1, quality: quality) }
            copies[key] = Copies(status: .found, folders: folders)
        }
    }

    static let enoughCopies = 5

    /// The folders that are this album, best first.
    private static func matching(_ album: AlbumKey, query: String, in folders: [RemoteFolder],
                                 quality: QualityPreference) async -> [RemoteFolder] {
        let grouped = await Task.detached {
            ReleaseGrouper.group(query: query, owned: [], store: [], folders: folders, quality: quality)
        }.value
        return grouped.releases.first {
            ReleaseText.titlesMatch($0.title, album.title) && ReleaseText.artistsMatch($0.artist, album.artist)
        }?.folders ?? []
    }

    /// Downloads a better copy and, once every file is in, swaps the album's tracks for it by
    /// title, keeping anything without a match.
    func upgrade(_ album: AlbumKey, replacing oldPaths: [String], with folder: RemoteFolder,
                 client: SoulseekClient, library: LibraryStore) {
        let key = AlbumReferences.key(album)
        guard upgrading.insert(key).inserted else { return }
        Task {
            defer { upgrading.remove(key) }
            let files = (try? await client.contents(of: folder)) ?? folder.files
            for file in files { client.download(file, replacingExisting: true) }
            let ids = Set(files.map(\.id))
            while true {
                try? await Task.sleep(for: .seconds(3))
                let transfers = client.transfers.filter { ids.contains($0.file.id) }
                if transfers.count >= ids.count, transfers.allSatisfy({ !$0.state.isActive }) {
                    let newPaths = transfers.compactMap(\.libraryPath)
                    if !newPaths.isEmpty { library.replace(oldPaths, with: newPaths) }
                    return
                }
            }
        }
    }
}
