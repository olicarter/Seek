import Foundation
import Observation

/// Seek on the person's Mac, doing this iPhone's or iPad's Soulseek work while it's reachable:
/// searching, listing folders, downloading (into the iCloud library both share) and fetching
/// songs to play. The Mac never sleeps the way iOS suspends apps, so waiting in other people's
/// queues and moving to other copies carries on with the app closed. When the Mac can't be
/// reached, the device signs in to Soulseek itself, as before.
///
/// The Mac puts its address and a key in iCloud Keychain (see AppKey), so only the person's own
/// devices find it; friends' never do and keep using Soulseek themselves.
@MainActor
@Observable
final class MacLink {
    enum State: Equatable {
        /// No Mac in iCloud Keychain.
        case none
        case unreachable
        case available
    }

    private(set) var state = State.none
    private(set) var address: URL?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private weak var client: SoulseekClient?
    @ObservationIgnored private var mirroring: Task<Void, Never>?
    @ObservationIgnored private var seenFailures: Set<UUID> = []
    @ObservationIgnored private var lastCheck = Date.distantPast

    init(client: SoulseekClient) {
        self.client = client
        load()
    }

    var host: String? { address?.host() }

    private func load() {
        var found = KeychainItem(service: MacLinkWire.keychainService).load()
        #if DEBUG
        // The simulator has no iCloud Keychain: -SeekMacAddress <url> -SeekMacKey <key>.
        if found == nil, let address = UserDefaults.standard.string(forKey: "SeekMacAddress"),
           let key = UserDefaults.standard.string(forKey: "SeekMacKey") {
            found = (address, Data(key.utf8))
        }
        #endif
        guard let (account, data) = found,
              let url = URL(string: account), let key = String(data: data, encoding: .utf8) else {
            address = nil
            key = nil
            state = .none
            return
        }
        address = url
        self.key = key
    }

    /// Whether the Mac answers now; at most every 20 seconds unless `force`.
    func check(force: Bool = false) async {
        guard force || Date.now.timeIntervalSince(lastCheck) > 20 else { return }
        lastCheck = .now
        load()
        guard address != nil else {
            client?.useMac(nil)
            return
        }
        let answered = (try? await get("/api/app/ping", timeout: 5) as [String: String]) != nil
        state = answered ? .available : .unreachable
        client?.useMac(answered ? self : nil)
        if answered { startMirroring() }
    }

    /// The Mac stopped answering mid-request: back to this device's own Soulseek.
    private func lost() {
        guard state == .available else { return }
        state = .unreachable
        client?.useMac(nil)
    }

    // MARK: - Soulseek, on the Mac

    /// A search, with what's been found so far as it comes in. `onGrouped`: the Mac groups the
    /// results into releases too (for the Search tab), so this device needn't.
    func search(_ query: String, seconds: Int, onUpdate: (([RemoteFolder]) async -> Bool)? = nil,
                onGrouped: ((ReleaseGrouper.Result) -> Void)? = nil) async -> [RemoteFolder]? {
        struct Body: Encodable { var query: String; var seconds: Int; var group: Bool }
        guard let started: [String: String] = try? await post("/api/app/search", Body(query: query, seconds: seconds, group: onGrouped != nil)),
              let id = started["id"] else { return nil }
        var reported = -1
        var lastGrouped: ReleaseGrouper.Result?
        // Grouping keeps going a moment after Soulseek goes quiet (Bandcamp, Apple's catalogue).
        var settled = 0
        for _ in 0..<(seconds + 20) {
            try? await Task.sleep(for: .seconds(1))
            guard let found: MacLinkWire.Search = try? await get("/api/app/search?id=\(id)") else { continue }
            if let grouped = found.grouped, grouped != lastGrouped {
                lastGrouped = grouped
                onGrouped?(grouped)
                settled = 0
            } else if found.done {
                settled += 1
            }
            if found.folders.count != reported {
                reported = found.folders.count
                if let onUpdate, await onUpdate(found.folders) { return found.folders }
            }
            if found.done, onGrouped == nil || settled >= 3 { return found.folders }
        }
        return nil
    }

    func contents(of folder: RemoteFolder) async throws -> [RemoteFile] {
        try await post("/api/app/contents", ["folder": folder])
    }

    func download(_ files: [RemoteFile], in folder: RemoteFolder, album: AlbumKey?, others: [RemoteFolder], group: UUID?) async {
        let _: [String: Bool]? = try? await post("/api/app/download",
                                                 MacLinkWire.Download(files: files, folder: folder, album: album, others: others, group: group))
        startMirroring()
    }

