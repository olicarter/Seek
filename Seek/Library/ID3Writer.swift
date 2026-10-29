import Foundation

/// Writes ID3v2 tags (MP3s), from the same field names as FLAC's Vorbis comments, so tags are
/// written one way whatever the format (see AudioTags).
enum ID3Tags {
    enum WriteError: LocalizedError {
        case unsupported

        var errorDescription: String? { "The MP3's tag couldn't be read" }
    }

    /// The frame each field is kept in. DATE is TYER before ID3v2.4 and TDRC from it.
    private static let frames: [String: String] = [
        "TITLE": "TIT2", "ARTIST": "TPE1", "ALBUMARTIST": "TPE2", "ALBUM": "TALB",
        "TRACKNUMBER": "TRCK", "DISCNUMBER": "TPOS", "GENRE": "TCON", "LABEL": "TPUB",
        "ORGANIZATION": "TPUB", "BPM": "TBPM", "KEY": "TKEY", "INITIALKEY": "TKEY",
    ]

    /// An MPEG audio file: an ID3 tag in front, or straight into MPEG frames.
    static func isMP3(_ head: Data) -> Bool {
        let bytes = Array(head.prefix(3))
        if bytes.count == 3, bytes == Array("ID3".utf8) { return true }
        // An MPEG frame's sync, with a layer set (AAC's ADTS frames have none).
        return bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0 && bytes[1] & 0x06 != 0
    }

    /// Sets the fields given, keeping the tag's other frames (artwork among them, unless a new
    /// front cover is given) and the audio untouched. The file is rewritten and swapped in.
    static func update(_ url: URL, setting values: [String: String], frontCover: FLACTags.Picture? = nil) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard isMP3(data.prefix(3)) else { throw WriteError.unsupported }
        let output = try updated(data, setting: values, frontCover: frontCover)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).\(url.pathExtension)")
        try output.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    static func updated(_ data: Data, setting values: [String: String], frontCover: FLACTags.Picture? = nil) throws -> Data {
        let bytes = [UInt8](data.prefix(10))
        var version: UInt8 = 3
        var kept: [(id: String, body: Data)] = []
        var audioStart = 0
        if bytes.count == 10, bytes.prefix(3) == [0x49, 0x44, 0x33] {
            version = bytes[3]
            // Older tags, and ones whose frames are unsynchronised or start with an extended
            // header, are left alone rather than read wrongly.
            guard version == 3 || version == 4, bytes[5] & 0xC0 == 0 else { throw WriteError.unsupported }
            let size = syncsafe(bytes[6...9])
            audioStart = 10 + size + (bytes[5] & 0x10 != 0 ? 10 : 0)
            guard audioStart <= data.count else { throw WriteError.unsupported }
            var offset = 10
            while offset + 10 <= 10 + size {
                let header = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 10)])
                guard header[0] != 0 else { break } // padding
                let id = String(decoding: header[0..<4], as: UTF8.self)
                let length = version == 4 ? syncsafe(header[4...7]) : header[4...7].reduce(0) { $0 << 8 | Int($1) }
                let end = offset + 10 + length
                guard end <= 10 + size else { throw WriteError.unsupported }
                // Kept whole, flags and all.
                kept.append((id, data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))))
                offset = end
            }
        }

        var replaced = Set(values.keys.compactMap { frames[$0.uppercased()] })
        let dateFrame = version == 4 ? "TDRC" : "TYER"
        if values.keys.contains(where: { $0.uppercased() == "DATE" }) { replaced.formUnion(["TDRC", "TYER"]) }
        if frontCover != nil { replaced.insert("APIC") }
        var tagFrames = kept.filter { frame in
            // Only the front cover goes (APIC's picture type follows its MIME type and description).
            guard frame.id == "APIC" else { return !replaced.contains(frame.id) }
            return frontCover == nil || !isFrontCover(frame.body)
        }.map(\.body)

        var written: [String: String] = [:]
        for (key, value) in values {
            guard let id = key.uppercased() == "DATE" ? dateFrame : frames[key.uppercased()], !value.isEmpty else { continue }
            written[id] = value
        }
        for id in written.keys.sorted() {
            tagFrames.append(frame(id, text(written[id]!, version: version), version: version))
        }
        if let frontCover {
            var body = Data([0])
            body.append(Data(frontCover.mimeType.utf8))
            body.append(contentsOf: [0, 3, 0]) // the end of the MIME type, front cover, no description
            body.append(frontCover.data)
            tagFrames.append(frame("APIC", body, version: version))
        }

        let tagBody = tagFrames.reduce(Data(), +)
        // A little padding, so the next edit can grow the tag in place in other taggers.
        let padding = 1024
        var output = Data([0x49, 0x44, 0x33, version, 0, 0])
        output.append(syncsafeBytes(tagBody.count + padding))
        output.append(tagBody)
        output.append(Data(count: padding))
        output.append(data[(data.startIndex + audioStart)...])
        return output
    }

    private static func isFrontCover(_ frame: Data) -> Bool {
        let body = [UInt8](frame.dropFirst(10))
        // Encoding, MIME type ending in 0, then the picture type.
        guard body.count > 2, let end = body.dropFirst().firstIndex(of: 0), end + 1 < body.count else { return false }
        return [0, 3].contains(body[end + 1])
    }

    private static func text(_ value: String, version: UInt8) -> Data {
        if version == 4 { return Data([3]) + Data(value.utf8) }
        // UTF-16 with a byte order mark: ID3v2.3 has no UTF-8.
        return Data([1, 0xFF, 0xFE]) + (value.data(using: .utf16LittleEndian) ?? Data())
    }

    private static func frame(_ id: String, _ body: Data, version: UInt8) -> Data {
        var data = Data(id.utf8)
        if version == 4 {
            data.append(syncsafeBytes(body.count))
        } else {
            data.append(contentsOf: [UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF),
                                     UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        }
        data.append(contentsOf: [0, 0])
        data.append(body)
        return data
    }

    static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func syncsafeBytes(_ value: Int) -> Data {
        Data([UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)])
    }
}

