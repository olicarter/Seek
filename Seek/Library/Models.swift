import Foundation
import SwiftData

/// A song file in the music folder. Indexed separately on each device from the synced files,
/// so this model lives in a local-only store.
@Model
final class Track {
    /// Path relative to the music folder, e.g. "Artist/Album/01 Song.flac".
    var path: String = ""
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    /// Record label, from LABEL/ORGANIZATION (FLAC) or the publisher tag.
    var label: String = ""
    var trackNumber: Int = 0
    var discNumber: Int = 0
    var year: Int = 0
    var duration: Double = 0
    var dateAdded: Date = Date.now
    var hasTags: Bool = false
    /// When the file was last changed as of the last tag read, to notice edits from other devices.
    var fileModified: Date?
    /// The release page the file came from (its URL tag), e.g. on Bandcamp.
    var sourceURL: String = ""
    /// "FLAC", "MP3", …; empty until read.
    var codec: String = ""
    var sampleRate: Int = 0
    var bitDepth: Int = 0
    /// Kilobits per second.
    var bitrate: Int = 0
    /// Set on songs played straight from Soulseek or Bandcamp, which aren't in the library.
    @Transient var stream: StreamSource? = nil
    /// Which version of tag reading filled this in; older reads are redone when the file is here.
    var tagsVersion: Int = 0
    /// 4: tempo and key. 5: tempo and key again, from the tags alone (clearing first results).
    /// 6: MP3s named .flac read as MP3s (they read as untagged FLACs). 7: and renamed (on the Mac).
    /// 8: reads that found no tags give way to the details other devices shared.
    static let currentTagsVersion = 8
    /// Beats a minute (0: not known), from the tags or worked out on the Mac (SongAnalysisStore).
    var bpm: Double = 0
    /// Its Camelot code ("8A"; empty: not known), from the tags or worked out on the Mac.
    var musicalKey: String = ""
    /// Chosen to stay on this device for offline listening; downloaded again if the system removes it.
    var keepOffline: Bool = false
    /// The `TrackInfo.changedAt` last applied, for tracks whose file this device hasn't read.
    var infoUpdated: Date?
    @Attribute(.externalStorage) var artwork: Data?

    init(path: String) {
        self.path = path
        apply(PathMetadata.parse(path))
    }

    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    var albumKey: AlbumKey { AlbumKey(artist: albumArtist.isEmpty ? displayArtist : albumArtist, title: displayAlbum) }
    var fileExtension: String { (path as NSString).pathExtension.lowercased() }

    func apply(_ metadata: TrackMetadata) {
        if let value = metadata.title, !value.isEmpty { title = value }
        if let value = metadata.artist, !value.isEmpty { artist = value }
        if let value = metadata.albumArtist { albumArtist = value }
        if let value = metadata.album, !value.isEmpty { album = value }
        if let value = metadata.label { label = value }
        if let value = metadata.trackNumber { trackNumber = value }
        if let value = metadata.discNumber { discNumber = value }
        if let value = metadata.year { year = value }
        if let value = metadata.duration { duration = value }
        if let value = metadata.artwork { artwork = value }
        if let value = metadata.sourceURL { sourceURL = value }
        if let value = metadata.codec { codec = value }
        if let value = metadata.sampleRate { sampleRate = value }
        if let value = metadata.bitDepth { bitDepth = value }
        if let value = metadata.bitrate { bitrate = value }
        if let value = metadata.bpm, value > 0 { bpm = value }
        if let value = metadata.key { musicalKey = value.camelot }
    }

