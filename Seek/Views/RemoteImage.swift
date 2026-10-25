import SwiftUI
import UIKit

/// Cover art from the web, kept in memory so it shows the moment a view needs it. Rows prefetch
/// every cover they'll show, so scrolling to one doesn't make it pop in.
@MainActor
enum RemoteImages {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        return cache
    }()
    private static var loading: [URL: Task<UIImage?, Never>] = [:]

    static func cached(_ url: URL?) -> UIImage? {
        url.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    /// The image, fetched once however many views ask at the same time.
    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            // Decoded (and shrunk) here rather than on the main thread when first drawn.
            return await image.byPreparingThumbnail(ofSize: CGSize(width: 600, height: 600)) ?? image
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    static func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil && loading[url] == nil {
            Task { _ = await load(url) }
        }
    }
}

/// Like AsyncImage, but shows a cached image straight away, with no flash on the first frame.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        if let image = RemoteImages.cached(url) ?? loaded.flatMap({ $0.url == url ? $0.image : nil }) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            placeholder()
                .task(id: url) {
                    guard let url, let image = await RemoteImages.load(url) else { return }
                    loaded = (url, image)
                }
        }
    }
}
