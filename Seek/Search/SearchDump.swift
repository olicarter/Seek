import Foundation

/// A developer tool: launched with `-SeekSearchDump "<query>"`, Seek runs that search on
/// Soulseek (with whatever account it's signed in to) and fetches the artist's catalogue,
/// writes both to a JSON file, prints where, and quits. The saved results can be replayed in
/// tests, so search grouping can be checked against real folders. Nothing else starts.
struct SearchDump: Codable {
    var query: String
    var date: Date
    var folders: [RemoteFolder]
    var catalog: [CatalogRelease]

    static let queryKey = "SeekSearchDump"
    static let secondsKey = "SeekSearchDumpSeconds"

    static var requestedQuery: String? { UserDefaults.standard.string(forKey: queryKey) }

    @MainActor
    static func run(_ query: String, client: SoulseekClient) async {
        let seconds = max(UserDefaults.standard.integer(forKey: secondsKey), 5)
        let effectiveSeconds = UserDefaults.standard.object(forKey: secondsKey) == nil ? 20 : seconds
        print("[dump] searching Soulseek for “\(query)” for \(effectiveSeconds)s")
        async let catalog = ArtistCatalog.releases(for: query)
        // Whether a login is saved, never what it is.
        print("[dump] saved login: \(Credentials.load() != nil ? "yes" : "no")")
        await client.connectIfNeeded()
        print("[dump] status: \(client.status)")
        guard let folders = await client.quietSearch(query, for: .seconds(effectiveSeconds)) else {
            print("[dump] Soulseek isn't available (not signed in, or couldn't connect)")
            return
        }
        let dump = SearchDump(query: query, date: .now, folders: folders, catalog: await catalog)
        let directory = URL.applicationSupportDirectory.appending(path: "search-dumps", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ReleaseText.fold(query).replacingOccurrences(of: " ", with: "-")
        let url = directory.appending(path: "search-\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(dump).write(to: url)
            print("[dump] \(folders.count) folders, \(dump.catalog.count) catalogue releases → \(url.path)")
        } catch {
            print("[dump] couldn't write: \(error)")
        }
    }
}
