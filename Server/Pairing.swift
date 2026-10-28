import AppKit
import CoreImage
import Foundation
import Hummingbird
import HTTPTypes

/// The key a browser needs to use the server from anywhere but this Mac. The server is on the
/// public internet (Tailscale Funnel), so everything under /api and /files asks for it.
enum WebKey {
    static let header = HTTPField.Name("X-Seek-Key")!

    /// Made once, kept with the server's index. Deleting the file unpairs every browser.
    static let value: String = {
        let file = Core.storeFolder.appending(path: "web.key")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try? key.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
    }()

    /// Straight from this Mac, not through Tailscale (whose proxy always adds X-Forwarded-For).
    static func isLocal(_ request: Request) -> Bool {
        request.headers[HTTPField.Name("X-Forwarded-For")!] == nil
            && ["localhost", "127.0.0.1", "[::1]"].contains { request.head.authority?.hasPrefix($0) == true }
    }

    /// The key, from the header (fetches) or `?key=` (audio, images and the event stream,
    /// which can't send headers).
    static func isPaired(_ request: Request) -> Bool {
        let given = request.headers[header] ?? request.uri.queryParameters.get("key")
        guard let given else { return false }
        // Compared in full every time, so timing doesn't give it away.
        let a = Array(given.utf8), b = Array(value.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Only paired browsers (and this Mac) get past /api and /files.
struct RequireKey<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let guarded = path.hasPrefix("/api/") || path.hasPrefix("/files/")
        if guarded, !WebKey.isLocal(request), !WebKey.isPaired(request) {
            throw HTTPError(.unauthorized, message: "Pair this browser: open http://localhost:8765/pair on the Mac running Seek.")
        }
        return try await next(request, context)
    }
}

/// /pair, on this Mac only: a link and QR code that pair a browser with the site on 4n.studio.
/// The key goes after the #, so it never reaches 4n.studio's servers.
enum PairingPage {
    static let site = "https://4n.studio/seek/web/"

    static func response(for request: Request) throws -> Response {
        guard WebKey.isLocal(request) else { throw HTTPError(.notFound) }
        let link = "\(site)#key=\(WebKey.value)"
        let qr = qrCode(link).map { "<img src=\"data:image/png;base64,\($0.base64EncodedString())\" alt=\"\" width=\"240\" height=\"240\">" } ?? ""
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Pair with Seek</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;text-align:center}
        img{image-rendering:pixelated;background:#fff;padding:12px;border-radius:12px}a{color:#ff4d6d;word-break:break-all}p{max-width:420px;color:rgba(235,235,245,.6)}
        </style></head><body><main><h1>Pair with Seek</h1>\(qr)
        <p>Scan this with your phone's camera, or open the link in any browser you want to use Seek in. It keeps the key, so you only do this once per browser.</p>
        <p><a href="\(link)">Open Seek on 4n.studio</a></p></main></body></html>
        """
        return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"],
                        body: ResponseBody(byteBuffer: .init(string: html)))
    }

    private static func qrCode(_ text: String) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
