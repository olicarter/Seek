import AVFoundation
import Foundation

struct TrackMetadata: Sendable, Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var label: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double?
    var artwork: Data?
    /// Where the file came from, e.g. its Bandcamp release page (the URL tag).
    var sourceURL: String?
    /// "FLAC", "ALAC", "AAC", "MP3", "WAV" or "AIFF".
    var codec: String?
    var sampleRate: Int?
    /// Bits per sample, for lossless formats.
    var bitDepth: Int?
    /// Kilobits per second.
    var bitrate: Int?
    var bpm: Double?
    var key: MusicalKey?
}

/// Best-effort metadata from a path like "Artist/Album (2001)/01 - Title.flac",
/// used until the file's own tags have been read.
enum PathMetadata {
    private static let genericFolders: Set<String> = [
        "music", "mp3", "flac", "albums", "downloads", "complete", "shared", "share", "my music", "audio",
    ]

    static func parse(_ path: String) -> TrackMetadata {
        let components = path.split(separator: "/").map(String.init)
        let fileName = ((components.last ?? path) as NSString).deletingPathExtension
        var metadata = TrackMetadata()

        let (number, rest) = splitTrackNumber(fileName)
        metadata.trackNumber = number
        metadata.title = rest

        if components.count >= 2 {
            var albumFolder = components[components.count - 2]
            var artistFolder = components.count >= 3 ? components[components.count - 3] : nil
            if artistFolder == nil || genericFolders.contains(artistFolder!.lowercased()),
               let range = albumFolder.range(of: " - ") {
                artistFolder = String(albumFolder[..<range.lowerBound])
                albumFolder = String(albumFolder[range.upperBound...])
            }
            let (album, year) = cleanAlbum(albumFolder)
            metadata.album = album
            metadata.year = year
            if let artistFolder, !genericFolders.contains(artistFolder.lowercased()) {
                metadata.artist = artistFolder
            }
        }

        // "Artist - Title" file names: drop the artist if it matches the folder.
        if let title = metadata.title, let range = title.range(of: " - ") {
            let prefix = String(title[..<range.lowerBound])
            if metadata.artist == nil || prefix.caseInsensitiveCompare(metadata.artist!) == .orderedSame {
                metadata.artist = metadata.artist ?? prefix
                metadata.title = String(title[range.upperBound...])
            }
        }
        return metadata
    }

    /// "01 - Title", "1-03 Title", "01. Title" → (1, "Title"); disc prefixes are dropped.
    static func splitTrackNumber(_ name: String) -> (Int?, String) {
        let pattern = /^(?:\d{1,2}[-.])?(\d{1,3})(?:\s*[-._)]\s*|\s+)(.+)$/
        guard let match = name.firstMatch(of: pattern) else { return (nil, name) }
        return (Int(match.1), String(match.2).trimmingCharacters(in: .whitespaces))
    }

    /// Strips "(2001)", "[FLAC]" and similar suffixes, keeping any year.
    static func cleanAlbum(_ folder: String) -> (String, Int?) {
        var year: Int?
        if let match = folder.firstMatch(of: /[(\[]((?:19|20)\d{2})[)\]]/) {
            year = Int(match.1)
        }
        let cleaned = folder
            .replacing(/\s*[(\[][^)\]]*[)\]]\s*/, with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? folder : cleaned, year)
    }
}

