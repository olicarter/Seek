import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

func json(_ value: some Encodable) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                    body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
}

struct Login: Decodable { var username: String; var password: String }
struct Query: Decodable { var query: String }
struct AlbumRef: Decodable { var artist: String; var title: String; var release: String? }

/// Everything the site asks the server for.
@MainActor
func makeRouter(core: Core, site: String) -> Router<BasicRequestContext> {
    let router = Router()

    // Before any route (a middleware only covers routes added after it): requests from the site
    // on 4n.studio, the key, then the site's pages, the library's songs (with range requests,
    // for seeking) and the site's files.
    router.middlewares.add(SiteOrigins())
    router.middlewares.add(RequireKey())
    router.middlewares.add(SitePages(page: URL(filePath: site).appending(path: "index.html")))
    router.middlewares.add(AudioTypes())
    router.middlewares.add(FileMiddleware(Core.musicFolder.path, urlBasePath: "/files", searchForIndexHtml: false))
    router.middlewares.add(FileMiddleware(site, searchForIndexHtml: true))

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

    router.get("/pair") { request, _ in try PairingPage.response(for: request) }

    router.get("/api/artist") { request, _ in
        guard let name = request.uri.queryParameters.get("name") else { throw HTTPError(.badRequest) }
        return try json(await core.artistPage(name))
    }

    /// A song that isn't in the library, played as the app plays it: from Soulseek while it
    /// downloads (into the stream cache, not the library), or Bandcamp's own stream.
    router.get("/api/stream") { request, _ in
        let params = request.uri.queryParameters
        guard let artist = params.get("artist"), let title = params.get("title"), let song = params.get("song") else {
            throw HTTPError(.badRequest)
        }
        let playable = await core.stream(artist: artist, title: title, release: params.get("release"),
                                         disc: params.get("disc").flatMap(Int.init) ?? 1,
                                         number: params.get("number").flatMap(Int.init) ?? 0, song: song)
        switch playable {
        case .file(let url):
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            return ranged(request, size: size, type: AudioTypes<BasicRequestContext>.type(of: url.pathExtension)) { offset, end in
                ProgressiveLoader.read(url, from: offset, upTo: min(end, offset + 256 * 1024))
            }
        case .progressive(let loader, let file):
            return ranged(request, size: loader.size, type: AudioTypes<BasicRequestContext>.type(of: file.fileExtension)) { offset, end in
                await loader.chunk(at: offset, upTo: end)
            }
        case .remote(let url):
            return Response(status: .found, headers: [.location: url.absoluteString])
        case nil:
            throw HTTPError(.notFound)
        }
    }

    router.post("/api/bandcamp/signin") { _, _ in
        await core.bandcampLogin.open()
        return try json(await core.status)
    }

    router.post("/api/bandcamp/signout") { _, _ in
        await core.bandcamp.signOut()
        return try json(await core.status)
    }

    /// The site opened an album's Bandcamp page to buy it there.
    router.post("/api/bandcamp/buying") { _, _ in
        await core.watchForPurchase()
        return try json(["ok": true])
    }

    return router
}

/// Songs with their audio type, which the file server doesn't know for most of them.
/// Part of a song, as a browser asks for it (`Range: bytes=start-end`), sent as `read` gives it
/// the bytes: all at once for a file, or as they arrive for one still downloading.
func ranged(_ request: Request, size: Int64, type: String,
            read: @escaping @Sendable (_ offset: Int64, _ end: Int64) async -> Data?) -> Response {
    var start: Int64 = 0
    var end = size - 1
    var partial = false
    if let header = request.headers[.range], header.hasPrefix("bytes=") {
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        if bounds.count == 2 {
            partial = true
            if let first = Int64(bounds[0]) {
                start = first
                if let last = Int64(bounds[1]) { end = min(last, size - 1) }
            } else if let suffix = Int64(bounds[1]) {
                start = max(size - suffix, 0)
            }
        }
    }
    guard size > 0, start <= end else {
        return Response(status: .rangeNotSatisfiable, headers: [.contentRange: "bytes */\(size)"])
    }
    var headers: HTTPFields = [.contentType: type, .acceptRanges: "bytes", .contentLength: "\(end - start + 1)",
                               .cacheControl: "no-store"]
    if partial { headers[.contentRange] = "bytes \(start)-\(end)/\(size)" }
    let (from, to) = (start, end + 1)
    return Response(status: partial ? .partialContent : .ok, headers: headers, body: ResponseBody { writer in
        var offset = from
        while offset < to {
            guard let chunk = await read(offset, to), !chunk.isEmpty else { break }
            try await writer.write(ByteBuffer(data: chunk))
            offset += Int64(chunk.count)
        }
        try await writer.finish(nil)
    })
}

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

    static func type(of fileExtension: String) -> String {
        types[fileExtension.lowercased()] ?? "application/octet-stream"
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

/// Lets the site on 4n.studio (and the dev server) talk to this one from your browser. The key
/// (RequireKey) is what keeps it private; this only says which pages may use it. Chrome also asks before a public page reaches a private address.
struct SiteOrigins<Context: RequestContext>: RouterMiddleware {
    static var allowed: Set<String> { ["https://4n.studio", "http://localhost:5173"] }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let origin = request.headers[.origin], Self.allowed.contains(origin) else {
            return try await next(request, context)
        }
        var headers: HTTPFields = [
            .accessControlAllowOrigin: origin,
            .accessControlAllowMethods: "GET, POST, OPTIONS",
            .accessControlAllowHeaders: "Content-Type, Range, X-Seek-Key",
            .accessControlExposeHeaders: "Content-Range, Content-Length, Accept-Ranges",
            .vary: "Origin",
        ]
        if request.method == .options {
            if request.headers[HTTPField.Name("Access-Control-Request-Private-Network")!] == "true" {
                headers[HTTPField.Name("Access-Control-Allow-Private-Network")!] = "true"
            }
            headers[.accessControlMaxAge] = "600"
            return Response(status: .noContent, headers: headers)
        }
        var response: Response
        do {
            response = try await next(request, context)
        } catch let error as HTTPError {
            // An error the site needs to read (e.g. not paired yet), with the headers it needs to read it.
            response = Response(status: error.status, body: ResponseBody(byteBuffer: ByteBuffer(string: error.body ?? "")))
        }
        for field in headers { response.headers[field.name] = field.value }
        return response
    }
}

