import Foundation
import Hummingbird
import HTTPTypes
import Observation

/// The Mac's side of listening together (see Jam): the session itself, which device is its
/// speaker, and the pages guests see. Kept in memory: quitting Seek ends it.
@MainActor
@Observable
final class JamHost {
    /// For the key check, which runs outside the routes.
    nonisolated(unsafe) static weak var shared: JamHost?

    private(set) var jam: Jam?
    /// The device playing the session (see JamSpeaker.device).
    private(set) var speaker: String?
    @ObservationIgnored private unowned let core: Core

    init(core: Core) {
        self.core = core
        Self.shared = self
    }

    /// The session, unless it has run out.
    var live: Jam? {
        if let jam, jam.isExpired() { end() }
        return jam
    }

    func start(hostName: String, speaker: String, songs: [Jam.Song]) -> Jam {
        var jam = Jam.start(hostName: hostName, key: Passkeys.base64url(Passkeys.random(24)))
        for song in songs { try? jam.add(withCover(song), by: Jam.host, id: UUID().uuidString) }
        self.jam = jam
        self.speaker = speaker
        Log.debug("jam: started, \(speaker) playing")
        return jam
    }

    func end() {
        guard jam != nil else { return }
        jam = nil
        speaker = nil
        Log.debug("jam: ended")
    }

    func isGuestKey(_ given: String?) -> Bool {
        guard let given, let live else { return false }
        return WebKey.compare(given, live.key)
    }

    /// Changes the session; nil when there's none.
    @discardableResult
    func change(_ body: (inout Jam) throws -> Void) rethrows -> Jam? {
        guard var jam = live else { return nil }
        try body(&jam)
        self.jam = jam
        return jam
    }

    /// The speaker's report; others' are ignored (another of the host's devices looking on).
    func report(_ report: Jam.Report, from device: String) -> Jam? {
        guard var jam = live else { return nil }
        if device == speaker { jam.report(report) }
        self.jam = jam
        return jam
    }

    /// A song guests can see the cover of.
    func withCover(_ song: Jam.Song) -> Jam.Song {
        guard song.cover == nil else { return song }
        var song = song
        song.cover = core.coverPath(AlbumKey(artist: song.albumArtist, title: song.album), size: Covers.tile)
        return song
    }

    /// A song from the web's album page, by the address it plays from there: a library file
    /// (`/files/…`) or a stream (`/api/stream?…`).
    func song(from address: String) async -> Jam.Song? {
        // A "+" in the query is a space (a real one comes as %2B).
        guard let url = URLComponents(string: address.replacingOccurrences(of: "+", with: "%20")) else { return nil }
        if url.path.hasPrefix("/files/") {
            let path = String(url.path.dropFirst("/files/".count))
            guard let track = core.library.track(atPath: path) else { return nil }
            return withCover(Jam.Song(track))
        }
        guard url.path == "/api/stream" else { return nil }
        let get = { (name: String) in url.queryItems?.first { $0.name == name }?.value }
        guard let artist = get("artist"), let title = get("title"), let name = get("song"),
              let track = await core.streamedTrack(artist: artist, title: title, release: get("release"),
                                                   disc: get("disc").flatMap(Int.init) ?? 1,
                                                   number: get("number").flatMap(Int.init) ?? 0, song: name) else { return nil }
        return withCover(Jam.Song(track))
    }

    // MARK: - Pages

    struct Page: Encodable {
        struct Item: Encodable {
            var id: String
            var title: String
            var artist: String
            var album: String
            var albumArtist: String
            var cover: String?
            var duration: Double
            var addedBy: String
            var mine: Bool
        }

        var me: String?
        var isHost: Bool
        var canControl: Bool
        var guestsCanControl: Bool
        var people: [String]
        var nowPlaying: Item?
        var playing: Bool
        var finished: Bool
        var position: Double
        var upNext: [Item]
        var played: [Item]
        /// The link to join, for the host.
        var link: String?
    }

    func page(for person: String?) -> Page? {
        guard let jam = live else { return nil }
        let isHost = person == Jam.host
        func item(_ item: Jam.Item) -> Page.Item {
            Page.Item(id: item.id, title: item.song.title, artist: item.song.artist, album: item.song.album,
                      albumArtist: item.song.albumArtist, cover: item.song.cover, duration: item.song.duration,
                      addedBy: jam.person(item.addedBy)?.name ?? "Someone", mine: item.addedBy == person)
        }
        let played = jam.items[..<(jam.current ?? jam.items.count)]
        return Page(me: person, isHost: isHost, canControl: person.map(jam.canControl) ?? false,
                    guestsCanControl: jam.guestsCanControl, people: jam.people.map(\.name),
                    nowPlaying: jam.nowPlaying.map(item), playing: jam.playing, finished: jam.finished,
                    position: jam.position(at: .now), upNext: jam.upNext.map(item), played: played.suffix(20).map(item),
                    link: isHost ? jam.link.absoluteString : nil)
    }
}

// MARK: - Routes

private struct JoinBody: Decodable { var name: String }
private struct AddBody: Decodable { var file: String }
private struct ItemBody: Decodable { var id: String }
private struct ControlBody: Decodable { var action: Jam.Control }
private struct MoveBody: Decodable { var id: String; var place: Int }
private struct SettingsBody: Decodable { var guestsCanControl: Bool }
private struct StartBody: Decodable { var hostName: String; var speaker: String; var songs: [Jam.Song] }
private struct ReportBody: Decodable { var report: Jam.Report; var device: String }
private struct SongBody: Decodable { var song: Jam.Song }

