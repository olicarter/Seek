import UIKit
import UniformTypeIdentifiers

/// "Seek" in the share sheet: passes what was shared (Shazam's "I used Shazam to discover…"
/// message and link, or an Apple Music link) to Seek, which works out the song and searches
/// for it. Nothing shows here; the sheet closes as Seek opens.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await share() }
    }

    private func share() async {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var parts: [String] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { parts.append(text) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    parts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    parts.append(text)
                }
            }
        }
        var link = URLComponents()
        link.scheme = "seek"
        link.host = "share"
        link.queryItems = [URLQueryItem(name: "text", value: parts.joined(separator: "\n"))]
        if let url = link.url { open(url) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions can't open other apps through the API, but the application is still in the
    /// responder chain.
    private func open(_ url: URL) {
        var responder: UIResponder? = self
        while let next = responder {
            if let application = next as? UIApplication {
                application.open(url)
                return
            }
            responder = next.next
        }
    }
}
