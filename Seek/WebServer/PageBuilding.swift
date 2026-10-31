import Foundation

@MainActor
extension Core {
    var status: Pages.Status {
        let failure: String? = if case .failed(let reason) = client.status { reason } else { nil }
        return Pages.Status(
            soulseek: "\(client.status)".components(separatedBy: "(").first ?? "",
            username: client.savedUsername, signedIn: client.savedUsername != nil,
            downloading: client.activeTransferCount + bandcamp.activeDownloadCount, failure: failure,
            bandcamp: bandcamp.username
        )
    }

    var searchPage: Pages.Search {
        let releases = search.results.result.releases.map { release in
            Pages.Release(
                id: release.id, artist: release.artist, title: release.title, year: release.year ?? release.catalog?.year,
                kind: release.catalog?.kind.name, artwork: release.artworkURL.map { BandcampAPI.largeArtwork($0).absoluteString },
                copies: release.folders.count, lossless: release.isLossless, quality: release.soundQuality,
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
        let owned = bandcamp.ownedRelease(artist: key.artist, title: key.title) ?? found?.owned
        let store = found?.store
        if let store, owned == nil, bandcamp.prices[store.id] == nil { Task { await bandcamp.loadPrice(for: store) } }
        let streams = streamQueue(key, album: album, missing: missing, folders: folders,
                                  bandcampPage: store?.url ?? owned?.itemURL ?? page, artwork: found?.artworkURL ?? reference?.artworkURL)
        let replacing = AlbumRows.replacing(album, client: client)
        // Each song in exactly one state, as in the app (see AlbumState).
        let searching = found == nil && copyFinder.copies(of: key)?.status == .searching
        let derived = AlbumState.derive(AlbumFacts.current(for: key, library: library, client: client, references: references,
                                                           adder: adder, folders: folders, searching: searching))
        let tracksByPath = Dictionary(album.tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let songs = derived.songs.map { song -> Pages.Song in
            if let track = song.libraryPath.flatMap({ tracksByPath[$0] }) {
                return Pages.Song(kind: "have", number: track.trackNumber > 0 ? track.trackNumber : nil, disc: max(track.discNumber, 1),
                                  title: track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title,
                                  artist: track.artist == album.artist ? nil : track.artist, duration: track.duration,
                                  file: "/files/" + track.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"),
                                  available: true, progress: replacing[track.persistentModelID]?.ringProgress,
                                  lossless: AudioQuality(track).isLossless,
                                  quality: AudioQuality(track).soundQuality, tempoAndKey: track.tempoAndKey(.camelot))
            }
            let reference = ReferenceTrack(number: song.number ?? 0, disc: song.disc, title: song.title, duration: song.duration)
            let streamable = song.isPlayable && streams.contains { $0.reference.number == reference.number && $0.reference.disc == reference.disc
                && $0.reference.title == reference.title }
            let arriving = if case .arriving = song.state { true } else { false }
            return Pages.Song(kind: arriving ? "arriving" : "missing", number: song.number, disc: song.disc, title: song.title,
                              artist: song.artist, duration: song.duration,
                              file: streamable ? Self.streamPath(key, release: id, track: reference) : nil,
                              available: song.isPlayable || arriving, progress: arriving ? song.progress ?? 0 : nil, lossless: nil)
        }
        let duration = album.tracks.reduce(0) { $0 + $1.duration } + missing.reduce(0) { $0 + ($1.duration ?? 0) }
        let count = songs.count
        let minutes = Int((duration / 60).rounded())
        let footer = [count == 1 ? "1 song" : "\(count) songs", minutes > 0 ? "\(minutes) minutes" : nil].compactMap { $0 }.joined(separator: ", ")
        let artwork: String? = album.tracks.isEmpty
            ? (found?.artworkURL ?? reference?.artworkURL).map { BandcampAPI.largeArtwork($0).absoluteString }
            : coverPath(key)
        let remoteArtwork = album.tracks.isEmpty ? (found?.artworkURL ?? reference?.artworkURL).map(BandcampAPI.largeArtwork) : nil
        let tint = await Self.tint(artwork: album.tracks.isEmpty ? nil : album.artwork, url: remoteArtwork)
        let adding = adder.isChecking(key) || derived.state.isAdding
            || owned.flatMap { bandcamp.download(for: $0) }?.state.isActive == true
        return Pages.Album(
            artist: key.artist, title: key.title,
            year: album.year > 0 ? album.year : (found?.year ?? reference?.year),
            artwork: artwork, preview: album.tracks.isEmpty ? nil : coverPreview(key), songs: songs, footer: footer,
            released: (reference?.released).map { $0.ISO8601Format(.iso8601.year().month().day().dateSeparator(.dash)) },
            copyright: reference?.copyright,
            tint: tint,
            about: albumAbout(key, year: album.year > 0 ? album.year : (found?.year ?? reference?.year), label: album.label),
            quality: album.tracks.isEmpty ? folders.first?.soundQuality : AudioQuality.summary(of: album.tracks)?.quality,
            qualityDetail: album.tracks.isEmpty ? folders.first?.qualityDetail : AudioQuality.summary(of: album.tracks)?.detail,
            listed: reference != nil, inLibrary: !album.tracks.isEmpty,
            canAdd: (derived.state.canAdd || owned?.redownloadURL != nil && album.tracks.isEmpty) && !adding,
            adding: adding,
            lookingForCopies: derived.state.isLooking,
            copies: folders.count,
            bandcamp: owned != nil || store != nil
                ? Pages.Bandcamp(owned: owned != nil, page: (owned?.itemURL ?? store?.url)?.absoluteString,
                                 price: store.flatMap { bandcamp.prices[$0.id] }.map(\.formatted),
                                 downloading: owned.flatMap { bandcamp.download(for: $0) }.flatMap { $0.state.isActive ? $0.ringProgress ?? 0 : nil })
                : nil
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
        // Bought: the purchase's own files, at no cost, beat any Soulseek copy (as in the app).
        if let item = bandcamp.ownedRelease(artist: key.artist, title: key.title) ?? found?.owned, item.redownloadURL != nil {
            if let existing = bandcamp.download(for: item) { bandcamp.retry(existing) } else { bandcamp.download(item) }
            return
        }
        let folders = copies(of: key, release: found, expectedTracks: reference?.tracks.count, missing: true)
        adder.add(key, from: folders, client: client, references: references)
    }

    /// The album's songs that aren't in the library, each with where to play it from, as the
    /// app's album page builds them.
    func streamQueue(_ key: AlbumKey, album: Album, missing: [ReferenceTrack], folders: [RemoteFolder],
                     bandcampPage: URL?, artwork: URL?) -> StreamService.Queue {
        guard !missing.isEmpty else { return [] }
        return streamer.queue(
            reference: AlbumReference(source: .itunes, artist: key.artist, title: key.title, tracks: missing),
            artist: key.artist, album: key.title, folders: folders.map(client.complete),
            bandcampPage: bandcampPage, artworkURL: artwork.map(BandcampAPI.largeArtwork), artwork: album.artwork
        )
    }

    /// Something to play for a song that isn't in the library, as the app's player gets it.
    func stream(artist: String, title: String, release id: String?, disc: Int, number: Int, song: String) async -> StreamService.Playable? {
        guard let track = await streamedTrack(artist: artist, title: title, release: id, disc: disc, number: number, song: song) else { return nil }
        return await streamer.fetch(track)
    }

    /// A song that isn't in the library, as the app's player has it (with the copies it plays from).
    func streamedTrack(artist: String, title: String, release id: String?, disc: Int, number: Int, song: String) async -> Track? {
        let found = id.flatMap(search.results.release)
        var key = AlbumKey(artist: artist, title: title)
        if let owned = found?.inLibrary ?? library.index.album(artist: artist, title: title, named: true) { key = owned }
        let album = library.albumsByKey[key] ?? Album(key: key, tracks: [])
        guard let reference = await references.reference(for: key) else { return nil }
        let missing = MissingTracks.missing(from: reference, have: album.tracks)
        let folders = copies(of: key, release: found, expectedTracks: reference.tracks.count, missing: true)
        let owned = bandcamp.ownedRelease(artist: key.artist, title: key.title) ?? found?.owned
        let queue = streamQueue(key, album: album, missing: missing, folders: folders,
                                bandcampPage: found?.store?.url ?? owned?.itemURL, artwork: found?.artworkURL ?? reference.artworkURL)
        guard let entry = queue.first(where: { $0.reference.disc == disc && $0.reference.number == number && $0.reference.title == song })
                ?? queue.first(where: { $0.reference.title == song }) else { return nil }
        return entry.track
    }

    static func streamPath(_ key: AlbumKey, release: String?, track: ReferenceTrack) -> String {
        var components = URLComponents()
        components.path = "/api/stream"
        components.queryItems = [
            URLQueryItem(name: "artist", value: key.artist), URLQueryItem(name: "title", value: key.title),
            URLQueryItem(name: "disc", value: "\(track.disc)"), URLQueryItem(name: "number", value: "\(track.number)"),
            URLQueryItem(name: "song", value: track.title),
        ] + (release.map { [URLQueryItem(name: "release", value: $0)] } ?? [])
        return components.string ?? "/api/stream"
    }

    /// The artist's albums in the library, then what else they've released (Apple's catalogue),
    /// under the app's headings.
    func artistPage(_ name: String) async -> Pages.Artist {
        let tracks = ArtistPage.tracks(of: name, in: library.allTracks)
        let albums = LibraryGrouping.albums(tracks).sorted { $0.year > $1.year }
        let catalog = await ArtistCatalog.releases(for: name)
        let shownName = albums.first?.artist ?? catalog.first?.artist ?? name
        about?.load(artist: shownName)
        return Pages.Artist(
            name: shownName,
            about: about?.text(forArtist: shownName),
            albums: albums.map { Pages.LibraryAlbum(artist: $0.artist, title: $0.title, year: $0.year > 0 ? $0.year : nil,
                                                    artwork: coverPath($0.key, size: Covers.tile), preview: coverPreview($0.key), songs: $0.tracks.count) },
            // Everything they've released, the library's albums among the rest (see ArtistPage.sections).
            sections: ArtistPage.sections(catalog: catalog, owned: albums).map { section in
                Pages.ArtistSection(title: section.section.rawValue, releases: section.entries.map { entry in
                    if let album = entry.album {
                        Pages.CatalogEntry(title: album.title, year: entry.year ?? 0, artwork: coverPath(album.key, size: Covers.tile),
                                           inLibrary: true, artist: album.artist, preview: coverPreview(album.key))
                    } else {
                        Pages.CatalogEntry(title: entry.title, year: entry.year ?? 0, artwork: entry.release?.artworkURL?.absoluteString)
                    }
                })
            }
        )
    }

    var libraryPage: [Pages.LibraryAlbum] {
        library.albums
            .sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                || $0.artist == $1.artist && $0.year < $1.year }
            .map { Pages.LibraryAlbum(artist: $0.artist, title: $0.title, year: $0.year > 0 ? $0.year : nil,
                                      artwork: coverPath($0.key, size: Covers.tile), preview: coverPreview($0.key), songs: $0.tracks.count) }
    }

    var downloadsPage: [Pages.Download] {
        // Bandcamp purchases first, then Soulseek songs.
        bandcamp.downloads.map { download in
            Pages.Download(id: "bc-\(download.id)", name: download.item.title, album: download.item.artist, user: "Bandcamp",
                           state: download.state.label, active: download.state.isActive,
                           progress: download.ringProgress ?? 0, speed: 0)
        } + client.transfers.filter { !$0.forStreaming }.map { transfer in
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

    /// A library album's cover at `size`, named by its version so browsers can keep it.
    func coverPath(_ key: AlbumKey, size: Int = Covers.page) -> String {
        var components = URLComponents()
        components.path = "/api/cover"
        components.queryItems = [URLQueryItem(name: "artist", value: key.artist), URLQueryItem(name: "title", value: key.title),
                                 URLQueryItem(name: "size", value: "\(size)"),
                                 URLQueryItem(name: "v", value: cover(artist: key.artist, title: key.title).map(Covers.version) ?? "0")]
        return components.string ?? "/api/cover"
    }

    func coverPreview(_ key: AlbumKey) -> String? {
        cover(artist: key.artist, title: key.title).flatMap { Covers.preview($0, key: "\(key.artist)|\(key.title)") }
    }

    /// Covers' page colours by link, so a cover is fetched for its colour once.
    private static var tints: [URL: String] = [:]

    /// The page's colour from its cover (ArtworkColor), as "#1e3f6e".
    static func tint(artwork: Data?, url: URL?) async -> String? {
        if let artwork { return await Task.detached { ArtworkColor.color(of: artwork)?.hex }.value }
        guard let url else { return nil }
        if let known = tints[url] { return known }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let hex = await Task.detached(operation: { ArtworkColor.color(of: data)?.hex }).value else { return nil }
        tints[url] = hex
        return hex
    }

    /// The album's description, asked for (with its similar albums) the first time its page is shown.
    func albumAbout(_ key: AlbumKey, year: Int?, label: String) -> String? {
        guard let about else { return nil }
        if let text = about.text(for: key) { return text }
        about.load(key, details: [year.map { "Released \($0)" }, label.isEmpty ? nil : "Label: \(label)"]
            .compactMap { $0 }.joined(separator: "\n"))
        return nil
    }
}
