import Foundation

/// An iPhone or iPad reaching the Jam on the person's Mac.
@MainActor
final class MacJamLink: JamLink {
    private let mac: MacLink

    init(mac: MacLink) {
        self.mac = mac
    }

    private struct Empty: Codable {}
    private struct Start: Encodable { var hostName: String; var speaker: String; var songs: [Jam.Song] }
    private struct Report: Encodable { var report: Jam.Report; var device: String }
    private struct Song: Encodable { var song: Jam.Song }
    private struct Item: Encodable { var id: String }
    private struct Move: Encodable { var id: String; var place: Int }
    private struct Control: Encodable { var action: Jam.Control }
    private struct Settings: Encodable { var guestsCanControl: Bool }

    func start(hostName: String, speaker: String, songs: [Jam.Song]) async -> Jam? {
        await mac.jamRequest("/api/jam/start", Start(hostName: hostName, speaker: speaker, songs: songs)).answer
    }

    func sync(_ report: Jam.Report, device: String) async -> JamAnswer {
        let (jam, status): (Jam?, Int?) = await mac.jamRequest("/api/jam/speaker", Report(report: report, device: device))
        if let jam { return .jam(jam) }
        return status == 404 ? .ended : .unreachable
    }

    func add(_ song: Jam.Song) async -> Jam? { await mac.jamRequest("/api/jam/song", Song(song: song)).answer }

    func control(_ control: Jam.Control) async { let _: (Empty?, Int?) = await mac.jamRequest("/api/jam/control", Control(action: control)) }
    func remove(_ item: String) async { let _: (Empty?, Int?) = await mac.jamRequest("/api/jam/remove", Item(id: item)) }
    func move(_ item: String, toUpNext place: Int) async {
        let _: (Empty?, Int?) = await mac.jamRequest("/api/jam/move", Move(id: item, place: place))
    }
    func setGuestsCanControl(_ allowed: Bool) async {
        let _: (Empty?, Int?) = await mac.jamRequest("/api/jam/settings", Settings(guestsCanControl: allowed))
    }
    func end() async { let _: (Empty?, Int?) = await mac.jamRequest("/api/jam/end", Empty()) }
}