enum JamRoutes {
    /// Header naming the guest (from joining) on a guest's requests.
    static let guestHeader = HTTPField.Name("X-Seek-Guest")!

    /// What guests may reach with the session's key: the session, and the library and search to
    /// pick songs from. Never the songs' files, downloads, settings or the Mac's accounts.
    static func guestMayUse(_ path: String) -> Bool {
        ["/api/jam", "/api/jam/join", "/api/jam/add", "/api/jam/remove", "/api/jam/control",
         "/api/library", "/api/artist", "/api/album", "/api/cover", "/api/events", "/api/search"].contains(path)
    }

    @MainActor
    static func add(to router: Hummingbird.Router<BasicRequestContext>, core: Core) {
        let host = core.jam

        /// Who's asking: the host (a trusted browser or device), a guest who has joined, or nobody yet.
        func person(_ request: Request) async -> String? {
            if await Access.isTrusted(request) { return Jam.host }
            guard let id = request.headers[guestHeader] else { return nil }
            return await MainActor.run { host.live?.person(id) != nil ? id : nil }
        }

        func page(_ request: Request) async throws -> Response {
            let who = await person(request)
            guard let page = await host.page(for: who) else { throw HTTPError(.notFound, message: "This Jam has ended.") }
            return try json(page)
        }

        func refused(_ refusal: Jam.Refusal) -> HTTPError {
            switch refusal {
            case .notAllowed: HTTPError(.forbidden, message: "The host hasn't allowed that.")
            case .notFound: HTTPError(.notFound, message: "That song isn't in the queue any more.")
            case .playing: HTTPError(.conflict, message: "That song is playing.")
            case .unknownPerson: HTTPError(.unauthorized, message: "Join the Jam first.")
            }
        }

        /// A change by whoever's asking, answered with their page.
        func changing(_ request: Request, _ body: @escaping @Sendable @MainActor (inout Jam, String) throws -> Void) async throws -> Response {
            guard let who = await person(request) else { throw refused(.unknownPerson) }
            do {
                let changed = try await MainActor.run { try host.change { jam in try body(&jam, who) } }
                guard changed != nil else { throw HTTPError(.notFound, message: "This Jam has ended.") }
            } catch let refusal as Jam.Refusal {
                throw refused(refusal)
            }
            return try await page(request)
        }

        router.get("/api/jam") { request, _ in try await page(request) }

        router.post("/api/jam/join") { request, context in
            let body = try await request.decode(as: JoinBody.self, context: context)
            let id = UUID().uuidString
            let joined = await MainActor.run { () -> Bool in
                (try? host.change { jam in _ = jam.join(name: body.name, id: id) }) != nil
            }
            guard joined else { throw HTTPError(.notFound, message: "This Jam has ended.") }
            return try json(["guest": id])
        }

        router.post("/api/jam/add") { request, context in
            let body = try await request.decode(as: AddBody.self, context: context)
            guard let song = await host.song(from: body.file) else { throw HTTPError(.notFound, message: "That song can't be played right now.") }
            return try await changing(request) { jam, who in try jam.add(song, by: who, id: UUID().uuidString) }
        }

        router.post("/api/jam/remove") { request, context in
            let body = try await request.decode(as: ItemBody.self, context: context)
            return try await changing(request) { jam, who in try jam.remove(body.id, by: who) }
        }

        router.post("/api/jam/control") { request, context in
            let body = try await request.decode(as: ControlBody.self, context: context)
            return try await changing(request) { jam, who in try jam.control(body.action, by: who) }
        }

        // The host's own (trusted only: guests' keys don't reach these, see RequireKey).

        router.post("/api/jam/move") { request, context in
            let body = try await request.decode(as: MoveBody.self, context: context)
            return try await changing(request) { jam, who in try jam.move(body.id, toUpNext: body.place, by: who) }
        }

        router.post("/api/jam/settings") { request, context in
            let body = try await request.decode(as: SettingsBody.self, context: context)
            return try await changing(request) { jam, who in try jam.setGuestsCanControl(body.guestsCanControl, by: who) }
        }

        router.post("/api/jam/end") { _, _ in
            await host.end()
            return try json(["ok": true])
        }

        // The host's devices: the session in full (with the copies streamed songs play from).

        router.post("/api/jam/start") { request, context in
            let body = try await request.decode(as: StartBody.self, context: context)
            return try json(await host.start(hostName: body.hostName, speaker: body.speaker, songs: body.songs))
        }

        router.post("/api/jam/speaker") { request, context in
            let body = try await request.decode(as: ReportBody.self, context: context)
            guard let jam = await host.report(body.report, from: body.device) else { throw HTTPError(.notFound) }
            return try json(jam)
        }

        router.post("/api/jam/song") { request, context in
            let body = try await request.decode(as: SongBody.self, context: context)
            let song = await host.withCover(body.song)
            let changed = try? await MainActor.run { try host.change { jam in try jam.add(song, by: Jam.host, id: UUID().uuidString) } }
            guard let changed = changed ?? nil else { throw HTTPError(.notFound) }
            return try json(changed)
        }
    }
}
