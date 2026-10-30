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
    /// Albums whose upgrade turned out not to be lossless, by `AlbumReferences.key`: their pages say so.
    private(set) var notLossless: Set<String> = []

    /// Copies named lossless that came in lossy (MP3s named .flac), by folder name: a rip's
    /// folder is named the same by everyone sharing it, so none of them is offered as lossless again.
    private(set) var fakeLossless = Set(UserDefaults.standard.stringArray(forKey: "fakeLosslessFolders") ?? [])

    func isFakeLossless(_ folder: RemoteFolder) -> Bool { fakeLossless.contains(folder.name.lowercased()) }

    private func markFakeLossless(_ folder: RemoteFolder) {
        fakeLossless.insert(folder.name.lowercased())
        UserDefaults.standard.set(Array(fakeLossless), forKey: "fakeLosslessFolders")
    }

    func copies(of album: AlbumKey) -> Copies? {
        copies[AlbumReferences.key(album)]
    }

    /// Looks for the album on Soulseek, at most every half hour.
    /// `expectedTracks`, the album's song count when its tracklist is known, keeps out folders
    /// that can't be it (see `CopyFilter.isCopy`).
    func find(_ album: AlbumKey, expectedTracks: Int? = nil, client: SoulseekClient, quality: QualityPreference) {
        let key = AlbumReferences.key(album)
        if let existing = copies[key], existing.status == .searching || existing.searchedAt.timeIntervalSinceNow > -1800 { return }
        copies[key] = Copies(status: .searching)
        Task {
            let query = Self.query(for: album)
            // Copies show (and can play) as they're found, rather than after the whole search.
            let found = await client.quietSearch(query) { [weak self] soFar in
                let matched = await Self.matching(album, query: query, in: soFar, expectedTracks: expectedTracks, quality: quality)
                self?.copies[key] = Copies(status: .searching, folders: matched)
                // Plenty of good copies with a free slot: no need to wait for the rest.
                return (CopyFilter.preferred(matched, quality: quality)?.count ?? 0) >= Self.enoughCopies
            }
            guard let found else {
                copies[key] = Copies(status: .unavailable)
                return
            }
            var folders = await Self.matching(album, query: query, in: found, expectedTracks: expectedTracks, quality: quality)
            copies[key] = Copies(status: .found, folders: folders)
            // A search only lists matching files; fetch the rest for the best few copies (not
            // for a single's song in a folder of other music, where the rest isn't the release).
            for folder in folders.prefix(3) where AlbumIdentity.folder(folder.path, holds: album.title) {
                _ = try? await client.contents(of: folder)
            }
            folders = folders.map(client.complete).sorted { ReleaseGrouper.better($0, $1, quality: quality) }
            copies[key] = Copies(status: .found, folders: folders)
        }
    }

    static let enoughCopies = 5

    /// What to search Soulseek for. It only finds folders with every word searched for.
    /// A double A-side by its first side: copies spell the other one many ways ("Die Brucke",
    /// or left out). Words that are only punctuation ("/") match nothing, so they're left out.
    nonisolated static func query(for album: AlbumKey) -> String {
        let title = AlbumIdentity.sides(album.title)[0]
        return "\(album.artist) \(ReleaseText.cleanTitle(title))"
            .split(separator: " ")
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .joined(separator: " ")
    }

    /// The folders that are this album, best first.
    nonisolated static func matching(_ album: AlbumKey, query: String, in folders: [RemoteFolder],
                                     expectedTracks: Int? = nil, quality: QualityPreference) async -> [RemoteFolder] {
        let grouped = await Task.detached {
            ReleaseGrouper.group(query: query, owned: [], store: [], folders: folders, quality: quality)
        }.value
        let sides = AlbumIdentity.sides(album.title)
        // A double A-side's copies may be named for both sides or the first alone.
        return grouped.releases
            .filter { release in
                ReleaseText.artistsMatch(release.artist, album.artist)
                    && (ReleaseText.titlesMatch(release.title, album.title)
                        || sides.count > 1 && ReleaseText.titlesMatch(release.title, sides[0]))
            }
            .flatMap(\.folders)
            .filter { CopyFilter.isCopy($0, expectedTracks: expectedTracks) }
            .appendingLooseSingles(expectedTracks == 1 ? looseSingles(album, in: folders) : [])
            .sorted { ReleaseGrouper.better($0, $1, quality: quality) }
    }

    /// Words naming another version of a song; "Original Mix" is the song itself.
    private nonisolated static let versionWords: Set<String> = [
        "remix", "mix", "edit", "dub", "vip", "instrumental", "acapella", "live", "rework", "bootleg", "flip",
        "refix", "extended", "radio", "remaster", "remastered", "version", "cover",
    ]

    /// A single found as a song on its own: in a folder named for something else (the artist's
    /// songs, a mix of tracks), the file named for the artist and the title and nothing else
    /// ("114 - jayc, lemtom - starlight.flac"). The copy is that song alone, lossless first.
    nonisolated static func looseSingles(_ album: AlbumKey, in folders: [RemoteFolder]) -> [RemoteFolder] {
        let title = ReleaseText.fold(ReleaseText.cleanTitle(album.title))
        guard !title.isEmpty else { return [] }
        let artists = ReleaseText.creditNames(album.artist).union([ReleaseText.fold(album.artist)]).filter { !$0.isEmpty }
        let titleWords = Set(title.split(separator: " ").map(String.init))
        let joiners: Set<String> = ["feat", "ft", "and", "x", "vs", "with"]
        return folders.compactMap { folder in
            let songs = folder.files.filter { file in
                var name = " " + ReleaseText.fold((file.name as NSString).deletingPathExtension) + " "
                name = name.replacingOccurrences(of: " original mix ", with: " ")
                // The artists named in the file or its folders.
                let path = " " + ReleaseText.fold(file.path) + " "
                guard artists.contains(where: { path.contains(" \($0) ") }) else { return false }
                // What's left of the name, once the artists and numbers are taken out, is the title.
                for artist in artists.sorted(by: { $0.count > $1.count }) {
                    name = name.replacingOccurrences(of: " \(artist) ", with: " ")
                }
                let rest = name.split(separator: " ").map(String.init)
                    .filter { !$0.allSatisfy(\.isNumber) && !joiners.contains($0) }
                guard rest.joined(separator: " ") == title else { return false }
                return !rest.contains { versionWords.contains($0) && !titleWords.contains($0) }
            }
            // A handful at most (the song in two formats); more is a folder of something else.
            guard !songs.isEmpty, songs.count <= 3 else { return nil }
            return RemoteFolder(username: folder.username, path: folder.path,
                                files: songs.sorted { $0.isLossless && !$1.isLossless },
                                hasFreeSlot: folder.hasFreeSlot, averageSpeed: folder.averageSpeed, queueLength: folder.queueLength)
        }
    }

    /// Downloads a better copy and, once every file is in, swaps the album's tracks for it by
    /// title, keeping anything without a match.
    func upgrade(_ album: AlbumKey, replacing oldPaths: [String], with folder: RemoteFolder, reference: AlbumReference? = nil,
                 client: SoulseekClient, library: LibraryStore) {
        let key = AlbumReferences.key(album)
        guard upgrading.insert(key).inserted else { return }
        Task {
            defer { upgrading.remove(key) }
            let all = (try? await client.contents(of: folder)) ?? folder.files
            // The tracklist's songs when it's known (named from it as they come in, so each finds
            // the song it replaces), otherwise the copy's audio.
            let audio = all.filter { AudioFormats.playable.contains($0.fileExtension) }
            let songs = reference?.tracks.compactMap { MissingTracks.file(for: $0, in: audio) } ?? []
            let files = songs.isEmpty ? audio : songs
            var chosen = folder
            chosen.files = all
            client.download(files, in: chosen, album: album, replacingExisting: true)
            let ids = Set(files.map(\.id))
            while true {
                try? await Task.sleep(for: .seconds(3))
                let transfers = client.transfers.filter { ids.contains($0.file.id) }
                if transfers.count >= ids.count, transfers.allSatisfy({ !$0.state.isActive }) {
                    let newPaths = Set(transfers.compactMap(\.libraryPath))
                    // What arrived is checked, not what it was called: some "FLAC" copies are MP3s.
                    // Then the album stays as it was, the copy goes, and it isn't offered again.
                    let arrived = library.allTracks.filter { newPaths.contains($0.path) }
                    if arrived.contains(where: { !AudioQuality($0).isLossless }) {
                        Log.debug("upgrade: \(folder.name) from \(folder.username) isn't lossless; keeping \(album.title) as it was")
                        markFakeLossless(folder)
                        notLossless.insert(key)
                        library.delete(arrived)
                        return
                    }
                    if !newPaths.isEmpty { library.replace(oldPaths, with: Array(newPaths)) }
                    return
                }
            }
        }
    }
}

private extension Array where Element == RemoteFolder {
    /// Loose songs found for a single, besides the folders already found as it.
    func appendingLooseSingles(_ loose: [RemoteFolder]) -> [RemoteFolder] {
        let ids = Set(map(\.id))
        return self + loose.filter { !ids.contains($0.id) }
    }
}
