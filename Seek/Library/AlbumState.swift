import Foundation

/// What an album page shows, worked out in one place from everything known about the album, so
/// each song is in exactly one state and the page only offers what that state allows. Album
/// pages in the app, on the web and on the Apple TV all draw from this.
///
/// Before, each page worked its state out from several sources that disagree for a while (this
/// device's library, iCloud minutes behind the Mac, the Mac's downloads as mirrored here, the
/// page's remembered copy search, adds in progress), and some mixes showed songs twice, greyed
/// out what could play, or offered Add while an add was under way. Here each source has its
/// place in an order of precedence, and the states below are the only ones there are.
enum AlbumState: Equatable, Sendable {
    /// None of it in the library.
    case looking
    case available
    case unavailable
    /// Soulseek can't be used (not signed in here, and no Mac).
    case noSoulseek
    /// Songs on their way: `arrived` of `total` in the library so far.
    case adding(arrived: Int, total: Int)
    /// Some songs in the library, others not; `canAdd` when a copy has any of the rest.
    case partial(missing: Int, canAdd: Bool)
    case complete
    /// The add stopped (a song couldn't be had), until it's tried again.
    case addFailed(String)

    /// Whether Add is offered: never while songs are on their way.
    var canAdd: Bool {
        switch self {
        case .available, .addFailed: true
        case .partial(_, let canAdd): canAdd
        default: false
        }
    }

    var isAdding: Bool { if case .adding = self { true } else { false } }
    var isInLibrary: Bool {
        switch self {
        case .complete, .partial: true
        default: false
        }
    }
    /// Still finding out whether there are copies: a spinner, not a dead button.
    var isLooking: Bool { self == .looking }
}

/// A song on an album page.
struct AlbumSong: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// In the library here: plays now.
        case inLibrary(path: String)
        /// In the library on the Mac, not on this device yet (iCloud lags): plays from the Mac.
        case onMac(path: String)
        /// In the library, a better copy on its way to replace it.
        case replacing(path: String, progress: Double?)
        /// Being added.
        case arriving(Arrival)
        /// Not in the library; a copy has it, to play or add.
        case available
        /// Not in the library; copies still being looked for.
        case looking
        /// Not in the library; nobody has it right now.
        case unavailable
        /// The add gave up on it.
        case failed(String)
    }

    enum Arrival: Equatable, Sendable {
        case connecting(user: String)
        case queued(user: String, place: Int?)
        case downloading(Double)
        /// Downloaded, going into the library (or into iCloud, on its way here).
        case importing
        /// Failed for now; tried again by itself at this time.
        case retrying(at: Date)
    }

    var id: String
    var number: Int?
    var disc: Int
    var title: String
    var artist: String?
    var duration: Double?
    var state: State

    /// Can be played now: from the library, the Mac, or a copy (streamed).
    var isPlayable: Bool {
        switch state {
        case .inLibrary, .onMac, .replacing, .available: true
        default: false
        }
    }

    var libraryPath: String? {
        switch state {
        case .inLibrary(let path), .onMac(let path), .replacing(let path, _): path
        default: nil
        }
    }

    /// A progress ring's value, while it's arriving or being replaced (nil: waiting, no ring value yet).
    var progress: Double? {
        switch state {
        case .arriving(.downloading(let progress)): progress
        case .arriving(.importing): 1
        case .replacing(_, let progress): progress
        default: nil
        }
    }
}

/// Everything known about an album, as plain values: what `AlbumState.derive` works from.
struct AlbumFacts: Sendable {
    struct LibrarySong: Equatable, Sendable {
        var path: String
        var title: String
        var number: Int
        var disc: Int
        var duration: Double
        var artist: String? = nil
        /// Listed from the Mac's library, its file not here yet.
        var fromMac = false
        /// From a Bandcamp purchase: the official release, whatever its titles say.
        var fromBandcamp = false
    }

    struct Download: Equatable, Sendable {
        var id: UUID
        var file: RemoteFile
        var state: Transfer.State
        var progress: Double?
        var retryAt: Date?
        /// Going now, or to be tried again.
        var onItsWay: Bool
        /// A better copy of a song the library has.
        var replacesExisting = false
    }

    enum Copies: Equatable, Sendable {
        /// Not looked for (yet).
        case notAsked
        case looking
        /// Found: every file of every copy (to match songs to).
        case found([RemoteFile])
        case noSoulseek
    }

    /// Apple's or Bandcamp's tracklist, when there is one.
    var tracklist: [ReferenceTrack]?
    var library: [LibrarySong] = []
    var downloads: [Download] = []
    var copies: Copies = .notAsked
    /// An add of this album that stopped, not yet tried again.
    var addFailure: String?
}

