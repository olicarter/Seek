import SwiftUI

/// Download progress as a ring that fills, like Apple Music's. Without a fraction yet (queued,
/// connecting) it sits nearly empty rather than spinning.
struct ProgressRing: View {
    let progress: Double?
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(min(progress ?? 0, 1), 0.02))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(progress.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Waiting to download")
    }
}
