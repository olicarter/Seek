import Foundation

extension FLACTags {
    enum WriteError: LocalizedError {
        case notFLAC
        case malformed

        var errorDescription: String? {
            switch self {
            case .notFLAC: "Not a FLAC file"
            case .malformed: "The FLAC file's metadata couldn't be read"
            }
        }
    }

    /// Other spellings of a field that should be replaced along with it.
    private static let aliases: [String: Set<String>] = [
        "ALBUMARTIST": ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"],
    ]

    /// A front cover to embed, replacing any existing front cover.
    struct Picture {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
    }

    /// Sets Vorbis comment fields (e.g. "ARTIST": "DreamKiller"), keeping every other field,
    /// the artwork and the audio untouched, and optionally replaces the front cover. The file is
    /// rewritten and swapped in atomically.
    static func update(_ url: URL, setting values: [String: String], frontCover: Picture? = nil) throws {
        let whole = try Data(contentsOf: url, options: .mappedIfSafe)
        // An ID3 tag in front (non-standard, see FLACTags.streamStart) is left out of the new file.
        guard let start = FLACTags.streamStart(whole.prefix(10)), whole.count > start + 4 else { throw WriteError.notFLAC }
        let data = whole.subdata(in: start..<whole.count)
        guard data.prefix(4) == Data("fLaC".utf8) else { throw WriteError.notFLAC }

        // Read every metadata block; the audio frames follow the last one.
        var blocks: [(type: UInt8, body: Data)] = []
        var offset = 4
        var isLast = false
        while !isLast {
            guard offset + 4 <= data.count else { throw WriteError.malformed }
            let header = data[data.startIndex + offset ..< data.startIndex + offset + 4].map { $0 }
            isLast = header[0] & 0x80 != 0
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            offset += 4
            guard offset + length <= data.count else { throw WriteError.malformed }
            blocks.append((header[0] & 0x7F, data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)))
            offset += length
        }
        guard blocks.first?.type == 0 else { throw WriteError.malformed }

        var vendor = "Seek"
        var comments: [String] = []
        if let existing = blocks.first(where: { $0.type == 4 }) {
            var reader = MessageReader(existing.body)
            vendor = (try? reader.string()) ?? vendor
            let count = (try? reader.uint32()) ?? 0
            for _ in 0..<count {
                guard let comment = try? reader.string() else { break }
                comments.append(comment)
            }
        }

        let replaced = values.keys.reduce(into: Set<String>()) { keys, key in
            keys.formUnion(aliases[key.uppercased()] ?? [key.uppercased()])
        }
        comments.removeAll { comment in
            guard let equals = comment.firstIndex(of: "=") else { return false }
            return replaced.contains(comment[..<equals].uppercased())
        }
        comments += values.keys.sorted().map { "\($0.uppercased())=\(values[$0]!)" }

        var body = MessageWriter()
        body.string(vendor)
        body.uint32(UInt32(comments.count))
        comments.forEach { body.string($0) }
        guard body.data.count < 1 << 24 else { throw WriteError.malformed }

        var newBlocks = blocks.filter { $0.type != 4 }
        newBlocks.insert((4, body.data), at: 1)
        if let frontCover {
            // Drop the old front cover (and untyped "other" pictures players treat as the cover).
            newBlocks.removeAll { $0.type == 6 && [0, 3].contains(pictureType(of: $0.body)) }
            let block = pictureBlock(frontCover)
            guard block.count < 1 << 24 else { throw WriteError.malformed }
            newBlocks.insert((6, block), at: 2)
        }

        var output = Data("fLaC".utf8)
        for (index, block) in newBlocks.enumerated() {
            let flag: UInt8 = index == newBlocks.count - 1 ? 0x80 : 0
            let length = block.body.count
            output.append(contentsOf: [flag | block.type, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            output.append(block.body)
        }
        output.append(data[(data.startIndex + offset)...])

        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).flac")
        try output.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private static func pictureType(of body: Data) -> UInt32 {
        guard body.count >= 4 else { return 0 }
        return body.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A METADATA_BLOCK_PICTURE body; unlike Vorbis comments, its integers are big-endian.
    static func pictureBlock(_ picture: Picture) -> Data {
        var data = Data()
        func append(_ value: Int) {
            data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        let mime = Data(picture.mimeType.utf8)
        append(3) // front cover
        append(mime.count)
        data.append(mime)
        append(0) // no description
        append(picture.width)
        append(picture.height)
        append(24) // colour depth
        append(0) // not indexed
        append(picture.data.count)
        data.append(picture.data)
        return data
    }
}