    func download(_ folder: RemoteFolder) async {
        let _: [String: Bool]? = try? await post("/api/app/download-folder", ["folder": folder])
        startMirroring()
    }

    func download(_ file: RemoteFile) async {
        let _: [String: Bool]? = try? await post("/api/app/download-file", ["file": file])
        startMirroring()
    }

    func act(_ action: String, on transfer: Transfer) async {
        guard let id = transfer.macID else { return }
        let _: [String: Bool]? = try? await post("/api/app/\(action)", ["id": id])
    }

    /// A song to play, fetched by the Mac and sent on as it arrives, into the transfer's partial
    /// file: the player reads it from there as it does any stream.
    func pull(_ transfer: Transfer) {
        guard let data = try? JSONEncoder().encode(transfer.file),
              let request = request("/api/app/stream?file=\(Self.base64url(data))", timeout: 120) else {
            transfer.state = .failed("Seek on the Mac can't be reached")
            return
        }
        transfer.state = .connecting
        let pull = StreamPull(transfer: transfer) { [weak self] transfer, error in
            guard transfer.state != .cancelled else { return }
            if error != nil {
                transfer.state = .failed("Couldn't play it from the Mac")
                return
            }
            transfer.state = .importing
            do {
                try self?.client?.cacheStream?(transfer, transfer.partialURL)
                transfer.state = .completed
            } catch {
                transfer.state = .failed("Couldn't keep it to play")
            }
        }
        pull.start(request)
        pulls[transfer.id] = pull
    }

    @ObservationIgnored private var pulls: [UUID: StreamPull] = [:]

    func stopPull(_ transfer: Transfer) {
        pulls.removeValue(forKey: transfer.id)?.cancel()
    }

    // MARK: - Mirroring downloads

    /// The Mac's downloads, shown here as this device's own, while any are on their way.
    private func startMirroring() {
        guard mirroring == nil else { return }
        mirroring = Task {
            defer { mirroring = nil }
            var idle = 0
            while !Task.isCancelled, state == .available, idle < 20 {
                if let wire: MacLinkWire.Transfers = try? await get("/api/app/transfers") {
                    client?.mirror(wire.transfers)
                    for failure in wire.failedAdds where seenFailures.insert(failure.group).inserted {
                        // Only an add from here (its songs were mirrored), not the Mac's own.
                        if client?.transfers.contains(where: { $0.addGroup == failure.group }) == true {
                            client?.onAddGroupFailed?(failure.album, failure.songs, [])
                        }
                    }
                    idle = wire.transfers.contains { MacLinkWire.decode($0.state, $0.detail).isActive } ? 0 : idle + 1
                } else {
                    idle += 1
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: - Requests

    private func request(_ path: String, timeout: TimeInterval = 20) -> URLRequest? {
        guard let address, let key, let url = URL(string: address.absoluteString.trimmingCharacters(in: ["/"]) + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(key, forHTTPHeaderField: "X-Seek-Key")
        return request
    }

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval = 20) async throws -> T {
        guard let request = request(path, timeout: timeout) else { throw URLError(.badURL) }
        return try await send(request)
    }

    private func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        guard var request = request(path) else { throw URLError(.badURL) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            lost()
            throw error
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A song coming from the Mac, written into its transfer's partial file chunk by chunk as it
/// arrives (for the player, which reads it as it grows).
private final class StreamPull: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transfer: Transfer
    private let done: @MainActor (Transfer, Error?) -> Void
    private var handle: FileHandle?
    private var session: URLSession?
    private var received: UInt64 = 0
    private let started = Date.now

    @MainActor
    init(transfer: Transfer, done: @escaping @MainActor (Transfer, Error?) -> Void) {
        self.transfer = transfer
        self.done = done
    }

    @MainActor
    func start(_ request: URLRequest) {
        FileManager.default.createFile(atPath: transfer.partialURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: transfer.partialURL)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300
        completionHandler(ok ? .allow : .cancel)
        if ok { Task { @MainActor in self.transfer.state = .downloading } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        received += UInt64(data.count)
        let total = received
        let speed = Double(total) / max(Date.now.timeIntervalSince(started), 0.1)
        Task { @MainActor in
            self.transfer.bytesReceived = total
            self.transfer.bytesPerSecond = speed
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        session.finishTasksAndInvalidate()
        let failed = error ?? (received == 0 ? URLError(.zeroByteResource) : nil)
        Task { @MainActor in self.done(self.transfer, failed) }
    }
}

