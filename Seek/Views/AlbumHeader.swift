import SwiftUI

/// The top of an album page, laid out like Apple Music's: artwork, title, artist, a details
/// line ("1980 · MAX 24-bit, 96 kHz"), round shuffle and download buttons around a wide Play, then a
/// short description that expands with MORE.
struct AlbumHeader<Artwork: View, Accessory: View>: View {
    let title: String
    let artist: String
    /// Opens the artist's page. A plain button rather than a NavigationLink, which in a list
    /// gets a chevron and stretches to the row's edge.
    var onArtist: (() -> Void)?
    var year: Int?
    /// TIDAL's tier (SoundQuality) and its detail, "24-bit, 96 kHz".
    var quality: SoundQuality?
    var qualityDetail: String?
    var description: String?
    var isDescribing = false
    var canPlay = true
    /// Sources are still being looked for: Play shows a spinner rather than looking disabled.
    var isPreparing = false
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    /// The round buttons on the right: download (a tick when it's all here), then buy.
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
                if year ?? 0 > 0 || quality != nil {
                    HStack(spacing: 6) {
                        if let year, year > 0 { Text(String(year)) }
                        if year ?? 0 > 0, quality != nil { Text("·") }
                        if let quality { SoundQualityBadge(quality: quality, detail: qualityDetail) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 14) {
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
                // Its own round buttons: add, and Bandcamp's buy when it sells the album.
                accessory()
                    .frame(minWidth: 50, minHeight: 50)
            }
            .padding(.top, 6)
            .padding(.horizontal)

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

/// Beside the add button when Bandcamp sells the album: a bag to buy it, filled and ticked once
/// it's been bought, which opens its Bandcamp page.
struct BandcampPurchaseButton: View {
    let owned: BandcampItem?
    var price: BandcampAPI.Price?
    let buy: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let owned {
            Button {
                if let page = owned.itemURL { openURL(page) }
            } label: {
                Image(systemName: "bag.fill")
                    .font(.title3.weight(.semibold))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(.systemBackground), .tint)
                            .offset(x: 6, y: 5)
                    }
                    .frame(width: 50, height: 50)
                    .background(.fill.secondary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bought on Bandcamp")
        } else {
            let paid = price.flatMap { $0.amount > 0 ? $0 : nil }
            RoundButton(systemImage: "bag", label: paid.map { "Buy on Bandcamp for \($0.formatted)" } ?? "Get on Bandcamp", action: buy)
        }
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
    /// The text's height in three lines, and in full: MORE only when the full text is taller.
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isCut: Bool { fullHeight > shownHeight + 1 }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !expanded { shownHeight = $0 } }
            .background(alignment: .topLeading) {
                // The whole text at the same width, unseen, to tell whether three lines cut it off.
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    .hidden()
            }
            .overlay(alignment: .bottomTrailing) {
                if !expanded && isCut {
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
            // Straight away, not animated (the list row resizing too made it slow and jumpy).
            .onTapGesture {
                guard isCut || expanded else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { expanded.toggle() }
            }
    }
}

/// The album page, for albums in the library and ones that aren't alike: the header, the
/// songs, the footer, other versions and similar albums, in that order. Only what fills them
/// differs, so the two pages can't drift apart.
struct AlbumPage<Header: View, Songs: View>: View {
    let artist: String
    let title: String
    let footer: AlbumFooter
    let versions: [CatalogRelease]
    @ViewBuilder let header: () -> Header
    @ViewBuilder let songs: () -> Songs

    var body: some View {
        List {
            header()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.bottom, 8)
            songs()
            footer
                .listRowSeparator(.hidden)
            OtherVersionsRow(versions: versions)
                .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            if !artist.isEmpty, artist != "Unknown Artist" {
                DiscoveryRow(subject: .album(artist: artist, title: title))
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
    }
}
