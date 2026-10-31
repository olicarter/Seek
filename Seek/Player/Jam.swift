import Foundation

/// Listening together, as Spotify's Jam: one device plays (the speaker) while everyone in the
/// session adds to its queue and, when the host allows, plays, pauses and skips. The Mac keeps
/// the session; guests join from the web with its link, the host from their own devices.
///
/// Every change is one of these functions, so what each person may do is decided in one place.
struct Jam: Codable, Equatable, Sendable {
    struct Person: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var isHost: Bool { id == Jam.host }
    }

    /// A song in the queue: one in the library (by its path), or one streamed from Soulseek.
    struct Song: Codable, Equatable, Sendable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var number: Int = 0
        var disc: Int = 1
        var duration: Double = 0
        /// The cover's address on the Mac, for guests.
        var cover: String?
        var path: String?
        var stream: StreamSource?
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var song: Song
        var addedBy: String
    }

    enum Control: String, Codable, Sendable { case play, pause, next, previous }

    enum Refusal: Error, Equatable {
        /// The host hasn't let guests control playback, or it's someone else's song.
        case notAllowed
        case notFound
        /// The song playing can't be taken out.
        case playing
        case unknownPerson
    }

    /// What the speaker says it's doing, each second or so.
    struct Report: Codable, Equatable, Sendable {
        var item: String?
        var playing: Bool
        var position: Double
        /// The last of the session's commands it has carried out (see `commands`).
        var commands: Int
        /// It played the last song to the end.
        var ended = false
    }

    static let host = "host"
    static let lifetime: TimeInterval = 12 * 3600

    /// The page guests join at: Seek on the web, with the key after the # (so it never reaches
    /// 4n.studio's servers, only the Mac).
    var link: URL { URL(string: "https://4n.studio/seek/web/jam/#jam=\(key)")! }

    /// The secret in the link guests join with.
    var key: String
    var started: Date
    var expires: Date
    var people: [Person]
    var guestsCanControl = true
    /// Every song added, in order: those played, the one playing (`current`), then those to come.
    var items: [Item] = []
    var current: Int?
    var playing = false
    /// The last song finished with nothing after it: the next one added starts straight away.
    var finished = false
    /// Where the speaker was in the song, and when.
    var position: Double = 0
    var positionAt: Date
    /// Bumped by each change the speaker has to carry out (a guest's skip or pause, a song
    /// started by being added). Until the speaker reports it has, what it says is playing
    /// doesn't overrule the session.
    var commands = 0
    /// Bumped when the song playing starts again from the beginning.
    var restarts = 0
    /// Bumped by any change, so pages showing the session refetch.
    var version = 0

    static func start(hostName: String, key: String, now: Date = .now) -> Jam {
        Jam(key: key, started: now, expires: now.addingTimeInterval(lifetime), people: [Person(id: host, name: hostName)], positionAt: now)
    }

    func isExpired(at now: Date = .now) -> Bool { now >= expires }

    var nowPlaying: Item? { current.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    var upNext: ArraySlice<Item> { items[((current ?? -1) + 1)...] }

    func person(_ id: String) -> Person? { people.first { $0.id == id } }

    /// Where the song playing is now, from the speaker's last report.
    func position(at now: Date) -> Double {
        position + (playing ? max(now.timeIntervalSince(positionAt), 0) : 0)
    }

    func canControl(_ person: String) -> Bool { person == Self.host || (guestsCanControl && self.person(person) != nil) }

    // MARK: - Changes

    mutating func join(name: String, id: String) -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let person = Person(id: id, name: trimmed.isEmpty ? "Guest" : String(trimmed.prefix(40)))
        people.append(person)
        version += 1
        return person
    }

    /// To the end of the queue; with nothing playing, it starts.
    mutating func add(_ song: Song, by person: String, id: String, now: Date = .now) throws(Refusal) {
        guard self.person(person) != nil else { throw .unknownPerson }
        items.append(Item(id: id, song: song, addedBy: person))
        if current == nil || finished {
            current = items.count - 1
            playing = true
            finished = false
            position = 0
            positionAt = now
            commands += 1
        }
        version += 1
    }

    /// The host can take out any song to come; guests, their own.
    mutating func remove(_ item: String, by person: String) throws(Refusal) {
        guard let index = items.firstIndex(where: { $0.id == item }) else { throw .notFound }
        guard person == Self.host || items[index].addedBy == person else { throw .notAllowed }
        guard index != current else { throw .playing }
        items.remove(at: index)
        if let at = current, index < at { current = at - 1 }
        version += 1
    }

    /// Moves a song to come to another place among those to come (the host only).
    mutating func move(_ item: String, toUpNext place: Int, by person: String) throws(Refusal) {
        guard person == Self.host else { throw .notAllowed }
        let first = (current ?? -1) + 1
        guard let index = items.firstIndex(where: { $0.id == item }), index >= first else { throw .notFound }
        let moved = items.remove(at: index)
        items.insert(moved, at: min(first + max(place, 0), items.count))
        version += 1
    }

    mutating func control(_ control: Control, by person: String, now: Date = .now) throws(Refusal) {
        guard canControl(person) else { throw .notAllowed }
        let at = position(at: now)
        switch control {
        case .play:
            guard current != nil else { return }
            if finished {
                // Played to the end: from the top of the last song again.
                finished = false
                restarts += 1
                position = 0
            } else {
                position = at
            }
            playing = true
        case .pause:
            position = at
            playing = false
        case .next:
            guard let index = current else { return }
            if index + 1 < items.count {
                current = index + 1
                playing = true
            } else {
                playing = false
                finished = true
            }
            position = 0
        case .previous:
            guard let index = current else { return }
            if at > 3 || index == 0 {
                restarts += 1
            } else {
                current = index - 1
            }
            finished = false
            position = 0
        }
        positionAt = now
        commands += 1
        version += 1
    }

    mutating func setGuestsCanControl(_ allowed: Bool, by person: String) throws(Refusal) {
        guard person == Self.host else { throw .notAllowed }
        guestsCanControl = allowed
        version += 1
    }

    /// What the speaker is doing. Once it has carried out every command, it's what's happening
    /// (the host skipping on the speaker itself, a song ending); before then only where it is in
    /// the song counts.
    mutating func report(_ report: Report, now: Date = .now) {
        let before = self
        // Something outside the session playing (before its first song) changes nothing.
        if report.commands >= commands, let item = report.item, let index = items.firstIndex(where: { $0.id == item }) {
            current = index
            playing = report.playing
            if report.ended {
                playing = false
                finished = true
            } else if report.playing {
                finished = false
            }
        }
        if report.item == nowPlaying?.id {
            position = report.position
            positionAt = now
        }
        if before.current != current || before.playing != playing || before.finished != finished { version += 1 }
    }
}

extension Jam.Song {
    init(_ track: Track) {
        self.init(title: track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title,
                  artist: track.displayArtist, album: track.displayAlbum, albumArtist: track.albumKey.artist,
                  number: track.trackNumber, disc: max(track.discNumber, 1), duration: track.duration,
                  path: track.isStreamed ? nil : track.path, stream: track.stream)
    }
}