@MainActor
extension AlbumState {
    /// The album's songs and its state. In order of precedence, a song is: in the library (or
    /// being replaced there), then on its way, then given up on, then available from a copy,
    /// still being looked for, or unavailable.
    static func derive(_ facts: AlbumFacts) -> (state: AlbumState, songs: [AlbumSong]) {
        var library = facts.library
        var downloads = facts.downloads
        let files: [RemoteFile] = if case .found(let files) = facts.copies { files } else { [] }
        var songs: [AlbumSong] = []

        func libraryState(_ song: AlbumFacts.LibrarySong) -> AlbumSong.State {
            let replacing = downloads.first { $0.replacesExisting && $0.onItsWay && Self.sameSong(song, $0.file) }
            if let replacing { return .replacing(path: song.path, progress: replacing.progress) }
            return song.fromMac ? .onMac(path: song.path) : .inLibrary(path: song.path)
        }

        if let tracklist = facts.tracklist {
            let official = !library.isEmpty && library.allSatisfy(\.fromBandcamp)
            // Extra discs (bonus material) only count once the library has something from them.
            let discs = Set(library.map { max($0.disc, 1) })
            let matched = Self.libraryMatches(tracklist, library, official: official)
            for (position, track) in tracklist.enumerated() {
                var song = AlbumSong(id: "\(track.disc)-\(track.number)-\(track.title)", number: track.number > 0 ? track.number : nil,
                                     disc: track.disc, title: track.title, artist: track.artist, duration: track.duration,
                                     state: .unavailable)
                if let have = matched[position] {
                    song.state = libraryState(have)
                } else if let index = Self.downloadMatch(for: track, in: downloads) {
                    let found = downloads.remove(at: index)
                    song.state = Self.arrivalState(found) ?? Self.copyState(track, files: files, copies: facts.copies)
                } else if track.disc > 1, !discs.isEmpty, !discs.contains(track.disc) {
                    continue
                } else {
                    song.state = Self.copyState(track, files: files, copies: facts.copies)
                }
                songs.append(song)
            }
        }
        // The library's songs the tracklist doesn't list (or all of them, without one).
        if let tracklist = facts.tracklist {
            let used = Set(Self.libraryMatches(tracklist, facts.library, official: !facts.library.isEmpty
                && facts.library.allSatisfy(\.fromBandcamp)).values.map(\.path))
            library.removeAll { used.contains($0.path) }
        }
        for have in library {
            songs.append(AlbumSong(id: "have-\(have.path)", number: have.number > 0 ? have.number : nil, disc: max(have.disc, 1),
                                   title: have.title, artist: have.artist, duration: have.duration, state: libraryState(have)))
        }
        // Downloads on their way that no song above is (a bonus track, or no tracklist).
        for download in downloads where !download.replacesExisting {
            guard let state = Self.arrivalState(download), case .arriving = state else { continue }
            songs.append(AlbumSong(id: "download-\(download.id)", number: ReleaseText.songNumber(download.file.name), disc: 1,
                                   title: ReleaseText.songTitle(download.file.name), duration: download.file.duration.map(Double.init),
                                   state: state))
        }
        songs.sort { ($0.disc, $0.number ?? 999) < ($1.disc, $1.number ?? 999) }

        return (Self.albumState(songs, facts: facts), songs)
    }

    private static func albumState(_ songs: [AlbumSong], facts: AlbumFacts) -> AlbumState {
        if let failure = facts.addFailure { return .addFailed(failure) }
        let arriving = songs.filter { if case .arriving = $0.state { true } else { false } }.count
        let have = songs.filter { $0.libraryPath != nil }.count
        if arriving > 0 { return .adding(arrived: have, total: have + arriving + songs.filter { $0.state == .available }.count) }
        if !songs.isEmpty, have == songs.count { return .complete }
        if have > 0 {
            let missing = songs.count - have
            return .partial(missing: missing, canAdd: songs.contains { $0.state == .available })
        }
        if songs.contains(where: { $0.state == .available }) { return .available }
        switch facts.copies {
        case .noSoulseek: return .noSoulseek
        case .looking, .notAsked: return .looking
        case .found: return .unavailable
        }
    }

    /// A download's state on the page: on its way, given up on, or (finished, its song not in the
    /// library here yet) going in. Nil for one cancelled.
    private static func arrivalState(_ download: AlbumFacts.Download) -> AlbumSong.State? {
        switch download.state {
        case .connecting: return .arriving(.connecting(user: download.file.username))
        case .queued(let place): return .arriving(.queued(user: download.file.username, place: place))
        case .starting: return .arriving(.connecting(user: download.file.username))
        case .downloading: return .arriving(.downloading(download.progress ?? 0))
        case .importing, .completed: return .arriving(.importing)
        case .failed(let reason):
            if let at = download.retryAt { return .arriving(.retrying(at: at)) }
            return download.onItsWay ? .arriving(.connecting(user: download.file.username)) : .failed(reason)
        case .cancelled: return nil
        }
    }

    private static func copyState(_ track: ReferenceTrack, files: [RemoteFile], copies: AlbumFacts.Copies) -> AlbumSong.State {
        if MissingTracks.file(for: track, in: files) != nil { return .available }
        switch copies {
        case .looking, .notAsked: return .looking
        default: return .unavailable
        }
    }

