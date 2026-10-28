import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps work going for a while after the app leaves the screen (iOS asks before suspending
/// it). On a Mac, where the server keeps running, there's nothing to ask for.
@MainActor
struct BackgroundWork {
    #if canImport(UIKit)
    private var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    var isRunning: Bool {
        #if canImport(UIKit)
        task != .invalid
        #else
        false
        #endif
    }

    /// `expired`: iOS is about to suspend the app anyway.
    mutating func begin(_ name: String, expired: @escaping @MainActor () -> Void) {
        #if canImport(UIKit)
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expired() }
        }
        #endif
    }

    mutating func end() {
        #if canImport(UIKit)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #endif
    }
}
