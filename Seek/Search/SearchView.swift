import SwiftData
import SwiftUI

/// The current search grouped into releases. Regrouped (throttled) as Soulseek results arrive,
/// and again when Claude answers about folders Seek wasn't sure of.
@MainActor
@Observable
final class SearchResults {
    enum Timing {
        /// Straight away, dropping any regroup on its way.
        case now
        /// Once typing pauses.
        case afterTyping
        /// At most every 300 ms, for Soulseek results that keep arriving: waiting for a pause
        /// would show nothing until a busy search went quiet.
        case throttled
    }

    private struct Inputs {
        let query: String
        let owned: [BandcampItem]
        let store: [BandcampAPI.StoreResult]
        let folders: [RemoteFolder]
        let library: LibraryIndex
        let wishlist: Set<Int>
        let quality: QualityPreference
        let catalog: [CatalogRelease]
    }

    private(set) var result = ReleaseGrouper.Result(releases: [], songs: [], unsure: [])
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingTiming: Timing?
    @ObservationIgnored private var resolveLater: Task<Void, Never>?
    @ObservationIgnored private var latest: Inputs?
    @ObservationIgnored private var generation = 0

    func release(_ id: SearchRelease.ID) -> SearchRelease? {
        result.releases.first { $0.id == id }
    }

    func update(query: String, owned: [BandcampItem], store: [BandcampAPI.StoreResult], folders: [RemoteFolder],
                resolver: FolderResolver, library: LibraryIndex, wishlist: Set<Int>, quality: QualityPreference,
                catalog: [CatalogRelease] = [], timing: Timing = .now) {
        latest = Inputs(query: query, owned: owned, store: store, folders: folders,
                        library: library, wishlist: wishlist, quality: quality, catalog: catalog)
        generation += 1
        // A throttled regroup already on its way picks up these inputs when it runs.
        if timing == .throttled, pending != nil, pendingTiming == .throttled { return }
        schedule(timing, resolver: resolver)
    }

    private func schedule(_ timing: Timing, resolver: FolderResolver) {
        pending?.cancel()
        pendingTiming = timing
        pending = Task {
            if timing != .now { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let inputs = latest else { return }
            let started = generation
            let hints = resolver.hints
            // All the matching happens off the main thread, so typing stays smooth.
            let grouped = await Task.detached {
                ReleaseGrouper.group(query: inputs.query, owned: inputs.owned, store: inputs.store,
                                     folders: inputs.folders, hints: hints, library: inputs.library,
                                     wishlist: inputs.wishlist, quality: inputs.quality, catalog: inputs.catalog)
            }.value
            guard !Task.isCancelled else { return }
            pending = nil
            pendingTiming = nil
            result = grouped
            // More arrived while grouping: go again shortly.
            if generation != started { schedule(.throttled, resolver: resolver) }
            // Once Soulseek goes quiet for a few seconds, ask Claude about the folders left unsure.
            resolveLater?.cancel()
            if !grouped.unsure.isEmpty {
                resolveLater = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    resolver.resolve(grouped.unsure, releases: grouped.releases)
                }
            }
        }
    }
}

/// Search across your Bandcamp purchases, the Bandcamp store and Soulseek, shown as one row per
/// release with the best way to get it.
struct SearchView: View {
    @Environment(Router.self) private var router
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(FolderResolver.self) private var resolver
    @Environment(StoreVerifier.self) private var storeVerifier
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var submitted = ""
    @State private var losslessOnly = false
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd
    @State private var freeSlotsOnly = false
    @State private var showAllFolders = false
    @State private var storeFound: [BandcampAPI.StoreResult] = []
    /// The artist's Apple Music catalogue, when the search is an artist's name.
    @State private var catalogFound: [CatalogRelease] = []
    /// What the store and catalogue results above are for, and how many songs the library index
    /// was built from. Coming back from a result reruns the tasks below; with these they keep
    /// what they have, so the list doesn't briefly reorder without them.
    @State private var storeLoadedFor: String?
    @State private var indexedTrackCount: Int?
    @State private var results = SearchResults()
    /// Pages opened from the results, all by value (see `openArtist`).
    @State private var path = NavigationPath()
    @State private var buying: StorePurchase?
    /// Rebuilt only when the library changes, never while typing.
    @State private var libraryIndex = LibraryIndex(albums: [])

    private var search: SearchSession? {
        client.currentSearch.flatMap { $0.query == submitted ? $0 : nil }
    }

