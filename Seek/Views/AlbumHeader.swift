import SwiftUI

/// The top of an album page, laid out like Apple Music's: artwork, title, artist, a details
/// line ("1980 · Lossless"), round shuffle and download buttons around a wide Play, then a
/// short description that expands with MORE.
struct AlbumHeader<Artwork: View, Accessory: View>: View {
    let title: String
    let artist: String
    /// Opens the artist's page. A plain button rather than a NavigationLink, which in a list
    /// gets a chevron and stretches to the row's edge.
    var onArtist: (() -> Void)?
    var year: Int?
    var isLossless = false
    var description: String?
    var isDescribing = false
    var canPlay = true
    /// Sources are still being looked for: Play shows a spinner rather than looking disabled.
    var isPreparing = false
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    /// The round button on the right: download, buy, or a tick when it's all here.
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 12) {
            artwork()
                .frame(maxWidth: 260)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                .padding(.horizontal, 60)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Group {
                    if let onArtist {
                        Button(artist, action: onArtist)
                            .buttonStyle(.plain)
                    } else {
                        Text(artist)
                    }
                }
                .font(.title3)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                if let details {
                    details
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 18) {
                RoundButton(systemImage: "shuffle", label: "Shuffle", action: onShuffle)
                    .opacity(canPlay ? 1 : 0.4)
                    .allowsHitTesting(canPlay)
                Button(action: onPlay) {
                    HStack(spacing: 8) {
                        if !canPlay && isPreparing {
                            ProgressView().tint(Color(.systemBackground))
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Play")
                    }
                    .font(.headline)
                    .foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: 190, minHeight: 50)
                    .background(Color.primary, in: .capsule)
                }
                .buttonStyle(.plain)
                .opacity(canPlay || isPreparing ? 1 : 0.4)
                .allowsHitTesting(canPlay)
                accessory()
                    .frame(width: 50, height: 50)
            }
            .padding(.top, 6)

            if let description {
                ExpandableText(text: description)
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut, value: description)
    }

    private var details: Text? {
        var parts: [Text] = []
        if let year, year > 0 { parts.append(Text(String(year))) }
        if isLossless { parts.append(Text("\(Image(systemName: "waveform")) Lossless")) }
        guard !parts.isEmpty else { return nil }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }
}

/// A round icon button, like Apple Music's shuffle and download buttons.
struct RoundButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 50)
                .background(.fill.secondary, in: .circle)
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The round button showing a progress ring while something downloads.
struct RoundProgress: View {
    let progress: Double?

    var body: some View {
        ProgressRing(progress: progress, size: 24, lineWidth: 3)
            .frame(width: 50, height: 50)
        .background(.fill.secondary, in: .circle)
    }
}

/// Three lines, with MORE to show the rest.
struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomTrailing) {
                if !expanded {
                    Text("MORE")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 24)
                        .background(
                            LinearGradient(colors: [.clear, Color(.systemBackground), Color(.systemBackground)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                }
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation { expanded.toggle() } }
    }
}
