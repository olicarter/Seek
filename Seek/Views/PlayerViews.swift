import AVKit
import MediaPlayer
import SwiftUI

struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(data: player.current?.artwork, cornerRadius: 4)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = player.current?.displayArtist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 14)
    }
}

/// Full-screen player in the style of Apple Music: artwork-tinted background, large artwork
/// that shrinks into the header when the queue is shown, and system volume and AirPlay.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var artworkSpace
    @State private var showingQueue = false
    /// Sheets can't show the app-wide prompt, so Now Playing has its own.
    @State private var newPlaylist = NewPlaylistPrompt()

    var body: some View {
        Group {
            if sizeClass == .compact { compactBody } else { wideBody }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        // The system grabber picks up the app's accent colour; draw a neutral one instead.
        .presentationDragIndicator(.hidden)
        .presentationBackground { NowPlayingBackground(artwork: player.current?.artwork) }
        .presentationSizing(.page)
        .newPlaylistPrompt()
        .environment(newPlaylist)
    }

    // MARK: - iPhone

    private var compactBody: some View {
        VStack(spacing: 0) {
            if showingQueue {
                compactHeader
                    .padding(.top, 28)
                QueueList()
            } else {
                Spacer(minLength: 24)
                ArtworkView(data: player.current?.artwork, cornerRadius: 12)
                    .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                    .frame(maxWidth: 520)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.82)
                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                Spacer(minLength: 24)
                titleRow
            }

            PlayerScrubBar()
            .padding(.top, 20)

            transportControls
                .padding(.vertical, 24)

            volumeRow

            bottomRow
                .padding(.top, 24)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 28)
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
        }
    }

    // MARK: - iPad and Mac

    /// Full screen like Apple Music on iPad and Mac: the artwork and controls in one column,
    /// centred, with Up Next sliding in beside them.
    private var wideBody: some View {
        GeometryReader { geometry in
            // Room for the title, scrubber, controls and volume below the artwork.
            let controlsHeight: CGFloat = 330
            let maxSide = showingQueue ? geometry.size.width * 0.4 : geometry.size.width * 0.5
            let side = max(min(maxSide, geometry.size.height - controlsHeight, 560), 240)
            HStack(spacing: 64) {
                VStack(spacing: 0) {
                    ArtworkView(data: player.current?.artwork, cornerRadius: 14)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                        .padding(.bottom, 32)
                    titleRow
                    PlayerScrubBar()
                    .padding(.top, 18)
                    transportControls
                        .padding(.vertical, 18)
                    volumeRow
                    bottomRow
                        .padding(.top, 14)
                }
                .frame(width: max(side, 380))

                if showingQueue {
                    QueueList()
                        .frame(maxWidth: 460)
                        .frame(height: side + controlsHeight - 40)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { NowPlayingBackground(artwork: player.current?.artwork) }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .padding(24)
        }
        // A full-screen cover has no sheet swipe; dragging down closes it the same way.
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 140, abs(value.translation.width) < value.translation.height {
                    dismiss()
                }
            }
        )
    }

    // MARK: - Pieces

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Menu { trackActions } label: { titleText(size: .title2) }
                .buttonStyle(.plain)
                .disabled(player.current == nil)
            favoriteButton
            moreButton
        }
    }

    private var favoriteButton: some View {
        let isFavorite = player.current.map(library.isFavorite) ?? false
        return Button {
            guard let track = player.current else { return }
            library.toggleFavorite(track)
            player.updateFavoriteCommand()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.body.weight(.bold))
                .foregroundStyle(isFavorite ? Color.pink : Color.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil || player.current?.isStreamed == true)
        .opacity(player.current?.isStreamed == true ? 0 : 1)
        .sensoryFeedback(.selection, trigger: isFavorite)
        .accessibilityLabel(isFavorite ? "Unfavourite" : "Favourite")
    }

    private var compactHeader: some View {
        HStack(spacing: 14) {
            ArtworkView(data: player.current?.artwork, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            titleText(size: .headline)
            favoriteButton
            moreButton
        }
        .padding(.bottom, 16)
    }

    private func titleText(size: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.current?.title ?? "Not Playing")
                .font(size.bold())
                .lineLimit(1)
            Text(player.current?.displayArtist ?? "")
                .font(size == .headline ? .subheadline : .title3)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var moreButton: some View {
        Menu { trackActions } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
        .accessibilityLabel("More")
    }

    @ViewBuilder private var trackActions: some View {
        if let track = player.current, track.isStreamed {
            Button("Go to Album", systemImage: "square.stack") {
                dismiss()
                router.show(ExternalAlbum(artist: track.albumArtist, title: track.album, artworkURL: track.stream?.artworkURL))
            }
        } else if let track = player.current {
            AddToPlaylistMenu(track: track)
            FavoriteButton(track: track)
            Button("Go to Album", systemImage: "square.stack") {
                dismiss()
                router.show(track.albumKey)
            }
            Button("Go to Artist", systemImage: "music.mic") {
                dismiss()
                router.show(ArtistKey(name: track.albumKey.artist))
            }
        }
    }

    private var transportControls: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52))
                    .frame(width: 64, height: 64)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34))
            }
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider()
                .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
    }

    private var bottomRow: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            Button {
                withAnimation(.spring(duration: 0.45)) { showingQueue.toggle() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(showingQueue ? .white.opacity(0.25) : .clear, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Up Next")
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

/// The current artwork, blurred and darkened, behind the whole player.
private struct NowPlayingBackground: View {
    let artwork: Data?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .scaleEffect(1.4)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
        .task(id: artwork) { image = await ThumbnailCache.shared.image(for: artwork) }
    }
}

/// A thin progress bar that thickens while dragged, with elapsed and remaining time.
/// The scrub bar fed by the player. Reading the playhead here, not in Now Playing itself, means
/// its twice-a-second updates redraw only the bar, not the menus and artwork around it.
private struct PlayerScrubBar: View {
    @Environment(Player.self) private var player

    var body: some View {
        ScrubBar(
            position: player.currentTime,
            duration: player.duration,
            isLoading: player.isLoading,
            fetchProgress: player.fetchProgress
        ) { player.seek(to: $0) }
    }
}

private struct ScrubBar: View {
    let position: Double
    let duration: Double
    let isLoading: Bool
    /// Set while a streamed song is still arriving.
    var fetchProgress: Double? = nil
    let onSeek: (Double) -> Void
    @State private var dragPosition: Double?

    var body: some View {
        let shown = dragPosition ?? position
        let isDragging = dragPosition != nil
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white.opacity(isDragging ? 1 : 0.7))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: isDragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragPosition = fraction * duration
                        }
                        .onEnded { _ in
                            if let dragPosition { onSeek(dragPosition) }
                            dragPosition = nil
                        }
                )
            }
            .frame(height: 24)
            .animation(.spring(duration: 0.3), value: isDragging)

            HStack {
                Text(format(shown))
                Spacer()
                if let fetchProgress {
                    Text("Fetching \(Int(fetchProgress * 100))%")
                } else if isLoading {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text("-" + format(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(isDragging ? 0.9 : 0.55))
        }
        .padding(.horizontal, isDragging ? -4 : 0)
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: .minuteSecond))
    }
}

/// The system volume slider (the only way an app can change output volume), restyled.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white.withAlphaComponent(0.75)
            slider.maximumTrackTintColor = .white.withAlphaComponent(0.2)
        }
    }

    private static let thumb = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
        UIColor.white.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white.withAlphaComponent(0.75)
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct QueueList: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Playing Next")
                    .font(.headline)
                Spacer()
                toggle("shuffle", label: "Shuffle", isOn: player.shuffle) { player.toggleShuffle() }
                toggle(player.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat", isOn: player.repeatMode != .off) {
                    player.repeatMode = player.repeatMode.next
                }
            }
            List {
                ForEach(Array(player.upNext), id: \.id) { track in
                    TrackRow(track: track)
                        .onTapGesture { player.jump(to: track) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparatorTint(.white.opacity(0.15))
                }
                .onDelete { player.removeFromQueue(at: $0) }
                .onMove { player.moveInQueue(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if player.upNext.isEmpty {
                    ContentUnavailableView("Nothing Up Next", systemImage: "list.bullet")
                }
            }
        }
    }

    private func toggle(_ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.black : .white)
                .frame(width: 40, height: 30)
                .background(isOn ? Color.white : .white.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
