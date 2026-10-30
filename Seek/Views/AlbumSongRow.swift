import SwiftUI

/// A song on an album page that isn't playing from the library: its state (AlbumSong.State)
/// decides everything shown, so a row can't show a mix of states.
struct AlbumSongRow: View {
    let song: AlbumSong
    /// The streamed song this row plays, to show when it's the one playing.
    var playing: Track? = nil
    /// Adds just this song (offered when a copy has it).
    var onAdd: (() -> Void)? = nil
    @Environment(Player.self) private var player

    private var isCurrent: Bool { playing.map { player.current?.path == $0.path } ?? false }

    var body: some View {
        HStack(spacing: 12) {
            TrackNumberColumn(number: song.number ?? 0, isCurrent: isCurrent, isFavorite: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : song.isPlayable ? .primary : .secondary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            trailing
                .frame(width: 28)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    /// Where a song on its way, or given up on, stands.
    private var detail: String? {
        switch song.state {
        case .arriving(.connecting(let user)): "Connecting to \(user)"
        case .arriving(.queued(let user, let place)): "In \(user)'s queue" + (place.map { " (place \($0))" } ?? "")
        case .arriving(.retrying(let at)): "Trying again \(at.formatted(.relative(presentation: .named)))"
        case .arriving(.importing): "Going into the library"
        case .failed(let reason): reason
        default: nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch song.state {
        case .arriving:
            ProgressRing(progress: song.progress)
        case .available:
            if let onAdd {
                Button("Add \(song.title) to Library", systemImage: "plus.circle", action: onAdd)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
            }
        case .looking:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}
