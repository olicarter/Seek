import CryptoKit
import Foundation

enum ServerCode {
    static let login: UInt32 = 1
    static let setWaitPort: UInt32 = 2
    static let getPeerAddress: UInt32 = 3
    static let connectToPeer: UInt32 = 18
    static let fileSearch: UInt32 = 26
    static let setStatus: UInt32 = 28
    static let ping: UInt32 = 32
    static let sharedFoldersFiles: UInt32 = 35
    static let relogged: UInt32 = 41
    static let privateMessage: UInt32 = 22
    static let privateMessageAcked: UInt32 = 23
    static let cantConnectToPeer: UInt32 = 1001
}

enum PeerCode {
    static let sharedFileListRequest: UInt32 = 4
    static let sharedFileListResponse: UInt32 = 5
    static let fileSearchResponse: UInt32 = 9
    static let userInfoRequest: UInt32 = 15
    static let userInfoResponse: UInt32 = 16
    static let folderContentsRequest: UInt32 = 36
    static let folderContentsResponse: UInt32 = 37
    static let transferRequest: UInt32 = 40
    static let transferResponse: UInt32 = 41
    static let queueUpload: UInt32 = 43
    static let placeInQueueResponse: UInt32 = 44
    static let uploadFailed: UInt32 = 46
    static let uploadDenied: UInt32 = 50
    static let placeInQueueRequest: UInt32 = 51
}

enum PeerInitCode {
    static let pierceFirewall: UInt8 = 0
    static let peerInit: UInt8 = 1
}

enum Messages {
    static let clientVersion: UInt32 = 160
    static let minorVersion: UInt32 = 1

    static func login(username: String, password: String) -> Data {
        let digest = Insecure.MD5.hash(data: Data((username + password).utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return Frame.message(ServerCode.login) {
            $0.string(username)
            $0.string(password)
            $0.uint32(clientVersion)
            $0.string(hash)
            $0.uint32(minorVersion)
        }
    }

    static func fileSearch(token: UInt32, query: String) -> Data {
        Frame.message(ServerCode.fileSearch) {
            $0.uint32(token)
            $0.string(query)
        }
    }

    static func peerInit(username: String, type: String, token: UInt32 = 0) -> Data {
        Frame.peerInit(PeerInitCode.peerInit) {
            $0.string(username)
            $0.string(type)
            $0.uint32(token)
        }
    }

    static func pierceFirewall(token: UInt32) -> Data {
        Frame.peerInit(PeerInitCode.pierceFirewall) { $0.uint32(token) }
    }
}

/// A file offered by a peer in a search result.
struct RemoteFile: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(username)\u{0}\(path)" }
    let username: String
    /// Full path on the peer, with backslash separators.
    let path: String
    let size: UInt64
    var bitrate: Int?
    var duration: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var isVBR = false

    var components: [String] { path.split(separator: "\\").map(String.init) }
    // Read thousands of times while grouping search results, so found without splitting the path.
    var name: String { path.lastIndex(of: "\\").map { String(path[path.index(after: $0)...]) } ?? path }
    var folder: String { path.lastIndex(of: "\\").map { String(path[..<$0]) } ?? "" }
    var fileExtension: String {
        guard let dot = path.lastIndex(of: "."), !path[dot...].contains("\\") else { return "" }
        return path[path.index(after: dot)...].lowercased()
    }
    var isLossless: Bool { ["flac", "wav", "aiff", "aif", "alac"].contains(fileExtension) }


    /// TIDAL's tier (SoundQuality): Max is lossless above CD quality, more than 16-bit or above
    /// 44.1 kHz. Many clients don't report either, so then it's judged by size: CD-quality audio
    /// is at most about 1.4 Mbit/s.
    var soundQuality: SoundQuality {
        guard isLossless else { return .low }
        if bitDepth == nil, sampleRate == nil, let duration, duration > 0 {
            return Double(size) * 8 / Double(duration) > 1_600_000 ? .max : .high
        }
        return SoundQuality(lossless: true, bitDepth: bitDepth, sampleRate: sampleRate)
    }
    var isHiRes: Bool { soundQuality == .max }

    /// "24-bit, 96 kHz", "320 kbps", "VBR 245 kbps".
    var qualityDetail: String? {
        if !isLossless, isVBR, let bitrate { return "VBR \(bitrate) kbps" }
        return SoundQuality.detail(lossless: isLossless, bitDepth: bitDepth, sampleRate: sampleRate, bitrate: bitrate)
    }
}

/// How good a copy Seek should prefer when choosing one to download.
enum QualityPreference: String, CaseIterable, Identifiable, Sendable {
    /// 16-bit lossless: far smaller than hi-res, and what DJ software and most ears need.
    case cd
    case highest

