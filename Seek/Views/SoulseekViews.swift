import SwiftData
import SwiftUI

struct RemoteFolderRow: View {
    let folder: RemoteFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.name).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let parent = folder.parentName {
                Text(parent).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            // Details and username share a line when they fit; otherwise the username wraps below.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    details
                    Spacer(minLength: 8)
                    peer.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) { details }
                    peer
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var details: some View {
        SoundQualityBadge(quality: folder.soundQuality, detail: folder.qualityDetail)
        Text("\(folder.files.count) files").fixedSize()
        Text(ByteCountFormatter.string(fromByteCount: Int64(folder.totalSize), countStyle: .file)).fixedSize()
    }

    private var peer: some View {
        HStack(spacing: 4) {
            Image(systemName: folder.hasFreeSlot ? "circle.fill" : "clock")
                .foregroundStyle(folder.hasFreeSlot ? .green : .orange)
                .font(.caption2)
            Text(folder.username)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct RemoteFolderView: View {
    let found: RemoteFolder
    @Environment(SoulseekClient.self) private var client
    @State private var isLoading = false

    init(folder: RemoteFolder) {
        found = folder
    }

    /// Every file once fetched; a search only lists the ones that matched.
    private var folder: RemoteFolder { client.complete(found) }

    var body: some View {
        List {
            Section {
                LabeledContent("User", value: folder.username)
                LabeledContent("Speed", value: ByteCountFormatter.string(fromByteCount: Int64(folder.averageSpeed), countStyle: .file) + "/s")
                LabeledContent("Queue", value: folder.hasFreeSlot ? "Free slot" : "\(folder.queueLength) waiting")
            }
            Section {
                ForEach(folder.files) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(2)
                            HStack {
                                SoundQualityBadge(quality: file.soundQuality, detail: file.qualityDetail)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                if let duration = file.duration {
                                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        if client.isDownloading(file) {
                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        } else {
                            Button("Add to Library", systemImage: "plus.circle") { client.download(file) }
                                .labelStyle(.iconOnly)
                                .font(.title2)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(folder.path.replacingOccurrences(of: "\\", with: " / "))
                    if isLoading { ProgressView().controlSize(.small) }
                }
            }
        }
        .task {
            guard client.folderContents[found.id] == nil else { return }
            isLoading = true
            _ = try? await client.contents(of: found)
            isLoading = false
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add All to Library", systemImage: "plus.circle.fill") { client.download(folder) }
        }
    }
}

struct DownloadsView: View {
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp

    // Only what's still going or needs attention: finished ones leave the list by themselves.
    private var bandcampShown: [BandcampDownload] { bandcamp.downloads.filter { $0.state != .completed } }
    private var transfersShown: [Transfer] {
        client.transfers.filter { !$0.forStreaming && $0.state != .completed && $0.state != .cancelled }
    }
    private var uploadsShown: [Upload] { client.uploads.filter { $0.state != .completed } }

    var body: some View {
        NavigationStack {
            List {
                if !bandcampShown.isEmpty {
                    Section("Bandcamp") {
                        ForEach(bandcampShown) { download in
                            BandcampDownloadRow(download: download)
                                .swipeActions {
                                    Button(download.state.isActive ? "Cancel" : "Remove",
                                           systemImage: download.state.isActive ? "xmark" : "trash",
                                           role: .destructive) { bandcamp.remove(download) }
                                    if case .failed = download.state {
                                        Button("Retry", systemImage: "arrow.clockwise") { bandcamp.retry(download) }
                                            .tint(.blue)
                                    }
                                }
                        }
                    }
                }
                // One section per release, as an album page lists it, rather than every song in one list.
                ForEach(ReleaseDownloads.group(transfersShown)) { release in
                    Section {
                        ForEach(release.transfers) { transfer in
                            NavigationLink(value: TransferSourcesKey(id: transfer.id)) {
                                TransferRow(transfer: transfer, numbered: true)
                            }
                                .swipeActions {
                                    if transfer.state.isActive {
                                        Button("Cancel", systemImage: "xmark", role: .destructive) { client.cancel(transfer) }
                                    } else {
                                        Button("Remove", systemImage: "trash", role: .destructive) { client.remove(transfer) }
                                        if transfer.state != .completed {
                                            Button("Retry", systemImage: "arrow.clockwise") { client.retry(transfer) }
                                                .tint(.blue)
                                        }
                                    }
                                }
                        }
                    } header: {
                        ReleaseDownloadsHeader(release: release, onMac: client.usingMac)
                    }
                }
                if !uploadsShown.isEmpty {
                    Section("Uploads") {
                        ForEach(uploadsShown) { upload in
                            UploadRow(upload: upload)
                        }
                    }
                }
            }
            .overlay {
                if transfersShown.isEmpty && bandcampShown.isEmpty && uploadsShown.isEmpty {
                    ContentUnavailableView(
                        "Nothing Happening",
                        systemImage: "arrow.up.arrow.down.circle",
                        description: Text("Music being added from Bandcamp and Soulseek, and songs others take from your library, appear here.")
                    )
                }
            }
            .navigationTitle("Activity")
            .navigationDestination(for: TransferSourcesKey.self) { key in
                if let transfer = client.transfers.first(where: { $0.id == key.id }) {
                    TransferSourcesView(transfer: transfer)
                } else {
                    ContentUnavailableView("Finished", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

struct TransferSourcesKey: Hashable { let id: UUID }

/// Downloads of one release (the album they were added as, or the folder they came from).
struct ReleaseDownloads: Identifiable {
    let id: String
    let title: String
    let artist: String?
    var transfers: [Transfer]

    @MainActor
    static func group(_ transfers: [Transfer]) -> [ReleaseDownloads] {
        var groups: [String: ReleaseDownloads] = [:]
        var order: [String] = []
        for transfer in transfers {
            let title: String, artist: String?
            if let album = transfer.album {
                (title, artist) = (album.title, album.artist)
            } else {
                let folder = RemoteFolder(username: transfer.username, path: transfer.file.folder, files: [transfer.file],
                                          hasFreeSlot: true, averageSpeed: 0, queueLength: 0)
                let parsed = FolderParser.parse(folder)
                (title, artist) = (parsed.title, parsed.artist)
            }
            let key = "\(ReleaseText.fold(artist ?? ""))|\(ReleaseText.fold(ReleaseText.cleanTitle(title)))"
            if groups[key] == nil {
                groups[key] = ReleaseDownloads(id: key, title: title, artist: artist, transfers: [])
                order.append(key)
            }
            groups[key]?.transfers.append(transfer)
        }
        return order.compactMap { key in
            groups[key].map { group in
                var sorted = group
                sorted.transfers.sort {
                    (ReleaseText.songNumber($0.file.name) ?? 999, $0.file.name) < (ReleaseText.songNumber($1.file.name) ?? 999, $1.file.name)
                }
                return sorted
            }
        }
    }
}

/// A release's heading: its name, and where its songs stand ("14 songs · 2 downloading · 12
/// queued with 1 user").
struct ReleaseDownloadsHeader: View {
    let release: ReleaseDownloads
    let onMac: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(release.title).font(.headline).foregroundStyle(.primary).textCase(nil)
            Text(summary).font(.caption).textCase(nil)
        }
    }

    private var summary: String {
        let songs = release.transfers
        let downloading = songs.filter { $0.state == .downloading }.count
        let queued = songs.filter { if case .queued = $0.state { true } else { false } }
        let failed = songs.filter { if case .failed = $0.state { true } else { false } }.count
        let users = Set(songs.map(\.username)).count
        var parts = [release.artist, songs.count == 1 ? "1 song" : "\(songs.count) songs"].compactMap { $0 }
        if downloading > 0 { parts.append("\(downloading) downloading") }
        if !queued.isEmpty {
            let queuedUsers = Set(queued.map(\.username)).count
            parts.append("\(queued.count) queued with \(queuedUsers == 1 ? "1 user" : "\(queuedUsers) users")")
        }
        if failed > 0 { parts.append("\(failed) failed") }
        if users > 1, queued.isEmpty { parts.append("from \(users) users") }
        return parts.joined(separator: " · ") + (onMac ? " · on your Mac" : "")
    }
}

/// Every user a song could come from, and how each went: the one it's coming from now, those
/// that failed (and why), and copies not asked yet.
struct TransferSourcesView: View {
    let transfer: Transfer
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        let sources = client.sources(of: transfer) ?? SongSources(found: [transfer.username], asked: [transfer.username])
        List {
            Section {
                TransferRow(transfer: transfer)
            }
            Section {
                ForEach(sources.found.sorted { rank($0, sources) < rank($1, sources) }, id: \.self) { user in
                    HStack {
                        Text(user)
                        Spacer()
                        Text(outcome(user, sources)).foregroundStyle(color(user, sources)).multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                }
            } header: {
                Text(SongSourcesSummary.text(sources))
            } footer: {
                Text("Users found with this song: the copy it was added from, the album's other copies, and any a search for another copy turned up. Seek moves a song to another copy when its user is offline, refuses, keeps failing or has kept it queued for a while.")
            }
        }
        .navigationTitle(ReleaseText.songTitle(transfer.file.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rank(_ user: String, _ sources: SongSources) -> (Int, String) {
        if user == transfer.username { return (0, user) }
        if sources.failed[user] != nil { return (1, user) }
        return (sources.asked.contains(user) ? 2 : 3, user)
    }

    private func outcome(_ user: String, _ sources: SongSources) -> String {
        if user == transfer.username { return "Now: \(transfer.state.label)" }
        if let reason = sources.failed[user] { return reason }
        return sources.asked.contains(user) ? "Asked" : "Not asked yet"
    }

    private func color(_ user: String, _ sources: SongSources) -> Color {
        if user == transfer.username { return .primary }
        return sources.failed[user] != nil ? .red : .secondary
    }
}

/// "4 copies · asked 2 · 1 failed".
enum SongSourcesSummary {
    static func text(_ sources: SongSources) -> String {
        var parts = [sources.found.count == 1 ? "1 copy" : "\(sources.found.count) copies", "asked \(sources.asked.count)"]
        if !sources.failed.isEmpty { parts.append("\(sources.failed.count) failed") }
        if sources.untried > 0 { parts.append("\(sources.untried) not asked") }
        return parts.joined(separator: " · ")
    }
}

struct BandcampDownloadRow: View {
    let download: BandcampDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(download.item.title).lineLimit(1)
            if download.state == .downloading {
                ProgressView(value: download.progress)
            }
            HStack {
                RetryingStatus(status: download.state == .downloading ? "\(Int(download.progress * 100))%" : download.state.label,
                               retryAt: download.retryAt)
                Spacer()
                Text(download.item.artist)
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 2)
    }

    /// Red only once it's given up; while a retry is due it's just waiting.
    private var isFailure: Bool {
        if case .failed = download.state { download.retryAt == nil } else { false }
    }
}

/// A download's status, with a countdown while it waits to be tried again.
struct RetryingStatus: View {
    let status: String
    let retryAt: Date?

    var body: some View {
        if let retryAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(status) · \(RetryPolicy.countdown(to: retryAt, now: context.date))")
            }
        } else {
            Text(status)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    /// Within its release: the song's number and title rather than the file's whole name.
    var numbered = false
    @Environment(SoulseekClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if numbered {
                HStack(spacing: 8) {
                    if let number = ReleaseText.songNumber(transfer.file.name) {
                        Text(verbatim: "\(number)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(ReleaseText.songTitle(transfer.file.name)).lineLimit(1)
                }
            } else {
                Text(transfer.file.name).lineLimit(1)
            }
            if transfer.state == .downloading {
                ProgressView(value: transfer.progress)
            }
            HStack {
                RetryingStatus(status: statusText, retryAt: transfer.retryAt)
                Spacer()
                Text(transfer.username)
            }
            .font(.caption)
            .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            if let sources = client.sources(of: transfer) {
                Text(SongSourcesSummary.text(sources)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Red only once it's given up; while a retry is due it's just waiting.
    private var isFailure: Bool {
        if case .failed = transfer.state { transfer.retryAt == nil } else { false }
    }

    private var statusText: String {
        guard transfer.state == .downloading else { return transfer.state.label }
        let received = ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesReceived), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(transfer.size), countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file)
        return "\(received) of \(total) · \(speed)/s"
    }
}

struct SettingsView: View {
    @Environment(SoulseekClient.self) private var client
    @Environment(BandcampClient.self) private var bandcamp
    @State private var showingBandcampLogin = false
    @State private var claudeKey = ClaudeTagFixer.apiKey ?? ""
    @AppStorage(ClaudeTagFixer.modelDefaultsKey) private var claudeModel = ClaudeTagFixer.Model.haiku.rawValue
    @AppStorage(QualityPreference.defaultsKey) private var quality = QualityPreference.cd
    @AppStorage(StreamingQuality.defaultsKey) private var streamingQuality = StreamingQuality.library
    @Environment(StreamService.self) private var streamer
    @Environment(SharingService.self) private var sharing
    @State private var cacheCleared = false
    @Environment(LibraryStore.self) private var library
    private var tracks: [Track] { library.allTracks }
    @State private var confirmingRemoveAll = false
    @AppStorage(LibraryStore.automaticDownloadsKey) private var automaticDownloads = LibraryStore.defaultAutomaticDownloads
    @State private var username = ""
    @State private var password = ""
    @AppStorage(MusicalKey.Notation.defaultsKey) private var notation = MusicalKey.Notation.camelot
    @Environment(SongAnalysisStore.self) private var analysis
    #if targetEnvironment(macCatalyst)
    @Environment(WebServer.self) private var web: WebServer?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                if AppUpdater.shared.availableBuild != nil {
                    Section {
                        Button("Update Seek", systemImage: "arrow.down.app") { AppUpdater.shared.install() }
                    } footer: {
                        Text("A new version is on 4n.studio. Seek closes while it installs.")
                    }
                }
                Section {
                    if client.usingMac {
                        LabeledContent("Status", value: statusText)
                        if let host = client.macLink?.host { LabeledContent("Mac", value: host) }
                    } else if let saved = client.savedUsername {
                        LabeledContent("Username", value: saved)
                        LabeledContent("Status", value: statusText)
                        if client.status == .connected, let port = client.listeningPort {
                            LabeledContent("Listening Port", value: String(port))
                        }
                        if client.status != .connected {
                            Button("Connect Now") { Task { await client.connectIfNeeded() } }
                                .disabled(client.status == .connecting)
                        }
                        Button("Sign Out", role: .destructive) { client.signOut() }
                    } else {
                        if case .failed(let reason) = client.status {
                            Text(reason).foregroundStyle(.red)
                        }
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Sign In") {
                            Task {
                                await client.signIn(username: username, password: password)
                                if client.status == .connected { password = "" }
                            }
                        }
                        .disabled(username.isEmpty || password.isEmpty || client.status == .connecting)
                    }
                } header: {
                    Text("Soulseek Account")
                } footer: {
                    Text(client.usingMac
                        ? "Seek on your Mac searches and downloads for this device, so albums keep coming with Seek closed. When the Mac can't be reached, this device signs in to Soulseek itself."
                        : client.savedUsername == nil
                        ? "Signing in with a new username creates the account. Your login is saved in iCloud Keychain, so your other devices can use it too."
                        : "Seek connects only while you're using the Soulseek tab or downloading, and disconnects when you leave the app with nothing downloading. Soulseek allows one connection per account, so the device you're using takes over.")
                }

                #if targetEnvironment(macCatalyst)
                if let web {
                    WebAccessSection(web: web)
                }
                #endif

                Section {
                    if let name = bandcamp.username {
                        LabeledContent("Account", value: name)
                        LabeledContent("Purchases") {
                            if bandcamp.isRefreshing {
                                ProgressView()
                            } else {
                                Text("\(bandcamp.items.count)")
                            }
                        }
                        if let error = bandcamp.lastError {
                            Text(error).foregroundStyle(.red)
                        }
                        Button("Refresh Purchases") { Task { await bandcamp.refresh() } }
                            .disabled(bandcamp.isRefreshing)
                        Button("Sign Out", role: .destructive) { bandcamp.signOut() }
                    } else {
                        Button("Sign In to Bandcamp") { showingBandcampLogin = true }
                    }
                } header: {
                    Text("Bandcamp")
                } footer: {
                    Text("Your Bandcamp purchases appear at the top of search results and download in the best quality available. Seek keeps Bandcamp's sign-in in iCloud Keychain, never your password.")
                }

                Section {
                    SecureField("API Key", text: $claudeKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { ClaudeTagFixer.setAPIKey(claudeKey) }
                        .onChange(of: claudeKey) { _, value in ClaudeTagFixer.setAPIKey(value) }
                    Picker("Model", selection: $claudeModel) {
                        ForEach(ClaudeTagFixer.Model.allCases) { model in
                            VStack(alignment: .leading) {
                                Text(model.name)
                                Text(model.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Used by Fix with Claude in an album's Edit Info. Create a key at platform.claude.com. It's kept in iCloud Keychain; album details are sent to Anthropic only when you use the button.")
                }

                Section {
                    Picker("Keys", selection: $notation) {
                        ForEach(MusicalKey.Notation.allCases) { Text($0.name).tag($0) }
                    }
                    #if targetEnvironment(macCatalyst)
                    if analysis.analysed > 0 { LabeledContent("Worked Out", value: "\(analysis.analysed) songs") }
                    #endif
                } header: {
                    Text("Tempo and Key")
                } footer: {
                    Text("From each song's tags where they say, otherwise worked out from the music by Seek on your Mac and shared with your other devices. Camelot codes show which keys mix: one number either way, or A to B at the same number.")
                }

                Section {
                    @Bindable var sharing = sharing
                    Toggle("Share Library on Soulseek", isOn: $sharing.isEnabled)
                    if sharing.isEnabled {
                        LabeledContent("Shared", value: "\(sharing.index.fileCount) songs in \(sharing.index.folderCount) folders")
                    }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Some Soulseek users only let people who share download from them. Others can browse your library and download from it while Seek is open or playing. Songs only in iCloud are fetched for them on Wi-Fi only, and one upload runs at a time.")
                }

                Section {
                    Picker("Preferred Quality", selection: $quality) {
                        ForEach(QualityPreference.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Streaming Quality", selection: $streamingQuality) {
                        ForEach(StreamingQuality.allCases) { Text($0.name).tag($0) }
                    }
                    LabeledContent("Streamed Songs", value: ByteCountFormatter.string(fromByteCount: cacheCleared ? 0 : streamer.cacheSize, countStyle: .file))
                    Button("Clear Streamed Songs", role: .destructive) {
                        streamer.clearCache()
                        cacheCleared = true
                    }
                    .disabled(cacheCleared || streamer.cacheSize == 0)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text(quality == .cd
                        ? "Quality follows TIDAL's tiers: Max is lossless above CD quality (more than 16-bit or above 44.1 kHz), High is lossless up to 16-bit, 44.1 kHz, Low is MP3 or AAC. When a release is on Soulseek in several qualities, Seek picks High over Max, which can be several times bigger. Max is still used when it's the only lossless copy. Bandcamp FLAC downloads come at whatever quality the artist uploaded."
                        : "Quality follows TIDAL's tiers: Max is lossless above CD quality (more than 16-bit or above 44.1 kHz), High is lossless up to 16-bit, 44.1 kHz, Low is MP3 or AAC. Seek picks the best-sounding copy, Max first.")
                    + Text("\n\nSongs played from album pages without adding them are kept in a cache of up to 2 GB, oldest dropped first. Adding one to your library later reuses the cached copy. MP3 for Faster Start streams MP3s where a copy has them.")
                }

                Section {
                    LabeledContent("Location", value: library.usesICloud ? "iCloud Drive › Seek › Music" : "On this device")
                    if library.usesICloud {
                        Toggle("Automatic Downloads", isOn: $automaticDownloads)
                        LabeledContent("Downloaded", value: "\(tracks.filter(\.keepOffline).count) songs · \(ByteCountFormatter.string(fromByteCount: library.downloadedBytes, countStyle: .file))")
                        LabeledContent("On This Device", value: "\(tracks.count - library.cloudOnlyCount) songs")
                        Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                            .disabled(library.cloudOnlyCount == tracks.count)
                            .confirmationDialog(
                                "Remove all downloads from this device?",
                                isPresented: $confirmingRemoveAll,
                                titleVisibility: .visible
                            ) {
                                Button("Remove All Downloads", role: .destructive) { library.removeDownloads(tracks) }
                            } message: {
                                Text("Your music stays in iCloud and downloads again when you play it.")
                            }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text(library.usesICloud
                        ? "Adding music from Bandcamp or Soulseek puts it in iCloud, synced across your devices. Download an album, playlist or song to keep it on this device for offline listening. With Automatic Downloads on, music you add here is downloaded too; with it off, it's removed from this device once it's in iCloud. Songs that aren't downloaded play straight from iCloud. If the device runs low on space, the system may remove songs, and Seek downloads ones you chose to keep again when it can."
                        : "iCloud Drive isn't available, so music stays on this device. Sign in to iCloud to sync.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingBandcampLogin) { BandcampLoginView() }
            .onAppear {
                if username.isEmpty { username = Credentials.load()?.username ?? "" }
            }
        }
    }

    private var statusText: String {
        if client.usingMac { return "Through Seek on your Mac" }
        return switch client.status {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let reason): reason
        }
    }
}

struct UploadRow: View {
    let upload: Upload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(upload.file.name).lineLimit(1)
            HStack {
                Text("To \(upload.username)")
                Spacer()
                Text(upload.state == .sending ? "\(Int(upload.progress * 100))%" : upload.state.label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if upload.state == .sending {
                ProgressView(value: upload.progress)
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Seek on the web, served from this Mac while Seek is open: on and off, and who can get in.
private struct WebAccessSection: View {
    let web: WebServer
    @Environment(\.openURL) private var openURL
    @State private var confirmingReset = false
    @AppStorage(AppKey.addressKey) private var address = ""

    var body: some View {
        Section {
            Toggle("Serve Seek on the Web", isOn: Binding(get: { web.state == .running }, set: { web.setEnabled($0) }))
            if case .failed(let reason) = web.state {
                Text(reason).foregroundStyle(.red)
            }
            if web.state == .running {
                LabeledContent("On This Mac", value: "localhost:\(WebServer.port)")
                TextField("Public Address", text: $address, prompt: Text("https://…ts.net"))
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { AppKey.publish() }
                    .onChange(of: address) { AppKey.publish() }
                LabeledContent("Passkeys", value: web.passkeyCount == 0 ? "None yet" : "\(web.passkeyCount)")
                Button("Open Seek on the Web", systemImage: "safari") { openURL(WebServer.site) }
                if web.passkeyCount == 0 {
                    Button("Pair a Browser", systemImage: "qrcode") {
                        openURL(URL(string: "http://localhost:\(WebServer.port)/pair")!)
                    }
                } else {
                    Button("Reset Web Sign-In", systemImage: "key.slash", role: .destructive) { confirmingReset = true }
                }
            }
        } header: {
            Text("Web")
        } footer: {
            Text("""
            While Seek is open on this Mac, your iPhone and iPad use it for Soulseek (it keeps going with them closed), and \
            4n.studio/seek/web and the Apple TV use it for everything. The public address is this Mac's Tailscale Funnel \
            one: your devices find it through iCloud Keychain. Browsers sign in with a passkey.
            """)
        }
        .task { await web.refreshPasskeys() }
        .confirmationDialog("Reset web sign-in?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Remove Passkeys and Sign Out Everywhere", role: .destructive) { Task { await web.resetAccess() } }
        } message: {
            Text("Every browser is signed out and your passkeys for Seek stop working. Pair a browser again to add a new one.")
        }
    }
}
#endif

