import SwiftUI

/// Long library lists split into letter sections, with iOS's own index down the right to jump
/// between them (A–Z, then # for names starting with a number or symbol), as in Apple Music.
enum LetterSections {
    static let order = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]

    /// The letter a name is filed under: its first letter, without accents; anything else is "#".
    static func letter(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let first = folded.first(where: { $0.isLetter || $0.isNumber }),
              let scalar = first.unicodeScalars.first, (65...90).contains(scalar.value) else { return "#" }
        return String(first)
    }

    /// The items under their letters, A–Z then #, each keeping the order it was given in.
    static func group<Item>(_ items: [Item], by name: (Item) -> String) -> [(letter: String, items: [Item])] {
        let grouped = Dictionary(grouping: items) { letter(for: name($0)) }
        return order.compactMap { letter in grouped[letter].map { (letter, $0) } }
    }
}

/// How an album page lays its albums out.
enum AlbumLayout: String {
    case grid, list
}

/// The Grid/List choice in an album page's toolbar.
struct AlbumLayoutMenu: View {
    @Binding var layout: AlbumLayout

    var body: some View {
        Menu("View", systemImage: "line.3.horizontal.decrease") {
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(AlbumLayout.grid)
                Label("List", systemImage: "list.bullet").tag(AlbumLayout.list)
            }
        }
        .tint(.primary)
    }
}

/// Albums as rows with their covers, by artist (then title), in letter sections with the index.
struct AlbumList: View {
    let albums: [Album]
    @State private var deleting: PendingDelete?

    private var byArtist: [Album] {
        albums.sorted {
            let artists = $0.artist.localizedStandardCompare($1.artist)
            return artists == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : artists == .orderedAscending
        }
    }

    var body: some View {
        List {
            ForEach(LetterSections.group(byArtist, by: \.artist), id: \.letter) { section in
                Section(section.letter) {
                    ForEach(section.items) { album in
                        NavigationLink(value: album.key) {
                            HStack(spacing: 14) {
                                ArtworkView(key: "album|\(album.key.artist)|\(album.key.title)", cornerRadius: 6) { album.artwork }
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).lineLimit(1)
                                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .contextMenu { AlbumMenuItems(album: album, deleting: $deleting) }
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .deleteConfirmation($deleting)
    }
}