    /// "128 · 8A", as song rows show it (nothing when neither is known).
    func tempoAndKey(_ notation: MusicalKey.Notation) -> String? {
        let parts = [bpm > 0 ? "\(Int(bpm.rounded()))" : nil, MusicalKey(musicalKey)?.shown(as: notation)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A track's tags and a small cover, synced through CloudKit so every device shows the right
/// details and artwork without downloading the music. Written by whichever device last read the
/// file's tags or edited them; keyed by the same path as `Track`.
@Model
final class TrackInfo {
    var path: String = ""
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    var label: String = ""
    var trackNumber: Int = 0
    var discNumber: Int = 0
    var year: Int = 0
    var duration: Double = 0
    var sourceURL: String = ""
    var codec: String = ""
    var sampleRate: Int = 0
    var bitDepth: Int = 0
    var bitrate: Int = 0
    /// Up to 600 pixels square, JPEG.
    @Attribute(.externalStorage) var cover: Data?
    /// When these details last changed; the newest wins when devices disagree.
    var changedAt: Date = Date.distantPast

    init(path: String) {
        self.path = path
    }

    /// Whether these details already match the track, so nothing needs uploading.
    func matches(_ track: Track) -> Bool {
        title == track.title && artist == track.artist && albumArtist == track.albumArtist && album == track.album
            && label == track.label && trackNumber == track.trackNumber && discNumber == track.discNumber
            && year == track.year && abs(duration - track.duration) < 0.5 && sourceURL == track.sourceURL
            && codec == track.codec && sampleRate == track.sampleRate && bitDepth == track.bitDepth && bitrate == track.bitrate
    }

    func copy(from track: Track) {
        title = track.title
        artist = track.artist
        albumArtist = track.albumArtist
        album = track.album
        label = track.label
        trackNumber = track.trackNumber
        discNumber = track.discNumber
        year = track.year
        duration = track.duration
        sourceURL = track.sourceURL
        codec = track.codec
        sampleRate = track.sampleRate
        bitDepth = track.bitDepth
        bitrate = track.bitrate
    }
}

/// A favourited song, with when it was favourited (for e.g. "favourites from October").
/// Synced, and keyed by path like playlists.
@Model
final class Favorite {
    var path: String = ""
    var favoritedAt: Date = Date.now

    init(path: String, favoritedAt: Date = .now) {
        self.path = path
        self.favoritedAt = favoritedAt
    }
}

/// Cached "similar artists/albums" from Claude, synced so each page is only ever asked about once.
@Model
final class Discovery {
    /// "artist:<name>" or "album:<artist>|<title>", folded to lower case.
    var key: String = ""
    var payload: Data = Data()
    var createdAt: Date = Date.distantPast

    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
        createdAt = .now
    }
}

extension Track {
    /// Takes on synced details. The cover is only for tracks without artwork read from the file,
    /// which is full size.
    func apply(_ info: TrackInfo, includingCover: Bool) {
        title = info.title
        artist = info.artist
        albumArtist = info.albumArtist
        album = info.album
        label = info.label
        trackNumber = info.trackNumber
        discNumber = info.discNumber
        year = info.year
        duration = info.duration
        sourceURL = info.sourceURL
        codec = info.codec
        sampleRate = info.sampleRate
        bitDepth = info.bitDepth
        bitrate = info.bitrate
        if includingCover, let cover = info.cover { artwork = cover }
        infoUpdated = info.changedAt
    }
}

/// Playlists sync through CloudKit. They reference tracks by path, which is the same on every
/// device because the files themselves sync through iCloud Drive.
@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var trackPaths: [String] = []

    init(name: String) {
        self.name = name
    }
}

struct AlbumKey: Hashable, Codable {
    let artist: String
    let title: String
}

struct ArtistKey: Hashable, Codable {
    let name: String
}

struct LabelKey: Hashable, Codable {
    let name: String
}

struct Album: Identifiable {
    var id: AlbumKey { key }
    let key: AlbumKey
    private let grouped: [Track]

    init(key: AlbumKey, tracks: [Track]) {
        self.key = key
        self.grouped = tracks
    }

    /// The album's tracks still in the library. Views can hold an Album for a moment after one of
    /// its tracks is removed (e.g. a duplicate dropped while a download is imported), and reading a
    /// removed SwiftData model crashes.
    var tracks: [Track] { grouped.filter { !$0.isDeleted && $0.modelContext != nil } }

