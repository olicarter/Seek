import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album covers for the site and the Apple TV, from the library's own (often the full-size
/// original): at the size they're shown, as progressive JPEGs (drawn coarse to fine as they
/// arrive, not top to bottom), and as a tiny preview that goes in the page itself, shown
/// pixelated until the cover's in. Kept once made.
@MainActor
enum Covers {
    /// Grid tiles, and album pages.
    static let tile = 300, page = 600
    /// The preview's longest side, in pixels: a few hundred bytes.
    static let previewSize = 24

    private static let made = NSCache<NSString, NSData>()

    static func resized(_ original: Data, key: String, size: Int) -> Data? {
        let name = "\(key)|\(original.count)|\(size)" as NSString
        if let cached = made.object(forKey: name) { return cached as Data }
        guard let jpeg = jpeg(original, maxPixel: size, progressive: true, quality: 0.8) else { return nil }
        made.setObject(jpeg as NSData, forKey: name)
        return jpeg
    }

    /// As a data: URL, for the page.
    static func preview(_ original: Data, key: String) -> String? {
        let name = "\(key)|\(original.count)|preview" as NSString
        if let cached = made.object(forKey: name) { return String(decoding: cached as Data, as: UTF8.self) }
        guard let jpeg = jpeg(original, maxPixel: previewSize, progressive: false, quality: 0.6) else { return nil }
        let url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        made.setObject(Data(url.utf8) as NSData, forKey: name)
        return url
    }

    /// Which cover it is: changes when the cover does, so browsers can keep it a long while.
    static func version(_ original: Data) -> String { "\(original.count)" }

    private static func jpeg(_ data: Data, maxPixel: Int, progressive: Bool, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
