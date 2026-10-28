import Foundation

/// What the site shows, as JSON: built from the app's own models, so a page here lists what
/// the same page in the app does.
enum Pages {
    struct Status: Encodable {
        var soulseek: String
        var username: String?
        var signedIn: Bool
        var downloading: Int
        var failure: String?
    }

    struct Release: Encodable {
        var id: String
        var artist: String
        var title: String
        var year: Int?
        var kind: String?
        var artwork: String?
        var copies: Int
        var lossless: Bool
        var bandcamp: Bool
        var inLibrary: Bool
        var adding: Bool
    }

    struct Search: Encodable {
        var query: String
        var searching: Bool
        var releases: [Release]
    }

    struct Song: Encodable {
        /// "have" (in the library), "missing" (on the tracklist, not here) or "arriving".
        var kind: String
        var number: Int?
        var disc: Int
        var title: String
        var artist: String?
        var duration: Double?
        /// The file to play, for songs in the library.
        var file: String?
        /// For missing songs: some copy has it.
        var available: Bool
        /// 0–1 while downloading.
        var progress: Double?
        var lossless: Bool?
    }

    struct Album: Encodable {
        var artist: String
        var title: String
        var year: Int?
        var artwork: String?
        var songs: [Song]
        var footer: String
        /// Has a tracklist (Apple's or Bandcamp's): adding adds exactly it.
        var listed: Bool
        var inLibrary: Bool
        var canAdd: Bool
        var adding: Bool
        var lookingForCopies: Bool
        var copies: Int
    }

    struct LibraryAlbum: Encodable {
        var artist: String
        var title: String
        var year: Int?
        var artwork: String
        var songs: Int
    }

    struct Download: Encodable {
        var id: String
        var name: String
        var album: String
        var user: String
        var state: String
        var active: Bool
        var progress: Double
        var speed: Double
    }
}

@MainActor
extension Core {
    var status: Pages.Status {
        let failure: String? = if case .failed(let reason) = client.status { reason } else { nil }
        return Pages.Status(
            soulseek: "\(client.status)".components(separatedBy: "(").first ?? "",
            username: client.savedUsername, signedIn: client.savedUsername != nil,
            downloading: client.activeTransferCount, failure: failure
        )
    }

    var searchPage: Pages.Search {
        let releases = search.results.result.releases.map { release in
            Pages.Release(
                id: release.id, artist: release.artist, title: release.title, year: release.year ?? release.catalog?.year,
                kind: release.catalog?.kind.name, artwork: release.artworkURL.map { BandcampAPI.largeArtwork($0).absoluteString },
                copies: release.folders.count, lossless: release.isLossless,
                bandcamp: release.store != nil || release.owned != nil, inLibrary: release.inLibrary != nil,
                adding: adder.isChecking(AlbumKey(artist: release.artist, title: release.title))
                    || ReleaseAction.soulseekProgress(release, client: client) != nil
            )
        }
        // Most results come in the first few seconds.
        let searching = client.currentSearch.map { $0.query == search.submitted && $0.startedAt.timeIntervalSinceNow > -15 } ?? false
        return Pages.Search(query: search.submitted, searching: searching, releases: releases)
    }