    var title: String { key.title }
    var artist: String { key.artist }
    var year: Int { tracks.map(\.year).max() ?? 0 }
    /// Apple's cover for the album when it has one, otherwise the files' own.
    @MainActor var artwork: Data? { AppleCovers.shared.cover(for: key) ?? tracks.first(where: { $0.artwork != nil })?.artwork }
    var label: String { tracks.first(where: { !$0.label.isEmpty })?.label ?? "" }
    var dateAdded: Date { tracks.map(\.dateAdded).max() ?? .distantPast }
}

enum LibraryGrouping {
    /// Songs of one album however their tags spell it: an album added from several Soulseek
    /// copies had "I Want To Disappear" from one and "I Want to Disappear" from another, and
    /// showed as two albums. Each is named as most of its songs spell it.
    static func albums(_ tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: { AlbumIdentity.releaseKey($0.albumKey) })
            .map { _, songs in
                let spellings = Dictionary(grouping: songs, by: \.albumKey)
                let key = spellings.max { a, b in a.value.count < b.value.count || a.value.count == b.value.count && a.key.title > b.key.title }!.key
                return Album(key: key, tracks: sortedForAlbum(songs))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }


    static func artists(_ tracks: [Track]) -> [String] {
        Set(tracks.map { $0.albumKey.artist })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Each song's place read once, then sorted: reading a song's fields is slow enough that
    /// doing it at every comparison made grouping a big library take a noticeable moment.
    static func sortedForAlbum(_ tracks: [Track]) -> [Track] {
        tracks.map { (key: ($0.discNumber, $0.trackNumber, $0.path), track: $0) }
            .sorted { $0.key < $1.key }
            .map(\.track)
    }

    static func sortedByTitle(_ tracks: [Track]) -> [Track] {
        tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// How a track or album sounds on paper: "FLAC 16-bit/44.1 kHz" or "MP3 320 kbps".
struct AudioQuality: Hashable {
    var codec: String
    var bitDepth: Int
    var sampleRate: Int
    var bitrate: Int

    static let losslessCodecs: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF"]
    static let losslessExtensions: Set<String> = ["flac", "wav", "aiff", "aif", "alac"]

    init(_ track: Track) {
        // Until a file's format is read, its extension is the best guess.
        let fallback = ["flac": "FLAC", "mp3": "MP3", "wav": "WAV", "aif": "AIFF", "aiff": "AIFF", "m4a": "AAC", "aac": "AAC"]
        codec = track.codec.isEmpty ? (fallback[track.fileExtension] ?? track.fileExtension.uppercased()) : track.codec
        bitDepth = track.bitDepth
        sampleRate = track.sampleRate
        bitrate = track.bitrate
    }

    var isLossless: Bool { Self.losslessCodecs.contains(codec) }
    var soundQuality: SoundQuality {
        SoundQuality(lossless: isLossless, bitDepth: bitDepth > 0 ? bitDepth : nil, sampleRate: sampleRate > 0 ? sampleRate : nil)
    }
    var isHiRes: Bool { soundQuality == .max }
    /// "24-bit, 96 kHz" or "320 kbps".
    var detail: String? {
        SoundQuality.detail(lossless: isLossless, bitDepth: bitDepth > 0 ? bitDepth : nil,
                            sampleRate: sampleRate > 0 ? sampleRate : nil, bitrate: bitrate > 0 ? bitrate : nil)
    }

    /// The album's quality: its lowest song's tier (an album is only Max if every song is), and
    /// the most common detail within that tier.
    static func summary(of tracks: [Track]) -> (quality: SoundQuality, detail: String?)? {
        let qualities = tracks.map(AudioQuality.init)
        guard let lowest = qualities.map(\.soundQuality).min() else { return nil }
        let details = qualities.filter { $0.soundQuality == lowest }.compactMap(\.detail)
        let counts = Dictionary(grouping: details, by: { $0 }).mapValues(\.count)
        return (lowest, counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key)
    }
}
