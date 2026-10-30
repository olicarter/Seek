import AVFoundation
import CryptoKit
import Foundation

/// Library songs played from the Mac while this device's copy hasn't come down from iCloud yet
/// (just added there, say). Each is pulled into a cache here and played as it arrives (through
/// ProgressiveLoader: a FLAC played straight from its address waits for most of the file), so
/// it starts after the first part, and playing it again starts at once. Kept a few days.
@MainActor
final class MacFiles {
    static let shared = MacFiles()

    private let directory = URL.cachesDirectory.appending(path: "Mac Files", directoryHint: .isDirectory)
    private var pulls: [String: Pull] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-3 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < old || file.pathExtension == "partial" { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func cacheURL(for path: String) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).\((path as NSString).pathExtension.lowercased())")
    }

    /// The song to play: the whole file when it was pulled before, otherwise played as it arrives.
    func item(for path: String, from remote: URL) async -> AVPlayerItem? {
        let cached = cacheURL(for: path)
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: cached.path)
            return AVPlayerItem(url: cached)
        }
        let pull = pulls[path] ?? {
            let pull = Pull(from: remote, to: cached) { [weak self] in self?.pulls[path] = nil }
            pulls[path] = pull
            return pull
        }()
        guard let loader = await pull.loader() else { return nil }
        let asset = AVURLAsset(url: loader.playerURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        return AVPlayerItem(asset: asset)
    }

    /// One song coming from the Mac, written to a partial file as it arrives, then moved into the cache.
    private final class Pull: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partial: URL
        private let destination: URL
        private let finished: @MainActor () -> Void
        private let lock = NSLock()
        private var handle: FileHandle?
        private var progressive: ProgressiveLoader?
        private var waiting: [CheckedContinuation<ProgressiveLoader?, Never>] = []
        private var failed = false
        private var session: URLSession?

        @MainActor
        init(from remote: URL, to destination: URL, finished: @escaping @MainActor () -> Void) {
            self.destination = destination
            partial = destination.appendingPathExtension("partial")
            self.finished = finished
            super.init()
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            handle = try? FileHandle(forWritingTo: partial)
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: remote).resume()
        }

        /// The loader, once the Mac has said how big the file is.
        func loader() async -> ProgressiveLoader? {
            await withCheckedContinuation { continuation in
                let ready: ProgressiveLoader?? = lock.withLock {
                    if let progressive { return .some(progressive) }
                    if failed { return .some(nil) }
                    waiting.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        private func answer(_ loader: ProgressiveLoader?) {
            let continuations = lock.withLock { () -> [CheckedContinuation<ProgressiveLoader?, Never>] in
                defer { waiting = [] }
                return waiting
            }
            continuations.forEach { $0.resume(returning: loader) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength > 0 else {
                completionHandler(.cancel)
                return
            }
            let loader = ProgressiveLoader(fileURL: partial, totalSize: response.expectedContentLength,
                                           fileExtension: destination.pathExtension)
            lock.withLock { progressive = loader }
            answer(loader)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { try? handle?.write(contentsOf: data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock {
                try? handle?.close()
                handle = nil
            }
            let loader = lock.withLock { progressive }
            if error == nil, loader != nil, (try? FileManager.default.moveItem(at: partial, to: destination)) != nil {
                loader?.update(fileURL: destination)
            } else {
                Log.debug("player: couldn't get a song from the Mac: \(error?.localizedDescription ?? "no answer")")
                lock.withLock { failed = true }
                loader?.update(failed: true)
                try? FileManager.default.removeItem(at: partial)
                answer(nil)
            }
            session.finishTasksAndInvalidate()
            Task { @MainActor in self.finished() }
        }
    }
}
