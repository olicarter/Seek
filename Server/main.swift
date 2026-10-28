import AppKit
import Hummingbird

// Seek on the web: the app's own core on this Mac, the site in web/dist, both served from
// one port. Only this Mac can reach it unless started with --lan, or Tailscale serves it;
// from anywhere but this Mac, a browser needs pairing first (see Pairing.swift).
//
// It runs as a Mac app with no Dock icon, so it can show Bandcamp's sign-in page in a window.

let arguments = CommandLine.arguments
let port = arguments.firstIndex(of: "--port").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 8765
let host = arguments.contains("--lan") ? "0.0.0.0" : "127.0.0.1"
let site = arguments.firstIndex(of: "--site").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "web/dist").path

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let core = Core()
    Task {
        await core.start()
        let app = Application(router: makeRouter(core: core, site: site),
                              configuration: .init(address: .hostname(host, port: port), serverName: "Seek"))
        print("Seek is at http://\(host == "0.0.0.0" ? "<this Mac's address>" : "localhost"):\(port)")
        print("Library: \(Core.musicFolder.path)")
        print("Pair a browser: http://localhost:\(port)/pair")
        do {
            try await app.runService()
        } catch {
            print("Seek stopped: \(error)")
            exit(1)
        }
    }
    NSApplication.shared.run()
}
