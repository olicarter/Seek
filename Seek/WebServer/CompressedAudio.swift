import AVFoundation
import CryptoKit
import Foundation

/// AAC copies of library songs for browsers on slow connections: a 24-bit FLAC needs well over
/// a megabit a second, more than some connections through Funnel keep up (playback stalls for
/// seconds at a time); AAC needs about 128 kbit/s. Made from the file the first time it's asked
/// for, kept a week.
actor CompressedAudio {
    static let shared = CompressedAudio()

    private let directory = URL.cachesDirectory.appending(path: "Seek Server/aac", directoryHint: .isDirectory)
    private var making: [String: Task<URL?, Never>] = [:]

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Copies not played for a week go.
        let old = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentAccessDateKey])) ?? []
        for file in files {
            let used = (try? file.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            if used < old { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The AAC copy of a song's file, made now if there isn't one. Nil when it can't be made.
    func copy(of source: URL) async -> URL? {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        // Named for the file and its version, so a changed file gets a new copy.
        let identity = "\(source.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let name = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let output = directory.appending(path: "\(name).m4a")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        if let task = making[name] { return await task.value }
        let task = Task<URL?, Never> {
            let asset = AVURLAsset(url: source)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
            let partial = output.deletingPathExtension().appendingPathExtension("partial.m4a")
            try? FileManager.default.removeItem(at: partial)
            do {
                try await session.export(to: partial, as: .m4a)
                try FileManager.default.moveItem(at: partial, to: output)
                return output
            } catch {
                Log.debug("web: couldn't compress \(source.lastPathComponent): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: partial)
                return nil
            }
        }
        making[name] = task
        let result = await task.value
        making[name] = nil
        return result
    }
}
