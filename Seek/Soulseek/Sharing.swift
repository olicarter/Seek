import Foundation
import Network
import Observation

/// One library file as other Soulseek users see it.
struct SharedFile: Sendable, Equatable {
    /// "Seek\Artist\Album\01 Song.flac": Soulseek paths use backslashes.
    var virtualPath: String
    /// Where it is in the library.
    var libraryPath: String
    var size: UInt64
    var duration: Int?
    var bitrate: Int?
    var sampleRate: Int?
    var bitDepth: Int?

    var name: String { String(virtualPath.split(separator: "\\").last ?? "") }
    var folder: String { virtualPath.split(separator: "\\").dropLast().joined(separator: "\\") }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isLossless: Bool { ["flac", "wav", "aiff", "aif", "alac"].contains(fileExtension) }
}

/// The library as a list of shared folders, and the messages that describe it to peers.
struct ShareIndex: Sendable {
    static let root = "Seek"

    let files: [String: SharedFile]
    /// Folder → its files, folders and files in order.
    let folders: [(name: String, files: [SharedFile])]

    var folderCount: Int { folders.count }
    var fileCount: Int { files.count }

    static let empty = ShareIndex(files: [])

    init(files list: [SharedFile]) {
        files = Dictionary(list.map { ($0.virtualPath, $0) }, uniquingKeysWith: { first, _ in first })
        folders = Dictionary(grouping: list, by: \.folder)
            .map { (name: $0.key, files: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func virtualPath(forLibraryPath path: String) -> String {
        ([root] + path.split(separator: "/").map(String.init)).joined(separator: "\\")
    }

    // MARK: - Messages

    /// SharedFileListResponse (peer code 5): every folder and file, zlib-compressed.
    func fileList() throws -> Data {
        var body = MessageWriter()
        body.uint32(UInt32(folders.count))
        for folder in folders { Self.write(folder.name, folder.files, into: &body) }
        body.uint32(0) // unknown field
        body.uint32(0) // private folders
        return try Zlib.deflate(body.data)
    }

    /// FolderContentsResponse (peer code 37) for one folder and any folders inside it.
    func folderContents(token: UInt32, folder: String) throws -> Data {
        let matching = folders.filter { $0.name == folder || $0.name.hasPrefix(folder + "\\") }
        var body = MessageWriter()
        body.uint32(token)
        body.string(folder)
        body.uint32(UInt32(matching.count))
        for entry in matching { Self.write(entry.name, entry.files, into: &body) }
        return try Zlib.deflate(body.data)
    }

    private static func write(_ folder: String, _ files: [SharedFile], into body: inout MessageWriter) {
        body.string(folder)
        body.uint32(UInt32(files.count))
        for file in files {
            body.uint8(1)
            body.string(file.name)
            body.uint64(file.size)
            body.string(file.fileExtension)
            var attributes: [(UInt32, UInt32)] = []
            if let duration = file.duration { attributes.append((1, UInt32(duration))) }
            if file.isLossless {
                if let sampleRate = file.sampleRate { attributes.append((4, UInt32(sampleRate))) }
                if let bitDepth = file.bitDepth { attributes.append((5, UInt32(bitDepth))) }
            } else if let bitrate = file.bitrate {
                attributes.insert((0, UInt32(bitrate)), at: 0)
            }
            body.uint32(UInt32(attributes.count))
            for (code, value) in attributes {
                body.uint32(code)
                body.uint32(value)
            }
        }
    }
}

/// Shares the library on Soulseek: keeps the share index current, reports its size, and finds
/// the files people ask for. Uploads only happen while Seek is running (iOS suspends it
/// otherwise); files only in iCloud are fetched for an upload on Wi-Fi only.
@MainActor
@Observable
final class SharingService {
    static let enabledKey = "shareLibrary"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    private(set) var index = ShareIndex.empty
    /// Called when what's shared changes, so the server can be told.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var onWiFi = false
    @ObservationIgnored private var rebuild: Task<Void, Never>?

    init(library: LibraryStore) {
        self.library = library
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.onWiFi = unmetered }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// What peers see: the full index when sharing is on, nothing when it's off.
    var shared: ShareIndex { isEnabled ? index : .empty }

    /// Rebuilds the index from the library, a moment after it stops changing.
    func libraryChanged() {
        rebuild?.cancel()
        rebuild = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let files = library.sharedFiles()
            let built = await Task.detached { ShareIndex(files: files) }.value
            guard !Task.isCancelled else { return }
            let changed = built.fileCount != index.fileCount || built.folderCount != index.folderCount
            index = built
            if changed { onChange?() }
        }
    }

    /// The local file for an upload, fetching it from iCloud if needed and on Wi-Fi.
    func localFile(for file: SharedFile) async -> URL? {
        guard let url = library.url(forPath: file.libraryPath) else { return nil }
        if library.isOnDevice(file.libraryPath) { return url }
        guard onWiFi else { return nil }
        return await library.ensureLocal(url) ? url : nil
    }
}
