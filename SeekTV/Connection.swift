import Foundation
import Observation
import Security

/// Which album page to open: by name, and the search result it came from, if any.
struct AlbumRef: Hashable, Codable {
    var artist: String
    var title: String
    var release: String?
}

struct ArtistRef: Hashable {
    var name: String
}

/// Seek on the Mac, as the TV talks to it: the same pages the site on 4n.studio gets, with the
/// TV's own sign-in (approved from a phone, see SignInView).
@MainActor
@Observable
final class Connection {
    enum Problem: Error {
        case notSignedIn
        case unreachable
        case failed(Int)
    }

    /// The Mac's address (its Tailscale Funnel one), set when the app is built.
    let server: URL?
    private(set) var session: String?
    /// Bumped whenever the Mac says something shown may have changed: pages reload on it.
    private(set) var changes = 0
    private(set) var isReachable = true
    @ObservationIgnored private var events: Task<Void, Never>?

    init() {
        let address = Bundle.main.object(forInfoDictionaryKey: "SeekServer") as? String ?? ""
        server = address.isEmpty ? nil : URL(string: address)
        session = Keychain.load()
        startEvents()
    }

    var isSignedIn: Bool { session != nil }

    func signIn(_ session: String) {
        Keychain.save(session)
        self.session = session
        startEvents()
    }

    func signOut() {
        if session != nil {
            Task { try? await post("/api/auth/signout") as [String: Bool] }
        }
        Keychain.clear()
        session = nil
        events?.cancel()
    }

    // MARK: - Requests

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(request(path))
    }

    func post<T: Decodable>(_ path: String, _ body: some Encodable = [String: String]()) async throws -> T {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    /// A song or cover on the Mac (`/files/…`, `/api/…`), with the session in the address: the
    /// player and image loading can't send headers. Others (Apple's, Bandcamp's art) as they are.
    func media(_ path: String?) -> URL? {
        guard let path else { return nil }
        guard path.hasPrefix("/"), let server else { return URL(string: path) }
        let separator = path.contains("?") ? "&" : "?"
        let key = session.map { "\(separator)key=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" } ?? ""
        return URL(string: server.absoluteString + path + key)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let server, let url = URL(string: server.absoluteString + path) else { throw Problem.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let session { request.setValue(session, forHTTPHeaderField: "X-Seek-Key") }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            isReachable = false
            throw Problem.unreachable
        }
        isReachable = true
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Signed out elsewhere (Sign Out Everywhere): sign in again.
            if session != nil, request.url?.path.hasPrefix("/api/auth/") == false { signOut() }
            throw Problem.notSignedIn
        }
        guard (200..<300).contains(status) else { throw Problem.failed(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Changes

    /// The Mac's change events, as lines; reconnects when they stop.
    private func startEvents() {
        events?.cancel()
        guard session != nil else { return }
        events = Task {
            while !Task.isCancelled {
                if let url = media("/api/events"), let (bytes, _) = try? await URLSession.shared.bytes(from: url) {
                    var last = Date.distantPast
                    do {
                        for try await line in bytes.lines where line.hasPrefix("data:") {
                            // At most twice a second: a busy search or download needn't reload constantly.
                            if Date.now.timeIntervalSince(last) > 0.5 {
                                last = .now
                                changes += 1
                            }
                        }
                    } catch {}
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// The TV's session, in its keychain (this device only).
enum Keychain {
    private static let service = "dev.olicarter.seek.tv.session"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ session: String) {
        clear()
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: Data(session.utf8)] as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