    /// The album page: the library's songs with the tracklist's missing ones slotted in, for a
    /// library album and one that isn't there alike. `release`: the search result it was opened
    /// from, whose copies it can add from.
    func albumPage(artist: String, title: String, release id: String?) async -> Pages.Album {
        let found = id.flatMap(search.results.release)
        var key = AlbumKey(artist: artist, title: title)
        if let owned = found?.inLibrary ?? library.index.album(artist: artist, title: title, named: true) { key = owned }
        let album = library.albumsByKey[key] ?? Album(key: key, tracks: [])
        let page = album.tracks.lazy.compactMap { $0.sourceURL.contains("bandcamp.com") ? URL(string: $0.sourceURL) : nil }.first
        let reference = await references.reference(for: key, page: page ?? found?.store?.url,
                                                    purchased: page != nil, trackCount: album.tracks.count)
        let missing = reference.map { MissingTracks.missing(from: $0, have: album.tracks) } ?? []
        // The search's copies when opened from it, otherwise a search of its own.
        let folders = copies(of: key, release: found, expectedTracks: reference?.tracks.count, missing: !missing.isEmpty || album.tracks.isEmpty)
        let downloads = AlbumRows.downloads(for: album, client: client)
        let files = folders.map(client.complete).flatMap(\.files)
        let songs = AlbumRows.rows(album, missing: missing, arriving: AlbumRows.arriving(album, missing: missing, client: client)).map { row in
            switch row {
            case .have(_, let track):
                return Pages.Song(kind: "have", number: track.trackNumber > 0 ? track.trackNumber : nil, disc: max(track.discNumber, 1),
                                  title: track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title,
                                  artist: track.artist == album.artist ? nil : track.artist, duration: track.duration,
                                  file: "/files/" + track.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"),
                                  available: true, progress: nil, lossless: AudioQuality(track).isLossless)
            case .missing(let track):
                let download = MissingTracks.download(for: track, in: downloads)
                return Pages.Song(kind: "missing", number: track.number > 0 ? track.number : nil, disc: track.disc, title: track.title,
                                  artist: nil, duration: track.duration, file: nil,
                                  available: download != nil || MissingTracks.file(for: track, in: files) != nil,
                                  progress: download.flatMap { $0.state.isActive ? $0.ringProgress : nil }, lossless: nil)
            case .arriving(let transfer):
                return Pages.Song(kind: "arriving", number: ReleaseText.songNumber(transfer.file.name), disc: 1,
                                  title: ReleaseText.songTitle(transfer.file.name), artist: nil, duration: nil, file: nil,
                                  available: true, progress: transfer.ringProgress, lossless: nil)
            }
        }
        let duration = album.tracks.reduce(0) { $0 + $1.duration } + missing.reduce(0) { $0 + ($1.duration ?? 0) }
        let count = songs.count
        let minutes = Int((duration / 60).rounded())
        let footer = [count == 1 ? "1 song" : "\(count) songs", minutes > 0 ? "\(minutes) minutes" : nil].compactMap { $0 }.joined(separator: ", ")
        let artwork: String? = album.tracks.isEmpty
            ? (found?.artworkURL ?? reference?.artworkURL).map { BandcampAPI.largeArtwork($0).absoluteString }
            : Self.coverPath(key)
        let adding = adder.isChecking(key) || AlbumRows.isBeingAdded(album, client: client)
        return Pages.Album(
            artist: key.artist, title: key.title,
            year: album.year > 0 ? album.year : (found?.year ?? reference?.year),
            artwork: artwork, songs: songs, footer: footer,
            listed: reference != nil, inLibrary: !album.tracks.isEmpty,
            canAdd: !folders.isEmpty && (album.tracks.isEmpty || !missing.isEmpty) && !adding,
            adding: adding,
            lookingForCopies: found == nil && copyFinder.copies(of: key)?.status == .searching,
            copies: folders.count
        )
    }

    /// The album's Soulseek copies, best first (whole copies first, by the tracklist).
    func copies(of key: AlbumKey, release: SearchRelease?, expectedTracks: Int?, missing: Bool) -> [RemoteFolder] {
        if let release, !release.folders.isEmpty {
            return ReleaseGrouper.sortedBest(release.folders.map(client.complete), quality: quality, expectedTracks: expectedTracks)
        }
        if missing, client.savedUsername != nil { copyFinder.find(key, expectedTracks: expectedTracks, client: client, quality: quality) }
        return copyFinder.copies(of: key)?.folders ?? []
    }

    func add(artist: String, title: String, release id: String?) async {
        let found = id.flatMap(search.results.release)
        let key = AlbumKey(artist: found?.artist ?? artist, title: found?.title ?? title)
        let reference = await references.reference(for: key)
        let folders = copies(of: key, release: found, expectedTracks: reference?.tracks.count, missing: true)
        adder.add(key, from: folders, client: client, references: references)
    }

    var libraryPage: [Pages.LibraryAlbum] {
        library.albums
            .sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                || $0.artist == $1.artist && $0.year < $1.year }
            .map { Pages.LibraryAlbum(artist: $0.artist, title: $0.title, year: $0.year > 0 ? $0.year : nil,
                                      artwork: Self.coverPath($0.key), songs: $0.tracks.count) }
    }

    var downloadsPage: [Pages.Download] {
        client.transfers.filter { !$0.forStreaming }.map { transfer in
            Pages.Download(
                id: transfer.id.uuidString, name: ReleaseText.songTitle(transfer.file.name),
                album: transfer.album?.title ?? (transfer.file.folder as NSString).lastPathComponent,
                user: transfer.file.username, state: transfer.state.label, active: transfer.state.isActive,
                progress: transfer.ringProgress ?? 0, speed: transfer.bytesPerSecond
            )
        }
    }

    func cover(artist: String, title: String) -> Data? {
        library.albumsByKey[AlbumKey(artist: artist, title: title)]?.artwork
    }

    static func coverPath(_ key: AlbumKey) -> String {
        var components = URLComponents()
        components.path = "/api/cover"
        components.queryItems = [URLQueryItem(name: "artist", value: key.artist), URLQueryItem(name: "title", value: key.title)]
        return components.string ?? "/api/cover"
    }
}
