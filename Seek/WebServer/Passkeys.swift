import CryptoKit
import Foundation

/// Signing in to the server with a passkey (WebAuthn), for browsers anywhere but this Mac.
///
/// Passkeys belong to 4n.studio, where the site is: only its pages can use them. The server keeps
/// each one's public key; signing in, the browser's passkey signs a fresh challenge, which is
/// checked here along with where it came from, and the browser gets a session of its own.
actor Passkeys {
    static let shared = Passkeys()
    static let site = "4n.studio"
    static let origin = "https://4n.studio"

    struct Passkey: Codable, Sendable {
        /// The credential's id, base64url, as browsers give it.
        var id: String
        /// SubjectPublicKeyInfo (DER), P-256.
        var publicKey: Data
        var signCount: UInt32
        var name: String
        var created: Date
        var lastUsed: Date?
    }

    private struct Session: Codable {
        /// SHA-256 of the token, so the file alone can't sign anyone in.
        var hash: String
        var created: Date
        var lastUsed: Date
    }

    private struct Saved: Codable {
        /// Who the passkeys are for (one person: whoever runs the server).
        var userID: Data
        var passkeys: [Passkey] = []
        var sessions: [Session] = []
    }

    enum Purpose: Sendable { case register, signIn }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let reason) = self { reason } else { "" } }
    }

    private var saved: Saved
    private var challenges: [Data: (purpose: Purpose, expires: Date)] = [:]

    /// A device that can't use a passkey (the Apple TV) waiting for a signed-in browser to approve
    /// its code. It polls with the secret, which only it knows; the code alone gets nothing.
    private struct Device {
        var secret: String
        var name: String
        var expires: Date
        var session: String?
    }
    private var devices: [String: Device] = [:]

    private static var file: URL { Core.storeFolder.appending(path: "passkeys.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            self.saved = saved
        } else {
            saved = Saved(userID: Self.random(16))
        }
    }

    var hasPasskeys: Bool { !saved.passkeys.isEmpty }
    var passkeys: [Passkey] { saved.passkeys }
    var userID: Data { saved.userID }

    // MARK: - Challenges

    /// A fresh challenge, good for five minutes and one use.
    func challenge(for purpose: Purpose) -> Data {
        let now = Date.now
        challenges = challenges.filter { $0.value.expires > now }
        // Plenty for one person; keeps anyone asking over and over from filling memory.
        if challenges.count > 50, let oldest = challenges.min(by: { $0.value.expires < $1.value.expires }) {
            challenges[oldest.key] = nil
        }
        let challenge = Self.random(32)
        challenges[challenge] = (purpose, now.addingTimeInterval(300))
        return challenge
    }

    // MARK: - Registering

    /// A new passkey, from a browser already trusted (the route checks that). Returns that
    /// browser's session.
    func register(id: String, clientData: Data, authenticatorData: Data, publicKey: Data, algorithm: Int, name: String) throws -> String {
        try check(clientData, type: "webauthn.create", purpose: .register)
        let flags = try checkAuthenticatorData(authenticatorData)
        // ES256 (P-256), which every passkey provider supports.
        guard algorithm == -7, (try? P256.Signing.PublicKey(derRepresentation: publicKey)) != nil else {
            throw Failure.invalid("That passkey's kind isn't supported")
        }
        // The credential the authenticator made is the one the browser named.
        guard flags & 0x40 != 0, authenticatorData.count >= 55 else { throw Failure.invalid("No new credential") }
        let length = Int(authenticatorData[53]) << 8 | Int(authenticatorData[54])
        guard authenticatorData.count >= 55 + length,
              Self.base64url(authenticatorData.subdata(in: 55..<(55 + length))) == id else {
            throw Failure.invalid("The credential doesn't match")
        }
        guard !saved.passkeys.contains(where: { $0.id == id }) else { throw Failure.invalid("That passkey is already added") }
        saved.passkeys.append(Passkey(id: id, publicKey: publicKey, signCount: Self.signCount(authenticatorData),
                                      name: name.isEmpty ? "Passkey" : String(name.prefix(60)), created: .now))
        return newSession()
    }

    // MARK: - Signing in

    func signIn(id: String, clientData: Data, authenticatorData: Data, signature: Data) throws -> String {
        try check(clientData, type: "webauthn.get", purpose: .signIn)
        _ = try checkAuthenticatorData(authenticatorData)
        guard let index = saved.passkeys.firstIndex(where: { $0.id == id }),
              let key = try? P256.Signing.PublicKey(derRepresentation: saved.passkeys[index].publicKey),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            throw Failure.invalid("That passkey isn't one of this server's")
        }
        // Signed: the authenticator data, then the hash of what the browser saw.
        let signed = authenticatorData + Data(SHA256.hash(data: clientData))
        guard key.isValidSignature(ecdsa, for: signed) else { throw Failure.invalid("The passkey's signature doesn't check out") }
        // Synced passkeys always say 0; a count going backwards means a copied authenticator.
        let count = Self.signCount(authenticatorData)
        let stored = saved.passkeys[index].signCount
        guard count == 0 || count > stored else { throw Failure.invalid("That passkey looks copied") }
        saved.passkeys[index].signCount = count
        saved.passkeys[index].lastUsed = .now
        return newSession()
    }

    // MARK: - Devices

    enum DeviceState: Sendable { case pending, approved(String), expired }

    /// A code to show on the device, and the secret it polls with. Good for ten minutes.
    func beginDevice(name: String) -> (code: String, secret: String) {
        let now = Date.now
        devices = devices.filter { $0.value.expires > now }
        if devices.count > 10, let oldest = devices.min(by: { $0.value.expires < $1.value.expires }) { devices[oldest.key] = nil }
        // No 0/O or 1/I/L: read off a TV across the room.
        let letters = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var code = ""
        repeat {
            code = String(Self.random(8).map { letters[Int($0) % letters.count] })
        } while devices[code] != nil
        let secret = Self.base64url(Self.random(32))
        devices[code] = Device(secret: secret, name: String(name.prefix(60)), expires: now.addingTimeInterval(600))
        return (Self.display(code), secret)
    }

    /// From a signed-in browser (the route checks that). Returns the device's name.
    func approveDevice(code: String) throws -> String {
        let key = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard var device = devices[key], device.expires > .now, device.session == nil else {
            throw Failure.invalid("That code isn't one the TV is showing now")
        }
        device.session = newSession()
        devices[key] = device
        return device.name
    }

    func pollDevice(secret: String) -> DeviceState {
        guard let (code, device) = devices.first(where: { $0.value.secret == secret }) else { return .expired }
        if let session = device.session {
            devices[code] = nil
            return .approved(session)
        }
        if device.expires < .now {
            devices[code] = nil
            return .expired
        }
        return .pending
    }

    /// "ABCD2345" → "ABCD-2345".
    static func display(_ code: String) -> String {
        "\(code.prefix(4))-\(code.suffix(code.count - 4))"
    }

    // MARK: - Sessions

    func isValid(session token: String) -> Bool {
        let hash = Self.hash(token)
        guard let index = saved.sessions.firstIndex(where: { $0.hash == hash }) else { return false }
        // Written at most hourly, not on every song request.
        if saved.sessions[index].lastUsed.timeIntervalSinceNow < -3600 {
            saved.sessions[index].lastUsed = .now
            save()
        }
        return true
    }

    func signOut(session token: String) {
        let hash = Self.hash(token)
        saved.sessions.removeAll { $0.hash == hash }
        save()
    }

    /// Every browser signs in again.
    func signOutEverywhere() {
        saved.sessions = []
        save()
    }

    func remove(passkey id: String) {
        saved.passkeys.removeAll { $0.id == id }
        save()
    }

    private func newSession() -> String {
        let token = Self.base64url(Self.random(32))
        saved.sessions.append(Session(hash: Self.hash(token), created: .now, lastUsed: .now))
        save()
        return token
    }

    // MARK: - Checks

    /// What the browser says it signed: the right kind of request, a challenge of ours (used up
    /// now), from the site on 4n.studio.
    private func check(_ clientData: Data, type: String, purpose: Purpose) throws {
        guard let json = try? JSONSerialization.jsonObject(with: clientData) as? [String: Any],
              json["type"] as? String == type,
              let challenge = (json["challenge"] as? String).flatMap(Self.data(base64url:)) else {
            throw Failure.invalid("The browser's answer isn't readable")
        }
        guard let pending = challenges.removeValue(forKey: challenge), pending.purpose == purpose, pending.expires > .now else {
            throw Failure.invalid("That sign-in took too long, or was already used")
        }
        guard json["origin"] as? String == Self.origin, json["crossOrigin"] as? Bool != true else {
            throw Failure.invalid("That passkey answer didn't come from \(Self.origin)")
        }
    }

    /// For 4n.studio, with you there (user present) and verified (Face ID, Touch ID or a PIN).
    /// Returns the flags.
    private func checkAuthenticatorData(_ data: Data) throws -> UInt8 {
        guard data.count >= 37, data.prefix(32) == Data(SHA256.hash(data: Data(Self.site.utf8))) else {
            throw Failure.invalid("That passkey is for another site")
        }
        let flags = data[data.startIndex + 32]
        guard flags & 0x01 != 0, flags & 0x04 != 0 else { throw Failure.invalid("The passkey wasn't confirmed with Face ID, Touch ID or a PIN") }
        return flags
    }

    private static func signCount(_ data: Data) -> UInt32 {
        data.subdata(in: 33..<37).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    // MARK: - Encoding

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
