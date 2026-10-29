import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// How a song sounds, in TIDAL's three tiers (tidal.com/sound-quality), the same everywhere
/// Seek shows quality: in the app, on the web and on the Apple TV.
/// - Max: lossless above CD quality (more than 16-bit or above 44.1 kHz).
/// - High: lossless up to 16-bit, 44.1 kHz.
/// - Low: lossy (MP3, AAC, Ogg), up to 320 kbps.
enum SoundQuality: String, Codable, Sendable, CaseIterable, Comparable {
    case low, high, max

    init(lossless: Bool, bitDepth: Int?, sampleRate: Int?) {
        guard lossless else { self = .low; return }
        if let bitDepth, bitDepth > 16 { self = .max; return }
        if let sampleRate, sampleRate > 44_100 { self = .max; return }
        self = .high
    }

    /// "MAX", as the badge shows it.
    var label: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .low: "Low"
        case .high: "High"
        case .max: "Max"
        }
    }

    var explanation: String {
        switch self {
        case .low: "Up to 320 kbps"
        case .high: "Up to 16-bit, 44.1 kHz"
        case .max: "Up to 24-bit, 192 kHz"
        }
    }

    /// "24-bit, 96 kHz" for lossless, "320 kbps" for lossy: what's in the badge's tier.
    static func detail(lossless: Bool, bitDepth: Int?, sampleRate: Int?, bitrate: Int?) -> String? {
        if lossless {
            guard let sampleRate, sampleRate > 0 else { return bitDepth.map { "\($0)-bit" } }
            let rate = "\(String(format: "%g", Double(sampleRate) / 1000)) kHz"
            return bitDepth.flatMap { $0 > 0 ? "\($0)-bit, \(rate)" : nil } ?? rate
        }
        guard let bitrate, bitrate > 0 else { return nil }
        // Bitrates read from files wobble (319, 321); rounded to the usual steps.
        let steps = [96, 128, 160, 192, 224, 256, 320]
        let rounded = steps.min { abs($0 - bitrate) < abs($1 - bitrate) } ?? bitrate
        return "\(abs(rounded - bitrate) <= 4 ? rounded : bitrate) kbps"
    }

    static func < (a: SoundQuality, b: SoundQuality) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

#if canImport(SwiftUI)
extension SoundQuality {
    /// TIDAL's colours: gold for Max, cyan for High; darker in light mode to stay readable.
    var tint: Color {
        switch self {
        case .max: Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.83, blue: 0.2, alpha: 1) : UIColor(red: 0.66, green: 0.48, blue: 0, alpha: 1) })
        case .high: Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.2, green: 1, blue: 0.93, alpha: 1) : UIColor(red: 0, green: 0.5, blue: 0.53, alpha: 1) })
        case .low: .secondary
        }
    }
}

/// The tier as a capsule ("MAX"), holding the detail too when given ("MAX 24-bit, 96 kHz").
struct SoundQualityBadge: View {
    let quality: SoundQuality
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(quality.label).font(.caption2.weight(.heavy)).tracking(0.6)
            if let detail { Text(detail).font(.caption2.weight(.medium)) }
        }
        .foregroundStyle(quality.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(quality.tint.opacity(0.15), in: .capsule)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quality.name) quality\(detail.map { ", \($0)" } ?? "")")
    }
}
#endif
