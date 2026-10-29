import Foundation
import Observation

/// One folder from one user, which is how results are usually browsed (roughly an album).
struct RemoteFolder: Identifiable, Hashable, Codable {
    var id: String { "\(username)\u{0}\(path)" }
    let username: String
    let path: String
    var files: [RemoteFile]
    var hasFreeSlot: Bool
    var averageSpeed: UInt32
    var queueLength: UInt32

    var components: [String] { path.split(separator: "\\").map(String.init) }
    var name: String { components.last ?? path }
    var parentName: String? { components.dropLast().last }
    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    /// Lossless only when (nearly) all of it is: folders mixing a few FLACs into MP3s aren't.
    var isLossless: Bool {
        guard !files.isEmpty else { return false }
        return Double(files.filter(\.isLossless).count) >= Double(files.count) * 0.9
    }
    var isHiRes: Bool { isLossless && files.contains(where: \.isHiRes) }
    var soundQuality: SoundQuality { isHiRes ? .max : isLossless ? .high : .low }
    /// The most common file's detail ("16-bit, 44.1 kHz"), with its format.
    var qualityDetail: String {
        let counts = Dictionary(grouping: files.filter { $0.isLossless == isLossless }) {
            [$0.fileExtension.uppercased(), $0.qualityDetail].compactMap { $0 }.joined(separator: " · ")
        }.mapValues(\.count)
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ""
    }

}

@MainActor
@Observable
final class SearchSession: Identifiable {
    let id: UInt32
    let query: String
    let startedAt = Date()
    private(set) var folders: [RemoteFolder] = []
    /// The releases Seek on the Mac grouped these into, when it ran the search (see MacLink).
    var grouped: ReleaseGrouper.Result?
    private(set) var responseCount = 0

    init(token: UInt32, query: String) {
        self.id = token
        self.query = query
    }

    /// What the Mac has found for it so far (see MacLink).
    func replaceFolders(_ found: [RemoteFolder]) {
        folders = found
        responseCount = Set(found.map(\.username)).count
    }

    func add(_ response: SearchResponse) {
        let playable = response.files.filter { AudioFormats.playable.contains($0.fileExtension) }
        guard !playable.isEmpty else { return }
        responseCount += 1
        for (path, files) in Dictionary(grouping: playable, by: \.folder) {
            folders.append(RemoteFolder(
                username: response.username,
                path: path,
                files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                hasFreeSlot: response.hasFreeSlot,
                averageSpeed: response.averageSpeed,
                queueLength: response.queueLength
            ))
        }
    }
}

enum AudioFormats {
    /// Formats AVFoundation can play on iOS.
    static let playable: Set<String> = ["mp3", "flac", "m4a", "aac", "alac", "wav", "aif", "aiff", "caf"]
}
