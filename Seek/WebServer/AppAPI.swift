import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// The key that lets this person's iPhone and iPad use this Mac for their Soulseek work, and
/// where to reach it: put in iCloud Keychain, which only their own devices share.
enum AppKey {
    static let addressKey = "webPublicAddress"

    static let value: String = {
        let file = Core.storeFolder.appending(path: "app.key")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        let key = Passkeys.base64url(Passkeys.random(32))
        try? key.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
    }()

    static func matches(_ given: String) -> Bool { WebKey.compare(given, value) }

    /// The Mac's public address (its Tailscale Funnel one), set in Settings › Web.
    static var address: String {
        UserDefaults.standard.string(forKey: addressKey) ?? ""
    }

    /// Tells the person's other devices where this Mac is, through iCloud Keychain.
    static func publish() {
        let item = KeychainItem(service: MacLinkWire.keychainService)
        guard !address.isEmpty else {
            item.clear()
            return
        }
        item.save(account: address, data: Data(value.utf8))
    }
}

private struct FolderBody: Decodable { var folder: RemoteFolder }
private struct FileBody: Decodable { var file: RemoteFile }
private struct IDBody: Decodable { var id: UUID }
private struct SearchBody: Decodable { var query: String; var seconds: Int? }

/// Searches run for devices, by id, while they poll for what's been found.
@MainActor
final class AppSearches {
    private var searches: [UUID: (search: MacLinkWire.Search, started: Date)] = [:]

    func start(_ query: String, seconds: Int, client: SoulseekClient) -> UUID {
        let id = UUID()
        searches = searches.filter { $0.value.started.timeIntervalSinceNow > -600 }
        searches[id] = (MacLinkWire.Search(folders: [], done: false), .now)
        Task {
            let found = await client.quietSearch(query, for: .seconds(max(5, min(seconds, 30)))) { [weak self] soFar in
                self?.searches[id]?.search.folders = soFar
                return false
            }
            searches[id]?.search = MacLinkWire.Search(folders: found ?? searches[id]?.search.folders ?? [], done: true)
        }
        return id
    }

    func result(_ id: UUID) -> MacLinkWire.Search? { searches[id]?.search }
}

/// What an iPhone or iPad asks this Mac for while it does their Soulseek work (see MacLink):
/// Soulseek's own folders and files, downloads into the shared iCloud library, and streams.
@MainActor
func addAppRoutes(to router: Hummingbird.Router<BasicRequestContext>, core: Core) {
    let client = core.client

    router.get("/api/app/ping") { _, _ in
        try json(["username": await client.savedUsername ?? ""])
    }

    router.post("/api/app/search") { request, context in
        let body = try await request.decode(as: SearchBody.self, context: context)
        let id = await core.appSearches.start(body.query, seconds: body.seconds ?? 15, client: client)
        return try json(["id": id.uuidString])
    }

    router.get("/api/app/search") { request, _ in
        guard let id = request.uri.queryParameters.get("id").flatMap(UUID.init(uuidString:)),
              let result = await core.appSearches.result(id) else { throw HTTPError(.notFound) }
        return try json(result)
    }

    router.post("/api/app/contents") { request, context in
        let body = try await request.decode(as: FolderBody.self, context: context)
        do {
            return try json(try await client.contents(of: body.folder))
        } catch {
            throw HTTPError(.badGateway, message: "\(error.localizedDescription)")
        }
    }

    router.post("/api/app/download") { request, context in
        let body = try await request.decode(as: MacLinkWire.Download.self, context: context)
        await client.connectIfNeeded()
        await client.download(body.files, in: body.folder, album: body.album, others: body.others, group: body.group)
        return try json(["ok": true])
    }

    router.post("/api/app/download-folder") { request, context in
        let body = try await request.decode(as: FolderBody.self, context: context)
        await client.connectIfNeeded()
        await client.download(body.folder)
        return try json(["ok": true])
    }

    router.post("/api/app/download-file") { request, context in
        let body = try await request.decode(as: FileBody.self, context: context)
        await client.connectIfNeeded()
        _ = await client.download(body.file)
        return try json(["ok": true])
    }

    router.get("/api/app/transfers") { _, _ in
        try json(await MainActor.run {
            MacLinkWire.Transfers(
                transfers: client.transfers.filter { !$0.forStreaming }.map { transfer in
                    let (state, detail) = MacLinkWire.encode(transfer.state)
                    return MacLinkWire.Transfer(
                        id: transfer.id, file: transfer.file, state: state, detail: detail, size: transfer.size,
                        bytesReceived: transfer.bytesReceived, bytesPerSecond: transfer.bytesPerSecond, album: transfer.album,
                        addGroup: transfer.addGroup, plannedPath: transfer.plannedPath, libraryPath: transfer.libraryPath,
                        retryAt: transfer.retryAt)
                },
                failedAdds: client.failedAdds)
        })
    }

    for action in ["cancel", "retry", "remove"] {
        router.post("/api/app/\(action)") { request, context in
            let body = try await request.decode(as: IDBody.self, context: context)
            await MainActor.run {
                guard let transfer = client.transfers.first(where: { $0.id == body.id }) else { return }
                switch action {
                case "cancel": client.cancel(transfer)
                case "retry": client.retry(transfer)
                default: client.remove(transfer)
                }
            }
            return try json(["ok": true])
        }
    }

    /// A song for the device to play: fetched here (into this Mac's stream cache) and sent on
    /// as it arrives, with range requests.
    router.get("/api/app/stream") { request, _ in
        guard let encoded = request.uri.queryParameters.get("file"), let data = Passkeys.data(base64url: String(encoded)),
              let file = try? JSONDecoder().decode(RemoteFile.self, from: data) else { throw HTTPError(.badRequest) }
        await client.connectIfNeeded()
        let loader = await MainActor.run { () -> ProgressiveLoader? in
            if let cached = core.streamer.cachedURL(for: file) {
                return ProgressiveLoader(fileURL: cached, totalSize: Int64(file.size), fileExtension: file.fileExtension)
            }
            return core.streamer.loader(for: client.stream(file))
        }
        guard let loader else { throw HTTPError(.notFound) }
        return ranged(request, size: Int64(file.size), type: AudioTypes<BasicRequestContext>.type(of: file.fileExtension)) { offset, end in
            await loader.chunk(at: offset, upTo: end)
        }
    }
}
