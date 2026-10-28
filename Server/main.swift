import Foundation
import Hummingbird
import NIOCore

// Seek on the web: the app's own core on this Mac, the site in web/dist, both served from
// one port. Only this Mac can reach it unless started with --lan.

let arguments = CommandLine.arguments
let port = arguments.firstIndex(of: "--port").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 8765
let host = arguments.contains("--lan") ? "0.0.0.0" : "127.0.0.1"
let site = arguments.firstIndex(of: "--site").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "web/dist").path

let core = await MainActor.run { Core() }
await core.start()

func json(_ value: some Encodable) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                    body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
}

struct Login: Decodable { var username: String; var password: String }
struct Query: Decodable { var query: String }
struct AlbumRef: Decodable { var artist: String; var title: String; var release: String? }

let router = Router()

router.get("/api/status") { _, _ in try json(await core.status) }

router.post("/api/login") { request, context in
    let login = try await request.decode(as: Login.self, context: context)
    await core.client.signIn(username: login.username, password: login.password)
    return try json(await core.status)
}

router.post("/api/logout") { _, _ in
    await core.client.signOut()
    return try json(await core.status)
}

router.post("/api/search") { request, context in
    let query = try await request.decode(as: Query.self, context: context)
    await core.search(query.query)
    return try json(await core.searchPage)
}

router.get("/api/search") { _, _ in try json(await core.searchPage) }

router.get("/api/album") { request, _ in
    let params = request.uri.queryParameters
    guard let artist = params.get("artist"), let title = params.get("title") else { throw HTTPError(.badRequest) }
    return try json(await core.albumPage(artist: artist, title: title, release: params.get("release")))
}

router.post("/api/album/add") { request, context in
    let album = try await request.decode(as: AlbumRef.self, context: context)
    await core.add(artist: album.artist, title: album.title, release: album.release)
    return try json(await core.albumPage(artist: album.artist, title: album.title, release: album.release))
}

router.get("/api/library") { _, _ in try json(await core.libraryPage) }

router.get("/api/downloads") { _, _ in try json(await core.downloadsPage) }

/// The last album that couldn't be added, once: the site says why.
router.post("/api/failure/take") { _, _ in
    let failure = await MainActor.run { () -> String? in
        defer { core.adder.failure = nil }
        return core.adder.failure.map {
            "Not all \($0.songs) songs of “\($0.album.title)” are on Soulseek right now, so nothing was added."
        }
    }
    return try json(["message": failure])
}

router.get("/api/cover") { request, _ in
    let params = request.uri.queryParameters
    guard let artist = params.get("artist"), let title = params.get("title"),
          let data = await core.cover(artist: artist, title: title) else { throw HTTPError(.notFound) }
    return Response(status: .ok, headers: [.contentType: "image/jpeg", .cacheControl: "max-age=300"],
                    body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
}

/// A line whenever something shown may have changed; the site refetches what it's showing.
router.get("/api/events") { _, _ in
    Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-store"],
             body: ResponseBody { writer in
        var last = -1
        while !Task.isCancelled {
            let version = await core.version
            if version != last {
                last = version
                try await writer.write(ByteBuffer(string: "data: \(version)\n\n"))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await writer.finish(nil)
    })
}

/// Songs with their audio type, which the file server doesn't know for most of them.
struct AudioTypes<Context: RequestContext>: RouterMiddleware {
    static var types: [String: String] {
        ["flac": "audio/flac", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "alac": "audio/mp4",
         "wav": "audio/wav", "aif": "audio/aiff", "aiff": "audio/aiff", "caf": "audio/x-caf"]
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        if request.uri.path.hasPrefix("/files/"),
           let type = Self.types[(request.uri.path as NSString).pathExtension.lowercased()] {
            response.headers[.contentType] = type
        }
        return response
    }
}

/// Any other path is one of the site's pages (it routes in the browser): the site's page.
struct SitePages<Context: RequestContext>: RouterMiddleware {
    let page: URL

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound
                    && request.method == .get && !request.uri.path.hasPrefix("/api/") && !request.uri.path.hasPrefix("/files/") {
            guard let html = try? Data(contentsOf: page) else { throw error }
            return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"],
                            body: ResponseBody(byteBuffer: ByteBuffer(data: html)))
        }
    }
}

// The site's pages, the library's songs (with range requests, for seeking), then the site's files.
router.middlewares.add(SitePages(page: URL(filePath: site).appending(path: "index.html")))
router.middlewares.add(AudioTypes())
router.middlewares.add(FileMiddleware(Core.musicFolder.path, urlBasePath: "/files", searchForIndexHtml: false))
router.middlewares.add(FileMiddleware(site, searchForIndexHtml: true))

let app = Application(router: router, configuration: .init(address: .hostname(host, port: port), serverName: "Seek"))
print("Seek is at http://\(host == "0.0.0.0" ? "<this Mac's address>" : "localhost"):\(port)")
print("Library: \(Core.musicFolder.path)")
try await app.runService()
