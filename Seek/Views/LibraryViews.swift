import SwiftData
import SwiftUI

/// iPhone library tab: section links, recently added, and a search across the whole library.
struct LibraryHomeView: View {
    @Environment(LibraryStore.self) private var library
    private var tracks: [Track] { library.allTracks }
    @Environment(Router.self) private var router
    @State private var query = ""

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.libraryPath) {
            Group {
                if query.isEmpty {
                    List {
                        Section {
                            ForEach(LibrarySection.allCases.filter { $0 != .downloaded || library.usesICloud }, id: \.self) { section in
                                NavigationLink(value: section) {
                                    Label(section.rawValue, systemImage: section.systemImage)
                                        .font(.title3)
                                }
                            }
                        }
                        DiscoverHomeRow()
                        if !tracks.isEmpty {
                            Section("Recently Added") {
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 16) {
                                        ForEach(recentAlbums) { album in
                                            NavigationLink(value: album.key) {
                                                AlbumCard(album: album).frame(width: 160)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                                .scrollIndicators(.hidden)
                                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if tracks.isEmpty { EmptyLibraryView().padding(.top, 200) }
                    }
                } else {
                    LibrarySearchResults(tracks: tracks, query: query)
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Your Library")
            .libraryDestinations()
        }
    }

    /// The 12 albums with the newest songs. The songs come newest first, so this stops as soon as
    /// it has 12 rather than grouping the whole library into albums each time a song arrives.
    private var recentAlbums: [Album] {
        var keys: [AlbumKey] = []
        for track in tracks where keys.count < 12 {
            let key = track.albumKey
            if !keys.contains(key) { keys.append(key) }
        }
        let albums = library.albumsByKey
        return keys.compactMap { albums[$0] }
    }
}

struct LibrarySearchResults: View {
    let tracks: [Track]
    let query: String
    @Environment(Player.self) private var player

    var body: some View {
        let matches = LibraryGrouping.sortedByTitle(tracks.matching(query))
        let artists = LibraryGrouping.artists(tracks).filter { $0.localizedStandardContains(query) }
        let albums = LibraryGrouping.albums(tracks).filter { $0.title.localizedStandardContains(query) }
        let labels = Set(tracks.map(\.label)).filter { !$0.isEmpty && $0.localizedStandardContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        List {
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists, id: \.self) { name in
                        NavigationLink(name, value: ArtistKey(name: name))
                    }
                }
            }
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(labels, id: \.self) { name in
                        NavigationLink(value: LabelKey(name: name)) {
                            Label(name, systemImage: "building.columns")
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink(value: album.key) {
                            HStack {
                                ArtworkView(key: "album|\(album.key.artist)|\(album.key.title)", cornerRadius: 4) { album.artwork }
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading) {
                                    Text(album.title)
                                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !matches.isEmpty {
                Section("Songs") {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { offset, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(matches, startingAt: offset) }
                            .contextMenu { TrackMenu(track: track) }
                    }
                }
            }
        }
        .overlay {
            if matches.isEmpty && artists.isEmpty && albums.isEmpty && labels.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView(
            "No Music Yet",
            systemImage: "music.note",
            description: Text("Search Soulseek to download music. It syncs to your other devices through iCloud Drive.")
        )
    }
}

struct ArtistsView: View {
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var deleting: PendingDelete?

    private func askToDelete(_ name: String) {
        deleting = PendingDelete(name: name, tracks: ArtistDetailView.tracks(of: name, in: tracks))
    }

    var body: some View {
        let artists = LibraryGrouping.artists(tracks).filter { query.isEmpty || $0.localizedStandardContains(query) }
        List {
            ForEach(LetterSections.group(artists) { $0 }, id: \.letter) { section in
                Section(section.letter) {
                    ForEach(section.items, id: \.self) { name in
                        NavigationLink(name, value: ArtistKey(name: name))
                            .contextMenu {
                                DeleteFromLibraryButton { askToDelete(name) }
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { askToDelete(name) }
                            }
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .deleteConfirmation($deleting)
        .overlay { if tracks.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Artists")
        .searchable(text: $query, prompt: "Artists")
    }
}

struct AlbumsView: View {
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @AppStorage("albumsLayout") private var layout = AlbumLayout.grid

    var body: some View {
        let albums = library.albums.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
        }
        Group {
            switch layout {
            case .grid: ScrollView { AlbumGrid(albums: albums).padding() }
            case .list: AlbumList(albums: albums)
            }
        }
        .overlay { if tracks.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Albums")
        .toolbar { AlbumLayoutMenu(layout: $layout) }
        .searchable(text: $query, prompt: "Albums")
    }
}

/// Albums with songs kept on this device for offline listening, like Apple Music's Downloaded.
struct DownloadedView: View {
    @Query(filter: #Predicate<Track> { $0.keepOffline }) private var tracks: [Track]
    @State private var query = ""
    @AppStorage("downloadedLayout") private var layout = AlbumLayout.grid

    var body: some View {
        let albums = LibraryGrouping.albums(tracks).filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
        }
        Group {
            switch layout {
            case .grid: ScrollView { AlbumGrid(albums: albums).padding() }
            case .list: AlbumList(albums: albums)
            }
        }
        .toolbar { AlbumLayoutMenu(layout: $layout) }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "Nothing Downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text("Download albums, playlists or songs to listen without a connection.")
                )
            }
        }
        .navigationTitle("Downloaded")
        .searchable(text: $query, prompt: "Downloaded")
    }
}

struct SongsView: View {
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @Environment(Player.self) private var player

    var body: some View {
        let songs = LibraryGrouping.sortedByTitle(tracks.matching(query))
        // Played in the order shown, which the letter sections can change (# goes last).
        let sections = LetterSections.group(songs, by: \.title)
        let ordered = sections.flatMap(\.items)
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        List {
            if !songs.isEmpty {
                PlayShuffleButtons(tracks: ordered)
            }
            ForEach(sections, id: \.letter) { section in
                Section(section.letter) {
                    ForEach(section.items) { track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(ordered, startingAt: position[track.id] ?? 0) }
                            .contextMenu { TrackMenu(track: track) }
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .overlay { if tracks.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Songs")
        .searchable(text: $query, prompt: "Songs")
    }
}

struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks)
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                player.playShuffled(tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .listRowSeparator(.hidden)
    }
}

struct AlbumDetailView: View {
    /// Can change when Edit Info renames the album or its artist.
    @State private var key: AlbumKey
    @State private var editing = false
    @State private var confirmingDuplicates = false
    @State private var deleting: PendingDelete?
    /// The same release on the Bandcamp store, for albums that didn't come from Bandcamp.
    @State private var bandcampRelease: BandcampAPI.StoreResult?
    @State private var confirmingReplace = false
    @State private var buying: StorePurchase?
    private var tracks: [Track] { library.allTracks }
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(SoulseekClient.self) private var client
    @Environment(AlbumReferences.self) private var references
    @Environment(CopyFinder.self) private var copyFinder
    @Environment(StoreVerifier.self) private var storeVerifier
    @Environment(StreamService.self) private var streamer
    @Environment(AlbumAbout.self) private var about
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd
    @State private var confirmingUpgrade = false
    /// Other copies are listed when the album could be better, or when asked for from the menu.
    @State private var showingCopies = false
    @State private var showingArtist = false
    /// The artist's releases in Apple Music: this one's date and ℗ line, and its other versions.
    @State private var catalog: [CatalogRelease]?

    init(key: AlbumKey) {
        _key = State(initialValue: key)
    }

    /// Every song lossless: as good as Seek aims for, so other copies aren't offered unasked.
    static func isLossless(_ tracks: [Track]) -> Bool {
        tracks.allSatisfy { AudioQuality($0).isLossless }
    }

    var body: some View {
        let album = library.albumsByKey[key] ?? Album(key: key, tracks: [])
        List {
            let copies = copyFinder.copies(of: key)
            let missing = references.cached(key).map { MissingTracks.missing(from: $0, have: album.tracks) } ?? []
            let streams = Dictionary(streamer.queue(
                reference: missing.isEmpty ? nil : AlbumReference(source: .itunes, artist: key.artist, title: key.title, tracks: missing),
                artist: key.artist, album: key.title, folders: missing.isEmpty ? [] : (copies?.folders ?? []),
                bandcampPage: bandcampRelease?.url, artworkURL: nil, artwork: album.artwork
            ).map { ($0.reference, $0.track) }, uniquingKeysWith: { first, _ in first })
            let rows = albumRows(album, missing: missing, arriving: arrivingDownloads(album, missing: missing))
            // The whole album, with songs not in the library streamed when their turn comes.
            let queue: [Track] = rows.compactMap { row in
                switch row {
                case .have(_, let track): track
                case .missing(let reference): streams[reference]
                case .arriving: nil
                }
            }
            AlbumHeader(
                title: album.title, artist: album.artist, onArtist: { showingArtist = true }, year: album.year,
                isLossless: Self.isLossless(album.tracks), description: about.text(for: key),
                isDescribing: about.loading.contains(AlbumAbout.key(key)), canPlay: !queue.isEmpty,
                isPreparing: copies?.status == .searching,
                onPlay: { player.play(queue, startingAt: 0) },
                onShuffle: { player.playShuffled(queue) }
            ) {
                // Apple's cover when it has the album (see AppleCovers).
                ArtworkView(data: album.artwork, cornerRadius: 10)
            } accessory: {
                HStack(spacing: 14) {
                    OfflineButton(tracks: album.tracks)
                    // Bought: from the purchase itself, or the store's copy matched to it.
                    if let owned = bandcamp.ownedRelease(artist: key.artist, title: key.title)
                        ?? bandcampRelease.flatMap(bandcamp.owned) {
                        BandcampPurchaseButton(owned: owned) {}
                    } else if let release = bandcampRelease {
                        BandcampPurchaseButton(owned: nil, price: bandcamp.prices[release.id]) { confirmingReplace = true }
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.bottom, 8)

            if let upgrade = upgradeCopy(album, copies: copies) {
                UpgradeBanner(folder: upgrade, isUpgrading: copyFinder.upgrading.contains(AlbumReferences.key(key))) {
                    confirmingUpgrade = true
                }
                .listRowSeparator(.hidden)
            }

            ForEach(rows) { row in
                switch row {
                case .have(_, let track):
                    TrackRow(track: track, showNumber: true)
                        .onTapGesture { player.play(queue, startingAt: queue.firstIndex { $0 === track } ?? 0) }
                        .contextMenu { TrackMenu(track: track) }
                case .arriving(let transfer):
                    ArrivingTrackRow(transfer: transfer)
                case .missing(let reference):
                    // A download of the song from any copy counts, not just the copy listed first.
                    MissingTrackRow(track: reference,
                                    file: MissingTracks.download(for: reference, in: albumDownloads(album))?.file
                                        ?? copies?.folders.lazy.compactMap { MissingTracks.file(for: reference, in: $0.files) }.first,
                                    isSearching: copies?.status == .searching,
                                    playing: streams[reference])
                        .contentShape(.rect)
                        .onTapGesture {
                            if let stream = streams[reference], let start = queue.firstIndex(where: { $0 === stream }) {
                                player.play(queue, startingAt: start)
                            }
                        }
                }
            }

            let listed = catalog.flatMap { CatalogRelease.release(of: key.title, in: $0) }
            AlbumFooter(released: listed?.released, year: album.year, songs: rows.count,
                        duration: album.tracks.reduce(0) { $0 + $1.duration } + missing.reduce(0) { $0 + ($1.duration ?? 0) },
                        copyright: listed?.copyright, label: album.label)
                .listRowSeparator(.hidden)

            OtherVersionsRow(versions: catalog.map { CatalogRelease.otherVersions(of: key.title, in: $0) } ?? [])
                .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)

            DiscoveryRow(subject: .album(artist: key.artist, title: key.title))
                .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingArtist) { ArtistDetailView(name: key.artist) }
        .sheet(isPresented: $showingCopies) {
            NavigationStack {
                List {
                    if let copies = copyFinder.copies(of: key), copies.status != .unavailable {
                        OtherCopiesSection(copies: copies)
                    } else {
                        Text("Soulseek isn't available right now.").foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Other Copies")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done", systemImage: "xmark") { showingCopies = false }
                }
                .libraryDestinations()
            }
        }
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                DownloadMenuItems(tracks: album.tracks)
                Button("Edit Info", systemImage: "pencil") { editing = true }
                    .disabled(album.tracks.isEmpty)
                let extra = LibraryStore.duplicates(in: album.tracks).reduce(0) { $0 + $1.remove.count }
                Button("Remove Duplicates", systemImage: "square.on.square.dashed") { confirmingDuplicates = true }
                    .disabled(extra == 0)
                if client.savedUsername != nil {
                    Button("Other Copies on Soulseek", systemImage: "square.stack.3d.down.right") {
                        showingCopies = true
                        copyFinder.find(key, client: client, quality: quality)
                    }
                }
                if let release = bandcampRelease {
                    Divider()
                    bandcampMenuItem(release)
                    Button("Open on Bandcamp", systemImage: "safari") { buying = StorePurchase(result: release) }
                } else if let page = bandcampPage(album) {
                    Divider()
                    Button("Open on Bandcamp", systemImage: "safari") { openURL(page) }
                }
                Divider()
                DeleteFromLibraryButton {
                    deleting = PendingDelete(name: album.title, tracks: album.tracks)
                }
                .disabled(album.tracks.isEmpty)
            }
            // White like Apple Music's, not the accent colour.
            .tint(.primary)
        }
        .deleteConfirmation($deleting) { dismiss() }
        .task(id: key.artist) { catalog = await ArtistCatalog.releases(for: key.artist) }
        .task(id: key) {
            about.load(key, details: [album.year > 0 ? "Released \(album.year)" : nil,
                                     album.label.isEmpty ? nil : "Label: \(album.label)",
                                     "Tracks: " + album.tracks.prefix(15).map(\.title).joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: "\n"))
            // The real tracklist, then Soulseek when songs are missing or a lossless copy could help.
            guard !album.tracks.isEmpty else { return }
            let page = album.tracks.lazy.compactMap { $0.sourceURL.contains("bandcamp.com") ? URL(string: $0.sourceURL) : nil }.first
            // Songs from a Bandcamp purchase: that page's tracklist is the one these files follow.
            let reference = await references.reference(for: key, page: page, purchased: page != nil, trackCount: album.tracks.count)
            let missing = reference.map { MissingTracks.missing(from: $0, have: album.tracks) } ?? []
            if (!missing.isEmpty || !Self.isLossless(album.tracks)), client.savedUsername != nil {
                copyFinder.find(key, client: client, quality: quality)
            }
        }
        .confirmationDialog("Upgrade to the lossless copy?", isPresented: $confirmingUpgrade, titleVisibility: .visible) {
            if let folder = upgradeCopy(album, copies: copyFinder.copies(of: key)) {
                Button("Add and Replace") {
                    copyFinder.upgrade(key, replacing: album.tracks.map(\.path), with: folder, client: client, library: library)
                }
            }
        } message: {
            Text("Seek downloads the lossless copy from Soulseek. When it's all in, each song here with a matching title is replaced, and playlists switch to the new copy. Songs without a match are kept.")
        }
        .task(id: key) {
            // Only for albums from elsewhere (e.g. Soulseek), and only with Bandcamp signed in,
            // since that's how Seek sees the purchase arrive.
            bandcampRelease = nil
            guard bandcamp.isSignedIn, !album.tracks.isEmpty,
                  !album.tracks.contains(where: { $0.sourceURL.contains("bandcamp.com") }) else { return }
            // Not a fan upload of the same name: its songs must agree with Apple's tracklist.
            guard let found = await bandcamp.storeRelease(artist: key.artist, title: key.title),
                  await storeVerifier.isGenuine(found, as: key, references: references) else { return }
            bandcampRelease = found
            await bandcamp.loadPrice(for: found)
        }
        .confirmationDialog(replaceTitle, isPresented: $confirmingReplace, titleVisibility: .visible) {
            if let release = bandcampRelease {
                let owned = bandcamp.owned(release) != nil
                Button(owned ? "Add from Bandcamp" : "Buy on Bandcamp") {
                    bandcamp.replace(album.tracks.map(\.path), with: release)
                    if !owned { buying = StorePurchase(result: release, price: bandcamp.prices[release.id]) }
                }
            }
        } message: {
            Text("When Bandcamp's copy has downloaded, each song here with a matching title is replaced by it, and playlists switch to the new copy. Songs without a match are kept.")
        }
        .sheet(item: $buying) { BandcampStoreView(result: $0.result, buyNow: $0.price) }
        .confirmationDialog(
            duplicatesTitle(album.tracks),
            isPresented: $confirmingDuplicates,
            titleVisibility: .visible
        ) {
            Button("Remove Duplicates", role: .destructive) { library.removeDuplicates(in: album.tracks) }
        } message: {
            Text("Seek keeps the best copy of each song (lossless first) and deletes the others from your library and iCloud. Playlists switch to the copy that's kept.")
        }
        .safeAreaInset(edge: .bottom) {
            if let release = bandcampRelease, bandcamp.isReplacing(release) {
                Label("Replaced with Bandcamp's copy once it downloads", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $editing) {
            EditAlbumView(tracks: album.tracks) { newKey in key = newKey }
        }
    }
}

@MainActor
private func duplicatesTitle(_ tracks: [Track]) -> String {
    let count = LibraryStore.duplicates(in: tracks).reduce(0) { $0 + $1.remove.count }
    return count == 1 ? "Remove 1 duplicate song?" : "Remove \(count) duplicate songs?"
}

extension AlbumDetailView {
    enum AlbumRow: Identifiable {
        case have(Int, Track)
        case missing(ReferenceTrack)
        /// A song on its way that the tracklist doesn't list (a bonus track, or no tracklist).
        case arriving(Transfer)

        var id: String {
            switch self {
            case .have(_, let track): "have-\(track.persistentModelID.hashValue)"
            case .missing(let track): "missing-\(track.disc)-\(track.number)-\(track.title)"
            case .arriving(let transfer): "arriving-\(transfer.id)"
            }
        }

        var order: (Int, Int) {
            switch self {
            case .have(_, let track): (max(track.discNumber, 1), track.trackNumber > 0 ? track.trackNumber : 999)
            case .missing(let track): (max(track.disc, 1), track.number > 0 ? track.number : 999)
            case .arriving(let transfer): (1, ArrivingTrackRow.number(transfer.file.name) ?? 999)
            }
        }
    }

    /// The album's songs with the ones it's missing, and ones still downloading, slotted in by
    /// track number.
    func albumRows(_ album: Album, missing: [ReferenceTrack], arriving: [Transfer] = []) -> [AlbumRow] {
        let have = album.tracks.enumerated().map { AlbumRow.have($0.offset, $0.element) }
        let gaps = missing.map(AlbumRow.missing)
        return (have + gaps + arriving.map(AlbumRow.arriving)).enumerated().sorted { a, b in
            a.element.order == b.element.order ? a.offset < b.offset : a.element.order < b.element.order
        }.map(\.element)
    }

    /// A lossless Soulseek copy, for an album that isn't lossless yet.
    func upgradeCopy(_ album: Album, copies: CopyFinder.Copies?) -> RemoteFolder? {
        guard !album.tracks.isEmpty, !album.tracks.contains(where: { AudioQuality($0).isLossless }),
              !isBeingAdded(album) else { return nil }
        return copies?.folders.first { $0.isLossless && $0.files.count >= album.tracks.count }
    }

    /// Downloads going now for songs that have no row yet: not a gap in the tracklist (those show
    /// their own progress) and not already in the library.
    private func arrivingDownloads(_ album: Album, missing: [ReferenceTrack]) -> [Transfer] {
        let downloads = albumDownloads(album)
        let claimed = Set(missing.compactMap { MissingTracks.download(for: $0, in: downloads)?.id })
        let paths = Set(album.tracks.map(\.path))
        return downloads.filter {
            client.isOnItsWay($0) && !claimed.contains($0.id) && !($0.plannedPath.map(paths.contains) ?? false)
        }
    }

    /// This album's Soulseek downloads, from whichever copies, going or done or failed.
    private func albumDownloads(_ album: Album) -> [Transfer] {
        // A finished download whose song was since deleted doesn't count.
        client.transfers.filter {
            !$0.forStreaming && $0.state != .cancelled && ($0.state != .completed || client.isDone($0))
                && Self.isFor(album, $0)
        }
    }

    /// Songs for this album still arriving from Soulseek: judge its quality once they're in.
    private func isBeingAdded(_ album: Album) -> Bool {
        client.transfers.contains { $0.state.isActive && !$0.forStreaming && Self.isFor(album, $0) }
    }

    /// A download for this album: filed under it when added from its page, otherwise from a folder
    /// named for it (and not for a remaster or live recording of it).
    private static func isFor(_ album: Album, _ transfer: Transfer) -> Bool {
        if let target = transfer.album { return AlbumIdentity.releaseKey(target) == AlbumIdentity.releaseKey(album.key) }
        return AlbumIdentity.folder(transfer.file.folder, holds: album.title)
    }

    /// The album's Bandcamp page when it came from there: the files' own link, or the purchase.
    func bandcampPage(_ album: Album) -> URL? {
        album.tracks.lazy.compactMap { $0.sourceURL.contains("bandcamp.com") ? URL(string: $0.sourceURL) : nil }.first
            ?? bandcamp.ownedRelease(artist: key.artist, title: key.title)?.itemURL
    }

    @ViewBuilder func bandcampMenuItem(_ release: BandcampAPI.StoreResult) -> some View {
        if bandcamp.owned(release) != nil {
            Button("Replace with Bandcamp Download", systemImage: "arrow.triangle.2.circlepath") { confirmingReplace = true }
        } else {
            let price = bandcamp.prices[release.id].map { " · \($0.formatted)" } ?? ""
            Button("Buy on Bandcamp\(price)", systemImage: "cart") { confirmingReplace = true }
        }
    }

    var replaceTitle: String {
        guard let release = bandcampRelease else { return "" }
        if bandcamp.owned(release) != nil { return "Replace these files with your Bandcamp download?" }
        let price = bandcamp.prices[release.id].map { " for \($0.formatted)" } ?? ""
        return "Buy “\(release.title)”\(price) and replace these files?"
    }
}

/// Under the songs, as in Apple Music: the release date, "11 songs, 41 minutes" and the ℗ line.
/// Without Apple's ℗ line, the library's label stands in, opening everything on that label.
struct AlbumFooter: View {
    var released: Date?
    var year: Int?
    var songs: Int
    var duration: TimeInterval
    var copyright: String?
    var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let released {
                // Apple dates releases at midnight in California: the day is the UTC one.
                Text(released.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
            } else if let year, year > 0 {
                Text(verbatim: "\(year)")
            }
            if songs > 0 {
                let minutes = (duration / 60).rounded()
                if minutes > 0 {
                    let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
                    Text("^[\(songs) song](inflect: true), \(length)")
                } else {
                    Text("^[\(songs) song](inflect: true)")
                }
            }
            if let copyright {
                Text(copyright)
            } else if !label.isEmpty {
                NavigationLink(value: LabelKey(name: label)) {
                    Text(verbatim: (year ?? 0) > 0 ? "℗ \(year ?? 0) \(label)" : "℗ \(label)")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// The album's other releases in Apple Music (remastered, deluxe, live), each opening its page.
struct OtherVersionsRow: View {
    let versions: [CatalogRelease]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if !versions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Other Versions").font(.title3.bold())
                    .padding(.horizontal)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(versions, id: \.title) { version in
                            Group {
                                if let owned = library.index.album(artist: version.artist, title: version.title, named: true) {
                                    NavigationLink(value: owned) { card(version) }
                                } else {
                                    NavigationLink(value: ExternalAlbum(artist: version.artist, title: version.title,
                                                                        artworkURL: version.artworkURL)) { card(version) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func card(_ version: CatalogRelease) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.secondary.opacity(0.15)
                .aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: version.artworkURL) { Color.clear } }
                .clipShape(.rect(cornerRadius: 8))
            Text(version.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(verbatim: "\(version.year)").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .contentShape(.rect)
    }
}

/// Browse by record label: every label in the library with its albums and newest artwork.
struct LabelsView: View {
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    var body: some View {
        let albumsByLabel = Dictionary(grouping: LibraryGrouping.albums(tracks.filter { !$0.label.isEmpty }), by: \.label)
        let labels = albumsByLabel.keys
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        List {
            ForEach(LetterSections.group(labels) { $0 }, id: \.letter) { section in
                Section(section.letter) {
                    ForEach(section.items, id: \.self) { name in
                        let albums = albumsByLabel[name] ?? []
                        NavigationLink(value: LabelKey(name: name)) {
                            HStack(spacing: 12) {
                                ArtworkView(key: "label|\(name)", cornerRadius: 4) { albums.max { $0.year < $1.year }?.artwork }
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                    Text("^[\(albums.count) album](inflect: true)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .overlay {
            if albumsByLabel.isEmpty {
                ContentUnavailableView(
                    "No Labels Yet",
                    systemImage: "building.columns",
                    description: Text("Labels come from your music's tags. Add one in an album's Edit Info, or let Fix with Claude fill it in.")
                )
            }
        }
        .navigationTitle("Labels")
        .searchable(text: $query, prompt: "Labels")
    }
}

/// Every album in the library released on one label.
struct LabelDetailView: View {
    let name: String
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let albums = LibraryGrouping.albums(tracks.filter { $0.label == name }).sorted { $0.year > $1.year }
        ScrollView {
            AlbumGrid(albums: albums).padding()
        }
        .navigationTitle(name)
    }
}

struct ArtistDetailView: View {
    let name: String
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: PendingDelete?
    /// Everything they've released, from Apple Music, to show what the library doesn't have.
    @State private var catalog: [CatalogRelease] = []

    /// Their albums, and their songs on other people's (e.g. compilations), but not the rest of those.
    static func tracks(of name: String, in tracks: [Track]) -> [Track] {
        tracks.filter { $0.albumKey.artist == name || $0.artist == name }
    }

    var body: some View {
        let artistTracks = Self.tracks(of: name, in: tracks)
        let albums = LibraryGrouping.albums(artistTracks).sorted { $0.year > $1.year }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlayShuffleButtons(tracks: albums.flatMap(\.tracks))
                AlbumGrid(albums: albums)
                let missing = Self.missing(from: catalog, owned: albums)
                ForEach(CatalogSection.allCases, id: \.self) { section in
                    let releases = missing.filter { section.kinds.contains($0.kind) }
                    if !releases.isEmpty {
                        Text(section.rawValue).font(.title3.bold())
                            .padding(.top, 8)
                        CatalogGrid(releases: releases)
                    }
                }
            }
            .padding()
            DiscoveryRow(subject: .artist(name))
                .padding(.vertical)
        }
        .navigationTitle(name)
        .task(id: name) { catalog = await ArtistCatalog.releases(for: name) }
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                DownloadMenuItems(tracks: artistTracks)
                Divider()
                DeleteFromLibraryButton {
                    deleting = PendingDelete(name: name, tracks: artistTracks)
                }
                .disabled(artistTracks.isEmpty)
            }
            // White like Apple Music's, not the accent colour.
            .tint(.primary)
        }
        .deleteConfirmation($deleting) { dismiss() }
    }
}

extension ArtistDetailView {
    /// The headings the rest of an artist's catalogue goes under, as in Apple Music.
    enum CatalogSection: String, CaseIterable {
        case albums = "Albums"
        case singles = "Singles & EPs"
        case other = "Remixes & Mixes"

        var kinds: [CatalogRelease.Kind] {
            switch self {
            case .albums: [.album]
            case .singles: [.ep, .single]
            case .other: [.other]
            }
        }
    }

    /// Releases the library doesn't have, newest first, each once (Apple lists clean and explicit
    /// versions separately). Only the very release in the library is left out: its deluxe
    /// edition, or an EP sharing its name, is a release of its own and is listed.
    static func missing(from catalog: [CatalogRelease], owned: [Album]) -> [CatalogRelease] {
        let have = Set(owned.map { AlbumIdentity.title($0.title).releaseKey })
        var seen = Set<String>()
        return catalog
            .sorted { $0.released > $1.released }
            .filter { release in
                let name = AlbumIdentity.title(release.title).releaseKey
                return !have.contains(name) && seen.insert(name).inserted
            }
    }
}

/// Releases that aren't in the library, opening their album page to listen or add them.
private struct CatalogGrid: View {
    let releases: [CatalogRelease]
    @Environment(Router.self) private var router

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
            ForEach(releases, id: \.title) { release in
                NavigationLink(value: ExternalAlbum(artist: release.artist, title: release.title, artworkURL: release.artworkURL)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Color.secondary.opacity(0.15)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { RemoteImage(url: release.artworkURL) { Color.clear } }
                            .clipShape(.rect(cornerRadius: 8))
                        Text(release.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(verbatim: "\(release.year)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Search Soulseek and Bandcamp", systemImage: "magnifyingglass") {
                        router.search("\(release.artist) \(release.title)")
                    }
                }
            }
        }
    }
}

struct PlaylistsView: View {
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Environment(\.modelContext) private var context
    @State private var newName = ""
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(LetterSections.group(playlists, by: \.name), id: \.letter) { section in
                Section(section.letter) {
                    ForEach(section.items) { playlist in
                        NavigationLink(value: playlist) {
                            VStack(alignment: .leading) {
                                Text(playlist.name)
                                Text("^[\(playlist.trackPaths.count) song](inflect: true)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { section.items[$0] }.forEach(context.delete)
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .overlay {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Playlists sync to your other devices through iCloud.")
                )
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Button("New Playlist", systemImage: "plus") { showingNew = true }
        }
        .alert("New Playlist", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                context.insert(Playlist(name: newName.isEmpty ? "Untitled Playlist" : newName))
                newName = ""
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        let byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = playlist.trackPaths.enumerated().map { (offset: $0.offset, track: byPath[$0.element]) }
        let playable = entries.compactMap(\.track)
        List {
            if !playable.isEmpty {
                PlayShuffleButtons(tracks: playable)
            }
            ForEach(entries, id: \.offset) { entry in
                if let track = entry.track {
                    TrackRow(track: track)
                        .onTapGesture {
                            player.play(playable, startingAt: playable.firstIndex(where: { $0 === track }) ?? 0)
                        }
                        .contextMenu { TrackMenu(track: track) }
                } else {
                    PendingSongRow(path: playlist.trackPaths[entry.offset])
                }
            }
            .onDelete { playlist.trackPaths.remove(atOffsets: $0) }
            .onMove { playlist.trackPaths.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .toolbar {
            DownloadToolbarMenu(tracks: playable)
            EditButton()
        }
        .overlay {
            if playlist.trackPaths.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("Long-press any song and choose Add to Playlist.")
                )
            }
        }
    }
}

/// A song downloading into an album that has no row for it yet: its name, greyed, and progress.
struct ArrivingTrackRow: View {
    let transfer: Transfer
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        HStack(spacing: 12) {
            TrackNumberColumn(number: Self.number(transfer.file.name) ?? 0, isCurrent: false, isFavorite: false)
            Text(Self.title(transfer.file.name)).lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            ProgressRing(progress: transfer.ringProgress)
                .frame(width: 28)
        }
        .contextMenu {
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { client.cancel(transfer) }
        }
    }

    /// "The Killers - Sam's Town - 15 - Where…" and "15 Where…" → 15.
    static func number(_ fileName: String) -> Int? {
        let parts = parts(fileName)
        if let part = parts.first(where: { $0.count <= 3 && $0.allSatisfy(\.isNumber) }) { return Int(part) }
        return MissingTracks.leadingNumber(parts.last ?? fileName)
    }

    /// The song's name, after any artist, album and number in front of it.
    static func title(_ fileName: String) -> String {
        let parts = parts(fileName)
        if let index = parts.lastIndex(where: { $0.count <= 3 && $0.allSatisfy(\.isNumber) }), index < parts.count - 1 {
            return parts[(index + 1)...].joined(separator: " - ")
        }
        return ReleaseDetailView.trackName(fileName)
    }

    private static func parts(_ fileName: String) -> [String] {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.split(separator: /\s+[-–—]\s+/).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A song favourited or put in a playlist before it's in the library: its name, greyed, with how
/// its download is going. Once the file arrives it's an ordinary song.
struct PendingSongRow: View {
    let path: String
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        let transfer = client.transfers.first { !$0.forStreaming && $0.plannedPath == path }
        let name = ReleaseDetailView.trackName((path as NSString).lastPathComponent)
        let folders = path.split(separator: "/").dropLast().map(String.init)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(folders.suffix(2).joined(separator: " · ")).font(.subheadline).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            Spacer()
            if let transfer, client.isOnItsWay(transfer) {
                ProgressRing(progress: transfer.ringProgress)
            } else if let transfer, case .failed = transfer.state {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    .accessibilityLabel(transfer.state.label)
            }
        }
        .contextMenu {
            if let transfer {
                if transfer.state.isActive {
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { client.cancel(transfer) }
                } else if case .failed = transfer.state {
                    Button("Retry Download", systemImage: "arrow.clockwise") { client.retry(transfer) }
                }
            }
        }
    }
}

/// A song the album should have but the library doesn't, like Apple Music shows: greyed out,
/// with a download button when a Soulseek copy has it.
struct MissingTrackRow: View {
    let track: ReferenceTrack
    let file: RemoteFile?
    let isSearching: Bool
    /// The streamed song this row plays, to show when it's the one playing.
    var playing: Track? = nil
    @Environment(SoulseekClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    /// Greyed out only when there's nowhere to play it from.
    private var titleStyle: Color {
        guard let playing else { return .secondary }
        return player.current?.path == playing.path ? .accentColor : .primary
    }

    /// This song's download to the library, if one's been asked for.
    private var download: Transfer? {
        guard let file else { return nil }
        return client.transfers.first { $0.file.id == file.id && !$0.forStreaming && $0.state != .cancelled }
    }

    /// Where the song will be in the library: its download's reserved path, starting the download
    /// (or retrying a failed one) when there isn't one going. Favourites and playlists use it.
    private func libraryPath() -> String? {
        if let download {
            if case .failed = download.state { client.retry(download) }
            return client.plannedPath(for: download)
        }
        return file.flatMap { client.download($0) }.flatMap { client.plannedPath(for: $0) }
    }

    var body: some View {
        let download = download
        let reserved = download?.plannedPath ?? download?.libraryPath
        HStack(spacing: 12) {
            TrackNumberColumn(
                number: track.number,
                isCurrent: playing.map { player.current?.path == $0.path } ?? false,
                isFavorite: reserved.map { library.isFavorite(path: $0) } ?? false
            )
            Text(track.title).lineLimit(1)
                .foregroundStyle(titleStyle)
            Spacer()
            Group {
                if let file, let transfer = client.transfers.first(where: { $0.file.id == file.id && !$0.forStreaming }), client.isOnItsWay(transfer) {
                    ProgressRing(progress: transfer.ringProgress)
                } else if let file, client.isDownloading(file) {
                    Image(systemName: "checkmark.circle")
                } else if let file {
                    Button("Add \(track.title) to Library", systemImage: "plus.circle") { client.download(file) }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                } else if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 28)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            if let playing {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(playing) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(playing) }
            }
            if file != nil {
                if download == nil {
                    Button("Add to Library", systemImage: "plus") { _ = libraryPath() }
                }
                // Before it's downloaded: the song is added to the library (if it isn't on its way
                // already) and favourited or put in the playlist under the path it'll arrive at.
                let isFavorite = reserved.map { library.isFavorite(path: $0) } ?? false
                Button(isFavorite ? "Unfavourite" : "Favourite", systemImage: isFavorite ? "heart.slash" : "heart") {
                    if let path = libraryPath() { library.toggleFavorite(path: path) }
                }
                AddToPlaylistMenu(title: track.title, currentPath: reserved, path: libraryPath)
            }
            if let artist = playing?.artist, !artist.isEmpty {
                NavigationLink(value: ArtistKey(name: artist)) {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
            if let download {
                Divider()
                if download.state.isActive {
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { client.cancel(download) }
                } else if case .failed = download.state {
                    Button("Retry Download", systemImage: "arrow.clockwise") { client.retry(download) }
                }
            }
        }
    }
}

/// "FLAC available on Soulseek" with an Upgrade button, for albums only in lossy formats.
struct UpgradeBanner: View {
    let folder: RemoteFolder
    let isUpgrading: Bool
    let upgrade: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lossless copy available").font(.subheadline.weight(.semibold))
                Text("\(folder.quality) · \(folder.files.count) files · \(folder.username)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isUpgrading {
                ProgressView()
            } else {
                Button("Upgrade", action: upgrade)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.green.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

/// Soulseek copies found for a library album: preferred ones first, the rest behind "Show All".
struct OtherCopiesSection: View {
    let copies: CopyFinder.Copies

    var body: some View {
        if copies.status == .searching || copies.folders.isEmpty {
            Section {
                if copies.status == .searching {
                    Label { Text("Looking on Soulseek…") } icon: { ProgressView() }
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("No other copies on Soulseek right now.").font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("Other Copies")
            }
        } else {
            SoulseekCopiesSection(folders: copies.folders, title: "Other Copies")
        }
    }
}

/// Favourited songs, newest first, grouped by the month they were favourited, each month
/// playable on its own like a playlist.
struct FavoritesView: View {
    @Query(sort: \Favorite.favoritedAt, order: .reverse) private var favorites: [Favorite]
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        let byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = favorites.compactMap { favorite in byPath[favorite.path].map { (track: $0, date: favorite.favoritedAt) } }
        // Favourited while still downloading: shown waiting until they arrive.
        let pendingPaths = Set(client.transfers.compactMap { $0.forStreaming ? nil : $0.plannedPath })
        let pending = favorites.filter { byPath[$0.path] == nil && pendingPaths.contains($0.path) }
        let pendingByMonth = Dictionary(grouping: pending) { Calendar.current.dateInterval(of: .month, for: $0.favoritedAt)?.start ?? $0.favoritedAt }
        let months = Dictionary(grouping: entries) { Calendar.current.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
            .merging(pendingByMonth.mapValues { _ in [] }) { songs, _ in songs }
            .sorted { $0.key > $1.key }
        let all = entries.map(\.track)
        List {
            if !all.isEmpty {
                PlayShuffleButtons(tracks: all)
            }
            ForEach(months, id: \.key) { month, songs in
                let monthTracks = songs.map(\.track)
                Section {
                    ForEach(Array(monthTracks.enumerated()), id: \.element.id) { offset, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(monthTracks, startingAt: offset) }
                            .contextMenu { TrackMenu(track: track) }
                    }
                    ForEach(pendingByMonth[month] ?? [], id: \.path) { favorite in
                        PendingSongRow(path: favorite.path)
                    }
                } header: {
                    HStack {
                        Text(month.formatted(.dateTime.month(.wide).year()))
                        Spacer()
                        Button("Play \(month.formatted(.dateTime.month(.wide)))", systemImage: "play.fill") {
                            player.play(monthTracks, startingAt: 0)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Favourites")
        .overlay {
            if entries.isEmpty && pending.isEmpty {
                ContentUnavailableView(
                    "No Favourites Yet",
                    systemImage: "heart",
                    description: Text("Tap the heart on Now Playing, or long-press a song and choose Favourite.")
                )
            }
        }
    }
}

/// The album header's round download button: keeps the album on this device for offline
/// listening, shows progress while it downloads, and a tick once it's all here.
struct OfflineButton: View {
    let tracks: [Track]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let states = tracks.map { library.availability(of: $0) }
        let downloading = states.compactMap { state -> Double? in
            if case .downloading(let progress) = state { return progress } else { return nil }
        }
        if !downloading.isEmpty {
            let done = Double(states.filter { $0 == .onDevice }.count) + downloading.reduce(0, +)
            RoundProgress(progress: done / Double(max(tracks.count, 1)))
        } else if !library.usesICloud || (tracks.allSatisfy(\.keepOffline) && !states.contains(.cloudOnly)) {
            RoundButton(systemImage: "checkmark", label: "Downloaded", tint: .secondary) {}
                .disabled(true)
        } else {
            RoundButton(systemImage: "arrow.down", label: "Download") { library.download(tracks) }
        }
    }
}