    private var folders: [RemoteFolder] {
        // Folders opened since the search show every file, not just the ones that matched.
        (search?.folders ?? []).map(client.complete).filter { (!losslessOnly || $0.isLossless) && (!freeSlotsOnly || $0.hasFreeSlot) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            resultsList
                .navigationTitle("Search")
                .searchable(text: $query, prompt: "Artists, albums, songs")
                .onSubmit(of: .search) {
                    submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    client.search(submitted)
                }
                .onChange(of: router.pendingSearch, initial: true) { _, text in
                    guard let text else { return }
                    router.pendingSearch = nil
                    path = NavigationPath()
                    query = text
                    submitted = text
                    client.search(text)
                }
                .toolbar { filterMenu }
                .modifier(ReleaseDestinations(compact: sizeClass == .compact, results: results, buying: $buying))
                .task(id: submitted) {
                    guard storeLoadedFor != submitted else { return }
                    storeFound = []
                    catalogFound = []
                    guard !submitted.isEmpty else { return }
                    async let catalog = ArtistCatalog.releases(for: submitted)
                    let found = await bandcamp.storeSearch(submitted)
                    let releases = await catalog
                    guard !Task.isCancelled else { return }
                    storeFound = found
                    catalogFound = releases
                    storeLoadedFor = submitted
                }
                // Not an artist's name: the catalogues of the artists found, for the releases named.
                .task(id: resultArtists) {
                    guard storeLoadedFor == submitted, !submitted.isEmpty, !resultArtists.isEmpty,
                          catalogFound.allSatisfy({ !ReleaseText.artistsMatch($0.artist, submitted) }) else { return }
                    let named = await ArtistCatalog.releases(named: submitted, by: resultArtists)
                    guard !Task.isCancelled, !named.isEmpty else { return }
                    let known = Set(catalogFound.map { "\($0.artist)|\($0.title)|\($0.released)" })
                    catalogFound += named.filter { !known.contains("\($0.artist)|\($0.title)|\($0.released)") }
                }
                .modifier(regroupTriggers)
                .task(id: tracks.count) {
                    guard indexedTrackCount != tracks.count else { return }
                    let count = tracks.count
                    let keys = Array(Set(tracks.map(\.albumKey)))
                    libraryIndex = await Task.detached { LibraryIndex(albums: keys) }.value
                    indexedTrackCount = count
                    regroup()
                }
                .fullScreenCover(item: $buying) { BandcampStoreView(result: $0.result, buyNow: $0.price, replacing: $0.replacing) }
        }
        .environment(\.openArtist) { path.append($0) }
        .onAppear {
            client.searchViewAppeared()
            Task { await bandcamp.refreshIfStale() }
        }
        .onDisappear { client.searchViewDisappeared() }
    }

