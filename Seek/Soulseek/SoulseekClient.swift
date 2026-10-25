import Foundation
import Network
import Observation
import UIKit

enum PeerError: LocalizedError {
    case offline
    case unreachable
    case notConnected

    var errorDescription: String? {
        switch self {
        case .offline: "User is offline"
        case .unreachable: "Couldn't reach user"
        case .notConnected: "Not connected to Soulseek"
        }
    }
}

struct PeerAddress {
    let host: String
    let port: UInt16
}

/// Talks to the Soulseek server and to peers: login, search, and downloads.
@MainActor
@Observable
final class SoulseekClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    static let serverHost = "server.slsknet.org"
    static let serverPort: UInt16 = 2242

    private(set) var status: Status = .disconnected
    private(set) var username = ""
    private(set) var currentSearch: SearchSession?
    /// Searches made for album pages, kept apart from the Search tab's.
    @ObservationIgnored private var quietSearches: [UInt32: SearchSession] = [:]
    /// Background searches go out one at a time with a gap, since the server drops clients that
    /// search too often. Searches typed in the Search tab go straight away but count too.
    @ObservationIgnored private var lastSearchAt = Date.distantPast
    @ObservationIgnored private var searchQueue: Task<Void, Never>?
    static let backgroundSearchGap: TimeInterval = 15
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private(set) var transfers: [Transfer] = []
    private(set) var listeningPort: UInt16?
    /// Files others are downloading from the library.
    private(set) var uploads: [Upload] = []
    /// What's shared. Set by the app.
    @ObservationIgnored weak var sharing: SharingService?
    @ObservationIgnored private var uploadReplies: [UInt32: CheckedContinuation<String?, Never>] = [:]
    /// One at a time: enough to count as sharing without slowing your own downloads.
    static let uploadSlots = 1

    /// Whole folders fetched from peers, by `RemoteFolder.id`.
    private(set) var folderContents: [String: [RemoteFile]] = [:]
    @ObservationIgnored private var folderWaiters: [UInt32: (path: String, continuation: CheckedContinuation<[RemoteFile], Error>)] = [:]
    @ObservationIgnored private var folderRequests: [String: Task<[RemoteFile], Error>] = [:]

    /// Moves a finished download into the library. Set by the app.
    @ObservationIgnored var importDownload: ((Transfer, URL) async throws -> String?)?
    /// Reserves where a download will go in the library, and keeps or lets go of reservations.
    @ObservationIgnored var reservePath: ((Transfer) -> String?)?
    @ObservationIgnored var keepReserved: ((String) -> Void)?
    @ObservationIgnored var releaseReserved: ((String, _ abandoned: Bool) -> Void)?
    /// Whether a song is (still) in the library, by path.
    @ObservationIgnored var libraryHas: ((String) -> Bool)?
    /// Whether the library folder a download is going to already has that song, from another
    /// copy (by name): the download is then a leftover with nothing to add.
    @ObservationIgnored var libraryHasSong: ((_ fileName: String, _ plannedPath: String) -> Bool)?

    /// Downloaded and still in the library. A finished download whose song was since deleted
    /// doesn't count: adding the album again downloads it again.
    func isDone(_ transfer: Transfer) -> Bool {
        guard transfer.state == .completed else { return false }
        guard let path = transfer.libraryPath else { return true }
        return libraryHas?(path) ?? true
    }
    /// Takes a finished streaming download into the stream cache. Set by the app.
    @ObservationIgnored var cacheStream: ((Transfer, URL) throws -> Void)?
    /// A file already in the stream cache, so adding it to the library needs no second download.
    @ObservationIgnored var cachedFile: ((RemoteFile) -> URL?)?

    @ObservationIgnored private var server: Socket?
    @ObservationIgnored private var serverTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [String: PeerConnection] = [:]
    @ObservationIgnored private var connecting: [String: Task<PeerConnection, Error>] = [:]
    @ObservationIgnored private var addressWaiters: [String: [CheckedContinuation<PeerAddress, Error>]] = [:]
    @ObservationIgnored private var pierceWaiters: [UInt32: CheckedContinuation<Socket, Error>] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var activeTransferCount: Int { transfers.filter { $0.state.isActive && !$0.forStreaming }.count }

    /// Username of the login saved in the keychain, if any.
    private(set) var savedUsername: String? = Credentials.load()?.username

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// After failed sign-ins, automatic ones wait (5 s growing to 5 min), so nothing can flood the
    /// server with attempts; it resets connections from clients that do. Signing in from
    /// Settings isn't held back.
    @ObservationIgnored private var signInFailures = 0
    @ObservationIgnored private var nextSignInAllowed = Date.distantPast
    /// Downloads that failed only for want of a connection; they carry on once signed in.
    @ObservationIgnored private var waitingForConnection: [Transfer] = []
    @ObservationIgnored private var lastSavedTransfers: Data?
    @ObservationIgnored private var saveLoop: Task<Void, Never>?

    private static var transfersURL: URL {
        URL.applicationSupportDirectory.appending(path: "soulseek-transfers.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.transfersURL),
           let saved = try? JSONDecoder().decode([SavedTransfer].self, from: data) {
            // Finished and cancelled ones aren't shown, so they aren't kept past a restart either.
            transfers = saved.filter { $0.outcome != .completed && $0.outcome != .cancelled }.map { $0.restore() }
            lastSavedTransfers = data
        }
    }

    // MARK: - Keeping the list

    /// Picks up downloads that were unfinished when the app last quit (or was updated), from
    /// where they stopped, and keeps the list saved from now on.
    func restoreDownloads() {
        for transfer in transfers where transfer.state != .completed {
            if let path = transfer.plannedPath { keepReserved?(path) }
        }
        for transfer in transfers where transfer.state.isActive {
            requestUpload(transfer)
        }
        // Ones that failed for a reason that may have passed (a dropped connection) get another go.
        for transfer in transfers {
            if case .failed(let reason) = transfer.state, RetryPolicy.delay(after: 0, reason: reason) != nil {
                requestUpload(transfer)
            }
        }
        saveLoop?.cancel()
        saveLoop = Task {
            while !Task.isCancelled {
                saveTransfers()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func saveTransfers() {
        // Streams are only for playing now; they aren't resumed after a restart.
        guard let data = try? JSONEncoder().encode(transfers.filter { !$0.forStreaming }.map(SavedTransfer.init)),
              data != lastSavedTransfers else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.transfersURL, options: .atomic)
        lastSavedTransfers = data
    }
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var visibleSearchViews = 0

    // MARK: - Signing in on use

    // Soulseek allows one session per account, so Seek only stays signed in while it's being
    // used. That lets it live on several devices: whichever one you're using takes over.

    func signIn(username: String, password: String) async {
        await connect(username: username, password: password)
        if status == .connected {
            Credentials.save(username: username, password: password)
            savedUsername = username
        }
    }

    func signOut() {
        disconnect()
        Credentials.clear()
        savedUsername = nil
    }

    /// Signs in with the saved login unless already connected.
    /// Signs in with the saved account unless already signed in. Everyone asking at once shares
    /// one sign-in: each starting their own would close the others' connections.
    func connectIfNeeded() async {
        if status == .connected { return }
        if let connectTask {
            await connectTask.value
            return
        }
        guard Date.now >= nextSignInAllowed, let saved = Credentials.load() else { return }
        let task = Task { await connect(username: saved.username, password: saved.password) }
        connectTask = task
        await task.value
        connectTask = nil
    }

    func searchViewAppeared() {
        visibleSearchViews += 1
        Task { await connectIfNeeded() }
    }

    func searchViewDisappeared() {
        visibleSearchViews = max(visibleSearchViews - 1, 0)
    }

    func appDidEnterBackground() {
        saveTransfers()
        isInBackground = true
        signOutIfIdle()
    }

    func appDidBecomeActive() {
        isInBackground = false
        if visibleSearchViews > 0 || transfers.contains(where: \.state.isActive) {
            Task { await connectIfNeeded() }
        }
    }

    private func signOutIfIdle() {
        guard isInBackground, status == .connected, !transfers.contains(where: \.state.isActive), quietSearches.isEmpty else { return }
        Log.debug("idle in background, signing out of Soulseek")
        disconnect()
    }

    // MARK: - Server

    func connect(username: String, password: String) async {
        disconnect()
        status = .connecting
        let socket = Socket(host: Self.serverHost, port: Self.serverPort)
        do {
            try await socket.open(timeout: 15)
            try await socket.send(Messages.login(username: username, password: password))
            var reader = MessageReader(try await socket.readFrame())
            guard try reader.uint32() == ServerCode.login else {
                throw ProtocolError.unexpected("Unexpected reply from server")
            }
            guard try reader.bool() else {
                throw ProtocolError.unexpected(Self.describeLoginFailure(try reader.string()))
            }
            self.username = username
            server = socket
            status = .connected
            signInFailures = 0
            nextSignInAllowed = .distantPast
            resumeWaitingDownloads()
            try await socket.send(Frame.message(ServerCode.setStatus) { $0.int32(2) })
            let shared = sharing?.shared ?? .empty
            try await socket.send(Frame.message(ServerCode.sharedFoldersFiles) {
                $0.uint32(UInt32(shared.folderCount))
                $0.uint32(UInt32(shared.fileCount))
            })
            startListening()
            serverTasks = [
                Task { await self.readServer(socket) },
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(300))
                        try? await socket.send(Frame.message(ServerCode.ping))
                    }
                },
            ]
        } catch {
            socket.close()
            status = .failed(error.localizedDescription)
            let wait = RetryPolicy.delays[min(signInFailures, RetryPolicy.delays.count - 1)]
            signInFailures += 1
            nextSignInAllowed = Date.now.addingTimeInterval(Double(wait.components.seconds))
            SoulseekEvents.record("sign-in failed: \(error.localizedDescription); next automatic try in \(wait.components.seconds)s")
        }
    }

    func disconnect() {
        serverTasks.forEach { $0.cancel() }
        serverTasks = []
        server?.close()
        server = nil
        listener?.cancel()
        listener = nil
        listeningPort = nil
        peers.values.forEach { $0.close() }
        peers = [:]
        for waiters in addressWaiters.values { waiters.forEach { $0.resume(throwing: PeerError.notConnected) } }
        addressWaiters = [:]
        pierceWaiters.values.forEach { $0.resume(throwing: PeerError.notConnected) }
        pierceWaiters = [:]
        if status != .disconnected, !isFailed { status = .disconnected }
    }

    private var isFailed: Bool {
        if case .failed = status { true } else { false }
    }

    private func readServer(_ socket: Socket) async {
        var reason = "Disconnected from server"
        do {
            while true {
                var reader = MessageReader(try await socket.readFrame())
                let code = try reader.uint32()
                Log.debug("server ← \(code) (\(reader.remaining) bytes)")
                do {
                    try handleServerMessage(code, &reader)
                } catch {
                    // A message we can't parse shouldn't cost us the connection.
                    Log.debug("server message \(code) unparsable: \(error)")
                }
            }
        } catch {
            Log.debug("server read ended: \(error)")
            reason = "Disconnected from server (\(error.localizedDescription))"
        }
        guard server === socket else { return }
        let wasConnected = status == .connected
        disconnect()
        if wasConnected {
            status = .failed(reason)
            SoulseekEvents.record("server dropped: \(reason); searches open \(visibleSearchViews), quiet \(quietSearches.count), active transfers \(transfers.filter(\.state.isActive).count)")
            reconnectIfNeeded()
        }
    }

    /// After an unexpected drop, signs back in (a few tries, spaced out) while something needs
    /// Soulseek: a search on screen, a download, or a background search.
    private func reconnectIfNeeded() {
        guard !isInBackground, reconnectTask == nil else { return }
        reconnectTask = Task {
            defer { reconnectTask = nil }
            for attempt in 1...3 {
                try? await Task.sleep(for: .seconds(3 * attempt))
                let needed = visibleSearchViews > 0 || transfers.contains(where: \.state.isActive) || !quietSearches.isEmpty
                guard needed, !isInBackground, status != .connected else { return }
                await connectIfNeeded()
                SoulseekEvents.record("reconnect attempt \(attempt): \(status == .connected ? "connected" : "failed")")
                if status == .connected { return }
            }
        }
    }

    private func handleServerMessage(_ code: UInt32, _ reader: inout MessageReader) throws {
        switch code {
        case ServerCode.getPeerAddress:
            let user = try reader.string()
            let host = try reader.ipAddress()
            let port = try reader.uint32()
            for waiter in addressWaiters.removeValue(forKey: user) ?? [] {
                if port == 0 || host == "0.0.0.0" {
                    waiter.resume(throwing: PeerError.offline)
                } else {
                    waiter.resume(returning: PeerAddress(host: host, port: UInt16(clamping: port)))
                }
            }
        case ServerCode.connectToPeer:
            let user = try reader.string()
            let type = try reader.string()
            let host = try reader.ipAddress()
            let port = try reader.uint32()
            let token = try reader.uint32()
            Task { await connectBack(to: user, type: type, host: host, port: UInt16(clamping: port), token: token) }
        case ServerCode.relogged:
            Log.debug("server says: relogged elsewhere")
            SoulseekEvents.record("signed in elsewhere (relogged)")
            disconnect()
            status = .failed("Signed in to Soulseek from another device")
        case ServerCode.privateMessage:
            // Seek has no chat, but unacknowledged messages are redelivered on every login.
            let id = try reader.uint32()
            Task { try? await sendToServer(Frame.message(ServerCode.privateMessageAcked) { $0.uint32(id) }) }
        case ServerCode.cantConnectToPeer:
            let token = try reader.uint32()
            pierceWaiters.removeValue(forKey: token)?.resume(throwing: PeerError.unreachable)
        default:
            break
        }
    }

    private func sendToServer(_ data: Data) async throws {
        guard let server else { throw PeerError.notConnected }
        try await server.send(data)
    }

    // MARK: - Search

    /// Searches without touching the Search tab, gathering results for a while and returning
    /// every folder found. Nil when Soulseek isn't available. `onUpdate` sees the folders so far
    /// about once a second as they arrive, and can end the search early by returning true.
    func quietSearch(_ query: String, for duration: Duration = .seconds(12),
                     onUpdate: (([RemoteFolder]) async -> Bool)? = nil) async -> [RemoteFolder]? {
        await waitForSearchSlot()
        await connectIfNeeded()
        guard status == .connected else { return nil }
        lastSearchAt = .now
        let token = Self.makeToken()
        let session = SearchSession(token: token, query: query)
        quietSearches[token] = session
        defer { quietSearches[token] = nil }
        try? await sendToServer(Messages.fileSearch(token: token, query: query))
        let end = ContinuousClock.now + duration
        var reported = 0
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .seconds(1))
            guard let onUpdate, session.folders.count != reported else { continue }
            reported = session.folders.count
            if await onUpdate(session.folders) { break }
        }
        return session.folders
    }

    private func waitForSearchSlot() async {
        let previous = searchQueue
        let slot = Task {
            await previous?.value
            let wait = lastSearchAt.addingTimeInterval(Self.backgroundSearchGap).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            lastSearchAt = .now
        }
        searchQueue = slot
        await slot.value
    }

    func search(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        lastSearchAt = .now
        Task {
            await connectIfNeeded()
            guard status == .connected else { return }
            let token = Self.makeToken()
            currentSearch = SearchSession(token: token, query: query)
            try? await sendToServer(Messages.fileSearch(token: token, query: query))
        }
    }

    func clearSearch() {
        currentSearch = nil
    }

    // MARK: - Downloads

    @discardableResult
    func download(_ file: RemoteFile, replacingExisting: Bool = false) -> Transfer? {
        if let existing = transfers.first(where: { $0.file.id == file.id && !$0.forStreaming }),
           existing.state.isActive || isDone(existing) {
            return existing
        }
        // A finished download of a song since deleted from the library is replaced by this one.
        transfers.removeAll { $0.file.id == file.id && !$0.forStreaming && $0.state == .completed }
        let transfer = Transfer(file: file)
        transfer.replacesExisting = replacingExisting
        transfer.plannedPath = reservePath?(transfer)
        transfers.insert(transfer, at: 0)
        // Being streamed right now: asking the same user for the same file again would leave
        // one request hanging. Follow the stream, then add its copy.
        if let streaming = transfers.first(where: { $0.file.id == file.id && $0.forStreaming && $0.state.isActive }) {
            Task {
                while streaming.state.isActive {
                    transfer.bytesReceived = streaming.bytesReceived
                    if streaming.state == .downloading { transfer.state = .downloading }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard transfer.state != .cancelled else { return }
                if cachedFile?(file) != nil { addCachedCopy(transfer) } else { requestUpload(transfer) }
            }
            return transfer
        }
        // Already streamed: add the cached copy instead of downloading it again.
        if cachedFile?(file) != nil {
            addCachedCopy(transfer)
            return transfer
        }
        requestUpload(transfer)
        return transfer
    }

    /// The library path a download will land at, reserving one if it has none yet (downloads
    /// added before paths were reserved). Nil once it's done or given up.
    func plannedPath(for transfer: Transfer) -> String? {
        if transfer.state == .completed { return transfer.libraryPath }
        guard transfer.state != .cancelled else { return nil }
        if transfer.plannedPath == nil { transfer.plannedPath = reservePath?(transfer) }
        return transfer.plannedPath
    }

    private func addCachedCopy(_ transfer: Transfer) {
        guard let cached = cachedFile?(transfer.file) else { return }
        transfer.state = .importing
        Task {
            do {
                let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(transfer.file.fileExtension)")
                try FileManager.default.copyItem(at: cached, to: copy)
                transfer.bytesReceived = transfer.size
                transfer.libraryPath = try await importDownload?(transfer, copy)
                transfer.state = .completed
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches a file to play: into the stream cache, not the library or the Downloads list.
    /// Returns the transfer to follow (an existing one for the same file if there is one).
    func stream(_ file: RemoteFile) -> Transfer {
        if let existing = transfers.first(where: { $0.file.id == file.id && ($0.state.isActive || $0.forStreaming && $0.state == .completed) }) {
            // Already downloading to the library: play that, and keep a copy for the player when
            // it moves into the library.
            if !existing.forStreaming { existing.alsoStreaming = true }
            return existing
        }
        transfers.removeAll { $0.file.id == file.id && $0.forStreaming }
        let transfer = Transfer(file: file)
        transfer.forStreaming = true
        transfers.append(transfer)
        requestUpload(transfer)
        return transfer
    }

    /// Downloads just these songs from a folder: an album's listed tracks, not its extras.
    func download(_ files: [RemoteFile], in folder: RemoteFolder) {
        for file in files { download(file) }
        var chosen = folder
        chosen.files = files
        share(chosen)
    }

    /// Downloads a whole folder. A search only lists the files that matched, so the rest are
    /// asked for and added once the user replies.
    func download(_ folder: RemoteFolder) {
        for file in folder.files { download(file) }
        Task {
            if let all = try? await contents(of: folder) { for file in all { download(file) } }
            share(complete(folder))
        }
    }

    // MARK: - Sharing

    /// Tells the server how much is shared now; other users' clients check it before letting
    /// you download.
    func shareCountsChanged() {
        guard status == .connected else { return }
        let shared = sharing?.shared ?? .empty
        Task {
            try? await sendToServer(Frame.message(ServerCode.sharedFoldersFiles) {
                $0.uint32(UInt32(shared.folderCount))
                $0.uint32(UInt32(shared.fileCount))
            })
        }
    }

    private func queueUpload(_ path: String, for peer: PeerConnection) {
        guard let file = sharing?.shared.files[path] else {
            Task {
                try? await peer.send(Frame.message(PeerCode.uploadDenied) {
                    $0.string(path)
                    $0.string("File not shared.")
                })
            }
            return
        }
        guard !uploads.contains(where: { $0.username == peer.username && $0.file.virtualPath == path && $0.state.isActive }) else { return }
        uploads.append(Upload(username: peer.username, file: file))
        startUploads()
    }

    private func startUploads() {
        var active = uploads.filter { $0.state == .preparing || $0.state == .sending }.count
        for upload in uploads where upload.state == .queued && active < Self.uploadSlots {
            active += 1
            send(upload)
        }
    }

    private func placeInQueue(of path: String, for user: String) -> Int {
        let waiting = uploads.filter { $0.state == .queued }
        return (waiting.firstIndex { $0.username == user && $0.file.virtualPath == path } ?? 0) + 1
    }

    private func send(_ upload: Upload) {
        upload.state = .preparing
        Task {
            defer { startUploads() }
            do {
                guard let url = await sharing?.localFile(for: upload.file) else {
                    throw ProtocolError.unexpected("Only in iCloud; fetched on Wi-Fi only")
                }
                let peer = try await peerConnection(to: upload.username)
                let token = Self.makeToken()
                // Offer the file; the peer says yes (or why not).
                let refusal: String? = await withCheckedContinuation { continuation in
                    uploadReplies[token] = continuation
                    Task {
                        try? await peer.send(Frame.message(PeerCode.transferRequest) {
                            $0.uint32(1)
                            $0.uint32(token)
                            $0.string(upload.file.virtualPath)
                            $0.uint64(upload.file.size)
                        })
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(30))
                        uploadReplies.removeValue(forKey: token)?.resume(returning: "No reply")
                    }
                }
                if let refusal { throw ProtocolError.unexpected(refusal) }

                let socket = try await fileConnection(to: upload.username)
                defer { socket.close() }
                var init_ = MessageWriter()
                init_.uint32(token)
                try await socket.send(init_.data)
                var offsetReader = MessageReader(try await socket.read(8))
                let offset = try offsetReader.uint64()
                upload.state = .sending
                upload.bytesSent = offset
                try await Self.sendFile(url, from: offset, over: socket) { sent in upload.bytesSent = sent }
                upload.state = .completed
                SoulseekEvents.record("upload of \(upload.file.name) to \(upload.username) finished")
            } catch {
                upload.state = .failed(error.localizedDescription)
                SoulseekEvents.record("upload of \(upload.file.name) to \(upload.username) failed: \(error.localizedDescription)")
                if let peer = peers[upload.username], peer.isOpen {
                    try? await peer.send(Frame.message(PeerCode.uploadFailed) { $0.string(upload.file.virtualPath) })
                }
            }
        }
    }

    /// An "F" connection to a peer for sending a file: direct, or through the server.
    private func fileConnection(to user: String) async throws -> Socket {
        let address = try await address(of: user)
        let direct = Socket(host: address.host, port: address.port)
        do {
            try await direct.open(timeout: 8)
            try await direct.send(Messages.peerInit(username: username, type: "F"))
            return direct
        } catch {
            direct.close()
            return try await indirectConnection(to: user, type: "F")
        }
    }

    nonisolated private static func sendFile(
        _ url: URL, from offset: UInt64, over socket: Socket, progress: @escaping @MainActor (UInt64) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var sent = offset
        var lastReport = Date.distantPast
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try await socket.send(chunk)
            sent += UInt64(chunk.count)
            if Date.now.timeIntervalSince(lastReport) > 0.5 {
                lastReport = .now
                let total = sent
                await progress(total)
            }
        }
        let total = sent
        await progress(total)
    }

    // MARK: - Folder contents

    /// Every playable file in a folder on a peer, asked for once and kept for the session.
    func contents(of folder: RemoteFolder) async throws -> [RemoteFile] {
        if let cached = folderContents[folder.id] { return cached }
        if let pending = folderRequests[folder.id] { return try await pending.value }
        let task = Task { () throws -> [RemoteFile] in
            await connectIfNeeded()
            let peer = try await peerConnection(to: folder.username)
            let token = UInt32.random(in: 1...UInt32.max)
            try await peer.send(Frame.message(PeerCode.folderContentsRequest) {
                $0.uint32(token)
                $0.string(folder.path)
            })
            let files = try await withCheckedThrowingContinuation { continuation in
                folderWaiters[token] = (folder.path, continuation)
                Task {
                    // Peers that don't answer would otherwise keep the request open forever.
                    try? await Task.sleep(for: .seconds(20))
                    if let waiter = folderWaiters.removeValue(forKey: token) {
                        waiter.continuation.resume(throwing: PeerError.unreachable)
                    }
                }
            }
            return files
                .filter { AudioFormats.playable.contains($0.fileExtension) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        folderRequests[folder.id] = task
        defer { folderRequests[folder.id] = nil }
        let files = try await task.value
        if !files.isEmpty { folderContents[folder.id] = files }
        return files.isEmpty ? folder.files : files
    }

    /// The folder with every file in it when that's been fetched, otherwise as the search found it.
    func complete(_ folder: RemoteFolder) -> RemoteFolder {
        guard let files = folderContents[folder.id] else { return folder }
        var folder = folder
        folder.files = files
        return folder
    }

    func isDownloading(_ file: RemoteFile) -> Bool {
        // Songs fetched to play aren't downloads.
        transfers.contains { $0.file.id == file.id && !$0.forStreaming && ($0.state.isActive || isDone($0)) }
    }

    func retry(_ transfer: Transfer) {
        guard !transfer.state.isActive else { return }
        transfer.retryAt = nil
        if let path = transfer.plannedPath { keepReserved?(path) }
        transfer.token = nil
        requestUpload(transfer)
    }

    /// Downloads parked while signed out start again, a few at a time.
    private func resumeWaitingDownloads() {
        let waiting = waitingForConnection
        waitingForConnection = []
        Task {
            for transfer in waiting {
                guard case .failed = transfer.state, transfers.contains(where: { $0 === transfer }) else { continue }
                transfer.token = nil
                requestUpload(transfer)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// One reconnect, once the sign-in cooldown is over, for downloads waiting on it.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !isInBackground else { return }
        reconnectTask = Task {
            defer { reconnectTask = nil }
            while true {
                try? await Task.sleep(for: .seconds(max(nextSignInAllowed.timeIntervalSinceNow, 1)))
                guard !Task.isCancelled, status != .connected, !isInBackground, !waitingForConnection.isEmpty else { return }
                await connectIfNeeded()
                SoulseekEvents.record("reconnect for waiting downloads: \(status == .connected ? "connected" : "failed")")
                if status == .connected { return }
            }
        }
    }

    /// Marks a download failed and, unless the reason won't pass, tries it again by itself after
    /// a growing wait. A download cut off part way carries on from where it stopped. Songs being
    /// streamed aren't retried: the player moves on to another copy.
    private func fail(_ transfer: Transfer, _ reason: String) {
        if takeBack(transfer, reason) { return }
        transfer.state = .failed(reason)
        // The user's gone, has refused, or keeps failing: look for the album from someone else.
        let rescuing = !transfer.forStreaming
            && (reason == PeerError.offline.errorDescription || transfer.retries >= 2 || RetryPolicy.isPermanent(reason))
        if rescuing { rescue(from: transfer) }
        guard !transfer.forStreaming, let delay = RetryPolicy.delay(after: transfer.retries, reason: reason) else {
            transfer.retryAt = nil
            // Given up for good: what was made for the song on its way goes too (unless another
            // copy is being looked for, which takes the song over if it finds one).
            if !rescuing, let path = transfer.plannedPath { releaseReserved?(path, true) }
            return
        }
        transfer.retries += 1
        let at = Date.now.addingTimeInterval(Double(delay.components.seconds))
        transfer.retryAt = at
        Task {
            try? await Task.sleep(for: delay)
            // Not if it was retried by hand, cancelled or removed meanwhile.
            guard case .failed = transfer.state, transfer.retryAt == at, transfers.contains(where: { $0 === transfer }) else { return }
            transfer.retryAt = nil
            SoulseekEvents.record("retrying \(transfer.file.name) from \(transfer.username) (try \(transfer.retries + 1)) after: \(reason)")
            transfer.token = nil
            requestUpload(transfer)
        }
    }

    // MARK: - Finding another copy

    /// Folders (user and path) whose stalled songs are being looked for elsewhere.
    @ObservationIgnored private var rescuing: Set<String> = []
    /// Users already tried and lost for each album, so a second rescue doesn't go back to them.
    @ObservationIgnored private var lostUsers: [String: Set<String>] = [:]

    /// When a user goes offline (or refuses, or keeps failing) partway through an album, finds
    /// the album from someone else and moves the songs still to come over to them. Each keeps
    /// its reserved library path, so favourites and playlist entries made meanwhile stay put.
    private func rescue(from failed: Transfer) {
        let folderPath = failed.file.folder
        let key = "\(failed.username)\u{0}\(folderPath)"
        guard rescuing.insert(key).inserted else { return }
        Task {
            defer { rescuing.remove(key) }
            // Everything from that folder not done yet (one going right now is left to finish).
            let stalled = transfers.filter {
                !$0.forStreaming && $0.username == failed.username && $0.file.folder == folderPath
                    && $0.state != .completed && $0.state != .cancelled && $0.state != .downloading
            }
            guard !stalled.isEmpty else { return }
            let all = transfers.filter { !$0.forStreaming && $0.username == failed.username && $0.file.folder == folderPath }
            let original = RemoteFolder(username: failed.username, path: folderPath, files: all.map(\.file),
                                        hasFreeSlot: true, averageSpeed: 0, queueLength: 0)
            let parsed = FolderParser.parse(original)
            let query = [parsed.artist, ReleaseText.cleanTitle(parsed.title)].compactMap { $0 }.joined(separator: " ")
            let album = ReleaseText.fold(query)
            lostUsers[album, default: []].insert(failed.username)
            SoulseekEvents.record("\(failed.username) stalled on \(stalled.count) songs of \(query); looking for another copy")

            guard let found = await quietSearch(query) else { return }
            let releases = ReleaseGrouper.group(query: query, owned: [], store: [], folders: found).releases
            let lost = lostUsers[album] ?? []
            let candidates = releases
                .filter { release in
                    ReleaseText.titlesMatch(release.title, parsed.title)
                        && (parsed.artist.map { ReleaseText.artistsMatch(release.artist, $0) } ?? true)
                }
                .flatMap(\.folders)
                .filter { !lost.contains($0.username) }
            // The whole album, free to send now, best first.
            let ranked = ReleaseGrouper.sortedBest(candidates.filter(\.hasFreeSlot) + candidates.filter { !$0.hasFreeSlot },
                                                   expectedTracks: all.count)
            for candidate in ranked.prefix(3) {
                let files = (try? await contents(of: candidate)) ?? candidate.files
                let matches = Self.counterparts(of: stalled.map(\.file), in: files)
                let moves = stalled.compactMap { transfer in matches[transfer.file.id].map { (old: transfer, new: $0) } }
                // A copy that has most of what's missing; otherwise try the next.
                guard moves.count * 2 >= stalled.count else { continue }
                SoulseekEvents.record("moving \(moves.count) of \(stalled.count) songs of \(query) to \(candidate.username)")
                for move in moves {
                    // Still waiting? (It may have come back and finished meanwhile.)
                    guard transfers.contains(where: { $0 === move.old }), move.old.state != .completed,
                          move.old.state != .downloading else { continue }
                    self.move(move.old, to: move.new)
                }
                return
            }
            SoulseekEvents.record("no other copy of \(query) found; carrying on with \(failed.username)")
            // Songs that had given up for good, with nowhere else to come from: let them go.
            for transfer in stalled where transfer.retryAt == nil {
                if case .failed = transfer.state, let path = transfer.plannedPath { releaseReserved?(path, true) }
            }
        }
    }

    /// Asks another user for a song instead. It keeps its reserved library path, so favourites
    /// and playlist entries made meanwhile stay put.
    @discardableResult
    private func move(_ old: Transfer, to file: RemoteFile) -> Transfer {
        let replacement = Transfer(file: file)
        replacement.plannedPath = old.plannedPath
        replacement.replacesExisting = old.replacesExisting
        old.plannedPath = nil
        old.retryAt = nil
        old.state = .cancelled
        old.task?.cancel()
        try? FileManager.default.removeItem(at: old.partialURL)
        transfers.removeAll { $0 === old }
        transfers.insert(replacement, at: 0)
        requestUpload(replacement)
        return replacement
    }

    // MARK: - Sharing an album between users

    /// An album coming from one user, with others who have the very same files sending some of
    /// its songs alongside them. Most users send one song at a time, so this goes several times
    /// as fast, and a slow user only holds up the songs they're sending.
    private final class SharedAlbum {
        let owner: String
        let folder: String
        /// Each helper's copy of the owner's songs, keyed by the owner's file id.
        var helpers: [String: [String: RemoteFile]]
        /// Songs lent to helpers, keyed by the helper's transfer: who has it, and the owner's file.
        var lent: [UUID: (helper: String, original: RemoteFile)] = [:]

        init(owner: String, folder: String, helpers: [String: [String: RemoteFile]]) {
            self.owner = owner
            self.folder = folder
            self.helpers = helpers
        }
    }

    @ObservationIgnored private var sharedAlbums: [SharedAlbum] = []
    static let maxHelpers = 2
    /// One song sending and the next asked for, so there's no gap between them.
    static let songsPerHelper = 2

    /// Finds users in the current search with the same rip of an album being downloaded, free
    /// to send now, and lends them songs from it.
    private func share(_ folder: RemoteFolder) {
        let songs = folder.files.filter { AudioFormats.playable.contains($0.fileExtension) }
        guard songs.count >= 4,
              !sharedAlbums.contains(where: { $0.owner == folder.username && $0.folder == folder.path }) else { return }
        let candidates = (currentSearch?.folders ?? [])
            .filter { $0.username != folder.username && $0.hasFreeSlot }
            .sorted { $0.averageSpeed > $1.averageSpeed }
        var helpers: [String: [String: RemoteFile]] = [:]
        for candidate in candidates where helpers[candidate.username] == nil {
            guard let match = SameRip.match(songs, in: complete(candidate).files) else { continue }
            helpers[candidate.username] = match
            if helpers.count == Self.maxHelpers { break }
        }
        guard !helpers.isEmpty else { return }
        let album = SharedAlbum(owner: folder.username, folder: folder.path, helpers: helpers)
        sharedAlbums.append(album)
        SoulseekEvents.record("sharing \(folder.name) from \(folder.username) with \(helpers.keys.sorted().joined(separator: ", "))")
        for helper in helpers.keys { lend(album, to: helper) }
    }

    /// Moves songs the owner hasn't started on to a helper, from the end of the album, since
    /// the owner sends from the start.
    private func lend(_ album: SharedAlbum, to helper: String) {
        guard let copies = album.helpers[helper] else { return }
        while album.lent.values.filter({ $0.helper == helper }).count < Self.songsPerHelper {
            let next = transfers
                .filter {
                    !$0.forStreaming && $0.username == album.owner && $0.file.folder == album.folder
                        && $0.state.isWaiting && copies[$0.file.id] != nil
                }
                .max { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
            guard let next, let copy = copies[next.file.id] else { break }
            SoulseekEvents.record("lending \(next.file.name) to \(helper)")
            let lent = move(next, to: copy)
            album.lent[lent.id] = (helper, next.file)
        }
        if album.lent.isEmpty { sharedAlbums.removeAll { $0 === album } }
    }

    /// A helper finished a song: give them another.
    private func lentSongFinished(_ transfer: Transfer) {
        guard let album = sharedAlbums.first(where: { $0.lent[transfer.id] != nil }),
              let loan = album.lent.removeValue(forKey: transfer.id) else { return }
        lend(album, to: loan.helper)
    }

    /// A helper couldn't send a song: it goes back to the owner, and the helper gets no more.
    /// False when the transfer wasn't lent.
    private func takeBack(_ transfer: Transfer, _ reason: String) -> Bool {
        guard let album = sharedAlbums.first(where: { $0.lent[transfer.id] != nil }),
              let loan = album.lent.removeValue(forKey: transfer.id) else { return false }
        SoulseekEvents.record("\(loan.helper) couldn't send \(transfer.file.name) (\(reason)); back to \(album.owner)")
        album.helpers[loan.helper] = nil
        // Its other lent song too, if it hasn't started.
        for (id, other) in album.lent where other.helper == loan.helper {
            guard let pending = transfers.first(where: { $0.id == id }), pending.state.isWaiting else { continue }
            album.lent[id] = nil
            move(pending, to: other.original)
        }
        move(transfer, to: loan.original)
        if album.lent.isEmpty { sharedAlbums.removeAll { $0 === album } }
        return true
    }

    /// The same songs in another copy of the album: by name ("02 - Artist - Song.flac" and
    /// "2. Song.flac" are the same song), then by track number. Keyed by the original file's id.
    nonisolated static func counterparts(of songs: [RemoteFile], in files: [RemoteFile]) -> [String: RemoteFile] {
        let audio = files.filter { AudioFormats.playable.contains($0.fileExtension) }
        var result: [String: RemoteFile] = [:]
        for song in songs {
            let name = ReleaseText.fold(ReleaseDetailView.trackName(song.name))
            let number = MissingTracks.leadingNumber(song.name)
            if let match = audio.first(where: { ReleaseText.fold(ReleaseDetailView.trackName($0.name)) == name })
                ?? number.flatMap({ n in audio.first { MissingTracks.leadingNumber($0.name) == n } }) {
                result[song.id] = match
            }
        }
        return result
    }

    func cancel(_ transfer: Transfer) {
        guard transfer.state.isActive else { return }
        for album in sharedAlbums { album.lent[transfer.id] = nil }
        transfer.state = .cancelled
        transfer.task?.cancel()
        transfer.socket?.close()
        try? FileManager.default.removeItem(at: transfer.partialURL)
        if let path = transfer.plannedPath { releaseReserved?(path, true) }
        updateBackgroundWork()
    }

    func remove(_ transfer: Transfer) {
        if !transfer.state.isActive, transfer.state != .completed, let path = transfer.plannedPath {
            releaseReserved?(path, true)
        }
        cancel(transfer)
        transfers.removeAll { $0 === transfer }
    }

    /// A song the library got meanwhile from another copy (an album added again from someone
    /// else while the first try was stuck): asking for it again would only add a duplicate.
    private func isLeftover(_ transfer: Transfer) -> Bool {
        guard !transfer.forStreaming, !transfer.replacesExisting, let path = transfer.plannedPath else { return false }
        return libraryHasSong?(transfer.file.name, path) ?? false
    }

    private func requestUpload(_ transfer: Transfer) {
        if isLeftover(transfer) {
            SoulseekEvents.record("dropping \(transfer.file.name) from \(transfer.username): already in the library")
            transfer.state = .cancelled
            transfer.retryAt = nil
            if let path = transfer.plannedPath { releaseReserved?(path, true) }
            transfers.removeAll { $0 === transfer }
            return
        }
        transfer.state = .connecting
        transfer.task = Task {
            do {
                await connectIfNeeded()
                let peer = try await peerConnection(to: transfer.username)
                try await peer.send(Frame.message(PeerCode.queueUpload) { $0.string(transfer.path) })
                if transfer.state == .connecting { transfer.state = .queued(place: nil) }
                try await peer.send(Frame.message(PeerCode.placeInQueueRequest) { $0.string(transfer.path) })
            } catch {
                guard transfer.state == .connecting else { return }
                if status != .connected {
                    // Not this download's fault: it carries on once Soulseek is back.
                    transfer.state = .failed("Waiting for Soulseek")
                    transfer.retryAt = nil
                    if !waitingForConnection.contains(where: { $0 === transfer }) { waitingForConnection.append(transfer) }
                    scheduleReconnect()
                } else {
                    fail(transfer, error.localizedDescription)
                }
                signOutIfIdle()
            }
        }
    }

    private func receiveFile(on socket: Socket, from user: String) async {
        do {
            let token = try await socket.readUInt32()
            guard let transfer = transfers.first(where: {
                $0.username == user && $0.token == token && $0.state.isActive
            }) else {
                socket.close()
                return
            }
            await receive(transfer, over: socket)
        } catch {
            socket.close()
        }
    }

    private func receive(_ transfer: Transfer, over socket: Socket) async {
        transfer.socket = socket
        transfer.state = .downloading
        updateBackgroundWork()
        defer { updateBackgroundWork() }

        let url = transfer.partialURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

        do {
            var writer = MessageWriter()
            writer.uint64(offset)
            try await socket.send(writer.data)
            transfer.bytesReceived = offset
            try await Self.stream(from: socket, to: url, offset: offset, size: transfer.size) { received, speed in
                transfer.bytesReceived = received
                transfer.bytesPerSecond = speed
            }
            socket.close()
            transfer.state = .importing
            if transfer.forStreaming {
                try cacheStream?(transfer, url)
            } else {
                if transfer.alsoStreaming {
                    // The player may be reading this file; it carries on from the cached copy.
                    let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(transfer.file.fileExtension)")
                    if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { try? cacheStream?(transfer, copy) }
                }
                transfer.libraryPath = try await importDownload?(transfer, url)
            }
            transfer.state = .completed
            lentSongFinished(transfer)
        } catch {
            socket.close()
            guard transfer.state != .cancelled else { return }
            SoulseekEvents.record("download from \(transfer.username) cut off at \(transfer.bytesReceived)/\(transfer.size): \(error.localizedDescription)")
            // Users drop connections now and then; it's tried again, carrying on from where it stopped.
            fail(transfer, error.localizedDescription)
        }
    }

    nonisolated private static func stream(
        from socket: Socket,
        to url: URL,
        offset: UInt64,
        size: UInt64,
        progress: @escaping @MainActor (UInt64, Double) -> Void
    ) async throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var received = offset
        var lastReport = Date()
        var lastReportedBytes = offset
        while received < size {
            let chunk = try await socket.readAvailable()
            try handle.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            let now = Date()
            let elapsed = now.timeIntervalSince(lastReport)
            if elapsed > 0.5 || received >= size {
                let speed = Double(received - lastReportedBytes) / max(elapsed, 0.001)
                let total = received
                await progress(total, speed)
                lastReport = now
                lastReportedBytes = received
            }
        }
    }

    private func updateBackgroundWork() {
        let busy = transfers.contains { $0.state == .downloading || $0.state == .importing }
        if busy, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Soulseek downloads") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundWork() }
            }
        } else if !busy {
            endBackgroundWork()
        }
        signOutIfIdle()
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Peers

    /// Returns a "P" connection to a user: direct first, then via the server (firewall piercing).
    private func peerConnection(to user: String) async throws -> PeerConnection {
        if let existing = peers[user], existing.isOpen { return existing }
        if let pending = connecting[user] { return try await pending.value }
        let task = Task { () throws -> PeerConnection in
            let socket: Socket
            do {
                let address = try await address(of: user)
                let direct = Socket(host: address.host, port: address.port)
                do {
                    try await direct.open(timeout: 8)
                    try await direct.send(Messages.peerInit(username: username, type: "P"))
                    socket = direct
                } catch {
                    direct.close()
                    socket = try await indirectConnection(to: user, type: "P")
                }
            }
            let peer = PeerConnection(username: user, socket: socket, client: self)
            peers[user] = peer
            peer.start()
            return peer
        }
        connecting[user] = task
        defer { connecting[user] = nil }
        return try await task.value
    }

    private func address(of user: String) async throws -> PeerAddress {
        try await withCheckedThrowingContinuation { continuation in
            let isFirst = addressWaiters[user] == nil
            addressWaiters[user, default: []].append(continuation)
            guard isFirst else { return }
            Task {
                do {
                    try await sendToServer(Frame.message(ServerCode.getPeerAddress) { $0.string(user) })
                } catch {
                    addressWaiters.removeValue(forKey: user)?.forEach { $0.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                addressWaiters.removeValue(forKey: user)?.forEach { $0.resume(throwing: SocketError.timeout) }
            }
        }
    }

    /// Asks the server to tell the peer to connect to us, then waits for its PierceFireWall.
    private func indirectConnection(to user: String, type: String) async throws -> Socket {
        let token = Self.makeToken()
        return try await withCheckedThrowingContinuation { continuation in
            pierceWaiters[token] = continuation
            Task {
                do {
                    try await sendToServer(Frame.message(ServerCode.connectToPeer) {
                        $0.uint32(token)
                        $0.string(user)
                        $0.string(type)
                    })
                } catch {
                    pierceWaiters.removeValue(forKey: token)?.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(20))
                pierceWaiters.removeValue(forKey: token)?.resume(throwing: PeerError.unreachable)
            }
        }
    }

    /// The peer couldn't reach us, so the server asked us to connect to it instead.
    private func connectBack(to user: String, type: String, host: String, port: UInt16, token: UInt32) async {
        let socket = Socket(host: host, port: port)
        do {
            try await socket.open(timeout: 10)
            try await socket.send(Messages.pierceFirewall(token: token))
            adopt(socket, from: user, type: type)
        } catch {
            socket.close()
            try? await sendToServer(Frame.message(ServerCode.cantConnectToPeer) {
                $0.uint32(token)
                $0.string(user)
            })
        }
    }

    private func adopt(_ socket: Socket, from user: String, type: String) {
        switch type {
        case "P":
            let peer = PeerConnection(username: user, socket: socket, client: self)
            if peers[user]?.isOpen != true { peers[user] = peer }
            peer.start()
        case "F":
            Task { await receiveFile(on: socket, from: user) }
        default:
            socket.close()
        }
    }

    private func startListening(port: UInt16 = 2234) {
        guard port < 2250,
              let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: endpointPort)
        else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(Socket(accepted: connection)) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.listeningPort = port
                    try? await self.sendToServer(Frame.message(ServerCode.setWaitPort) { $0.uint32(UInt32(port)) })
                case .failed:
                    listener.cancel()
                    self.startListening(port: port + 1)
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func accept(_ socket: Socket) {
        socket.startAccepted()
        Task {
            do {
                var reader = MessageReader(try await socket.readFrame(limit: 4096))
                switch try reader.uint8() {
                case PeerInitCode.pierceFirewall:
                    let token = try reader.uint32()
                    if let waiter = pierceWaiters.removeValue(forKey: token) {
                        waiter.resume(returning: socket)
                    } else {
                        socket.close()
                    }
                case PeerInitCode.peerInit:
                    let user = try reader.string()
                    let type = try reader.string()
                    adopt(socket, from: user, type: type)
                default:
                    socket.close()
                }
            } catch {
                socket.close()
            }
        }
    }

    fileprivate func peerClosed(_ peer: PeerConnection) {
        if peers[peer.username] === peer { peers[peer.username] = nil }
    }

    /// A search reply, already unpacked off the main thread.
    fileprivate func handleSearchResponse(_ response: SearchResponse, from peer: PeerConnection) {
        if let search = currentSearch, search.id == response.token {
            search.add(response)
        } else if let search = quietSearches[response.token] {
            search.add(response)
        }
        // Search results arrive on throwaway connections; don't keep them open.
        if !transfers.contains(where: { $0.username == peer.username && $0.state.isActive }) {
            peer.close()
        }
    }

    fileprivate func handlePeerMessage(_ code: UInt32, _ reader: inout MessageReader, from peer: PeerConnection) throws {
        switch code {
        case PeerCode.fileSearchResponse:
            handleSearchResponse(try SearchResponse.parse(compressed: try reader.bytes(reader.remaining)), from: peer)

        case PeerCode.folderContentsResponse:
            let contents = try FolderContents.parse(compressed: try reader.bytes(reader.remaining), username: peer.username)
            // Matched by token, or by folder for clients that don't echo it.
            let token = folderWaiters[contents.token] != nil ? contents.token
                : folderWaiters.first { $0.value.path == contents.folder }?.key
            if let token, let waiter = folderWaiters.removeValue(forKey: token) {
                waiter.continuation.resume(returning: contents.files)
            }

        case PeerCode.transferRequest:
            let direction = try reader.uint32()
            let token = try reader.uint32()
            let path = try reader.string()
            guard direction == 1 else { return }
            let size = reader.remaining >= 8 ? try reader.uint64() : nil
            let transfer = transfers.first {
                $0.username == peer.username && $0.path == path && $0.state.isActive && $0.state != .downloading
            }
            if let transfer {
                transfer.token = token
                if let size { transfer.size = size }
                transfer.state = .starting
            }
            Task {
                try? await peer.send(Frame.message(PeerCode.transferResponse) {
                    $0.uint32(token)
                    $0.bool(transfer != nil)
                    if transfer == nil { $0.string("Cancelled") }
                })
            }

        case PeerCode.placeInQueueResponse:
            let path = try reader.string()
            let place = try reader.uint32()
            if let transfer = transfer(from: peer.username, path: path), case .queued = transfer.state {
                transfer.state = .queued(place: Int(place))
            }

        case PeerCode.uploadFailed:
            let path = try reader.string()
            if let transfer = transfer(from: peer.username, path: path), transfer.state != .downloading {
                fail(transfer, "Peer couldn't send the file")
            }

        case PeerCode.uploadDenied:
            let path = try reader.string()
            let reason = try reader.string()
            if let transfer = transfer(from: peer.username, path: path) { fail(transfer, reason.isEmpty ? "Denied" : reason) }

        case PeerCode.userInfoRequest:
            let sharing = self.sharing?.isEnabled == true
            let queued = UInt32(uploads.filter { $0.state == .queued }.count)
            let free = sharing && uploads.filter { $0.state == .preparing || $0.state == .sending }.count < Self.uploadSlots
            Task {
                try? await peer.send(Frame.message(PeerCode.userInfoResponse) {
                    $0.string("Seek for iOS")
                    $0.bool(false)
                    $0.uint32(sharing ? UInt32(Self.uploadSlots) : 0)
                    $0.uint32(queued)
                    $0.bool(free)
                    $0.uint32(sharing ? 1 : 0) // uploads allowed: everyone
                })
            }

        case PeerCode.sharedFileListRequest:
            let shared = sharing?.shared ?? .empty
            Task {
                let body = await Task.detached { try? shared.fileList() }.value
                if let body { try? await peer.send(Frame.message(PeerCode.sharedFileListResponse) { $0.append(body) }) }
            }

        case PeerCode.folderContentsRequest:
            let token = try reader.uint32()
            let folder = try reader.string()
            let shared = sharing?.shared ?? .empty
            Task {
                let body = await Task.detached { try? shared.folderContents(token: token, folder: folder) }.value
                if let body { try? await peer.send(Frame.message(PeerCode.folderContentsResponse) { $0.append(body) }) }
            }

        case PeerCode.queueUpload:
            queueUpload(try reader.string(), for: peer)

        case PeerCode.placeInQueueRequest:
            let path = try reader.string()
            let place = placeInQueue(of: path, for: peer.username)
            Task {
                try? await peer.send(Frame.message(PeerCode.placeInQueueResponse) {
                    $0.string(path)
                    $0.uint32(UInt32(place))
                })
            }

        case PeerCode.transferResponse:
            let token = try reader.uint32()
            let allowed = try reader.bool()
            let reason = allowed ? nil : ((try? reader.string()) ?? "Declined")
            uploadReplies.removeValue(forKey: token)?.resume(returning: reason)

        default:
            break
        }
    }

    private func transfer(from user: String, path: String) -> Transfer? {
        transfers.first { $0.username == user && $0.path == path && $0.state.isActive }
    }

    // MARK: - Helpers

    private static func makeToken() -> UInt32 {
        UInt32.random(in: 1...0x7FFF_FFFF)
    }

    private static func describeLoginFailure(_ reason: String) -> String {
        switch reason {
        case "INVALIDPASS": "Wrong password"
        case "INVALIDUSERNAME": "Invalid username"
        case "INVALIDVERSION": "Server rejected this client version"
        default: reason
        }
    }
}

/// A "P" (peer message) connection to one user.
@MainActor
final class PeerConnection {
    let username: String
    private let socket: Socket
    private weak var client: SoulseekClient?
    private(set) var isOpen = true

    init(username: String, socket: Socket, client: SoulseekClient) {
        self.username = username
        self.socket = socket
        self.client = client
    }

    func start() {
        Task { await readLoop() }
    }

    func send(_ data: Data) async throws {
        try await socket.send(data)
    }

    func close() {
        isOpen = false
        socket.close()
    }

    private func readLoop() async {
        do {
            while isOpen {
                var reader = MessageReader(try await socket.readFrame())
                let code = try reader.uint32()
                if code == PeerCode.fileSearchResponse {
                    // Busy searches bring hundreds of these: unpack them away from the UI.
                    let body = try reader.bytes(reader.remaining)
                    guard let response = await Task.detached(operation: { try? SearchResponse.parse(compressed: body) }).value
                    else { continue }
                    client?.handleSearchResponse(response, from: self)
                    continue
                }
                try? client?.handlePeerMessage(code, &reader, from: self)
            }
        } catch {}
        isOpen = false
        client?.peerClosed(self)
    }
}
