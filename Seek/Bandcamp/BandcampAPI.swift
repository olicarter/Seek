import Foundation

/// A purchase in the fan's Bandcamp collection.
struct BandcampItem: Codable, Identifiable, Hashable, Sendable {
    /// "a" album, "t" track, "p" package (physical with digital download).
    let saleItemType: String
    let saleItemId: Int
    let title: String
    let artist: String
    let isTrack: Bool
    let artId: Int?
    let redownloadURL: URL?
    /// The release page, e.g. https://label.bandcamp.com/album/name.
    var itemURL: URL? = nil
    /// The album or track id, shared with store search results.
    var itemId: Int? = nil

    var id: String { "\(saleItemType)\(saleItemId)" }

    var artworkURL: URL? {
        artId.flatMap(BandcampAPI.artworkURL)
    }

    func matches(_ words: [String]) -> Bool {
        let haystack = "\(artist) \(title)"
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }
}

enum BandcampError: LocalizedError {
    case notSignedIn
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to Bandcamp"
        case .unexpected(let detail): detail
        }
    }
}

/// Bandcamp's website API. It isn't public or documented, so every parser here is
/// deliberately forgiving and fails with a readable message rather than crashing.
enum BandcampAPI {
    /// Album art from its id, zero-padded to ten digits ("a0992531817_2.jpg"). Ids go past the
    /// 32-bit range, which a "%d" format would garble, so the padding is done by hand.
    /// Fixes art addresses saved by older versions, where ids past 32 bits wrapped negative
    /// ("a-1270344389_2.jpg" for 3024622907). The real id is the wrapped one plus 2³².
    static func repaired(_ url: URL?) -> URL? {
        guard let url, let match = url.absoluteString.firstMatch(of: /\/img\/a(-\d+)_(\d+)\.jpg$/),
              let wrapped = Int(match.output.1) else { return url }
        return artworkURL(wrapped + (1 << 32))
    }

    static func artworkURL(_ artId: Int) -> URL? {
        let digits = String(artId)
        return URL(string: "https://f4.bcbits.com/img/a\(String(repeating: "0", count: max(0, 10 - digits.count)))\(digits)_2.jpg")
    }

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static func request(_ url: URL, identity: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity=\(identity)", forHTTPHeaderField: "Cookie")
        return request
    }

    // MARK: - Fan

    struct Fan: Sendable {
        let id: Int
        let username: String?
    }

    static func fan(identity: String) async throws -> Fan {
        let url = URL(string: "https://bandcamp.com/api/fan/2/collection_summary")!
        let (data, _) = try await URLSession.shared.data(for: request(url, identity: identity))
        return try parseFan(data)
    }