enum MetadataReader {
    /// Codec, sample rate, bit depth and bitrate from the audio track itself.
    static func readFormat(of asset: AVURLAsset, url: URL, into metadata: inout TrackMetadata) async {
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await audio.load(.formatDescriptions).first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return }
        metadata.sampleRate = Int(stream.mSampleRate)
        if let rate = try? await audio.load(.estimatedDataRate), rate > 0 { metadata.bitrate = Int(rate / 1000) }
        switch stream.mFormatID {
        case kAudioFormatMPEGLayer3: metadata.codec = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: metadata.codec = "AAC"
        case kAudioFormatAppleLossless:
            metadata.codec = "ALAC"
            // ALAC keeps the source bit depth in its flags: 1 = 16, 2 = 20, 3 = 24, 4 = 32.
            metadata.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(stream.mFormatFlags)]
        case kAudioFormatLinearPCM:
            metadata.codec = ["aif", "aiff"].contains(url.pathExtension.lowercased()) ? "AIFF" : "WAV"
            metadata.bitDepth = Int(stream.mBitsPerChannel)
        case kAudioFormatFLAC: metadata.codec = "FLAC"
        default: break
        }
    }

    /// Reads tags from a local file. FLAC Vorbis comments are parsed directly because
    /// AVFoundation doesn't expose them.
    static func read(_ url: URL) async -> TrackMetadata {
        var metadata = TrackMetadata()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            metadata.duration = duration.seconds
        }
        await readFormat(of: asset, url: url, into: &metadata)
        // By what the file holds: some MP3s are named .flac.
        if AudioTags.container(of: url) == .flac {
            if let flac = try? FLACTags.read(url) {
                metadata.title = flac.title
                metadata.artist = flac.artist
                metadata.albumArtist = flac.albumArtist
                metadata.album = flac.album
                metadata.label = flac.label
                metadata.trackNumber = flac.trackNumber
                metadata.discNumber = flac.discNumber
                metadata.year = flac.year
                metadata.artwork = flac.artwork
                metadata.sourceURL = flac.url
                metadata.codec = "FLAC"
                metadata.sampleRate = flac.sampleRate
                metadata.bitDepth = flac.bitDepth
                metadata.bpm = flac.bpm
                metadata.key = flac.key
                if let duration = metadata.duration, duration > 0,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    metadata.bitrate = Int(Double(size) * 8 / duration / 1000)
                }
            }
            return metadata
        }

        guard let items = try? await asset.load(.metadata) else { return metadata }
        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
                }
            }
            return nil
        }
        func data(_ identifiers: [AVMetadataIdentifier]) async -> Data? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.dataValue) { return value }
                }
            }
            return nil
        }

        metadata.title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        metadata.artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        metadata.albumArtist = await string([.iTunesMetadataAlbumArtist, .id3MetadataBand])
        metadata.album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        metadata.label = await string([.commonIdentifierPublisher, .id3MetadataPublisher, .iTunesMetadataPublisher])
        metadata.artwork = await data([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt])

        if let value = await string([.id3MetadataTrackNumber]) {
            metadata.trackNumber = leadingNumber(value)
        } else if let raw = await data([.iTunesMetadataTrackNumber]), raw.count >= 4 {
            metadata.trackNumber = Int(raw[2]) << 8 | Int(raw[3])
        }
        if let value = await string([.id3MetadataPartOfASet]) {
            metadata.discNumber = leadingNumber(value)
        } else if let raw = await data([.iTunesMetadataDiscNumber]), raw.count >= 4 {
            metadata.discNumber = Int(raw[2]) << 8 | Int(raw[3])
        }
        if let value = await string([
            .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate,
        ]) {
            metadata.year = leadingNumber(value)
        }
        if let value = await string([.id3MetadataBeatsPerMinute]), let bpm = Double(value), bpm > 0 {
            metadata.bpm = bpm
        } else if let raw = await data([.iTunesMetadataBeatsPerMin]), raw.count >= 2 {
            let bpm = Double(Int(raw[raw.count - 2]) << 8 | Int(raw[raw.count - 1]))
            if bpm > 0 { metadata.bpm = bpm }
        }
        if let value = await string([.id3MetadataInitialKey]) { metadata.key = MusicalKey(value) }
        return metadata
    }

    static func leadingNumber(_ value: String) -> Int? {
        value.firstMatch(of: /\d+/).flatMap { Int($0.0) }
    }
}

