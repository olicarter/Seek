import AVKit
import Combine
import MediaPlayer
import SwiftUI

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    /// How far the song has been swiped: left towards the next song, right towards the one before.
    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 1

    var body: some View {
        HStack(spacing: 10) {
            swipeable
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

    /// The song coming in as it's swiped.
    private var neighbour: Track? {
        drag < 0 ? player.nextTrack : drag > 0 ? player.previousTrack : nil
    }

    /// Swiping moves the title (and the artist, if it changes) with the finger, the next song's
    /// coming in beside it, and fades the cover across if it changes. Let go far enough (or
    /// flicked) and that song plays; otherwise it springs back.
    private var swipeable: some View {
        let current = player.current
        let other = neighbour
        let progress = min(abs(drag) / max(width, 1), 1)
        let sameCover = other.map { $0.albumKey == current?.albumKey } ?? true
        let sameArtist = other.map { $0.displayArtist == current?.displayArtist } ?? true
        // The next song comes in from the right, the one before from the left.
        let side: CGFloat = drag < 0 ? 1 : -1
        return HStack(spacing: 10) {
            ZStack {
                ArtworkView(data: current?.cover, cornerRadius: 4)
                    .opacity(sameCover ? 1 : 1 - progress)
                if let other, !sameCover {
                    ArtworkView(data: other.cover, cornerRadius: 4).opacity(progress)
                }
            }
            .frame(width: 32, height: 32)
            ZStack(alignment: .leading) {
                lines(current, offset: drag, artistOffset: sameArtist ? 0 : drag, showsArtist: true)
                if let other {
                    let offset = drag + side * width
                    lines(other, offset: offset, artistOffset: offset, showsArtist: !sameArtist)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .clipped()
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) || drag != 0 else { return }
                    let dx = value.translation.width
                    // Nowhere to go that way: it gives a little, then springs back.
                    let possible = dx < 0 ? player.nextTrack != nil : player.previousTrack != nil
                    drag = possible ? dx : dx * 0.25
                }
                .onEnded { value in
                    guard drag != 0 else { return }
                    let forward = drag < 0
                    let possible = forward ? player.nextTrack != nil : player.previousTrack != nil
                    let far = abs(drag) > width * 0.35 || abs(value.predictedEndTranslation.width) > width * 0.7
                    guard possible, far else {
                        withAnimation(.spring(duration: 0.3)) { drag = 0 }
                        return
                    }
                    withAnimation(.easeOut(duration: 0.18)) {
                        drag = forward ? -width : width
                    } completion: {
                        if forward { player.next() } else { player.skipBack() }
                        // The new song now sits where the old one was: no animation back.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { drag = 0 }
                    }
                }
        )
    }

    /// A song's title and artist. The artist line is always laid out (hidden when it doesn't
    /// change), so titles stay level as they pass.
    private func lines(_ track: Track?, offset: CGFloat, artistOffset: CGFloat, showsArtist: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(track?.title ?? "Not Playing")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .offset(x: offset)
            Text(track?.displayArtist ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .offset(x: artistOffset)
                .opacity(showsArtist ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-screen player in the style of Apple Music: artwork-tinted background, large artwork
/// that shrinks into the header when the queue is shown, and system volume and AirPlay.
struct NowPlayingView: View {
    @AppStorage(MusicalKey.Notation.defaultsKey) private var notation = MusicalKey.Notation.camelot
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var artworkSpace
    @State private var showingQueue = false
    /// How far the player has been pulled down to close it.
    @State private var dragOffset: CGFloat = 0
    @State private var height: CGFloat = 900
    /// Sheets can't show the app-wide prompt, so Now Playing has its own.
    @State private var newPlaylist = NewPlaylistPrompt()

    var body: some View {
        Group {
            if sizeClass == .compact { compactBody } else { wideBody }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .background { NowPlayingBackground(artwork: player.current?.cover) }
        // Full screen like Apple Music, but it follows the finger down and the app shows behind.
        .mask {
            RoundedRectangle(cornerRadius: dragOffset > 0 ? 44 : 0, style: .continuous)
                .ignoresSafeArea()
        }
        .offset(y: dragOffset)
        .gesture(dismissDrag, isEnabled: !showingQueue)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationBackground(.clear)
        .newPlaylistPrompt()
        .environment(newPlaylist)
    }

    /// Pulling down anywhere outside the scrubber and volume closes the player.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                let down = value.translation.height
                guard dragOffset > 0 || (down > 0 && down > abs(value.translation.width)) else { return }
                dragOffset = max(down, 0)
            }
            .onEnded { value in
                guard dragOffset > 0 else { return }
                if dragOffset > 140 || value.predictedEndTranslation.height > 420 {
                    withAnimation(.easeOut(duration: 0.22)) {
                        dragOffset = height + 100
                    } completion: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { dismiss() }
                    }
                } else {
                    withAnimation(.spring(duration: 0.35)) { dragOffset = 0 }
                }
            }
    }

    // MARK: - iPhone

    private var compactBody: some View {
        VStack(spacing: 0) {
            if showingQueue {
                compactHeader
                    .padding(.top, 28)
                    .contentShape(.rect)
                    .gesture(dismissDrag)
                QueueList()
            } else {
                Spacer(minLength: 24)
                ArtworkView(data: player.current?.cover, cornerRadius: 10)
                    .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                    .frame(maxWidth: 420)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .padding(.horizontal, 22)
                    .scaleEffect(player.isPlaying ? 1 : 0.86)
                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                Spacer(minLength: 24)
                titleRow
            }

            PlayerScrubBar()
            .padding(.top, 24)

            transportControls
                .padding(.vertical, 28)

            volumeRow

            bottomRow
                .padding(.top, 24)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 32)
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
                    ArtworkView(data: player.current?.cover, cornerRadius: 14)
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
    }

    // MARK: - Pieces

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
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
                .font(.title2)
                .foregroundStyle(isFavorite ? Color.pink : Color.white)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
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
            ArtworkView(data: player.current?.cover, cornerRadius: 6)
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
            if let current = player.current {
                HStack(spacing: 8) {
                    // A song streamed from Soulseek isn't read until it's here: its tier is a guess.
                    if current.stream == nil || !current.codec.isEmpty {
                        let quality = AudioQuality(current)
                        SoundQualityBadge(quality: quality.soundQuality, detail: quality.detail)
                    }
                    if let tempoAndKey = current.tempoAndKey(notation) {
                        Text(tempoAndKey)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var moreButton: some View {
        Menu { trackActions } label: {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.semibold))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
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
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 60, height: 60)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var volumeRow: some View {
        VolumeSlider()
    }

    private var bottomRow: some View {
        HStack(alignment: .top) {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            OutputRouteButton()
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
                    Rectangle().fill(.white.opacity(0.2))
                    Rectangle()
                        .fill(.white.opacity(isDragging ? 1 : 0.7))
                        .frame(width: geometry.size.width * fraction)
                }
                .clipShape(.capsule)
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

/// System volume as a bar like the scrubber's, with the speaker icons centred beside it.
/// Only `MPVolumeView`'s slider can change output volume, so a hidden one does the setting.
private struct VolumeSlider: View {
    @State private var volume = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var dragStart: Double?
    @State private var volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))

    var body: some View {
        let isDragging = dragStart != nil
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            GeometryReader { geometry in
                // A square-ended fill inside the rounded track, like Apple Music's: a rounded fill
                // squashes at low volumes, so steps looked uneven.
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.2))
                    Rectangle()
                        .fill(.white.opacity(isDragging ? 1 : 0.7))
                        .frame(width: geometry.size.width * volume)
                }
                .clipShape(.capsule)
                .frame(height: isDragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStart ?? volume
                            dragStart = start
                            let raw = min(max(start + value.translation.width / geometry.size.width, 0), 1)
                            // In the system's own steps, so the bar doesn't jump when let go.
                            let stepped = (raw * Self.steps).rounded() / Self.steps
                            guard stepped != volume else { return }
                            withAnimation(.easeOut(duration: 0.12)) { set(stepped) }
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
            .frame(height: 24)
            .animation(.spring(duration: 0.3), value: isDragging)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(isDragging ? 0.9 : 0.6))
        .background { HiddenVolumeView(view: volumeView) }
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume)) { value in
            // The buttons move it a step at a time: slide there rather than jump.
            if dragStart == nil, Double(value) != volume { withAnimation(.easeOut(duration: 0.2)) { volume = Double(value) } }
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(volume.formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            set(min(max(volume + (direction == .increment ? 0.0625 : -0.0625), 0), 1))
        }
    }

    /// iOS keeps the volume in sixteenths, as its buttons step it.
    private static let steps = 16.0

    private func set(_ value: Double) {
        volume = value
        volumeView.subviews.compactMap { $0 as? UISlider }.first?.value = Float(value)
    }
}

/// Keeps the volume view in the window (it only works there, and it hides the system volume HUD).
private struct HiddenVolumeView: UIViewRepresentable {
    let view: MPVolumeView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        container.addSubview(view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// AirPlay, as in Apple Music: the plain AirPlay icon on this device's speaker; otherwise the
/// output's own icon with where it's playing underneath, like "iPhone → Kitchen".
private struct OutputRouteButton: View {
    @State private var outputs = AVAudioSession.sharedInstance().currentRoute.outputs

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .overlay { AirPlayButton() }
            if let caption {
                Text(caption)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(caption ?? "AirPlay")
    }

    private var isLocal: Bool {
        outputs.allSatisfy { [.builtInSpeaker, .builtInReceiver].contains($0.portType) }
    }

    private var caption: String? {
        guard !isLocal else { return nil }
        let names = outputs.map(\.portName).formatted(.list(type: .and))
        return "\(UIDevice.current.model) → \(names)"
    }

    private var symbol: String {
        guard !isLocal, let output = outputs.first else { return "airplay.audio" }
        switch output.portType {
        case .airPlay: return outputs.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            return output.portName.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case .headphones, .usbAudio: return "headphones"
        case .carAudio: return "car.fill"
        case .HDMI: return "tv"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// The system route picker, invisible over our own icon so it still opens the AirPlay menu.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .clear
        picker.activeTintColor = .clear
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
