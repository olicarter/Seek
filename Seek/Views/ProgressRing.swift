import SwiftUI

/// Download progress as a ring that fills, like Apple Music's. Without a fraction yet (queued,
/// connecting) a short arc turns instead, so waiting doesn't look stuck at nothing.
struct ProgressRing: View {
    let progress: Double?
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2.5
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.2), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(min(progress, 1), 0.02))
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 270 : -90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = true }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(progress.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Waiting to download")
    }
}
