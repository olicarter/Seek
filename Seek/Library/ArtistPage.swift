import Foundation

/// What an artist's page shows, for the app's and the server's alike.
@MainActor
enum ArtistPage {
    /// Their albums, and their songs on other people's (e.g. compilations), but not the rest of those.
    static func tracks(of name: String, in tracks: [Track]) -> [Track] {
        tracks.filter { $0.albumKey.artist == name || $0.artist == name }
    }

    /// The headings the rest of an artist's catalogue goes under, as in Apple Music.
    enum Section: String, CaseIterable {
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

    /// A release on the artist's page: one in the library (with its catalogue entry when Apple
    /// lists it), or one that isn't.
    struct Entry: Identifiable {
        var album: Album?
        var release: CatalogRelease?
        var id: String { album.map { "have|\($0.key.artist)|\($0.key.title)" } ?? "release|\(release?.title ?? "")" }
        var title: String { album?.title ?? release?.title ?? "" }
        var year: Int? { release?.year ?? album.flatMap { $0.year > 0 ? $0.year : nil } }
        var date: Date {
            release?.released ?? album.flatMap { $0.year > 0 ? Calendar.current.date(from: DateComponents(year: $0.year)) : nil } ?? .distantPast
        }
    }

    /// The artist's releases under Apple Music's headings, newest first, with the library's
    /// albums where they'd be anyway (marked as in the library), not set apart. An album Apple
    /// doesn't list goes under the heading its length suggests.
    static func sections(catalog: [CatalogRelease], owned: [Album]) -> [(section: Section, entries: [Entry])] {
        var byKey: [String: Album] = [:]
        for album in owned {
            let key = AlbumIdentity.title(album.title).releaseKey
            if byKey[key] == nil { byKey[key] = album }
        }
        var placed = Set<String>()
        var seen = Set<String>()
        var entries: [Section: [Entry]] = [:]
        for release in catalog.sorted(by: { $0.released > $1.released }) {
            let key = AlbumIdentity.title(release.title).releaseKey
            guard seen.insert(key).inserted, let section = Section.allCases.first(where: { $0.kinds.contains(release.kind) }) else { continue }
            if byKey[key] != nil { placed.insert(key) }
            entries[section, default: []].append(Entry(album: byKey[key], release: release))
        }
        for (key, album) in byKey where !placed.contains(key) {
            let section: Section = album.tracks.count >= 7 ? .albums : .singles
            entries[section, default: []].append(Entry(album: album, release: nil))
        }
        return Section.allCases.compactMap { section in
            guard let list = entries[section], !list.isEmpty else { return nil }
            return (section, list.sorted { $0.date > $1.date })
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