    @ViewBuilder private var resultsList: some View {
        if query.isEmpty && submitted.isEmpty {
            ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text(emptyPrompt))
        } else {
            List {
                artistSection
                releasesSection
                songsSection
                if showAllFolders { allFoldersSection }
            }
        }
    }

    private var filterMenu: some View {
        Menu("Filter", systemImage: "line.3.horizontal.decrease") {
            Toggle("Lossless Only", isOn: $losslessOnly)
            Toggle("Free Slots Only", isOn: $freeSlotsOnly)
            Divider()
            Toggle("Show All Folders", isOn: $showAllFolders)
        }
    }

    /// Regroups whenever any source changes.
    private var regroupTriggers: RegroupTriggers {
        RegroupTriggers(
            query: query, submitted: submitted, storeCount: storeFound.count - storeVerifier.rejected.count, catalogCount: catalogFound.count,
            folderCount: search?.folders.count ?? 0,
            hintCount: resolver.hints.count, losslessOnly: losslessOnly, freeSlotsOnly: freeSlotsOnly, quality: quality,
            purchaseCount: bandcamp.items.count, fetchedFolders: client.folderContents.count, regroup: regroup
        )
    }

    /// The artists of the top few releases found, whose catalogues can tell their editions apart.
    private var resultArtists: [String] {
        var artists: [String] = []
        for release in results.result.releases where !release.folders.isEmpty && release.artist != "Unknown Artist" {
            if !artists.contains(where: { ReleaseText.artistsMatch($0, release.artist) }) { artists.append(release.artist) }
            if artists.count == 3 { break }
        }
        return artists
    }

    private func regroup(_ timing: SearchResults.Timing = .now) {
        let text = submitted.isEmpty ? query : submitted
        results.update(
            query: text,
            owned: bandcamp.search(query.isEmpty ? submitted : query),
            store: bandcamp.storeResults(for: submitted, found: storeFound).filter { !storeVerifier.rejected.contains($0.id) },
            folders: folders,
            resolver: resolver,
            library: libraryIndex,
            wishlist: Set(bandcamp.wishlist.map(\.id)),
            quality: quality,
            // Only for the search it was looked up for, not one being typed.
            catalog: query.isEmpty || query == submitted ? catalogFound : [],
            timing: timing
        )
    }

    private var emptyPrompt: String {
        bandcamp.isSignedIn
            ? "Search your Bandcamp purchases, the Bandcamp store and Soulseek."
            : "Search Soulseek and the Bandcamp store. Sign in to Bandcamp in Settings to include your purchases."
    }

    // MARK: - Releases

    /// The artist searched for, as in Apple Music: their page, with everything they've released.
    /// From Apple's catalogue, or the library when Apple doesn't know them.
    private var searchedArtist: (name: String, artwork: URL?)? {
        guard !submitted.isEmpty, query.isEmpty || query == submitted else { return nil }
        let wanted = ReleaseText.artistMatchName(submitted)
        let owned = library.albums.first { ReleaseText.artistMatchName($0.artist) == wanted }?.artist
        let theirs = catalogFound.filter { ReleaseText.artistMatchName($0.artist) == wanted }
        guard let name = owned ?? theirs.first?.artist else { return nil }
        let newest = theirs.filter { $0.kind == .album }.max { $0.released < $1.released } ?? theirs.max { $0.released < $1.released }
        return (name, newest?.artworkURL)
    }

    @ViewBuilder private var artistSection: some View {
        if let artist = searchedArtist {
            Section {
                NavigationLink(value: ArtistKey(name: artist.name)) {
                    HStack(spacing: 14) {
                        Color.secondary.opacity(0.15)
                            .overlay {
                                RemoteImage(url: artist.artwork) {
                                    Image(systemName: "music.mic").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(.circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.headline)
                            Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var releasesSection: some View {
        let releases = results.result.releases
        Section {
            ForEach(releases) { release in
                ReleaseRow(release: release, inLibrary: release.inLibrary, buying: $buying)
                    .contentShape(.rect)
                    .onTapGesture { path.append(SearchResultPage(id: release.id)) }
            }
            status
        } header: {
            if !releases.isEmpty { Text("Releases") }
        }
    }

    @ViewBuilder private var status: some View {
        if !submitted.isEmpty {
            if client.savedUsername == nil {
                Text("Sign in to Soulseek in Settings to include other people's music.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if case .failed(let reason) = client.status {
                HStack {
                    Text(reason).foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect") {
                        Task {
                            await client.connectIfNeeded()
                            client.search(submitted)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.subheadline)
            } else if client.status != .connected || search == nil {
                Label { Text("Signing in to Soulseek…") } icon: { ProgressView() }
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let search {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date.timeIntervalSince(search.startedAt) < 15 {
                        Label { Text("Searching Soulseek…") } icon: { ProgressView() }
                    } else if resolver.isResolving {
                        Label { Text("Matching folders with Claude…") } icon: { ProgressView() }
                    } else if results.result.releases.isEmpty, results.result.songs.isEmpty {
                        Text("No results")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Songs

    @ViewBuilder private var songsSection: some View {
        let songs = results.result.songs
        if !songs.isEmpty {
            Section("Songs") {
                ForEach(songs.prefix(20)) { file in
                    SongRow(file: file)
                }
            }
        }
    }

    // MARK: - All folders

    @ViewBuilder private var allFoldersSection: some View {
        if !submitted.isEmpty {
            let sorted = folders.sorted { ReleaseGrouper.better($0, $1, quality: quality) }
            Section {
                ForEach(sorted) { folder in
                    NavigationLink(value: folder) {
                        RemoteFolderRow(folder: folder)
                    }
                    .swipeActions {
                        Button("Add to Library", systemImage: "plus") { client.download(folder) }
                            .tint(.accentColor)
                    }
                }
            } header: {
                Text("All Soulseek Folders · \(sorted.count)")
            }
        }
    }
}

// MARK: - Getting a release

/// The best way to get a release right now, in order: it's in the library; it's a Bandcamp
/// purchase (downloading or ready to download); it's free on Soulseek; it's for sale on Bandcamp.
@MainActor
struct ReleaseAction {
    enum Kind {
        case inLibrary(AlbumKey)
        case downloadingBandcamp(Double?)
        case downloadBandcamp(BandcampItem)
        case downloadingSoulseek(Double?)
        case downloadSoulseek(RemoteFolder)
        case buy(BandcampAPI.StoreResult, BandcampAPI.Price?)
        case none
    }

    let kind: Kind

    init(release: SearchRelease, inLibrary: AlbumKey?, client: SoulseekClient, bandcamp: BandcampClient) {
        if let inLibrary {
            kind = .inLibrary(inLibrary)
        } else if let item = release.owned, let download = bandcamp.download(for: item), download.state.isActive {
            kind = .downloadingBandcamp(download.ringProgress)
        } else if let item = release.owned, item.redownloadURL != nil {
            // Already bought: the official files, at no cost, beat any Soulseek copy.
            kind = .downloadBandcamp(item)
        } else if let progress = Self.soulseekProgress(release, client: client) {
            kind = .downloadingSoulseek(progress)
        } else if let folder = release.bestFolder {
            kind = .downloadSoulseek(folder)
        } else if let store = release.store {
            kind = .buy(store, bandcamp.prices[store.id])
        } else {
            kind = .none
        }
    }

    /// Progress of any of the release's Soulseek folders being downloaded.
    static func soulseekProgress(_ release: SearchRelease, client: SoulseekClient) -> Double? {
        // Any song from the release's copies: adding it takes each from its copy's full folder,
        // not only the files the search listed.
        let folderIDs = Set(release.folders.map(\.id))
        guard !release.fileIDs.isEmpty || !folderIDs.isEmpty else { return nil }
        // Finished songs still count, so the ring doesn't fall back each time one completes.
        // Finished ones only while their songs are still in the library: once all are in, the
        // album still reads as added (a check) rather than offering to add it again.
        let transfers = client.transfers.filter {
            (client.isOnItsWay($0) || client.isDone($0)) && !$0.forStreaming
                && (release.fileIDs.contains($0.file.id) || folderIDs.contains("\($0.file.username)\u{0}\($0.file.folder)"))
        }
        guard !transfers.isEmpty else { return nil }
        let size = transfers.reduce(0) { $0 + $1.size }
        return size > 0 ? Double(transfers.reduce(0) { $0 + $1.bytesReceived }) / Double(size) : 0
    }
}

/// One release: cover, name, where it's available, and one button for the best way to get it.
struct ReleaseRow: View {
    let release: SearchRelease
    let inLibrary: AlbumKey?
    @Binding var buying: StorePurchase?
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(StoreVerifier.self) private var storeVerifier
    @Environment(AlbumReferences.self) private var references

    var body: some View {
        HStack(spacing: 12) {
            ReleaseArtwork(url: release.artworkURL, size: 56)
            // Takes whatever width is left; nothing in it may push the artwork or button out.
            VStack(alignment: .leading, spacing: 3) {
                Text(release.title).font(.body.weight(.medium)).lineLimit(2)
                // The track count goes first when it doesn't fit.
                ViewThatFits(in: .horizontal) {
                    Text(subtitle(withCount: true))
                    Text(subtitle(withCount: false))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                SourceBadges(release: release, inLibrary: inLibrary != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReleasePrimaryButton(release: release, inLibrary: inLibrary, buying: $buying, compact: true)
                .fixedSize()
        }
        .task(id: release.store?.id) {
            guard let store = release.store, release.owned == nil else { return }
            // Where Apple knows the album, make sure this isn't a fan upload of the same name.
            if release.catalog != nil { storeVerifier.verify(store, as: AlbumKey(artist: release.artist, title: release.title), references: references) }
            await bandcamp.loadPrice(for: store)
        }
    }

    private func subtitle(withCount: Bool) -> String {
        var parts = [release.artist]
        if let kind = release.catalog?.kind, kind != .other { parts.insert(kind.name, at: 0) }
        if let year = release.year { parts.append(String(year)) }
        if release.isTrack {
            parts.append("Track")
        } else if withCount, let count = release.trackCount {
            parts.append(count == 1 ? "1 track" : "\(count) tracks")
        }
        return parts.joined(separator: " · ")
    }
}

struct ReleaseArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        // Shared with suggestion cards, so an album opened from one shows its cover at once.
        RemoteImage(url: url) {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size > 100 ? 10 : 5))
    }
}

/// Where a release can come from: "Purchased" or "Bandcamp", "Soulseek ×14", "Lossless". Shortens
/// to icons and counts when the row is narrow, and never makes the row wider.
struct SourceBadges: View {
    let release: SearchRelease
    let inLibrary: Bool
    @Environment(BandcampClient.self) private var bandcamp

    var body: some View {
        ViewThatFits(in: .horizontal) {
            badges(short: false)
            badges(short: true)
            HStack(spacing: 4) {
                ForEach(items, id: \.label) { item in
                    Image(systemName: item.icon ?? "waveform").font(.caption2).foregroundStyle(item.tint)
                }
            }
        }
        .lineLimit(1)
    }

    private struct Item {
        var label: String
        var short: String
        var icon: String?
        var tint: Color
    }

    private var items: [Item] {
        var items: [Item] = []
        if inLibrary { items.append(Item(label: "In Library", short: "Library", icon: "checkmark", tint: .green)) }
        if release.owned != nil {
            items.append(Item(label: "Purchased", short: "", icon: "bag.fill", tint: .teal))
        } else if let store = release.store {
            // Sellers taking PayPal only can't be bought in one tap with a saved card.
            let paypal = bandcamp.prices[store.id]?.paypalOnly == true
            items.append(Item(label: paypal ? "Bandcamp · PayPal" : "Bandcamp", short: paypal ? "PayPal" : "",
                              icon: "cart", tint: .teal))
        }
        if !release.folders.isEmpty {
            let count = release.folders.count
            items.append(Item(label: count == 1 ? "Soulseek" : "Soulseek ×\(count)", short: count == 1 ? "" : "\(count)",
                              icon: "arrow.down.circle", tint: .blue))
        }
        if let best = release.bestFolder, best.isHiRes {
            items.append(Item(label: "Hi-Res", short: "Hi-Res", icon: nil, tint: .purple))
        } else if release.isLossless {
            items.append(Item(label: "Lossless", short: "Lossless", icon: nil, tint: .green))
        }
        return items
    }

    private func badges(short: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.label) { item in
                badge(short ? item.short : item.label, systemImage: item.icon, tint: item.tint)
            }
        }
    }

    private func badge(_ text: String, systemImage: String?, tint: Color) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            if !text.isEmpty { Text(text) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: .capsule)
        .fixedSize()
    }
}

/// The one button for a release, plus a menu of every other way to get it.
struct ReleasePrimaryButton: View {
    let release: SearchRelease
    let inLibrary: AlbumKey?
    @Binding var buying: StorePurchase?
    var compact: Bool
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(Router.self) private var router
    @Environment(AlbumAdder.self) private var adder
    @Environment(AlbumReferences.self) private var references

    var body: some View {
        let action = ReleaseAction(release: release, inLibrary: inLibrary, client: client, bandcamp: bandcamp)
        let key = AlbumKey(artist: release.artist, title: release.title)
        HStack(spacing: 6) {
            switch action.kind {
            case .inLibrary(let key):
                NavigationLink(value: key) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open in Library")
            case .downloadingBandcamp(let progress), .downloadingSoulseek(let progress):
                ProgressRing(progress: progress, size: 24)
            case .downloadBandcamp(let item):
                button("Add to Library", systemImage: "plus") { download(item) }
            case .downloadSoulseek:
                if adder.isChecking(key) {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else {
                    button("Add to Library", systemImage: "plus") {
                        adder.add(key, from: release.folders, client: client, references: references)
                    }
                }
            case .buy(let store, let price):
                if let price, price.amount > 0, bandcamp.isSignedIn {
                    button(price.shortFormatted, systemImage: nil) { buying = StorePurchase(result: store, price: price) }
                        .accessibilityLabel("Buy for \(price.formatted)")
                } else {
                    button("Buy", systemImage: compact ? nil : "cart") { buying = StorePurchase(result: store) }
                }
            case .none:
                EmptyView()
            }
            moreMenu
        }
    }

    private func download(_ item: BandcampItem) {
        if let existing = bandcamp.download(for: item) { bandcamp.retry(existing) } else { bandcamp.download(item) }
    }

    /// In rows, Add is just its plus and Buy just its word or price, so titles keep the room.
    private func button(_ title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let systemImage, !compact || systemImage == "plus" {
                Label(title, systemImage: systemImage).labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            } else {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityLabel(title)
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(compact ? .small : .large)
        .fixedSize()
    }

    /// Every other way to get it, so the button's choice can always be overridden.
    private var moreMenu: some View {
        Menu {
            ReleaseMenuItems(release: release, buying: $buying)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("More Options")
    }
}

/// A single matching song from a folder that isn't one release.
struct SongRow: View {
    let file: RemoteFile
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((file.name as NSString).deletingPathExtension).lineLimit(2)
                Text("\(file.quality) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) · \(file.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if client.isDownloading(file) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Button("Add to Library", systemImage: "plus.circle") { client.download(file) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Release details

/// Everything about one release: its sources (each Soulseek folder and Bandcamp), tracks and
/// similar albums. A sheet on iPhone; pushed alongside the results on iPad and Mac.
struct ReleaseDetailView: View {
    /// Looked up on each render, so the page follows the release as more sources turn up.
    let source: () -> SearchRelease?
    @Binding var buying: StorePurchase?
    /// How the Soulseek search for this page is going, when the page runs its own.
    var soulseekStatus: CopyFinder.Status?

    init(id: SearchRelease.ID, results: SearchResults, buying: Binding<StorePurchase?>) {
        source = { results.release(id) }
        _buying = buying
    }

    init(release: @escaping () -> SearchRelease?, buying: Binding<StorePurchase?>, soulseekStatus: CopyFinder.Status?) {
        source = release
        _buying = buying
        self.soulseekStatus = soulseekStatus
    }
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @State private var loadingFolder: String?
    @State private var showingCopies = false
    @Environment(\.openArtist) private var openArtist
    @Environment(Router.self) private var router
    /// The artist's releases in Apple Music: this one's date and ℗ line, and its other versions.
    @State private var catalog: [CatalogRelease]?
    @Environment(AlbumReferences.self) private var references
    @Environment(Player.self) private var player
    @Environment(StreamService.self) private var streamer
    @Environment(AlbumAbout.self) private var about
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd

    static func completeFirst(_ release: SearchRelease, expectedTracks: Int?, client: SoulseekClient,
                              quality: QualityPreference) -> SearchRelease {
        guard expectedTracks != nil else { return release }
        var release = release
        release.folders = ReleaseGrouper.sortedBest(release.folders.map(client.complete), quality: quality,
                                                    expectedTracks: expectedTracks)
        return release
    }

    /// Each song with somewhere to play it from, as streamed tracks.
    private func streamQueue(_ release: SearchRelease) -> [(reference: ReferenceTrack, track: Track)] {
        guard release.inLibrary == nil else { return [] }
        return streamer.queue(
            reference: references.cached(AlbumKey(artist: release.artist, title: release.title)),
            artist: release.artist, album: release.title,
            folders: release.folders.map(client.complete),
            bandcampPage: release.store?.url ?? release.owned?.itemURL,
            artworkURL: release.artworkURL.map(Self.large)
        )
    }

    var body: some View {
        if let found = source() {
            // Copies with the whole album first, by the tracklist when there is one: the one the
            // Add button takes, and the ones counted as ready, have all the songs.
            let expected = references.cached(AlbumKey(artist: found.artist, title: found.title))?.tracks.count ?? found.catalog?.trackCount
            let release = Self.completeFirst(found, expectedTracks: expected, client: client, quality: quality)
            let inLibrary = release.inLibrary
            let queue = streamQueue(release)
            let key = AlbumKey(artist: release.artist, title: release.title)
            let reference = references.cached(key)
            let listed = catalog.flatMap { CatalogRelease.release(of: release.title, in: $0) } ?? release.catalog
            AlbumPage(
                artist: release.artist, title: release.title,
                footer: AlbumFooter(released: listed?.released, year: release.year ?? reference?.year,
                                    songs: reference?.tracks.count ?? release.bestFolder?.files.count ?? 0,
                                    duration: reference.map { $0.tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
                                        ?? Double(release.bestFolder?.files.reduce(0) { $0 + ($1.duration ?? 0) } ?? 0),
                                    copyright: listed?.copyright),
                versions: catalog.map { CatalogRelease.otherVersions(of: release.title, in: $0) } ?? []
            ) {
                AlbumHeader(
                    title: release.title, artist: release.artist,
                    onArtist: release.artist == "Unknown Artist" ? nil : { openArtistPage(release.artist) },
                    year: release.year ?? reference?.year,
                    isLossless: release.isLossless, description: about.text(for: key),
                    isDescribing: about.loading.contains(AlbumAbout.key(key)), canPlay: !queue.isEmpty,
                    isPreparing: soulseekStatus == .searching || client.currentSearch != nil && release.folders.isEmpty,
                    // Played without adding to the library: songs are fetched as they come up.
                    onPlay: { player.play(queue.map(\.track), startingAt: 0) },
                    onShuffle: { player.playShuffled(queue.map(\.track)) }
                ) {
                    ReleaseArtwork(url: release.artworkURL.map(Self.large), size: 300)
                        .aspectRatio(1, contentMode: .fit)
                } accessory: {
                    HStack(spacing: 14) {
                        ReleaseAccessory(release: release, inLibrary: inLibrary,
                                         isPreparing: soulseekStatus == .searching)
                        if let owned = release.owned {
                            BandcampPurchaseButton(owned: owned) {}
                        } else if let store = release.store {
                            let price = bandcamp.prices[store.id]
                            BandcampPurchaseButton(owned: nil, price: price) {
                                buying = StorePurchase(result: store, price: bandcamp.isSignedIn ? price.flatMap { $0.amount > 0 ? $0 : nil } : nil)
                            }
                        }
                    }
                }
            } songs: {
                if let reference {
                    // The real tracklist, each song downloadable from whichever copy has it.
                    let files = release.folders.map(client.complete).flatMap(\.files)
                    // Adding the album may take each song from a different copy than the one
                    // listed first, so a song's download from any of the copies counts.
                    let folderIDs = Set(release.folders.map(\.id))
                    let downloads = client.transfers.filter {
                        !$0.forStreaming && $0.state != .cancelled && folderIDs.contains("\($0.file.username)\u{0}\($0.file.folder)")
                    }
                    ForEach(reference.tracks, id: \.self) { track in
                        let stream = queue.firstIndex { $0.reference == track }
                        MissingTrackRow(track: track,
                                        file: MissingTracks.download(for: track, in: downloads)?.file
                                            ?? MissingTracks.file(for: track, in: files),
                                        isSearching: false,
                                        playing: stream.map { queue[$0].track })
                            .contentShape(.rect)
                            .onTapGesture {
                                if let stream { player.play(queue.map(\.track), startingAt: stream) }
                            }
                    }
                } else if let folder = release.bestFolder {
                    // No tracklist: the best copy's songs, by their file names.
                    ForEach(Array(folder.files.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            Text(Self.trackName(file.name)).lineLimit(1)
                            Spacer()
                        }
                    }
                    if loadingFolder == folder.id {
                        Label { Text("Getting the full folder…") } icon: { ProgressView().controlSize(.small) }
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showingCopies) {
                NavigationStack {
                    List {
                        if release.folders.isEmpty {
                            Text(soulseekStatus == .searching ? "Looking on Soulseek…" : "No copies found on Soulseek.")
                                .foregroundStyle(.secondary)
                        } else {
                            SoulseekCopiesSection(folders: release.folders, expectedTracks: expected,
                                                  isLooking: soulseekStatus == .searching, album: key)
                        }
                    }
                    .navigationTitle("Copies on Soulseek")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Done", systemImage: "xmark") { showingCopies = false }
                    }
                    .libraryDestinations()
                    .albumAddFailureAlert()
                }
            }
            .toolbar {
                Menu("More", systemImage: "ellipsis") {
                    ReleaseMenuItems(release: release, buying: $buying)
                    if !release.folders.isEmpty || soulseekStatus == .searching {
                        Button("Copies on Soulseek", systemImage: "square.stack.3d.down.right") { showingCopies = true }
                    }
                }
                // White like Apple Music's, not the accent colour.
                .tint(.primary)
            }
            .task(id: release.artist) {
                guard release.artist != "Unknown Artist" else { return }
                catalog = await ArtistCatalog.releases(for: release.artist)
            }
            // Left open a moment: the first song starts fetching, so Play starts at once.
            .task(id: streamQueue(release).first?.track.path) {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                streamer.warm(streamQueue(release).first?.track)
            }
            // The cover shown here is Apple's: once the album is being added, it keeps it from the
            // first song rather than showing the files' own until a lookup finds it.
            .task(id: ReleaseAction.soulseekProgress(release, client: client) != nil || release.inLibrary != nil) {
                guard ReleaseAction.soulseekProgress(release, client: client) != nil || release.inLibrary != nil,
                      let url = release.catalog?.artworkURL ?? release.trustedArtwork else { return }
                AppleCovers.shared.prime(AlbumKey(artist: release.artist, title: release.title), artworkURL: url)
            }
            .task(id: release.store?.id) {
                if let store = release.store, release.owned == nil { await bandcamp.loadPrice(for: store) }
            }
            .task(id: release.id) {
                guard release.artist != "Unknown Artist" else { return }
                let key = AlbumKey(artist: release.artist, title: release.title)
                about.load(key, details: [release.year.map { "Released \($0)" }, release.seller.map { "Released by \($0)" }]
                    .compactMap { $0 }.joined(separator: "\n"))
                _ = await references.reference(for: AlbumKey(artist: release.artist, title: release.title),
                                               page: release.owned?.itemURL ?? release.store?.url, purchased: release.owned != nil)
                // The best copy's full folder, so each track can be matched to a file.
                if let folder = release.bestFolder, client.folderContents[folder.id] == nil {
                    loadingFolder = folder.id
                    _ = try? await client.contents(of: folder)
                    loadingFolder = nil
                }
            }
        } else {
            ContentUnavailableView("No Longer in Results", systemImage: "magnifyingglass")
        }
    }

    /// Bandcamp's 350-pixel thumbnails as 700-pixel art for the header.
    static func large(_ url: URL) -> URL {
        URL(string: url.absoluteString.replacingOccurrences(of: "_2.jpg", with: "_16.jpg")) ?? url
    }

    func openArtistPage(_ name: String) {
        let artist = ArtistKey(name: name)
        if let openArtist { openArtist(artist) } else { router.show(artist) }
    }

    /// "01 - Cryogeyser - Glitch.flac" → "Glitch".
    static func trackName(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var parts = stem.split(separator: /\s+[-–—]\s+/).map(String.init)
        // "Artist - Album - 02 - Song" or "Artist - Album - 02 Song": the song comes after its number.
        if let index = parts.lastIndex(where: { $0.count <= 3 && $0.allSatisfy(\.isNumber) }), index > 0, index < parts.count - 1 {
            return parts[(index + 1)...].joined(separator: " - ")
        }
        if parts.count > 2, let last = parts.last, last.firstMatch(of: /^\d{1,3}[\s.\-_]+\D/) != nil {
            return last.replacing(/^\d{1,3}[\s.\-_]+/, with: "")
        }
        if let first = parts.first, first.allSatisfy(\.isNumber), parts.count > 1 { parts.removeFirst() }
        if parts.count > 1 { parts.removeFirst() }
        let name = parts.joined(separator: " - ")
        return name.replacing(/^\d{1,3}[\s.\-_]+/, with: "")
    }
}

private struct RegroupTriggers: ViewModifier {
    let query: String
    let submitted: String
    let storeCount: Int
    let catalogCount: Int
    let folderCount: Int
    let hintCount: Int
    let losslessOnly: Bool
    let freeSlotsOnly: Bool
    let quality: QualityPreference
    let purchaseCount: Int
    let fetchedFolders: Int
    let regroup: (SearchResults.Timing) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: query) { regroup(.afterTyping) }
            .onChange(of: submitted) { regroup(.now) }
            .onChange(of: storeCount) { regroup(.now) }
            .onChange(of: catalogCount) { regroup(.now) }
            .onChange(of: folderCount) { regroup(.throttled) }
            .onChange(of: hintCount) { regroup(.now) }
            .onChange(of: losslessOnly) { regroup(.now) }
            .onChange(of: quality) { regroup(.now) }
            .onChange(of: freeSlotsOnly) { regroup(.now) }
            .onChange(of: purchaseCount) { regroup(.afterTyping) }
            .onChange(of: fetchedFolders) { regroup(.now) }
    }
}

/// A search result's page, opened by value like every other page.
struct SearchResultPage: Hashable {
    let id: SearchRelease.ID
}

/// Release details, pushed like any other page. A release already in the library opens its
/// library album page, which has everything the release page would and more.
private struct ReleaseDestinations: ViewModifier {
    let compact: Bool
    let results: SearchResults
    @Binding var buying: StorePurchase?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: SearchResultPage.self) { page in
                let id = page.id
                if let key = results.release(id)?.inLibrary {
                    AlbumDetailView(key: key)
                } else if let release = results.release(id), release.isCatalogOnly {
                    // Only known from Apple's catalogue: the album page looks on every source.
                    ExternalAlbumView(album: ExternalAlbum(artist: release.artist, title: release.title, artworkURL: release.artworkURL))
                } else {
                    ReleaseDetailView(id: id, results: results, buying: $buying)
                }
            }
            .libraryDestinations()
    }
}

/// Lets a label style be chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Which Soulseek copies to show first: the ones at the preferred quality that can be downloaded
/// right now (a free slot). The rest stay a tap away.
enum CopyFilter {
    static func meetsTarget(_ folder: RemoteFolder, quality: QualityPreference) -> Bool {
        quality == .cd ? folder.isLossless && !folder.isHiRes : folder.isLossless
    }

    /// Has (nearly) all the album: at least 80% of its songs, allowing for a bonus track missing
    /// or a stray extra. Some users share a single song in a folder named for the album.
    static func isComplete(_ folder: RemoteFolder, expectedTracks: Int?) -> Bool {
        guard let expectedTracks, expectedTracks > 1 else { return true }
        return folder.files.count * 5 >= expectedTracks * 4
    }

    /// One song isn't a copy of a release with several, however it's named: it's the single
    /// of the same name (a 2-song EP's title track on its own), or one song shared alone.
    static func isCopy(_ folder: RemoteFolder, expectedTracks: Int?) -> Bool {
        guard let expectedTracks, expectedTracks > 1 else { return true }
        return folder.files.count > 1
    }

    /// The preferred copies, or nil when none qualify (then everything is shown).
    static func preferred(_ folders: [RemoteFolder], quality: QualityPreference, expectedTracks: Int? = nil) -> [RemoteFolder]? {
        let good = folders.filter {
            $0.hasFreeSlot && meetsTarget($0, quality: quality) && isComplete($0, expectedTracks: expectedTracks)
        }
        return good.isEmpty ? nil : good
    }
}

/// Soulseek copies of a release: preferred ones first, the rest behind "Show All".
struct SoulseekCopiesSection: View {
    let folders: [RemoteFolder]
    var title = "Soulseek"
    /// The album's song count, when known, so copies missing most of it aren't offered first.
    var expectedTracks: Int? = nil
    /// Still looking: more copies may come.
    var isLooking = false
    /// The album these are copies of: adding one takes only its songs, and only if it has them all.
    var album: AlbumKey? = nil
    @Environment(SoulseekClient.self) private var client
    @Environment(AlbumAdder.self) private var adder
    @Environment(AlbumReferences.self) private var references
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd
    @State private var showingAll = false

    var body: some View {
        let preferred = CopyFilter.preferred(folders, quality: quality, expectedTracks: expectedTracks)
        let shown = showingAll ? folders : (preferred ?? folders)
        Section {
            ForEach(shown.prefix(showingAll ? folders.count : 8)) { folder in
                HStack {
                    NavigationLink(value: folder) { RemoteFolderRow(folder: folder) }
                    Button("Add to Library", systemImage: "plus.circle") {
                        if let album { adder.add(album, from: [folder], client: client, references: references) } else { client.download(folder) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                }
            }
            if !showingAll, folders.count > min(shown.count, 8) {
                Button("Show All \(folders.count) Copies") { withAnimation { showingAll = true } }
            }
            if isLooking {
                Label { Text("Looking for more…") } icon: { ProgressView() }
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text(preferred != nil && !showingAll
                 ? "\(title) · \(preferred!.count) ready at \(quality == .cd ? "CD quality" : "lossless")"
                 : "\(title) · \(folders.count) \(folders.count == 1 ? "copy" : "copies")")
        }
    }
}

/// Every way to get a release, for its ••• menus.
struct ReleaseMenuItems: View {
    let release: SearchRelease
    @Binding var buying: StorePurchase?
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(AlbumAdder.self) private var adder
    @Environment(AlbumReferences.self) private var references

    var body: some View {
        if !release.folders.isEmpty {
            Button("Add from Soulseek", systemImage: "plus") {
                adder.add(AlbumKey(artist: release.artist, title: release.title), from: release.folders,
                          client: client, references: references)
            }
        }
        if let item = release.owned, item.redownloadURL != nil {
            Button("Add from Bandcamp", systemImage: "bag") {
                if let existing = bandcamp.download(for: item) { bandcamp.retry(existing) } else { bandcamp.download(item) }
            }
        }
        if let store = release.store, release.owned == nil {
            let price = bandcamp.prices[store.id].flatMap { $0.amount > 0 ? $0 : nil }
            Button(price.map { "Buy on Bandcamp · \($0.formatted)" } ?? "Get on Bandcamp", systemImage: "cart") {
                buying = StorePurchase(result: store, price: price)
            }
        }
        // Its page, bought or not.
        if let store = release.store {
            Button("Open on Bandcamp", systemImage: "safari") { buying = StorePurchase(result: store) }
        } else if let page = release.owned?.itemURL {
            Button("Open on Bandcamp", systemImage: "safari") { openURL(page) }
        }
        Divider()
        Button("Search for \(release.artist)", systemImage: "magnifyingglass") { router.search(release.artist) }
    }
}

/// The album header's round button for a release: the best way to get it, as an icon.
struct ReleaseAccessory: View {
    let release: SearchRelease
    let inLibrary: AlbumKey?
    var isPreparing = false
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(AlbumAdder.self) private var adder
    @Environment(AlbumReferences.self) private var references

    var body: some View {
        switch ReleaseAction(release: release, inLibrary: inLibrary, client: client, bandcamp: bandcamp).kind {
        case .inLibrary(let key):
            NavigationLink(value: key) {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 50, height: 50)
                    .background(.fill.secondary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("In Library")
        case .downloadingBandcamp, .downloadingSoulseek:
            // Added, as in Apple Music: the songs below show how their downloads are going.
            Image(systemName: "checkmark")
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 50)
                .background(.fill.secondary, in: .circle)
                .accessibilityLabel("Added to Library")
        case .downloadBandcamp(let item):
            RoundButton(systemImage: "plus", label: "Add from Bandcamp") {
                if let existing = bandcamp.download(for: item) { bandcamp.retry(existing) } else { bandcamp.download(item) }
            }
        case .downloadSoulseek:
            let key = AlbumKey(artist: release.artist, title: release.title)
            if adder.isChecking(key) {
                ProgressView()
                    .frame(width: 50, height: 50)
                    .background(.fill.secondary, in: .circle)
                    .accessibilityLabel("Checking copies")
            } else {
                RoundButton(systemImage: "plus", label: "Add to Library") {
                    adder.add(key, from: release.folders, client: client, references: references)
                }
            }
        case .buy, .none:
            // Buying has its own button beside this one. A spinner while sources are found (not
            // a ring: nothing is downloading yet), otherwise a plus with nothing to add.
            if isPreparing {
                ProgressView()
                    .frame(width: 50, height: 50)
                    .background(.fill.secondary, in: .circle)
                    .accessibilityLabel("Finding copies")
            } else {
                RoundButton(systemImage: "plus", label: "Nothing to add") {}
                    .opacity(0.4)
                    .allowsHitTesting(false)
            }
        }
    }
}
