import Foundation
import Observation
import UIKit
import ZIPFoundation

@MainActor
@Observable
final class BandcampDownload: Identifiable {
    enum State: Equatable {
        case preparing
        case downloading
        case importing
        case completed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .completed, .failed: false
            default: true
            }
        }

        var label: String {
            switch self {
            case .preparing: "Preparing on Bandcamp…"
            case .downloading: "Downloading"
            case .importing: "Adding to library…"
            case .completed: "Done"
            case .failed(let reason): reason
            }
        }
    }

    let item: BandcampItem
    var state: State = .preparing
    var progress: Double = 0
    /// Tries so far after failing, and when it'll be tried again by itself.
    @ObservationIgnored var retries = 0
    var retryAt: Date?
    @ObservationIgnored var task: Task<Void, Never>?

    nonisolated var id: String { item.id }

    init(item: BandcampItem) {
        self.item = item
    }
}

/// Signs in to Bandcamp, caches the fan's purchases, and downloads them into the library.
@MainActor
@Observable
final class BandcampClient {
    private(set) var username: String?
    private(set) var items: [BandcampItem] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    private(set) var downloads: [BandcampDownload] = []
    /// The fan's wishlist, used to put wanted releases first in Buy on Bandcamp.
    private(set) var wishlist: [BandcampAPI.StoreResult] = []
    /// Store releases opened for purchase that haven't shown up in the collection yet.
    private(set) var awaitingPurchase: Set<Int> = []

    /// Imports one audio file into Music/<folders…>/<name>. Set by the app.
    @ObservationIgnored var importFile: ((URL, [String], String) async throws -> Void)?
    /// Swaps library files for a just-imported purchase's: (purchase, paths to replace). Set by the app.
    @ObservationIgnored var replaceFiles: ((BandcampItem, [String]) async -> Void)?

    // MARK: - Replacing downloads

    private static let replacementsKey = "bandcampReplacements"

