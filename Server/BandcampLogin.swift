import AppKit
import WebKit

/// Bandcamp's own login page in a window on this Mac, as the app shows it in a sheet: once
/// Bandcamp sets its `identity` cookie, the server keeps that (never the password) and closes it.
@MainActor
final class BandcampLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var checking = false
    private let bandcamp: BandcampClient

    init(bandcamp: BandcampClient) {
        self.bandcamp = bandcamp
    }

    var isOpen: Bool { window != nil }

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720))
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "https://bandcamp.com/login")!))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign In to Bandcamp"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let url = webView.url
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                MainActor.assumeIsolated {
                    if let identity = BandcampAPI.identity(after: url, in: cookies) { self.signIn(identity) }
                }
            }
        }
    }

    private func signIn(_ identity: String) {
        guard !checking else { return }
        checking = true
        Task {
            do {
                try await bandcamp.completeSignIn(identity: identity)
                window?.close()
            } catch {
                // Bandcamp sets the cookie for logged-out visitors too; keep waiting.
                Log.debug("bandcamp sign-in check: \(error)")
            }
            checking = false
        }
    }
}
