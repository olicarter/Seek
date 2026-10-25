import SwiftUI
import UIKit

/// Builds installed from 4n.studio notice when there's a newer one there and install it the
/// way the site's Install button does: iOS asks, then replaces the app in place.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater(app: "seek")

    /// The newer build on 4n.studio, once one is found.
    private(set) var availableBuild: Int?
    /// What changed since this build, newest first.
    private(set) var changes: [String] = []
    /// Only ad hoc builds (the ones 4n.studio serves) look for updates; development builds don't.
    let isEnabled: Bool
    private let app: String
    @ObservationIgnored private var lastCheck: Date?
    /// Set once Update is tapped, until iOS's install prompt has been answered.
    @ObservationIgnored fileprivate var awaitingPrompt = false
    @ObservationIgnored fileprivate var sawPrompt = false

    init(app: String) {
        self.app = app
        #if DEBUG
        isEnabled = Self.isAdHoc || UserDefaults.standard.bool(forKey: "AppUpdaterTest")
        #else
        isEnabled = Self.isAdHoc
        #endif
    }

    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// Looks each time the app comes to the front (a tiny file, so only quick repeats are skipped).
    func check() async {
        guard isEnabled, lastCheck.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true,
              let url = URL(string: "https://4n.studio/\(app)/version.json") else { return }
        lastCheck = .now
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let latest = try? JSONDecoder().decode(Latest.self, from: data),
              let build = Int(latest.build) else { return }
        guard build > currentBuild else {
            availableBuild = nil
            changes = []
            return
        }
        // Every build since this one, so skipping a few updates still shows all that changed.
        changes = (latest.history ?? [])
            .filter { (Int($0.build) ?? 0) > currentBuild }
            .flatMap(\.notes)
        availableBuild = build
    }

    /// Opens iOS's install prompt. The update only starts once the app has quit, so it quits as
    /// soon as the prompt is answered.
    func install() {
        guard let url = URL(string: "itms-services://?action=download-manifest&url=https://4n.studio/\(app)/manifest.plist") else { return }
        awaitingPrompt = true
        sawPrompt = false
        UIApplication.shared.open(url)
    }

    fileprivate func sceneChanged(to phase: ScenePhase) {
        guard awaitingPrompt else { return }
        switch phase {
        case .inactive:
            sawPrompt = true
        case .active where sawPrompt:
            awaitingPrompt = false
            // Off to the Home Screen, where the icon shows the update's progress, then quit.
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                exit(0)
            }
        case .background:
            // Left by hand while the prompt was up: quitting now lets the update start.
            awaitingPrompt = false
            exit(0)
        default:
            break
        }
    }

    private struct Latest: Decodable {
        let build: String
        let history: [Release]?
    }

    private struct Release: Decodable {
        let build: String
        let notes: [String]
    }

    /// An ad hoc profile lists the devices it installs on and doesn't allow debugging.
    private static var isAdHoc: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any]
        else { return false }
        let entitlements = plist["Entitlements"] as? [String: Any]
        return plist["ProvisionedDevices"] != nil && entitlements?["get-task-allow"] as? Bool == false
    }
}

extension View {
    /// Checks for a newer build whenever the app comes to the front and offers it once per build.
    func appUpdatePrompt() -> some View {
        modifier(AppUpdatePrompt())
    }
}

private struct AppUpdatePrompt: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("AppUpdaterDeclinedBuild") private var declinedBuild = 0
    private var updater: AppUpdater { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                updater.sceneChanged(to: phase)
                if phase == .active { Task { await updater.check() } }
            }
            .alert(
                "Update Available",
                isPresented: Binding(
                    get: { (updater.availableBuild ?? 0) > declinedBuild },
                    set: { if !$0 { declinedBuild = updater.availableBuild ?? declinedBuild } }
                )
            ) {
                Button("Update") { updater.install() }
                Button("Later", role: .cancel) {}
            } message: {
                Text(Self.message(updater.changes))
            }
    }

    static func message(_ changes: [String]) -> String {
        guard !changes.isEmpty else { return "A new version is on 4n.studio. You can also update later from Settings." }
        let shown = changes.prefix(6).map { "• \($0)" }
        let more = changes.count > 6 ? ["and \(changes.count - 6) more"] : []
        return (["What's new:"] + shown + more).joined(separator: "\n")
    }
}
