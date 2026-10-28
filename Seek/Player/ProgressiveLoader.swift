import AVFoundation
import UniformTypeIdentifiers

/// Feeds the player a file that's still downloading. The player asks for byte ranges; whatever
/// has arrived is sent straight away, and the rest is waited for, so playback can start once
/// the first part is in and simply pauses if it ever catches up with the download.
final class ProgressiveLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "seekstream"

    private let lock = NSLock()
    /// Where the bytes are now: the partial download, then the cache once it's moved there.
    private var fileURL: URL
    private var failed = false
    private var cancelled = Set<ObjectIdentifier>()
    private let totalSize: Int64
    private let contentType: String
    let queue = DispatchQueue(label: "dev.olicarter.seek.progressive", attributes: .concurrent)

    /// The address the player is given; its extension tells AVFoundation the format.
    let playerURL: URL

    init(fileURL: URL, totalSize: Int64, fileExtension: String) {
        self.fileURL = fileURL
        self.totalSize = totalSize
        contentType = Self.contentType(for: fileExtension)
        playerURL = URL(string: "\(Self.scheme)://stream/\(UUID().uuidString).\(fileExtension)")!
    }

    static func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "flac": "org.xiph.flac"
        case "mp3": UTType.mp3.identifier
        case "m4a", "alac": UTType.mpeg4Audio.identifier
        case "aac": UTType.mpeg4Audio.identifier
        case "wav": UTType.wav.identifier
        case "aif", "aiff": UTType.aiff.identifier
        default: UTType.audio.identifier
        }
    }

    /// The file moved (e.g. into the cache) or the download gave up for good.
    func update(fileURL: URL? = nil, failed: Bool = false) {
        lock.withLock {
            if let fileURL { self.fileURL = fileURL }
            if failed { self.failed = true }
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let request = UncheckedRequest(request: loadingRequest)
        Task.detached { await self.serve(request.request) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        _ = lock.withLock { cancelled.insert(ObjectIdentifier(loadingRequest)) }
    }

    // MARK: - Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = totalSize
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        var offset = dataRequest.currentOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? totalSize
            : min(totalSize, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        let id = ObjectIdentifier(request)
        while offset < end {
            guard let chunk = await chunk(at: offset, upTo: end, isCancelled: { self.lock.withLock { self.cancelled.contains(id) } }) else {
                if !lock.withLock({ cancelled.contains(id) }) { request.finishLoading(with: URLError(.networkConnectionLost)) }
                return
            }
            dataRequest.respond(with: chunk)
            offset += Int64(chunk.count)
        }
        request.finishLoading()
    }

    /// The file's size once it's all here.
    var size: Int64 { totalSize }

    /// The next bytes from `offset` (up to `end`, at most 256 KB), waiting for them to arrive:
    /// for the player here, and for the server sending the song to a browser. Nil once the
    /// download gives up for good, or the reader no longer wants them.
    func chunk(at offset: Int64, upTo end: Int64, isCancelled: @Sendable () -> Bool = { false }) async -> Data? {
        while true {
            let (url, failed) = lock.withLock { (fileURL, self.failed) }
            if failed || isCancelled() { return nil }
            if let chunk = Self.read(url, from: offset, upTo: min(end, offset + 256 * 1024)), !chunk.isEmpty { return chunk }
            // Not here yet; the download is still on its way.
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Bytes from `offset` up to `end` that have arrived so far.
    static func read(_ url: URL, from offset: Int64, upTo end: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), Int64(size) > offset else { return nil }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: Int(min(end, Int64(size)) - offset))
    }
}

/// Loading requests aren't Sendable, but AVFoundation lets them be answered from any thread.
private struct UncheckedRequest: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}
