import Foundation
import Observation

/// How a device reaches the Mac's Jam (see JamHost): in the Mac app itself, or from an iPhone
/// or iPad through MacLink.
@MainActor
protocol JamLink: AnyObject {
    func start(hostName: String, speaker: String, songs: [Jam.Song]) async -> Jam?
    func sync(_ report: Jam.Report, device: String) async -> JamAnswer
    func add(_ song: Jam.Song) async -> Jam?
    func control(_ control: Jam.Control) async
    func remove(_ item: String) async
    func move(_ item: String, toUpNext place: Int) async
    func setGuestsCanControl(_ allowed: Bool) async
    func end() async
}

enum JamAnswer {
    case jam(Jam)
    /// The Mac has no session (ended, or the Mac app restarted).
    case ended
    case unreachable
}

/// This device playing a Jam: its player follows the session (what's playing, paused or not, the
/// queue) and says each second what it's doing, so the host's own skips and songs ending reach
/// everyone. Songs the host queues here go into the session instead of only this device's queue.
@MainActor
@Observable
final class JamSpeaker {
    private(set) var jam: Jam?
    /// Starting or ending, for the buttons.
    private(set) var isBusy = false
    private(set) var problem: String?
    @ObservationIgnored var link: JamLink?
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var tracks: [String: Track] = [:]
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var restartsApplied = 0
    @ObservationIgnored private var syncing: Task<Void, Never>?

    /// This device, to the Mac: which of the host's devices is the speaker.
    static let device: String = {
        if let saved = UserDefaults.standard.string(forKey: "jamDevice") { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: "jamDevice")
        return made
    }()

    init(player: Player, library: LibraryStore) {
        self.player = player
        self.library = library
        player.jamTakes = { [weak self] track in self?.take(track) ?? false }
        player.jamRemoves = { [weak self] track in self?.remove(track) ?? false }
        player.jamMoves = { [weak self] track, place in self?.move(track, toUpNext: place) ?? false }
    }

    var isActive: Bool { jam != nil }
    var canStart: Bool { link != nil }

    /// What's playing here, and what's queued after it, carry on as the session's first songs.
    func start(hostName: String) async {
        guard let link, jam == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        let seeded = player.current.map { [$0] + Array(player.upNext) } ?? []
        guard let started = await link.start(hostName: hostName, speaker: Self.device, songs: seeded.map(Jam.Song.init)) else {
            problem = "Couldn't reach Seek on your Mac."
            return
        }
        tracks = [:]
        for (item, track) in zip(started.items, seeded) { tracks[item.id] = track }
        applied = started.commands
        restartsApplied = started.restarts
        jam = started
        if !seeded.isEmpty { follow(started, command: false) }
        startSyncing()
    }

    func end() async {
        guard let link else { return }
        isBusy = true
        await link.end()
        isBusy = false
        stopped()
    }

    func control(_ control: Jam.Control) {
        Task { await link?.control(control) }
    }

    func remove(_ item: Jam.Item) {
        Task { await link?.remove(item.id) }
    }

    func setGuestsCanControl(_ allowed: Bool) {
        jam?.guestsCanControl = allowed
        Task { await link?.setGuestsCanControl(allowed) }
    }

    private func stopped() {
        syncing?.cancel()
        syncing = nil
        jam = nil
        tracks = [:]
    }

    private func startSyncing() {
        syncing?.cancel()
        syncing = Task { [weak self] in
            var unreachable = 0
            while !Task.isCancelled {
                guard let self, let link = self.link else { return }
                switch await link.sync(self.report(), device: Self.device) {
                case .jam(let jam):
                    unreachable = 0
                    self.apply(jam)
                case .ended:
                    self.stopped()
                    return
                case .unreachable:
                    // The Mac out of reach a while: the session goes on there, but not here.
                    unreachable += 1
                    if unreachable >= 30 {
                        self.problem = "Lost touch with Seek on your Mac."
                        self.stopped()
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func report() -> Jam.Report {
        let item = player.current.flatMap { current in tracks.first { $0.value === current }?.key }
        return Jam.Report(item: item, playing: player.isPlaying, position: player.currentTime, commands: applied,
                          ended: player.reachedEnd)
    }

    private func apply(_ jam: Jam) {
        self.jam = jam
        let command = jam.commands > applied || jam.restarts != restartsApplied
        follow(jam, command: command)
        applied = jam.commands
        restartsApplied = jam.restarts
    }

    /// The player's queue as the session's; with a command, also what's playing and whether it is.
    private func follow(_ jam: Jam, command: Bool) {
        let list = jam.items.map { track(for: $0) }
        tracks = tracks.filter { id, _ in jam.items.contains { $0.id == id } }
        if command {
            player.follow(list, at: jam.current, playing: jam.playing, restart: jam.restarts != restartsApplied)
        } else {
            player.followQueue(list)
        }
    }

    private func track(for item: Jam.Item) -> Track {
        if let made = tracks[item.id] { return made }
        let song = item.song
        let made: Track
        if let source = song.stream {
            made = Track.streamed(ReferenceTrack(number: song.number, disc: song.disc, title: song.title,
                                                 duration: song.duration > 0 ? song.duration : nil),
                                  artist: song.albumArtist, album: song.album, source: source)
            made.artist = song.artist
        } else if let path = song.path, let have = library.track(atPath: path) {
            made = have
        } else {
            // Added on the Mac and not here yet: played from the Mac meanwhile (see MacFiles).
            made = Track(path: song.path ?? "")
            made.title = song.title
            made.artist = song.artist
            made.albumArtist = song.albumArtist
            made.album = song.album
            made.trackNumber = song.number
            made.discNumber = song.disc
            made.duration = song.duration
            made.hasTags = true
        }
        tracks[item.id] = made
        return made
    }

    // MARK: - The host queueing here

    private func take(_ track: Track) -> Bool {
        guard isActive, let link else { return false }
        Task {
            if let jam = await link.add(Jam.Song(track)) {
                // The song's own object, so it isn't loaded twice.
                if let item = jam.items.last, item.song.title == track.title { tracks[item.id] = track }
                apply(jam)
            }
        }
        return true
    }

    private func remove(_ track: Track) -> Bool {
        guard isActive, let link else { return false }
        guard let id = tracks.first(where: { $0.value === track })?.key else { return true }
        Task { await link.remove(id) }
        return true
    }

    private func move(_ track: Track, toUpNext place: Int) -> Bool {
        guard isActive, let link else { return false }
        guard let id = tracks.first(where: { $0.value === track })?.key else { return true }
        Task { await link.move(id, toUpNext: place) }
        return true
    }
}
