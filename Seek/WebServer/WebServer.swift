import Foundation
import Hummingbird
import Observation

/// Seek on the web, served by the Mac app: the site (bundled with the app) and what it asks
/// for, on this Mac's port 8765. Tailscale Funnel puts that on the internet at the Mac's ts.net
/// address, where the site on 4n.studio reaches it; browsers sign in with passkeys.
@MainActor
@Observable
final class WebServer {
    enum State: Equatable {
        case off
        case running
        case failed(String)
    }

    static let port = 8765
    static let enabledKey = "webAccess"
    static let site = URL(string: "https://4n.studio/seek/web/")!

    private(set) var state = State.off
    private(set) var passkeyCount = 0
    @ObservationIgnored private let core: Core
    @ObservationIgnored private var serving: Task<Void, Never>?

    init(core: Core) {
        self.core = core
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    /// Once the library is open (its folder is where songs are served from).
    func start() {
        guard Self.isEnabled, serving == nil else { return }
        let site = Bundle.main.resourceURL?.appending(path: "web").path ?? ""
        let app = Application(router: makeRouter(core: core, site: site),
                              configuration: .init(address: .hostname("127.0.0.1", port: Self.port), serverName: "Seek"))
        core.start()
        // Where this Mac is, for the person's iPhone and iPad (through iCloud Keychain).
        AppKey.publish()
        // Signed in to Soulseek even with the window closed: the web may want it any time.
        core.client.staysSignedIn = true
        state = .running
        serving = Task {
            do {
                try await app.runService()
                if state == .running { state = .off }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        Task { passkeyCount = await Passkeys.shared.passkeys.count }
    }

    func stop() {
        serving?.cancel()
        serving = nil
        core.stop()
        core.client.staysSignedIn = false
        state = .off
    }

    func refreshPasskeys() async {
        passkeyCount = await Passkeys.shared.passkeys.count
    }

    /// Back in on every device: drops the passkeys and sessions, so pairing links work again.
    func resetAccess() async {
        for passkey in await Passkeys.shared.passkeys { await Passkeys.shared.remove(passkey: passkey.id) }
        await Passkeys.shared.signOutEverywhere()
        passkeyCount = 0
    }
}