    /// Library files to swap for a release's Bandcamp copy once it's downloaded, by release id.
    /// Saved, since a purchase can take a while to arrive.
    private var replacements: [Int: [String]] {
        get {
            (UserDefaults.standard.data(forKey: Self.replacementsKey))
                .flatMap { try? JSONDecoder().decode([Int: [String]].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.replacementsKey) }
    }

    /// After buying (or if already owned, downloading) this release, its tracks replace these files.
    func replace(_ paths: [String], with result: BandcampAPI.StoreResult) {
        replacements[result.id] = paths
        if let item = owned(result) {
            if let existing = download(for: item), existing.state == .completed {
                downloads.removeAll { $0 === existing }
            }
            download(item)
        }
    }

    /// A purchase in the collection with this artist and title, including labels' "Artist - Album" uploads.
    func ownedRelease(artist: String, title: String) -> BandcampItem? {
        items.first { item in
            let split = ReleaseGrouper.splitLabelUpload(title: item.title, seller: item.artist)
            return ReleaseText.titlesMatch(split.title, title)
                && (ReleaseText.artistsMatch(split.artist, artist) || ReleaseText.artistsMatch(item.artist, artist))
        }
    }

    func isReplacing(_ result: BandcampAPI.StoreResult) -> Bool {
        replacements[result.id] != nil
    }

    /// Finds an album on the Bandcamp store: same title, and the artist as artist or as the
    /// "Artist - Album" of a label's upload.
    func storeRelease(artist: String, title: String) async -> BandcampAPI.StoreResult? {
        let results = await storeSearch("\(artist) \(title)")
        return results.first { result in
            guard !result.isTrack else { return false }
            let split = ReleaseGrouper.splitLabelUpload(title: result.title, seller: result.artist)
            return ReleaseText.titlesMatch(split.title, title)
                && (ReleaseText.artistsMatch(split.artist, artist) || ReleaseText.artistsMatch(result.artist, artist))
        }
    }

    /// The login cookie syncs through iCloud Keychain, so signing in once covers every device.
    @ObservationIgnored private let keychain = KeychainItem(service: "dev.olicarter.seek.bandcamp")
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var fanId: Int?
    @ObservationIgnored private var purchaseWatches: [Int: Task<Void, Never>] = [:]

    private static var cacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "bandcamp-collection.json")
    }

    private static var wishlistCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "bandcamp-wishlist.json")
    }

    private static var downloadsURL: URL {
        URL.applicationSupportDirectory.appending(path: "bandcamp-downloads.json")
    }

    /// A download as saved between launches.
    private struct SavedDownload: Codable {
        var item: BandcampItem
        var completed: Bool
        var failure: String?
    }

    @ObservationIgnored private var lastSavedDownloads: Data?
    @ObservationIgnored private var saveLoop: Task<Void, Never>?

    init() {
        username = keychain.load()?.account
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([BandcampItem].self, from: data) {
            items = cached
        }
        // Kept between launches so Buy on Bandcamp can put wishlist items first straight away.
        if let data = try? Data(contentsOf: Self.wishlistCacheURL),
           let cached = try? JSONDecoder().decode([BandcampAPI.StoreResult].self, from: data) {
            wishlist = cached.map { result in
                var result = result
                result.artworkURL = BandcampAPI.repaired(result.artworkURL)
                return result
            }
        }
        if let data = try? Data(contentsOf: Self.downloadsURL),
           let saved = try? JSONDecoder().decode([SavedDownload].self, from: data) {
            // Finished ones aren't shown, so they aren't kept past a restart either.
            downloads = saved.filter { !$0.completed }.map { saved in
                let download = BandcampDownload(item: saved.item)
                if saved.completed {
                    download.state = .completed
                    download.progress = 1
                } else if let failure = saved.failure {
                    download.state = .failed(failure)
                }
                return download
            }
            lastSavedDownloads = data
        }
    }

    /// Starts again any downloads that were unfinished when the app last quit (or was updated),
    /// and keeps the list saved from now on.
    func restoreDownloads() {
        for download in downloads where download.state.isActive {
            start(download)
        }
        // Ones that failed for a reason that may have passed (a dropped connection) get another go.
        for download in downloads {
            if case .failed(let reason) = download.state, RetryPolicy.delay(after: 0, reason: reason) != nil {
                start(download)
            }
        }
        saveLoop?.cancel()
        saveLoop = Task {
            while !Task.isCancelled {
                saveDownloads()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func saveDownloads() {
        let saved = downloads.map { download in
            var failure: String?
            if case .failed(let reason) = download.state { failure = reason }
            return SavedDownload(item: download.item, completed: download.state == .completed, failure: failure)
        }
        guard let data = try? JSONEncoder().encode(saved), data != lastSavedDownloads else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.downloadsURL, options: .atomic)
        lastSavedDownloads = data
    }

    var isSignedIn: Bool { username != nil }
    var activeDownloadCount: Int { downloads.filter(\.state.isActive).count }

    private var identity: String? {
        keychain.load().flatMap { String(data: $0.data, encoding: .utf8) }
    }

    // MARK: - Account

    /// Called by the login page once Bandcamp has set its `identity` cookie.
    func completeSignIn(identity: String) async throws {
        let fan = try await BandcampAPI.fan(identity: identity)
        let name = fan.username ?? "Bandcamp"
        keychain.save(account: name, data: Data(identity.utf8))
        username = name
        await refresh()
    }

    func signOut() {
        keychain.clear()
        username = nil
        items = []
        wishlist = []
        lastRefresh = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.wishlistCacheURL)
        Task { await BandcampLoginView.clearCookies() }
    }

    // MARK: - Collection

    /// Refreshes the collection if it's empty or more than a few hours old.
    func refreshIfStale() async {
        guard isSignedIn, !isRefreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 6 * 3600, !items.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        guard let identity, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fan = try await BandcampAPI.fan(identity: identity)
            fanId = fan.id
            let fetched = try await BandcampAPI.collection(fanId: fan.id, identity: identity)
            items = fetched
            // The wishlist only affects ordering, so a failure here isn't worth reporting.
            do {
                wishlist = try await BandcampAPI.wishlist(fanId: fan.id, identity: identity)
                try? JSONEncoder().encode(wishlist).write(to: Self.wishlistCacheURL)
            } catch {
                Log.debug("bandcamp wishlist failed: \(error)")
            }
            lastRefresh = Date()
            lastError = nil
            saveCache()
            Log.debug("bandcamp: \(fetched.count) items, \(fetched.filter { $0.redownloadURL != nil }.count) downloadable, \(wishlist.count) wishlisted")
        } catch {
            lastError = error.localizedDescription
            Log.debug("bandcamp refresh failed: \(error)")
        }
    }

    private func saveCache() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.cacheURL)
    }

    // MARK: - Buying

    /// Bandcamp's raw search results; rank them with `storeResults(for:found:)` when showing them.
    func storeSearch(_ query: String) async -> [BandcampAPI.StoreResult] {
        (try? await BandcampAPI.searchStore(query)) ?? []
    }

    /// Releases for sale matching a search: wishlisted ones first (including any the site search
    /// missed), leaving out ones already owned. Recomputed whenever the wishlist or collection change.
    func storeResults(for query: String, found: [BandcampAPI.StoreResult]) -> [BandcampAPI.StoreResult] {
        Self.rank(found, query: query, wishlist: wishlist).filter { owned($0) == nil }
    }

    nonisolated static func rank(_ found: [BandcampAPI.StoreResult], query: String,
                                 wishlist: [BandcampAPI.StoreResult]) -> [BandcampAPI.StoreResult] {
        let words = query.split(separator: " ").map(String.init)
        let wishlistIDs = Set(wishlist.map(\.id))
        let wantedMatches = wishlist.filter { item in
            words.allSatisfy { "\(item.artist) \(item.title)".localizedStandardContains($0) }
        }
        let wantedIDs = Set(wantedMatches.map(\.id))
        let wantedInSearch = found.filter { wishlistIDs.contains($0.id) && !wantedIDs.contains($0.id) }
        let rest = found.filter { !wishlistIDs.contains($0.id) }
        return wantedMatches + wantedInSearch + rest
    }

    /// Minimum digital prices of store results, loaded from their release pages as they're shown.
    private(set) var prices: [Int: BandcampAPI.Price] = [:]
    @ObservationIgnored private var loadingPrices: Set<Int> = []

    func loadPrice(for result: BandcampAPI.StoreResult) async {
        guard prices[result.id] == nil, loadingPrices.insert(result.id).inserted else { return }
        defer { loadingPrices.remove(result.id) }
        if let price = try? await BandcampAPI.release(at: result.url)?.price {
            prices[result.id] = price
        }
    }

    func isWishlisted(_ result: BandcampAPI.StoreResult) -> Bool {
        wishlist.contains { $0.id == result.id }
    }

    func owned(_ result: BandcampAPI.StoreResult) -> BandcampItem? {
        items.first { Self.matches($0, result) }
    }

    nonisolated static func matches(_ item: BandcampItem, _ result: BandcampAPI.StoreResult) -> Bool {
        if let id = item.itemId, id == result.id { return true }
        guard let url = item.itemURL else { return false }
        return normalized(url) == normalized(result.url)
    }

    nonisolated private static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: "http://", with: "https://")
    }

    /// Keeps checking the newest purchases for a while after a release page is opened, and
    /// downloads the release into the library as soon as Bandcamp adds it to the collection.
    func watchForPurchase(of result: BandcampAPI.StoreResult) {
        guard isSignedIn, owned(result) == nil, purchaseWatches[result.id] == nil else { return }
        awaitingPurchase.insert(result.id)
        purchaseWatches[result.id] = Task {
            defer {
                awaitingPurchase.remove(result.id)
                purchaseWatches[result.id] = nil
            }
            // About 15 minutes: enough for checkout, PayPal and Bandcamp's own processing.
            for _ in 0..<90 {
                if await checkForPurchase(of: result) || Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Looks for the release among the newest purchases now; starts its download if found.
    @discardableResult
    func checkForPurchase(of result: BandcampAPI.StoreResult) async -> Bool {
        guard let identity else { return false }
        if fanId == nil { fanId = try? await BandcampAPI.fan(identity: identity).id }
        guard let fanId,
              let recent = try? await BandcampAPI.recentPurchases(fanId: fanId, identity: identity),
              let item = recent.first(where: { Self.matches($0, result) })
        else { return false }
        Log.debug("bandcamp: purchase of \(item.title) arrived")
        if !items.contains(where: { $0.id == item.id }) {
            items.insert(item, at: 0)
            saveCache()
        }
        download(item)
        return true
    }

    func search(_ query: String) -> [BandcampItem] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { $0.matches(words) }
    }

    // MARK: - Downloads

    func download(for item: BandcampItem) -> BandcampDownload? {
        downloads.first { $0.item.id == item.id }
    }

    func download(_ item: BandcampItem) {
        if let existing = download(for: item), existing.state.isActive || existing.state == .completed { return }
        downloads.removeAll { $0.item.id == item.id }
        let download = BandcampDownload(item: item)
        downloads.insert(download, at: 0)
        start(download)
    }

    func retry(_ download: BandcampDownload) {
        guard !download.state.isActive else { return }
        download.retryAt = nil
        start(download)
    }

    /// Marks a download failed and tries it again by itself after a growing wait (a dropped
    /// connection, Bandcamp briefly unavailable), up to four times.
    private func fail(_ download: BandcampDownload, _ reason: String) {
        download.state = .failed(reason)
        guard download.retries < 4, let delay = RetryPolicy.delay(after: download.retries + 1, reason: reason) else {
            download.retryAt = nil
            return
        }
        download.retries += 1
        let at = Date.now.addingTimeInterval(Double(delay.components.seconds))
        download.retryAt = at
        Task {
            try? await Task.sleep(for: delay)
            guard case .failed = download.state, download.retryAt == at, downloads.contains(where: { $0 === download }) else { return }
            download.retryAt = nil
            Log.debug("bandcamp: retrying \(download.item.title) (try \(download.retries + 1))")
            start(download)
        }
    }

    func remove(_ download: BandcampDownload) {
        download.task?.cancel()
        downloads.removeAll { $0 === download }
        updateBackgroundWork()
    }

    private func start(_ download: BandcampDownload) {
        download.state = .preparing
        download.progress = 0
        updateBackgroundWork()
        download.task = Task {
            defer { updateBackgroundWork() }
            do {
                guard let identity else { throw BandcampError.notSignedIn }
                let link = try await BandcampAPI.downloadLink(for: download.item, identity: identity)
                let ready = try await BandcampAPI.waitUntilReady(link, identity: identity)
                download.state = .downloading
                let file = try await Self.fetch(ready, identity: identity) { fraction in
                    download.progress = fraction
                }
                download.state = .importing
                try await importArchiveOrFile(file, for: download.item)
                if let id = download.item.itemId, let paths = replacements[id] {
                    await replaceFiles?(download.item, paths)
                    replacements[id] = nil
                }
                download.state = .completed
            } catch is CancellationError {
                download.state = .failed("Cancelled")
            } catch {
                Log.debug("bandcamp download failed: \(error)")
                fail(download, error.localizedDescription)
            }
        }
    }

    /// Albums arrive as a zip; single tracks as one audio file. Tags are checked against the
    /// release page before the files are filed under Artist/Album as "01 Title.flac".
    func importArchiveOrFile(_ file: URL, for item: BandcampItem) async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        var audio = [file]
        let extracted = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: extracted) }

        if file.pathExtension.lowercased() == "zip" {
            try await Task.detached {
                try FileManager.default.unzipItem(at: file, to: extracted)
            }.value
            audio = (FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { AudioFormats.playable.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !audio.isEmpty else { throw BandcampError.unexpected("The download had no playable files") }
        }

        // The page is a best-effort check; a failed fetch just means the tags are used as they are.
        var release: BandcampAPI.ReleaseInfo?
        if let page = item.itemURL {
            release = try? await BandcampAPI.release(at: page)
        }

        let files = audio
        let placements = await Task.detached { [release] in
            Self.correctTags(of: files, item: item, release: release)
        }.value
        for placement in placements {
            try await importFile?(placement.url, placement.folders, placement.name)
        }
    }

    struct Placement: Sendable {
        let url: URL
        let folders: [String]
        let name: String
    }

    /// Fills in or corrects artists from the release page, records the page address in the file,
    /// writes changes into FLAC files, and works out where each file belongs.
    nonisolated static func correctTags(of files: [URL], item: BandcampItem, release: BandcampAPI.ReleaseInfo?) -> [Placement] {
        let pageOwner = item.artist
        let isPageOwner: (String?) -> Bool = { name in
            guard let name, !name.isEmpty else { return true }
            return name.caseInsensitiveCompare(pageOwner) == .orderedSame
        }
        // Only trust the page's artist when it names someone other than the page owner.
        let creditedArtist = release?.artist.flatMap { isPageOwner($0) ? nil : $0 }

        return files.map { url in
            let ext = url.pathExtension.lowercased()
            let tags = ext == "flac" ? (try? FLACTags.read(url)) ?? FLACTags.Tags() : FLACTags.Tags()
            let album = tags.album ?? (item.isTrack ? "" : item.title)
            let fromName = titleFromFileName(url, pageName: pageOwner, album: album)
            let title = tags.title ?? fromName.title
            // A standalone single has no number on Bandcamp; it's track 1 of its release.
            let isSingle = item.isTrack && album.isEmpty && files.count == 1
            let number = tags.trackNumber ?? fromName.number ?? (isSingle ? 1 : nil)
            var artist = tags.artist ?? pageOwner
            var albumArtist = tags.albumArtist ?? ""
            var changes: [String: String] = [:]

            if let number, let trackArtist = release?.trackArtists[number], trackArtist != artist {
                artist = trackArtist
                changes["ARTIST"] = trackArtist
            } else if let creditedArtist, isPageOwner(artist) {
                artist = creditedArtist
                changes["ARTIST"] = creditedArtist
            }
            if let creditedArtist, isPageOwner(albumArtist) {
                albumArtist = creditedArtist
            } else if albumArtist.isEmpty {
                albumArtist = release?.trackArtists.isEmpty == false ? (release?.artist ?? artist) : artist
            }
            if albumArtist != tags.albumArtist { changes["ALBUMARTIST"] = albumArtist }
            // The page's publisher is the label, unless it's the artist releasing their own music.
            if tags.label == nil, let label = release?.label, label.caseInsensitiveCompare(albumArtist) != .orderedSame {
                changes["LABEL"] = label
                changes["ORGANIZATION"] = label
            }
            if tags.trackNumber == nil, let number { changes["TRACKNUMBER"] = String(number) }
            if tags.year == nil, let year = release?.year { changes["DATE"] = String(year) }
            if tags.url == nil, let page = item.itemURL { changes["URL"] = page.absoluteString }

            if !changes.isEmpty, ext == "flac" {
                do {
                    try FLACTags.update(url, setting: changes)
                } catch {
                    Log.debug("couldn't update tags in \(url.lastPathComponent): \(error)")
                }
            }
            let fileName = BandcampClient.fileName(title: title, number: number, ext: ext)
            return Placement(url: url, folders: [albumArtist, album.isEmpty ? "Singles" : album], name: fileName)
        }
    }

    /// "01 Soul.flac"
    nonisolated static func fileName(title: String, number: Int?, ext: String) -> String {
        let prefix = number.map { String(format: "%02d ", $0) } ?? ""
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(prefix)\(safe).\(ext)"
    }

    /// Bandcamp names files "Page - Album - 01 Title.flac"; used only when a file has no tags.
    nonisolated static func titleFromFileName(_ url: URL, pageName: String, album: String) -> (title: String, number: Int?) {
        var name = url.deletingPathExtension().lastPathComponent
        for prefix in ["\(pageName) - \(album) - ", "\(pageName) - "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        let (number, title) = PathMetadata.splitTrackNumber(name)
        return (title, number)
    }

    /// Downloads to a temporary file named as the server suggests (so .zip vs .flac is known).
    nonisolated static func fetch(
        _ url: URL, identity: String, progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let reporter = ProgressReporter(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(
            for: BandcampAPI.request(url, identity: identity), delegate: reporter
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BandcampError.unexpected("Bandcamp returned HTTP \(http.statusCode)")
        }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let destination = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func updateBackgroundWork() {
        let busy = downloads.contains(where: \.state.isActive)
        if busy, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Bandcamp downloads") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundWork() }
            }
        } else if !busy {
            endBackgroundWork()
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @MainActor (Double) -> Void
    private var lastReport = Date.distantPast

    init(progress: @escaping @MainActor (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.3 else { return }
        lastReport = Date()
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Which Bandcamp purchases are already in the library. Imports record the release page in each
/// file, which survives any tag fixes; for older files, a release matches when its title holds an
/// album (or, for a single, a song) and its title or seller names that album's artist, which
/// covers labels selling "Artist - Album".
struct OwnedReleases {
    private let sources: Set<String>
    private let releases: [(artist: String, title: String)]

    init(tracks: [Track]) {
        sources = Set(tracks.compactMap { $0.sourceURL.isEmpty ? nil : Self.normalized($0.sourceURL) })
        var releases: [(String, String)] = []
        for track in tracks {
            for artist in Set([track.albumKey.artist, track.artist]) {
                if !track.album.isEmpty { releases.append((Self.fold(artist), Self.fold(track.album))) }
                releases.append((Self.fold(artist), Self.fold(track.title)))
            }
        }
        self.releases = releases.filter { $0.0.count >= 2 && $0.1.count >= 3 }
    }

    func contains(_ item: BandcampItem) -> Bool {
        if let url = item.itemURL, sources.contains(Self.normalized(url.absoluteString)) { return true }
        let title = Self.fold(item.title)
        let everything = Self.fold("\(item.artist) \(item.title)")
        return releases.contains { title.contains($0.title) && everything.contains($0.artist) }
    }

    static func normalized(_ url: String) -> String {
        var text = url.lowercased().replacingOccurrences(of: "http://", with: "https://")
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
