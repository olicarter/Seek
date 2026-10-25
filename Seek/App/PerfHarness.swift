#if DEBUG
import Foundation

/// Developer tool: `-PerfImports <n>` adds n copies of a library song one by one, as downloads
/// would, while a watchdog prints every main-thread stall over 50 ms. Prints lines starting "PERF".
enum PerfHarness {
    static var requestedImports: Int {
        UserDefaults.standard.integer(forKey: "PerfImports")
    }

    @MainActor
    static func run(_ count: Int, library: LibraryStore) async {
        startWatchdog()
        try? await Task.sleep(for: .seconds(8))
        guard let source = library.allTracks.first(where: { $0.fileExtension == "flac" }).flatMap(library.url(for:)) else {
            print("PERF no source file")
            return
        }
        for index in 1...count {
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
            try? FileManager.default.copyItem(at: source, to: copy)
            print("PERF import \(index) start \(Date.now.timeIntervalSince1970)")
            _ = try? await library.importFile(at: copy, folders: ["Perf Artist", "Perf Album"], name: "\(index) - Perf Song \(index).flac")
            print("PERF import \(index) done \(Date.now.timeIntervalSince1970)")
            try? await Task.sleep(for: .seconds(4))
        }
        print("PERF finished")
    }

    private static func startWatchdog() {
        Thread.detachNewThread {
            while true {
                let sent = Date.now
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let stall = Date.now.timeIntervalSince(sent)
                if stall > 0.05 { print("PERF stall \(Int(stall * 1000)) ms at \(sent.timeIntervalSince1970)") }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
}
#endif