    var id: String { rawValue }
    static let defaultsKey = "qualityPreference"

    var name: String {
        switch self {
        case .cd: "High (up to 16-bit, 44.1 kHz)"
        case .highest: "Max (up to 24-bit, 192 kHz)"
        }
    }
}

struct SearchResponse: Sendable {
    let username: String
    let token: UInt32
    let files: [RemoteFile]
    let hasFreeSlot: Bool
    let averageSpeed: UInt32
    let queueLength: UInt32

    /// Parses the zlib-compressed body of a FileSearchResponse (peer code 9).
    static func parse(compressed: Data) throws -> SearchResponse {
        var reader = MessageReader(try Zlib.inflate(compressed))
        let username = try reader.string()
        let token = try reader.uint32()
        let count = try reader.uint32()
        var files: [RemoteFile] = []
        files.reserveCapacity(Int(min(count, 5000)))
        for _ in 0..<count {
            _ = try reader.uint8()
            var file = RemoteFile(username: username, path: try reader.string(), size: try reader.uint64())
            _ = try reader.string()
            let attributeCount = try reader.uint32()
            for _ in 0..<attributeCount {
                let code = try reader.uint32()
                let value = Int(try reader.uint32())
                switch code {
                case 0: file.bitrate = value
                case 1: file.duration = value
                case 2: file.isVBR = value != 0
                case 4: file.sampleRate = value
                case 5: file.bitDepth = value
                default: break
                }
            }
            files.append(file)
        }
        let hasFreeSlot = try reader.bool()
        let averageSpeed = try reader.uint32()
        let queueLength = reader.remaining >= 4 ? try reader.uint32() : 0
        return SearchResponse(
            username: username, token: token, files: files,
            hasFreeSlot: hasFreeSlot, averageSpeed: averageSpeed, queueLength: queueLength
        )
    }
}

/// Everything in one folder on a peer (FolderContentsResponse, peer code 37). Searches only return
/// the files whose names match, so this is how a whole release is seen.
struct FolderContents: Sendable {
    let token: UInt32
    let folder: String
    let files: [RemoteFile]

    static func parse(compressed: Data, username: String) throws -> FolderContents {
        var reader = MessageReader(try Zlib.inflate(compressed))
        let token = try reader.uint32()
        let folder = try reader.string()
        var files: [RemoteFile] = []
        let directories = try reader.uint32()
        for _ in 0..<min(directories, 200) {
            let directory = try reader.string()
            let count = try reader.uint32()
            for _ in 0..<count {
                _ = try reader.uint8()
                let name = try reader.string()
                // Names are usually relative to their directory; some clients send full paths.
                let path = name.contains("\\") ? name : "\(directory)\\\(name)"
                var file = RemoteFile(username: username, path: path, size: try reader.uint64())
                _ = try reader.string()
                let attributeCount = try reader.uint32()
                for _ in 0..<attributeCount {
                    let code = try reader.uint32()
                    let value = Int(try reader.uint32())
                    switch code {
                    case 0: file.bitrate = value
                    case 1: file.duration = value
                    case 2: file.isVBR = value != 0
                    case 4: file.sampleRate = value
                    case 5: file.bitDepth = value
                    default: break
                    }
                }
                files.append(file)
            }
        }
        return FolderContents(token: token, folder: folder, files: files)
    }
}
