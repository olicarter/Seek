import Compression
import Foundation

enum ProtocolError: LocalizedError {
    case truncated
    case decompression
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .truncated: "Message ended early"
        case .decompression: "Couldn't decompress message"
        case .unexpected(let detail): detail
        }
    }
}

/// Little-endian encoder for Soulseek message bodies.
struct MessageWriter {
    private(set) var data = Data()

    mutating func uint8(_ value: UInt8) { data.append(value) }
    mutating func bool(_ value: Bool) { uint8(value ? 1 : 0) }
    mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func int32(_ value: Int32) { uint32(UInt32(bitPattern: value)) }
    mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func append(_ bytes: Data) { data.append(bytes) }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }
}

/// Little-endian decoder for Soulseek message bodies.
struct MessageReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ProtocolError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func uint8() throws -> UInt8 { try bytes(1)[0] }
    mutating func bool() throws -> Bool { try uint8() != 0 }

    mutating func uint32() throws -> UInt32 {
        let raw = try bytes(4)
        return raw.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func uint64() throws -> UInt64 {
        let raw = try bytes(8)
        return raw.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    /// Strings are length-prefixed. Most clients send UTF-8, older ones Latin-1.
    mutating func string() throws -> String {
        let raw = try bytes(Int(try uint32()))
        return String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
    }

    /// IPv4 addresses are sent as a little-endian integer, so the octets arrive reversed.
    mutating func ipAddress() throws -> String {
        try bytes(4).reversed().map(String.init).joined(separator: ".")
    }
}

enum Frame {
    /// Server and peer messages: uint32 length, uint32 code, body.
    static func message(_ code: UInt32, _ build: (inout MessageWriter) -> Void = { _ in }) -> Data {
        var body = MessageWriter()
        build(&body)
        var frame = MessageWriter()
        frame.uint32(UInt32(body.data.count + 4))
        frame.uint32(code)
        frame.append(body.data)
        return frame.data
    }

    /// Peer init messages (PierceFireWall, PeerInit): uint32 length, uint8 code, body.
    static func peerInit(_ code: UInt8, _ build: (inout MessageWriter) -> Void) -> Data {
        var body = MessageWriter()
        build(&body)
        var frame = MessageWriter()
        frame.uint32(UInt32(body.data.count + 1))
        frame.uint8(code)
        frame.append(body.data)
        return frame.data
    }
}

/// Soulseek compresses some peer messages with zlib. Apple's Compression framework
/// speaks raw deflate, so the zlib header and checksum are handled here.
enum Zlib {
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 2 else { throw ProtocolError.decompression }
        return try process(Data(data.dropFirst(2)), operation: COMPRESSION_STREAM_DECODE)
    }

    static func deflate(_ data: Data) throws -> Data {
        var output = Data([0x78, 0x9C])
        output.append(try process(data, operation: COMPRESSION_STREAM_ENCODE))
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        withUnsafeBytes(of: ((b << 16) | a).bigEndian) { output.append(contentsOf: $0) }
        return output
    }

    private static func process(_ input: Data, operation: compression_stream_operation) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ProtocolError.decompression
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()

        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let empty: [UInt8] = [0]
            try empty.withUnsafeBufferPointer { fallback in
                stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress ?? fallback.baseAddress!
                stream.pointee.src_size = source.count
                var status: compression_status
                repeat {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = bufferSize
                    status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    guard status != COMPRESSION_STATUS_ERROR else { throw ProtocolError.decompression }
                    output.append(buffer, count: bufferSize - stream.pointee.dst_size)
                } while status == COMPRESSION_STATUS_OK
            }
        }
        return output
    }
}