/// What a song's file holds, decided by its contents rather than its name: some uploads are
/// MP3s named .flac. Tags are written by it, and a file named for something else is renamed.
enum AudioTags {
    enum Container: String {
        case flac, mp3, mp4, wav, aiff, ogg, aac

        /// The extensions a file holding this may have; the first is the one to give it.
        var extensions: [String] {
            switch self {
            case .flac: ["flac"]
            case .mp3: ["mp3"]
            case .mp4: ["m4a", "mp4", "alac", "m4b"]
            case .wav: ["wav"]
            case .aiff: ["aiff", "aif", "aifc"]
            case .ogg: ["ogg", "oga", "opus"]
            case .aac: ["aac"]
            }
        }
    }

    static let audioExtensions = Set([Container.flac, .mp3, .mp4, .wav, .aiff, .ogg, .aac].flatMap(\.extensions))

    static func container(of url: URL) -> Container? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12) else { return nil }
        if head.prefix(3) == Data("ID3".utf8) {
            // An ID3 tag in front: what follows it says what this is.
            guard let start = FLACTags.streamStart(head), (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let after = try? handle.read(upToCount: 12) else { return nil }
            if after.prefix(4) == Data("fLaC".utf8) { return .flac }
            if isADTS(after) { return .aac }
            // MPEG audio, or padding before it.
            return .mp3
        }
        return container(head)
    }

    static func container(_ head: Data) -> Container? {
        let bytes = [UInt8](head.prefix(12))
        func text(_ range: Range<Int>) -> String? {
            bytes.count >= range.upperBound ? String(decoding: bytes[range], as: UTF8.self) : nil
        }
        if text(0..<4) == "fLaC" { return .flac }
        if text(4..<8) == "ftyp" { return .mp4 }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return .wav }
        if text(0..<4) == "FORM", ["AIFF", "AIFC"].contains(text(8..<12) ?? "") { return .aiff }
        if text(0..<4) == "OggS" { return .ogg }
        if isADTS(head) { return .aac }
        if ID3Tags.isMP3(head) { return .mp3 }
        return nil
    }

    private static func isADTS(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(2))
        return bytes.count == 2 && bytes[0] == 0xFF && bytes[1] & 0xF6 == 0xF0
    }

    /// The extension the file should have, when its own is another audio format's: "mp3" for
    /// an MP3 named .flac. Nil when it's right, or the contents aren't recognised.
    static func correctedExtension(for url: URL) -> String? {
        let current = url.pathExtension.lowercased()
        guard audioExtensions.contains(current), let container = container(of: url),
              !container.extensions.contains(current) else { return nil }
        return container.extensions[0]
    }

    /// Whether tags can be written into this file.
    static func canWrite(_ url: URL) -> Bool { [.flac, .mp3].contains(container(of: url)) }

    static func update(_ url: URL, setting values: [String: String], frontCover: FLACTags.Picture? = nil) throws {
        switch container(of: url) {
        case .flac: try FLACTags.update(url, setting: values, frontCover: frontCover)
        case .mp3: try ID3Tags.update(url, setting: values, frontCover: frontCover)
        default: throw FLACTags.WriteError.notFLAC
        }
    }
}
