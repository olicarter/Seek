import Foundation

/// The Mac app playing its own Jam.
@MainActor
final class LocalJamLink: JamLink {
    private let host: JamHost

    init(host: JamHost) {
        self.host = host
    }

    func start(hostName: String, speaker: String, songs: [Jam.Song]) async -> Jam? {
        host.start(hostName: hostName, speaker: speaker, songs: songs)
    }

    func sync(_ report: Jam.Report, device: String) async -> JamAnswer {
        host.report(report, from: device).map(JamAnswer.jam) ?? .ended
    }

    func add(_ song: Jam.Song) async -> Jam? {
        let song = host.withCover(song)
        return try? host.change { try $0.add(song, by: Jam.host, id: UUID().uuidString) }
    }

    func control(_ control: Jam.Control) async { _ = try? host.change { try $0.control(control, by: Jam.host) } }
    func remove(_ item: String) async { _ = try? host.change { try $0.remove(item, by: Jam.host) } }
    func move(_ item: String, toUpNext place: Int) async { _ = try? host.change { try $0.move(item, toUpNext: place, by: Jam.host) } }
    func setGuestsCanControl(_ allowed: Bool) async { _ = try? host.change { try $0.setGuestsCanControl(allowed, by: Jam.host) } }
    func end() async { host.end() }
}
