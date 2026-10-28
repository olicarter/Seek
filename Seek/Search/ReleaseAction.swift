import Foundation

/// The best way to get a release right now, in order: it's in the library; it's a Bandcamp
/// purchase (downloading or ready to download); it's free on Soulseek; it's for sale on Bandcamp.
@MainActor
struct ReleaseAction {
    enum Kind {
        case inLibrary(AlbumKey)
        case downloadingBandcamp(Double?)
        case downloadBandcamp(BandcampItem)
        case downloadingSoulseek(Double?)
        case downloadSoulseek(RemoteFolder)
        case buy(BandcampAPI.StoreResult, BandcampAPI.Price?)
        case none
    }

    let kind: Kind

    init(release: SearchRelease, inLibrary: AlbumKey?, client: SoulseekClient, bandcamp: BandcampClient) {
        if let inLibrary {
            kind = .inLibrary(inLibrary)
        } else if let item = release.owned, let download = bandcamp.download(for: item), download.state.isActive {
            kind = .downloadingBandcamp(download.ringProgress)
        } else if let item = release.owned, item.redownloadURL != nil {
            // Already bought: the official files, at no cost, beat any Soulseek copy.
            kind = .downloadBandcamp(item)
        } else if let progress = Self.soulseekProgress(release, client: client) {
            kind = .downloadingSoulseek(progress)
        } else if let folder = release.bestFolder {
            kind = .downloadSoulseek(folder)
        } else if let store = release.store {
            kind = .buy(store, bandcamp.prices[store.id])
        } else {
            kind = .none
        }
    }

    /// Progress of any of the release's Soulseek folders being downloaded.
    static func soulseekProgress(_ release: SearchRelease, client: SoulseekClient) -> Double? {
        // Any song from the release's copies: adding it takes each from its copy's full folder,
        // not only the files the search listed.
        let folderIDs = Set(release.folders.map(\.id))
        guard !release.fileIDs.isEmpty || !folderIDs.isEmpty else { return nil }
        // Finished songs still count, so the ring doesn't fall back each time one completes.
        // Finished ones only while their songs are still in the library: once all are in, the
        // album still reads as added (a check) rather than offering to add it again.
        let transfers = client.transfers.filter {
            (client.isOnItsWay($0) || client.isDone($0)) && !$0.forStreaming
                && (release.fileIDs.contains($0.file.id) || folderIDs.contains("\($0.file.username)\u{0}\($0.file.folder)"))
        }
        guard !transfers.isEmpty else { return nil }
        let size = transfers.reduce(0) { $0 + $1.size }
        return size > 0 ? Double(transfers.reduce(0) { $0 + $1.bytesReceived }) / Double(size) : 0
    }
}
