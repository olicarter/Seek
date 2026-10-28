import SwiftUI
import WebKit

/// Bandcamp's own login page. Once Bandcamp sets its `identity` cookie, Seek keeps that
/// cookie (never the password) and closes the page.
struct BandcampLoginView: View {
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            LoginWebView { identity in
                guard !checking else { return }
                checking = true
                Task {
                    do {
                        try await bandcamp.completeSignIn(identity: identity)
                        dismiss()
                    } catch {
                        // Bandcamp sets the cookie for logged-out visitors too; keep waiting.
                        Log.debug("bandcamp sign-in check: \(error)")
                    }
                    checking = false
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign In to Bandcamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if checking {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
        }
    }

}

private struct LoginWebView: UIViewRepresentable {
    let onIdentity: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onIdentity: onIdentity)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = BandcampAPI.userAgent
        webView.load(URLRequest(url: URL(string: "https://bandcamp.com/login")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onIdentity: (String) -> Void

        init(onIdentity: @escaping (String) -> Void) {
            self.onIdentity = onIdentity
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // After a successful login Bandcamp navigates away from /login.
            guard webView.url?.path.hasPrefix("/login") == false else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [onIdentity] cookies in
                if let identity = cookies.first(where: { $0.name == "identity" && $0.domain.hasSuffix("bandcamp.com") }),
                   !identity.value.isEmpty {
                    onIdentity(identity.value)
                }
            }
        }
    }
}
