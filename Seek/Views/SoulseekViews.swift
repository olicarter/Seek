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
        Text(folder.quality)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(folder.isLossless ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: .capsule)
            .fixedSize()
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
                                Text(file.quality)
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
                if !transfersShown.isEmpty {
                    Section("Soulseek") {
                        ForEach(transfersShown) { transfer in
                            TransferRow(transfer: transfer)
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
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transfer.file.name).lineLimit(1)
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
                    if let saved = client.savedUsername {
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
                    Text(client.savedUsername == nil
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
                        ? "When a release is on Soulseek in several qualities, Seek picks a 16-bit lossless copy over hi-res (24-bit or above 48 kHz), which can be several times bigger. Hi-res is still used when it's the only lossless copy. Bandcamp FLAC downloads come at whatever quality the artist uploaded."
                        : "Seek picks the best-sounding copy, including 24-bit and high sample rates.")
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
        switch client.status {
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

    var body: some View {
        Section {
            Toggle("Serve Seek on the Web", isOn: Binding(get: { web.state == .running }, set: { web.setEnabled($0) }))
            if case .failed(let reason) = web.state {
                Text(reason).foregroundStyle(.red)
            }
            if web.state == .running {
                LabeledContent("On This Mac", value: "localhost:\(WebServer.port)")
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
            While Seek is open on this Mac, 4n.studio/seek/web uses it: this Mac's library, Soulseek and Bandcamp, from any \
            browser. Tailscale Funnel makes it reachable from anywhere; browsers sign in with a passkey (the first one is \
            added from a paired browser).
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

