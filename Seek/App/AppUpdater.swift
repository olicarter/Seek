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
    /// Only ad hoc builds (the ones 4n.studio serves) look for updates; development builds don't.
    let isEnabled: Bool
    private let app: String
    @ObservationIgnored private var lastCheck: Date?

    init(app: String) {
        self.app = app
        #if DEBUG
        isEnabled = Self.isAdHoc || UserDefaults.standard.bool(forKey: "AppUpdaterTest")
        #else
        isEnabled = Self.isAdHoc
        #endif
    }

    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// Looks at most every ten minutes, as the app comes to the front.
    func check() async {
        guard isEnabled, lastCheck.map({ Date.now.timeIntervalSince($0) > 600 }) ?? true,
              let url = URL(string: "https://4n.studio/\(app)/version.json") else { return }
        lastCheck = .now
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let latest = try? JSONDecoder().decode(Latest.self, from: data),
              let build = Int(latest.build) else { return }
        availableBuild = build > currentBuild ? build : nil
    }

    func install() {
        guard let url = URL(string: "itms-services://?action=download-manifest&url=https://4n.studio/\(app)/manifest.plist") else { return }
        UIApplication.shared.open(url)
    }

    private struct Latest: Decodable {
        let build: String
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
            .task(id: scenePhase) {
                if scenePhase == .active { await updater.check() }
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
                Text("A new version is on 4n.studio. You can also update later from Settings.")
            }
    }
}