    static func parseFan(_ data: Data) throws -> Fan {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BandcampError.unexpected("Unexpected reply from Bandcamp")
        }
        if json["error"] as? Bool == true {
            throw BandcampError.unexpected(json["error_message"] as? String ?? "Bandcamp returned an error")
        }
        guard let id = json["fan_id"] as? Int else { throw BandcampError.notSignedIn }
        let summary = json["collection_summary"] as? [String: Any]
        return Fan(id: id, username: summary?["username"] as? String)
    }

    // MARK: - Collection

    struct CollectionPage: Sendable {
        let items: [BandcampItem]
        let lastToken: String?
        let moreAvailable: Bool
    }

    /// The newest purchases only (the collection is ordered by purchase date), for spotting a new buy.
    static func recentPurchases(fanId: Int, identity: String) async throws -> [BandcampItem] {
        try await collectionPage(fanId: fanId, olderThan: "\(Int(Date().timeIntervalSince1970) + 86400)::a::", identity: identity).items
    }

    static func collection(fanId: Int, identity: String) async throws -> [BandcampItem] {
        var items: [BandcampItem] = []
        var token = "\(Int(Date().timeIntervalSince1970))::a::"
        while true {
            let page = try await collectionPage(fanId: fanId, olderThan: token, identity: identity)
            items += page.items
            guard page.moreAvailable, let next = page.lastToken, next != token else { break }
            token = next
        }
        return items
    }

    private static func collectionPage(fanId: Int, olderThan token: String, identity: String) async throws -> CollectionPage {
        var request = request(URL(string: "https://bandcamp.com/api/fancollection/1/collection_items")!, identity: identity)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fan_id": fanId, "older_than_token": token, "count": 100,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseCollectionPage(data)
    }

    static func parseCollectionPage(_ data: Data) throws -> CollectionPage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BandcampError.unexpected("Unexpected collection reply from Bandcamp")
        }
        if json["error"] as? Bool == true {
            throw BandcampError.unexpected(json["error_message"] as? String ?? "Bandcamp returned an error")
        }
        let redownloads = json["redownload_urls"] as? [String: String] ?? [:]
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { raw -> BandcampItem? in
            guard let type = raw["sale_item_type"] as? String, let saleId = raw["sale_item_id"] as? Int else { return nil }
            return BandcampItem(
                saleItemType: type,
                saleItemId: saleId,
                title: raw["item_title"] as? String ?? raw["album_title"] as? String ?? "Untitled",
                artist: raw["band_name"] as? String ?? "Unknown Artist",
                isTrack: raw["item_type"] as? String == "track",
                artId: raw["item_art_id"] as? Int,
                redownloadURL: redownloads["\(type)\(saleId)"].flatMap(URL.init(string:)),
                itemURL: (raw["item_url"] as? String).flatMap(URL.init(string:)),
                itemId: raw["item_id"] as? Int ?? raw["tralbum_id"] as? Int
            )
        }
        return CollectionPage(
            items: items,
            lastToken: json["last_token"] as? String,
            moreAvailable: json["more_available"] as? Bool ?? false
        )
    }

    // MARK: - Store search

    /// A release for sale on Bandcamp.
    struct StoreResult: Identifiable, Hashable, Codable, Sendable {
        let id: Int
        let isTrack: Bool
        let title: String
        let artist: String
        let url: URL
        var artworkURL: URL?
    }

    /// Bandcamp's own site search (albums and tracks).
    static func searchStore(_ query: String) async throws -> [StoreResult] {
        var request = URLRequest(url: URL(string: "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic")!)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "search_text": query, "search_filter": "", "full_page": false, "fan_id": NSNull(),
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return parseStoreResults(data)
    }

    /// Everything on the fan's wishlist, as store results.
    static func wishlist(fanId: Int, identity: String) async throws -> [StoreResult] {
        var results: [StoreResult] = []
        var token = "\(Int(Date().timeIntervalSince1970) + 86400)::a::"
        while true {
            var request = request(URL(string: "https://bandcamp.com/api/fancollection/1/wishlist_items")!, identity: identity)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "fan_id": fanId, "older_than_token": token, "count": 100,
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            let page = parseWishlistPage(data)
            results += page.items
            guard page.moreAvailable, let next = page.lastToken, next != token else { break }
            token = next
        }
        return results
    }

    static func parseWishlistPage(_ data: Data) -> (items: [StoreResult], lastToken: String?, moreAvailable: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil, false) }
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { raw -> StoreResult? in
            guard let id = raw["item_id"] as? Int ?? raw["tralbum_id"] as? Int,
                  let url = (raw["item_url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return StoreResult(
                id: id,
                isTrack: raw["item_type"] as? String == "track",
                title: raw["item_title"] as? String ?? raw["album_title"] as? String ?? "Untitled",
                artist: raw["band_name"] as? String ?? "",
                url: url,
                artworkURL: (raw["item_art_id"] as? Int).flatMap(artworkURL)
            )
        }
        return (items, json["last_token"] as? String, json["more_available"] as? Bool ?? false)
    }

    static func parseStoreResults(_ data: Data) -> [StoreResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = (json["auto"] as? [String: Any])?["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap { raw in
            guard let type = raw["type"] as? String, type == "a" || type == "t",
                  let id = raw["id"] as? Int,
                  let title = raw["name"] as? String,
                  let url = (raw["item_url_path"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return StoreResult(
                id: id,
                isTrack: type == "t",
                title: title,
                artist: raw["band_name"] as? String ?? "",
                url: url,
                // The "img" field lacks the "a" prefix album art needs; build it from the art id instead.
                artworkURL: (raw["art_id"] as? Int).flatMap(artworkURL)
            )
        }
    }

    // MARK: - Release pages

    /// What the release page says about who made it.
    struct ReleaseInfo: Sendable, Equatable {
        /// The credited artist ("by …"). Labels uploading without crediting the artist show themselves here.
        var artist: String?
        var label: String?
        var year: Int?
        /// "02 Jul 2021 00:00:00 GMT" on the page.
        var released: Date?
        /// Per-track artists on compilations, keyed by track number.
        var trackArtists: [Int: String] = [:]
        /// The lowest price for the digital release; nil when it isn't for sale.
        var price: Price?
        /// The tracklist, in order.
        var tracks: [ReferenceTrack] = []
    }

    struct Price: Sendable, Equatable, Hashable {
        var amount: Double
        /// ISO code, e.g. USD.
        var currency: String
        /// The seller takes PayPal only, not cards, so Seek can't buy it in one tap with a saved card.
        var paypalOnly = false

        var formatted: String {
            amount.formatted(.currency(code: currency))
        }

        /// For tight spaces: "$7" rather than "US$7,00".
        var shortFormatted: String {
            let whole = amount.rounded() == amount
            return amount.formatted(.currency(code: currency).presentation(.narrow)
                .precision(.fractionLength(whole ? 0 : 2)))
        }
    }

    /// Release pages are read as a desktop browser sees them: the phone version leaves out the
    /// artist, year and whether the seller takes cards.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func release(at url: URL) async throws -> ReleaseInfo? {
        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return parseRelease(String(decoding: data, as: UTF8.self))
    }

    static func parseRelease(_ html: String) -> ReleaseInfo? {
        var info = ReleaseInfo()
        var found = false
        if let start = html.range(of: "<script type=\"application/ld+json\">"),
           let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
           let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any] {
            found = true
            info.artist = (json["byArtist"] as? [String: Any])?["name"] as? String
            info.label = (json["publisher"] as? [String: Any])?["name"] as? String
            if let date = json["datePublished"] as? String {
                info.year = MetadataReader.leadingNumber(String(date.split(separator: " ").first { $0.count == 4 } ?? ""))
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.dateFormat = "dd MMM yyyy HH:mm:ss zzz"
                info.released = format.date(from: date)
            }
        }
        if let start = html.range(of: "data-tralbum=\""),
           let end = html[start.upperBound...].firstIndex(of: "\""),
           let json = try? JSONSerialization.jsonObject(with: Data(unescapeHTML(String(html[start.upperBound..<end])).utf8)) as? [String: Any] {
            found = true
            info.artist = info.artist ?? json["artist"] as? String
            if let current = json["current"] as? [String: Any],
               let minimum = (current["minimum_price"] as? NSNumber)?.doubleValue,
               let currency = sellerCurrency(in: html) {
                info.price = Price(amount: minimum, currency: currency)
            }
            // Whether the seller takes cards shows on its physical items: none taking cards means
            // PayPal only (true of the digital release too). Digital-only releases don't say.
            let cardable = (json["packages"] as? [[String: Any]] ?? []).compactMap { $0["is_cardable"] as? Bool }
            if !cardable.isEmpty, !cardable.contains(true) { info.price?.paypalOnly = true }
            for (index, track) in (json["trackinfo"] as? [[String: Any]] ?? []).enumerated() {
                if let number = track["track_num"] as? Int, let artist = track["artist"] as? String, !artist.isEmpty {
                    info.trackArtists[number] = artist
                }
                if let listed = track["title"] as? String {
                    let (title, artist) = songTitle(listed, artist: track["artist"] as? String)
                    info.tracks.append(ReferenceTrack(
                        number: track["track_num"] as? Int ?? index + 1, disc: 1, title: title,
                        duration: (track["duration"] as? NSNumber)?.doubleValue,
                        streamURL: ((track["file"] as? [String: Any])?["mp3-128"] as? String).flatMap(URL.init(string:)),
                        artist: artist
                    ))
                }
            }
        }
        return found ? info : nil
    }

    /// A song's name without its artist, which split releases put in front ("MIKE & SURF GANG -
    /// The Fall", with MIKE & SURF GANG as its artist): the name, and the artist when it was there.
    static func songTitle(_ listed: String, artist: String?) -> (title: String, artist: String?) {
        guard let artist, !artist.isEmpty else { return (listed, nil) }
        for separator in [" - ", " – ", " — "] {
            let prefix = artist + separator
            if listed.count > prefix.count, listed.lowercased().hasPrefix(prefix.lowercased()) {
                return (String(listed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), artist)
            }
        }
        return (listed, nil)
    }

    /// The release's selling currency: on the band data, or failing that on the sole seller in the
    /// page data. (The cart's currency is the visitor's, not the price's.)
    static func sellerCurrency(in html: String) -> String? {
        if let currency = attributeJSON("data-band", in: html)?["currency"] as? String { return currency }
        // The desktop page: data-band-currency="SEK".
        if let start = html.range(of: "data-band-currency=\""),
           let end = html[start.upperBound...].firstIndex(of: "\""), html.distance(from: start.upperBound, to: end) == 3 {
            return String(html[start.upperBound..<end])
        }
        let sellers = (attributeJSON("data-pagedata-blob", in: html)?["item_sellers"] as? [String: Any])?
            .values.compactMap { ($0 as? [String: Any])?["currency"] as? String } ?? []
        return Set(sellers).count == 1 ? sellers.first : nil
    }

    /// The JSON object in an HTML attribute such as `data-band="{…}"`.
    static func attributeJSON(_ name: String, in html: String) -> [String: Any]? {
        guard let start = html.range(of: "\(name)=\""),
              let end = html[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(unescapeHTML(String(html[start.upperBound..<end])).utf8)) as? [String: Any]
    }

    // MARK: - Downloads

    /// Preferred formats, best first. All play on iOS.
    static let formats = ["flac", "alac", "aiff-lossless", "wav", "mp3-320", "mp3-v0", "aac-hi"]

    /// Reads the purchase's download page and returns the link for the best available format.
    static func downloadLink(for item: BandcampItem, identity: String) async throws -> URL {
        guard let page = item.redownloadURL else {
            throw BandcampError.unexpected("Bandcamp didn't provide a download for this item")
        }
        let (data, _) = try await URLSession.shared.data(for: request(page, identity: identity))
        guard let html = String(data: data, encoding: .utf8) else {
            throw BandcampError.unexpected("Couldn't read the download page")
        }
        return try parseDownloadLink(html)
    }

    static func parseDownloadLink(_ html: String) throws -> URL {
        guard let blob = pageDataBlob(html),
              let json = try? JSONSerialization.jsonObject(with: Data(blob.utf8))
        else { throw BandcampError.unexpected("Couldn't read the download page") }
        guard let downloads = findDownloads(in: json) else {
            throw BandcampError.unexpected("No downloads on the download page")
        }
        for format in formats {
            if let entry = downloads[format] as? [String: Any],
               let string = entry["url"] as? String,
               let url = URL(string: string.hasPrefix("//") ? "https:" + string : string) {
                return url
            }
        }
        throw BandcampError.unexpected("No playable format offered")
    }

    /// The JSON in `<div id="pagedata" data-blob="…">`, HTML-unescaped.
    static func pageDataBlob(_ html: String) -> String? {
        guard let marker = html.range(of: "id=\"pagedata\"") else { return nil }
        let rest = html[marker.upperBound...]
        guard let start = rest.range(of: "data-blob=\"") else { return nil }
        let body = rest[start.upperBound...]
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return unescapeHTML(String(body[..<end]))
    }

    static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Finds the first `"downloads": {format: {url: …}}` object anywhere in the page data.
    private static func findDownloads(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let downloads = dictionary["downloads"] as? [String: Any],
               downloads.values.contains(where: { ($0 as? [String: Any])?["url"] != nil }) {
                return downloads
            }
            for child in dictionary.values {
                if let found = findDownloads(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findDownloads(in: child) { return found }
            }
        }
        return nil
    }

    /// Bandcamp builds the archive on demand. Polls its status endpoint until the file is ready
    /// and returns the URL to fetch, falling back to the original link.
    static func waitUntilReady(_ link: URL, identity: String) async throws -> URL {
        guard var components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.path.contains("/download/")
        else { return link }
        components.path = components.path.replacingOccurrences(of: "/download/", with: "/statdownload/")
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: ".vrs", value: "1")]
        guard let statURL = components.url else { return link }

        for _ in 0..<40 {
            try Task.checkCancellation()
            if let (data, _) = try? await URLSession.shared.data(for: request(statURL, identity: identity)),
               let status = parseStatus(data) {
                if let ready = status.downloadURL { return ready }
                if status.result == "ok" { return link }
            }
            try await Task.sleep(for: .seconds(3))
        }
        return link
    }

    struct Status {
        let result: String?
        let downloadURL: URL?
    }

    /// The status reply is JSONP-ish: `if ( window.Downloads ) { Downloads.statResult ( {...} ) };`
    static func parseStatus(_ data: Data) -> Status? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "{\"")?.lowerBound
        else { return nil }
        // The wrapper adds its own braces, so try each closing brace from the end until the JSON parses.
        let json = text.indices.reversed()
            .lazy
            .filter { $0 > start && text[$0] == "}" }
            .compactMap { try? JSONSerialization.jsonObject(with: Data(text[start...$0].utf8)) as? [String: Any] }
            .first
        guard let json else { return nil }
        let url = (json["download_url"] as? String).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
        return Status(result: json["result"] as? String, downloadURL: url)
    }
}

extension BandcampAPI {
    /// Bandcamp's 350-pixel thumbnails as 700-pixel art for the header.
    static func largeArtwork(_ url: URL) -> URL {
        URL(string: url.absoluteString.replacingOccurrences(of: "_2.jpg", with: "_16.jpg")) ?? url
    }

    /// The `identity` cookie Bandcamp sets once signed in, from its login page's cookies, once it
    /// has moved on from /login (it sets one for logged-out visitors too).
    static func identity(after url: URL?, in cookies: [HTTPCookie]) -> String? {
        guard url?.path.hasPrefix("/login") == false,
              let identity = cookies.first(where: { $0.name == "identity" && $0.domain.hasSuffix("bandcamp.com") }),
              !identity.value.isEmpty else { return nil }
        return identity.value
    }
}
