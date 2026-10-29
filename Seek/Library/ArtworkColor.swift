import CoreGraphics
import Foundation
import ImageIO

/// The colour of an album page and Now Playing, taken from the artwork as Apple Music does: the
/// artwork's main colour, a saturated one ahead of white or grey borders, dark enough for white
/// text. Black and grey artwork gives a near-black page.
enum ArtworkColor {
    struct RGB: Equatable, Sendable {
        var red: Double, green: Double, blue: Double

        init(red: Double, green: Double, blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }

        /// From "#1e3f6e", as pages send it.
        init?(hex: String) {
            guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
            self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }

        /// "#1e3f6e", for the web.
        var hex: String {
            String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
        }
    }

    private static let cache = NSCache<NSData, Box>()
    private final class Box { let value: RGB?; init(_ value: RGB?) { self.value = value } }

    /// From encoded artwork (JPEG, PNG…); remembered per artwork.
    static func color(of data: Data) -> RGB? {
        if let cached = cache.object(forKey: data as NSData) { return cached.value }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary
        let value = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
            .flatMap(color(of:))
        cache.setObject(Box(value), forKey: data as NSData)
        return value
    }

    static func color(of image: CGImage) -> RGB? {
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(size * size)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            samples.append((Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255))
        }
        return color(of: samples)
    }

    /// The page colour for these pixels: the strongest hue (by how much of the artwork it covers,
    /// weighted by how saturated it is), or a near-black grey when there isn't one.
    static func color(of samples: [(r: Double, g: Double, b: Double)]) -> RGB? {
        guard !samples.isEmpty else { return nil }
        let buckets = 18
        var weight = [Double](repeating: 0, count: buckets)
        var sums = [(h: (x: Double, y: Double), s: Double, v: Double)](repeating: ((0, 0), 0, 0), count: buckets)
        for sample in samples {
            let (h, s, v) = hsv(sample.r, sample.g, sample.b)
            guard s > 0.22, v > 0.18 else { continue }
            let bucket = min(buckets - 1, Int(h * Double(buckets)))
            let w = 0.4 + s
            weight[bucket] += w
            // Hue averaged as an angle, so reds either side of 0 don't average to cyan.
            sums[bucket].h.x += cos(h * 2 * .pi) * w
            sums[bucket].h.y += sin(h * 2 * .pi) * w
            sums[bucket].s += s * w
            sums[bucket].v += v * w
        }
        // Neighbouring buckets count together: one colour split across a boundary still wins.
        let joined = (0..<buckets).map { weight[$0] + 0.5 * (weight[($0 + 1) % buckets] + weight[($0 + buckets - 1) % buckets]) }
        guard let best = joined.indices.max(by: { joined[$0] < joined[$1] }),
              // A colour covering a few percent of the artwork at least; less is a speck.
              weight[best] >= Double(samples.count) * 0.06 else {
            // Black, white or grey artwork: a dark grey page.
            return RGB(red: 0.08, green: 0.08, blue: 0.09)
        }
        let w = weight[best]
        var hue = atan2(sums[best].h.y, sums[best].h.x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let saturation = min(0.8, sums[best].s / w)
        // Dark enough for white text, never so dark the colour is lost.
        let value = min(0.45, max(0.28, sums[best].v / w * 0.55))
        return rgb(hue, saturation, value)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        guard range > 0 else { return (0, 0, high) }
        var hue: Double
        if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, range / high, high)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return RGB(red: v, green: t, blue: p)
        case 1: return RGB(red: q, green: v, blue: p)
        case 2: return RGB(red: p, green: v, blue: t)
        case 3: return RGB(red: p, green: q, blue: v)
        case 4: return RGB(red: t, green: p, blue: v)
        default: return RGB(red: v, green: p, blue: q)
        }
    }
}
