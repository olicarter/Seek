import SwiftUI

/// An album page, the same for albums in the library and ones that aren't, as in the app.
struct AlbumView: View {
    let ref: AlbumRef
    @Environment(Connection.self) private var connection
    @Environment(TVPlayer.self) private var player
    @State private var adding = false

    var body: some View {
        Live(path: Paths.album(ref)) { (album: Pages.Album) in
            ScrollView {
                HStack(alignment: .top, spacing: 80) {
                    header(album)
                        .frame(width: 520)
                    songs(album)
                }
                .padding(80)
            }
            #if DEBUG
            // -SeekTVPlay YES: plays it as soon as it's open, for checking in the simulator.
            .task {
                if UserDefaults.standard.bool(forKey: "SeekTVPlay"), player.current == nil { play(album) }
            }
            #endif
        }
    }

    private func header(_ album: Pages.Album) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Cover(url: connection.media(album.artwork), preview: album.preview)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title).font(.title2.bold()).lineLimit(3)
                NavigationLink(value: ArtistRef(name: album.artist)) {
                    Text(album.artist).foregroundStyle(Color("AccentColor"))
                }
                .buttonStyle(.plain)
                if let year = album.year { Text(String(year)).font(.callout).foregroundStyle(.secondary) }
            }
            HStack(spacing: 24) {
                Button("Play", systemImage: "play.fill") { play(album) }
                    .disabled(queue(album).isEmpty)
                Button("Shuffle", systemImage: "shuffle") { play(album, shuffled: true) }
                    .labelStyle(.iconOnly)
                    .disabled(queue(album).isEmpty)
                if album.adding || adding {
                    ProgressView()
                } else if album.canAdd {
                    Button("Add", systemImage: "plus") {
                        adding = true
                        Task {
                            _ = try? await connection.post("/api/album/add", ref) as Pages.Album
                            adding = false
                        }
                    }
                    .labelStyle(.iconOnly)
                } else if album.inLibrary {
                    Image(systemName: "checkmark").font(.title3).foregroundStyle(.secondary)
                }
            }
            if !album.inLibrary, album.listed, album.copies == 0, album.bandcamp?.owned != true {
                Text(album.lookingForCopies ? "Looking on Soulseek…" : "No copies on Soulseek right now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let released = album.released, let date = try? Date(released + "T00:00:00Z", strategy: .iso8601) {
                    // Apple dates releases at midnight in California: the day is the UTC one.
                    Text(date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
                }
                Text(album.footer)
                if let copyright = album.copyright { Text(copyright) }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func songs(_ album: Pages.Album) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(album.songs.enumerated()), id: \.offset) { _, song in
                Button {
                    if song.file != nil { play(album, from: song) }
                } label: {
                    HStack(spacing: 24) {
                        Text(song.number.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                                .foregroundStyle(isCurrent(song) ? Color("AccentColor") : song.kind == "have" ? .primary : .secondary)
                            if let artist = song.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let tempoAndKey = song.tempoAndKey {
                            Text(tempoAndKey).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let progress = song.progress {
                            ProgressView(value: progress).frame(width: 120)
                        } else {
                            Text(duration(song.duration)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(song.file == nil)
            }
        }
        // Rows are buttons: without this, their numbers and times take the accent colour.
        .tint(.white)
    }

    private func isCurrent(_ song: Pages.Song) -> Bool {
        guard let file = song.file else { return false }
        return player.current?.url == connection.media(file)
    }

    /// The album's songs that can play: the library's, and the Mac's streams of the rest.
    private func queue(_ album: Pages.Album) -> [QueueItem] {
        album.songs.compactMap { song in
            connection.media(song.file).map {
                QueueItem(url: $0, title: song.title, artist: song.artist ?? album.artist, album: album.title,
                          artwork: connection.media(album.artwork))
            }
        }
    }

    private func play(_ album: Pages.Album, from song: Pages.Song? = nil, shuffled: Bool = false) {
        var items = queue(album)
        if shuffled { items.shuffle() }
        let start = song.flatMap { song in items.firstIndex { $0.url == connection.media(song.file) } } ?? 0
        player.play(items, startingAt: start)
    }
}

struct NowPlayingView: View {
    @Environment(TVPlayer.self) private var player

    var body: some View {
        if let song = player.current {
            HStack(spacing: 80) {
                Cover(url: song.artwork).frame(width: 600)
                VStack(alignment: .leading, spacing: 24) {
                    Text(song.title).font(.largeTitle.bold()).lineLimit(2)
                    Text(song.artist).font(.title2).foregroundStyle(.secondary)
                    Text(song.album).font(.title3).foregroundStyle(.secondary)
                    ProgressView(value: player.duration > 0 ? min(player.time / player.duration, 1) : 0)
                    HStack {
                        Text(duration(player.time)); Spacer(); Text(duration(player.duration))
                    }
                    .monospacedDigit().foregroundStyle(.secondary)
                    HStack(spacing: 32) {
                        Button("Previous", systemImage: "backward.fill") { player.previous() }
                        Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                        Button("Next", systemImage: "forward.fill") { player.next() }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    if player.queue.count > 1 {
                        Text("Song \(player.index + 1) of \(player.queue.count)").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 900)
            }
            .padding(80)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "play.circle",
                                   description: Text("Play an album from your library or search."))
        }
    }
}

struct SettingsView: View {
    @Environment(Connection.self) private var connection

    var body: some View {
        Live(path: "/api/status") { (status: Pages.Status) in
            Form {
                Section("Seek on the Mac") {
                    LabeledContent("Address", value: connection.server?.host() ?? "")
                    LabeledContent("Soulseek", value: status.username.map { "\($0) (\(status.soulseek))" } ?? "Not signed in")
                    LabeledContent("Bandcamp", value: status.bandcamp ?? "Not signed in")
                }
                Section {
                    Button("Sign Out of This TV", role: .destructive) { connection.signOut() }
                } footer: {
                    Text("Seek on the Mac signs in to Soulseek and Bandcamp; change them in its Settings.")
                }
            }
            .frame(maxWidth: 1100)
        }
    }
}
