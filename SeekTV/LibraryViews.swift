import SwiftUI

/// An album's cover, from the Mac or Apple's or Bandcamp's servers.
struct Cover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(1, contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
    }
}

/// A grid tile: cover, name and a line under it.
struct AlbumTile: View {
    let title: String
    let subtitle: String
    let artwork: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Cover(url: artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

let gridColumns = [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: 48, alignment: .top)]

struct LibraryView: View {
    @Environment(Connection.self) private var connection

    var body: some View {
        Live(path: "/api/library") { (albums: [Pages.LibraryAlbum]) in
            ScrollView {
                if albums.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "music.note.house",
                                           description: Text("Albums you add show up here, and on your other devices."))
                }
                LazyVGrid(columns: gridColumns, spacing: 56) {
                    ForEach(albums, id: \.key) { album in
                        NavigationLink(value: AlbumRef(artist: album.artist, title: album.title)) {
                            AlbumTile(title: album.title, subtitle: album.artist, artwork: connection.media(album.artwork))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 80)
            }
            .navigationTitle("Library")
        }
    }
}

/// Search across Soulseek, Bandcamp and Apple's catalogue, run by the Mac.
struct SearchView: View {
    @Environment(Connection.self) private var connection
    @State private var query = ""

    var body: some View {
        Live(path: "/api/search") { (page: Pages.Search) in
            ScrollView {
                if page.query.isEmpty {
                    ContentUnavailableView.search
                } else if page.releases.isEmpty {
                    Text(page.searching ? "Searching…" : "Nothing found.").foregroundStyle(.secondary).padding(.top, 60)
                }
                LazyVGrid(columns: gridColumns, spacing: 56) {
                    ForEach(page.releases, id: \.id) { release in
                        NavigationLink(value: AlbumRef(artist: release.artist, title: release.title, release: release.id)) {
                            AlbumTile(title: release.title,
                                      subtitle: [release.kind, release.artist, release.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                      artwork: connection.media(release.artwork))
                                .overlay(alignment: .topTrailing) {
                                    if release.inLibrary {
                                        Image(systemName: "checkmark.circle.fill").font(.title2).padding(12)
                                            .foregroundStyle(.white, .green)
                                    }
                                }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 80)
            }
        }
        .searchable(text: $query, prompt: "Artists, albums, songs")
        .onSubmit(of: .search) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            Task { _ = try? await connection.post("/api/search", ["query": text]) as Pages.Search }
        }
    }
}

struct ArtistView: View {
    let name: String
    @Environment(Connection.self) private var connection

    var body: some View {
        Live(path: "/api/artist?" + Paths.query(["name": name])) { (artist: Pages.Artist) in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(artist.name).font(.largeTitle.bold())
                    grid(artist.albums.map { ($0.title, $0.year.map(String.init) ?? "", connection.media($0.artwork)) })
                    ForEach(artist.sections, id: \.title) { section in
                        Text(section.title).font(.title2.bold())
                        grid(section.releases.map { ($0.title, String($0.year), connection.media($0.artwork)) })
                    }
                }
                .padding(.horizontal, 80)
            }
        }
    }

    private func grid(_ albums: [(String, String, URL?)]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 56) {
            ForEach(albums, id: \.0) { title, subtitle, artwork in
                NavigationLink(value: AlbumRef(artist: name, title: title)) {
                    AlbumTile(title: title, subtitle: subtitle, artwork: artwork)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

extension Pages.LibraryAlbum {
    var key: String { "\(artist)\u{0}\(title)" }
}
