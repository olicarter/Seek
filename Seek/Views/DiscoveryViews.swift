import SwiftData
import SwiftUI

/// "Similar Artists" or "Similar Albums": a row of cards from Claude, asked once per page and
/// cached (and synced) after that.
struct DiscoveryRow: View {
    let subject: DiscoveryService.Subject
    @Environment(DiscoveryService.self) private var discovery
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    private var tracks: [Track] { library.allTracks }
    @Query private var entries: [Discovery]

    init(subject: DiscoveryService.Subject) {
        self.subject = subject
        let key = subject.key
        _entries = Query(filter: #Predicate<Discovery> { $0.key == key }, sort: \Discovery.createdAt, order: .reverse)
    }

    private var title: String {
        if case .artist = subject { "Similar Artists" } else { "Similar Albums" }
    }

    var body: some View {
        let suggestions = entries.first.flatMap { try? JSONDecoder().decode([DiscoveryService.Suggestion].self, from: $0.payload) }
        let state = discovery.states[subject.key]
        VStack(alignment: .leading, spacing: 10) {
            if suggestions != nil || state != nil || ClaudeTagFixer.apiKey != nil {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    if suggestions != nil, state != .loading {
                        Menu("More", systemImage: "ellipsis") {
                            Button("Suggest Again", systemImage: "arrow.clockwise") {
                                discovery.load(subject, refresh: true)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }
            if state == .loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding \(title.lowercased())…").foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else {
                if case .failed(let reason) = state {
                    HStack {
                        Text(reason).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Try Again") { discovery.load(subject, refresh: true) }
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                }
                // Earlier suggestions stay when asking again fails.
                if let suggestions, !suggestions.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(suggestions) { suggestion in
                                DiscoveryCard(suggestion: suggestion, owned: owned(suggestion))
                                    .frame(width: 150)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task(id: suggestions?.map(\.id)) {
            if let suggestions { await DiscoveryService.prefetchCovers(suggestions) }
        }
        .task(id: subject) {
            // First visit only: once cached, this does nothing.
            if let entry = entries.first, discovery.cached(subject) != nil {
                discovery.fillMissingArtwork(entry)
            } else {
                discovery.load(subject)
            }
        }
    }

    /// Where the suggestion already is in the library, if it is.
    private func owned(_ suggestion: DiscoveryService.Suggestion) -> DiscoveryCard.Destination? {
        let index = LibraryMemo.value("ownedIndex", version: library.contentVersion(trackCount: tracks.count)) {
            var albums: [String: AlbumKey] = [:]
            var artists: [String: String] = [:]
            for track in tracks {
                let key = track.albumKey
                albums["\(key.artist.lowercased())|\(track.album.lowercased())"] = key
                artists[key.artist.lowercased()] = key.artist
            }
            return (albums: albums, artists: artists)
        }
        let artist = suggestion.artist.lowercased()
        if let title = suggestion.title?.lowercased() {
            return index.albums["\(artist)|\(title)"].map { .album($0) }
        }
        return index.artists[artist].map { .artist(ArtistKey(name: $0)) }
    }
}

/// One suggestion: cover art, name and (on the page it was suggested for) Claude's reason. Opens the library page when it's already
/// there; otherwise an album opens its page (every source in one place) and an artist a search.
struct DiscoveryCard: View {
    enum Destination: Hashable {
        case album(AlbumKey)
        case artist(ArtistKey)
    }

    let suggestion: DiscoveryService.Suggestion
    let owned: Destination?
    /// Claude's reason compares the suggestion with the page it was asked from, so it only makes
    /// sense on that page.
    var showsReason = true
    @Environment(Router.self) private var router
    /// The cover, looked up when the saved suggestion has none (usually already, by the row).
    private var cover: URL? { DiscoveryService.knownCover(for: suggestion) ?? foundCover }
    @State private var foundCover: URL?

    var body: some View {
        Group {
            switch owned {
            case .album(let key):
                NavigationLink(value: key) { content }
            case .artist(let key):
                NavigationLink(value: key) { content }
            case nil:
                if let title = suggestion.title {
                    // Albums open their page, gathered from every source, like Apple Music.
                    NavigationLink(value: ExternalAlbum(artist: suggestion.artist, title: title, artworkURL: cover)) { content }
                } else {
                    Button { router.search(suggestion.searchText) } label: { content }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Search Soulseek and Bandcamp", systemImage: "magnifyingglass") { router.search(suggestion.searchText) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: cover) { placeholder }
            .frame(width: 150, height: 150)
            .clipShape(.rect(cornerRadius: suggestion.title == nil ? 75 : 8))
            .overlay(alignment: .bottomTrailing) {
                if owned != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .font(.title3)
                        .padding(6)
                }
            }
            Text(suggestion.title ?? suggestion.artist)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if suggestion.title != nil {
                Text(suggestion.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if showsReason {
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(.rect)
        .task(id: suggestion.id) {
            if cover == nil { foundCover = await DiscoveryService.cover(for: suggestion) }
        }
    }

    /// A colour picked from the name, so each placeholder looks different but stays the same.
    private var placeholder: some View {
        let hue = Double(abs(suggestion.id.hashValue % 360)) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue + 0.08, saturation: 0.7, brightness: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: suggestion.title == nil ? "music.mic" : "music.note")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The library home's Discover row: albums suggested on album pages you've visited that aren't
/// in the library yet. Uses the cache only, so it never asks Claude by itself.
struct DiscoverHomeRow: View {
    @Query(sort: \Discovery.createdAt, order: .reverse) private var entries: [Discovery]
    private var tracks: [Track] { library.allTracks }
    @Environment(LibraryStore.self) private var library
    @Environment(DiscoveryService.self) private var discovery

    var body: some View {
        let owned = LibraryMemo.value("ownedAlbums", version: library.contentVersion(trackCount: tracks.count)) {
            Set(tracks.map { "\($0.albumKey.artist.lowercased())|\($0.album.lowercased())" })
        }
        let suggestions = Self.albums(from: entries).filter {
            !owned.contains("\($0.artist.lowercased())|\(($0.title ?? "").lowercased())")
        }
        if !suggestions.isEmpty {
            Section("Discover") {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(suggestions.prefix(16)) { suggestion in
                            DiscoveryCard(suggestion: suggestion, owned: nil, showsReason: false).frame(width: 150)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                // On the row itself: modifiers on a Section aren't reliably run.
                .task(id: entries.count) {
                    for entry in entries.prefix(40) where entry.key.hasPrefix("album:") { discovery.fillMissingArtwork(entry) }
                    await DiscoveryService.prefetchCovers(Array(suggestions.prefix(16)))
                }
            }
        }
    }

    static func albums(from entries: [Discovery]) -> [DiscoveryService.Suggestion] {
        var seen = Set<String>()
        var result: [DiscoveryService.Suggestion] = []
        for entry in entries.prefix(40) where entry.key.hasPrefix("album:") {
            let suggestions = (try? JSONDecoder().decode([DiscoveryService.Suggestion].self, from: entry.payload)) ?? []
            // The top few from each page, so one album doesn't fill the row.
            for suggestion in suggestions.prefix(4) where seen.insert(suggestion.id.lowercased()).inserted {
                result.append(suggestion)
            }
        }
        return result
    }
}