    /// Which library song each tracklist song is (by its position in the tracklist), in passes
    /// over the whole album so a looser rule never takes a song a stricter one would give
    /// another: the same title; then one name starting with the other ("Volitant" and
    /// "Volitant (Original Mix)"); then the same place and length; then (a song not read yet,
    /// named after its file) its file name. A Bandcamp purchase goes by place alone.
    static func libraryMatches(_ tracklist: [ReferenceTrack], _ library: [AlbumFacts.LibrarySong],
                               official: Bool) -> [Int: AlbumFacts.LibrarySong] {
        var left = library
        var result: [Int: AlbumFacts.LibrarySong] = [:]
        func pass(_ matches: (ReferenceTrack, AlbumFacts.LibrarySong) -> Bool) {
            for (position, track) in tracklist.enumerated() where result[position] == nil {
                if let index = left.firstIndex(where: { matches(track, $0) }) { result[position] = left.remove(at: index) }
            }
        }
        let folded = { (song: AlbumFacts.LibrarySong) in ReleaseText.fold(ReleaseText.cleanTitle(song.title)) }
        if official {
            pass { track, song in song.number == track.number && max(song.disc, 1) == track.disc }
        }
        pass { track, song in track.matchTitles.contains(folded(song)) }
        pass { track, song in
            let have = folded(song)
            return have.count >= 4 && track.matchTitles.contains { $0.hasPrefix(have + " ") || have.hasPrefix($0 + " ") }
        }
        pass { track, song in
            song.number == track.number && max(song.disc, 1) == track.disc && track.duration.map { abs($0 - song.duration) < 3 } == true
        }
        pass { track, song in
            MissingTracks.file(for: track, in: [RemoteFile(username: "", path: (song.path as NSString).lastPathComponent, size: 0)]) != nil
        }
        return result
    }

    /// A library song and a download are the same song (for a replacement on its way).
    private static func sameSong(_ song: AlbumFacts.LibrarySong, _ file: RemoteFile) -> Bool {
        let track = ReferenceTrack(number: song.number, disc: max(song.disc, 1), title: song.title,
                                   duration: song.duration > 0 ? song.duration : nil)
        return MissingTracks.file(for: track, in: [file]) != nil
    }

    /// This song's download, from whichever copy: one on its way first, then one finished,
    /// then one that failed.
    private static func downloadMatch(for track: ReferenceTrack, in downloads: [AlbumFacts.Download]) -> Int? {
        func rank(_ download: AlbumFacts.Download) -> Int {
            if download.onItsWay { return 0 }
            if download.state == .completed || download.state == .importing { return 1 }
            return 2
        }
        let candidates = downloads.indices.filter { !downloads[$0].replacesExisting && downloads[$0].state != .cancelled }
            .sorted { rank(downloads[$0]) < rank(downloads[$1]) }
        guard let file = MissingTracks.file(for: track, in: candidates.map { downloads[$0].file }) else { return nil }
        return candidates.first { downloads[$0].file.id == file.id }
    }
}

// MARK: - From the app

@MainActor
extension AlbumFacts {
    /// What the app knows about an album right now. `folders`: its copies on Soulseek as the
    /// page knows them (a search result's, or the copy finder's); `searching` while they're
    /// still being looked for.
    static func current(for key: AlbumKey, library: LibraryStore, client: SoulseekClient, references: AlbumReferences,
                        adder: AlbumAdder?, folders: [RemoteFolder]?, searching: Bool) -> AlbumFacts {
        let album = library.albumsByKey[key] ?? Album(key: key, tracks: [])
        var facts = AlbumFacts()
        facts.tracklist = references.cached(key)?.tracks
        facts.library = album.tracks.map { track in
            LibrarySong(path: track.path, title: track.title, number: track.trackNumber, disc: track.discNumber,
                        duration: track.duration, artist: track.artist == album.artist ? nil : track.artist,
                        fromMac: library.fromMac.contains(track.path), fromBandcamp: track.sourceURL.contains("bandcamp.com"))
        }
        // This album's downloads: added as it, from a folder named for it, or from one of its copies.
        let folderIDs = Set((folders ?? []).map(\.id))
        facts.downloads = client.transfers
            .filter { transfer in
                !transfer.forStreaming && transfer.state != .cancelled
                    && (AlbumRows.isFor(album, transfer) || folderIDs.contains("\(transfer.username)\u{0}\(transfer.file.folder)"))
                    && (transfer.state != .completed || client.isDone(transfer))
            }
            .map { transfer in
                Download(id: transfer.id, file: transfer.file, state: transfer.state, progress: transfer.ringProgress,
                         retryAt: transfer.retryAt, onItsWay: client.isOnItsWay(transfer), replacesExisting: transfer.replacesExisting)
            }
        if !client.canUseSoulseek {
            facts.copies = .noSoulseek
        } else if let folders, !folders.isEmpty {
            facts.copies = .found(folders.map(client.complete).flatMap(\.files))
        } else {
            facts.copies = searching ? .looking : (folders == nil ? .notAsked : .found([]))
        }
        facts.addFailure = adder?.stopReason(key)
        return facts
    }
}