/// Minimal FLAC metadata block parser: Vorbis comments and the front cover picture.
enum FLACTags {
    struct Tags: Equatable {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var label: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var artwork: Data?
        /// Where the file came from (Seek writes the Bandcamp release page here).
        var url: String?
        var comment: String?
        var sampleRate: Int?
        var bitDepth: Int?
        var bpm: Double?
        var key: MusicalKey?
    }

    /// Where the FLAC stream starts: at once, or after an ID3 tag some rippers put in front
    /// (non-standard, and its tags are often junk: "m" as the artist, a link as the album artist).
    static func streamStart(_ head: Data) -> Int? {
        if head.prefix(4) == Data("fLaC".utf8) { return 0 }
        guard head.count >= 10, head.prefix(3) == Data("ID3".utf8) else { return nil }
        let bytes = Array(head.prefix(10))
        // A "syncsafe" size: seven bits a byte. Plus the footer, when the flags say there is one.
        let size = Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9])
        return 10 + size + (bytes[5] & 0x10 != 0 ? 10 : 0)
    }

    static func read(_ url: URL) throws -> Tags {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 10), let start = streamStart(head) else { return Tags() }
        try handle.seek(toOffset: UInt64(start))
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return Tags() }
        var tags = Tags()
        var isLast = false
        while !isLast {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if type == 0 || type == 4 || type == 6 {
                guard let block = try handle.read(upToCount: length), block.count == length else { break }
                switch type {
                case 0: parseStreamInfo(block, into: &tags)
                case 4: parseComments(block, into: &tags)
                default: parsePicture(block, into: &tags)
                }
            } else {
                try handle.seek(toOffset: try handle.offset() + UInt64(length))
            }
        }
        return tags
    }

    static func parseComments(_ block: Data, into tags: inout Tags) {
        var reader = MessageReader(block)
        guard (try? reader.string()) != nil, let count = try? reader.uint32() else { return }
        for _ in 0..<count {
            guard let comment = try? reader.string(), let equals = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<equals].uppercased()
            let value = String(comment[comment.index(after: equals)...])
            switch key {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = tags.albumArtist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "LABEL", "ORGANIZATION", "PUBLISHER": tags.label = tags.label ?? value
            case "TRACKNUMBER": tags.trackNumber = MetadataReader.leadingNumber(value)
            case "DISCNUMBER": tags.discNumber = MetadataReader.leadingNumber(value)
            case "DATE", "YEAR": tags.year = tags.year ?? MetadataReader.leadingNumber(value)
            case "URL", "WEBSITE": tags.url = tags.url ?? value
            case "COMMENT", "DESCRIPTION": tags.comment = tags.comment ?? value
            // "0" means the tagger didn't know.
            case "BPM", "TEMPO": if let bpm = Double(value.replacingOccurrences(of: ",", with: ".")), bpm > 0 { tags.bpm = bpm }
            case "INITIALKEY", "KEY", "INITIAL KEY": tags.key = tags.key ?? MusicalKey(value)
            default: break
            }
        }
    }

    /// STREAMINFO: sample rate (20 bits), channels (3), bits per sample (5), from byte 10.
    static func parseStreamInfo(_ block: Data, into tags: inout Tags) {
        let b = [UInt8](block)
        guard b.count >= 14 else { return }
        tags.sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        tags.bitDepth = (Int(b[12] & 1) << 4 | Int(b[13]) >> 4) + 1
    }

    /// FLAC picture blocks use big-endian integers, unlike Vorbis comments.
    static func parsePicture(_ block: Data, into tags: inout Tags) {
        let bytes = [UInt8](block)
        var offset = 0
        func uint32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        guard let pictureType = uint32(), let mimeLength = uint32() else { return }
        offset += mimeLength
        guard let descriptionLength = uint32() else { return }
        offset += descriptionLength + 16
        guard let length = uint32(), offset + length <= bytes.count else { return }
        // Prefer the front cover (type 3) but take any picture if there's nothing else.
        if tags.artwork == nil || pictureType == 3 {
            tags.artwork = Data(bytes[offset..<offset + length])
        }
    }
}
