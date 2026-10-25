import SwiftUI

/// Edits an album's tags. "Fix with Claude" fills the fields with suggestions to review;
/// nothing is written until Save. Changes are saved into FLAC files so they sync and show up
/// in other apps (rekordbox, Finder) too.
struct EditAlbumView: View {
    let tracks: [Track]
    var onSave: (AlbumKey) -> Void = { _ in }

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var albumArtist = ""
    @State private var album = ""
    @State private var label = ""
    @State private var year = ""
    @State private var rows: [Row] = []
    @State private var suggestion: ClaudeTagFixer.Suggestion?
    @State private var isFixing = false
    @State private var isSaving = false
    @State private var error: String?
    /// The cover Claude found, downloaded for review.
    @State private var suggestedCover: FLACTags.Picture?
    @State private var isLoadingCover = false
    @State private var useSuggestedCover = false

    struct Row: Identifiable {
        let id: PersistentIdentifierWrapper
        var number: String
        var title: String
        var artist: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        fixWithClaude()
                    } label: {
                        if isFixing {
                            Label { Text("Asking Claude… this can take a minute") } icon: { ProgressView() }
                        } else {
                            Label("Fix with Claude", systemImage: "sparkles")
                        }
                    }
                    .disabled(isFixing || isSaving)
                } footer: {
                    Text(suggestion == nil
                        ? "Claude checks the tags against the release page and the web, then fills in suggestions for you to review."
                        : "Claude's changes are marked below. Review them, then tap Save.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if isLoadingCover || suggestedCover != nil {
                    artworkSection
                }

                Section("Album") {
                    field("Album Artist", text: $albumArtist, original: tracks.first?.albumKey.artist, labelled: true)
                    if let previous = tracks.first?.albumKey.artist, previous != albumArtist, !albumArtist.isEmpty,
                       rows.contains(where: { $0.artist == previous }) {
                        Button("Use “\(albumArtist)” as the artist for all tracks", systemImage: "arrow.down.circle") {
                            for index in rows.indices where rows[index].artist == previous {
                                rows[index].artist = albumArtist
                            }
                        }
                    }
                    field("Album", text: $album, original: tracks.first?.album, labelled: true)
                    field("Label", text: $label, original: originalLabel, labelled: true)
                    // A label uploading under its own name: the old "artist" is really the label.
                    if label.isEmpty, let previous = tracks.first?.albumKey.artist, previous != albumArtist, !albumArtist.isEmpty {
                        Button("Use “\(previous)” as the label", systemImage: "building.columns") { label = previous }
                    }
                    field("Year", text: $year, original: originalYear, keyboard: .numberPad, labelled: true)
                }

                Section {
                    ForEach($rows) { $row in
                        let track = tracks.first { PersistentIdentifierWrapper($0) == row.id }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                TextField("#", text: $row.number)
                                    .keyboardType(.numberPad)
                                    .frame(width: 32)
                                    .foregroundStyle(.secondary)
                                field("Title", text: $row.title, original: track?.title)
                            }
                            field("Artist", text: $row.artist, original: track?.artist)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 40)
                        }
                    }
                } header: {
                    Text("Tracks")
                } footer: {
                    if tracks.contains(where: { $0.fileExtension != "flac" }) {
                        Text("Only FLAC files can be updated. Changes to other formats are kept in Seek's library only.")
                    }
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .bold()
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var originalLabel: String {
        tracks.first(where: { !$0.label.isEmpty })?.label ?? ""
    }

    private var originalYear: String? {
        tracks.map(\.year).max().map { $0 > 0 ? String($0) : "" }
    }

    /// A text field that shows the previous value underneath when it has been changed.
    private func field(_ label: String, text: Binding<String>, original: String?,
                       keyboard: UIKeyboardType = .default, labelled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if labelled {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(label, text: text)
                    .keyboardType(keyboard)
                if labelled, !text.wrappedValue.isEmpty {
                    Button("Clear \(label)", systemImage: "xmark.circle.fill") { text.wrappedValue = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            if let original, !original.isEmpty, original != text.wrappedValue {
                Text("Was “\(original)”")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func load() {
        guard rows.isEmpty else { return }
        albumArtist = tracks.first?.albumKey.artist ?? ""
        album = tracks.first?.album ?? ""
        label = originalLabel
        year = originalYear ?? ""
        rows = tracks.map { track in
            Row(id: PersistentIdentifierWrapper(track),
                number: track.trackNumber > 0 ? String(track.trackNumber) : "",
                title: track.title,
                artist: track.artist)
        }
    }

    private func fixWithClaude() {
        guard let apiKey = ClaudeTagFixer.apiKey else {
            error = ClaudeTagFixer.FixError.noKey.localizedDescription
            return
        }
        isFixing = true
        error = nil
        Task {
            defer { isFixing = false }
            var source: (url: String?, comment: String?) = (nil, nil)
            if let first = tracks.first { source = await library.sourceInfo(for: first) }
            let request = ClaudeTagFixer.Album(
                albumArtist: albumArtist,
                album: album,
                label: label,
                year: Int(year),
                tracks: rows.enumerated().map { index, row in
                    ClaudeTagFixer.Track(title: row.title, artist: row.artist, trackNumber: Int(row.number) ?? 0,
                                         fileName: (tracks[index].path as NSString).lastPathComponent)
                },
                sourceURL: source.url,
                comment: source.comment,
                hasArtwork: currentArtwork != nil
            )
            do {
                let result = try await ClaudeTagFixer.suggest(for: request, apiKey: apiKey)
                albumArtist = result.albumArtist
                album = result.album
                label = result.label
                if let resultYear = result.year { year = String(resultYear) }
                for index in rows.indices {
                    rows[index].title = result.tracks[index].title
                    rows[index].artist = result.tracks[index].artist
                    if let number = result.tracks[index].number { rows[index].number = String(number) }
                }
                suggestion = result
                if let url = result.artworkURL { await loadCover(from: url) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var currentArtwork: Data? {
        tracks.first(where: { $0.artwork != nil })?.artwork
    }

    private func loadCover(from url: URL) async {
        isLoadingCover = true
        defer { isLoadingCover = false }
        do {
            let cover = try await FLACTags.Picture.download(from: url)
            // Skip a cover that's the same as the one already there.
            guard cover.data != currentArtwork else { return }
            suggestedCover = cover
            // Fill a missing cover by default; replacing one is the user's call.
            useSuggestedCover = currentArtwork == nil
        } catch {
            Log.debug("claude: couldn't download artwork from \(url): \(error)")
        }
    }

    @ViewBuilder private var artworkSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                cover(currentArtwork, caption: "Current")
                    .opacity(useSuggestedCover ? 0.45 : 1)
                if let suggestedCover {
                    cover(suggestedCover.data, caption: "\(suggestedCover.width) × \(suggestedCover.height)")
                        .opacity(useSuggestedCover ? 1 : 0.45)
                } else {
                    ProgressView().frame(width: 120, height: 120)
                }
            }
            .animation(.easeInOut, value: useSuggestedCover)
            if suggestedCover != nil {
                Toggle("Use Claude's Artwork", isOn: $useSuggestedCover)
            }
        } header: {
            Text("Artwork")
        } footer: {
            if suggestedCover != nil {
                Text("Saved into the files, so it shows on your other devices and in other apps too.")
            }
        }
    }

    private func cover(_ data: Data?, caption: String) -> some View {
        VStack(spacing: 6) {
            ArtworkView(data: data, cornerRadius: 8)
                .frame(width: 120, height: 120)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        isSaving = true
        error = nil
        let edits = zip(tracks, rows).map { track, row in
            LibraryStore.TagEdit(
                track: track,
                title: row.title.trimmingCharacters(in: .whitespaces),
                artist: row.artist.trimmingCharacters(in: .whitespaces),
                albumArtist: albumArtist.trimmingCharacters(in: .whitespaces),
                album: album.trimmingCharacters(in: .whitespaces),
                label: label.trimmingCharacters(in: .whitespaces),
                trackNumber: Int(row.number) ?? 0,
                year: Int(year) ?? 0
            )
        }
        Task {
            defer { isSaving = false }
            do {
                try await library.save(edits, frontCover: useSuggestedCover ? suggestedCover : nil)
                if let first = tracks.first { onSave(first.albumKey) }
                dismiss()
            } catch {
                self.error = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}

/// Lets rows refer to tracks without holding the model object in the row itself.
struct PersistentIdentifierWrapper: Hashable {
    let id: AnyHashable

    init(_ track: Track) {
        id = track.persistentModelID
    }
}

extension FLACTags.Picture {
    enum DownloadError: LocalizedError {
        case notAnImage

        var errorDescription: String? { "That link isn't an image" }
    }

    /// Fetches a cover image, keeping JPEGs and PNGs as they are unless they're very large, which
    /// are scaled to 1400 pixels so they don't bloat every file on the album.
    static func download(from url: URL) async throws -> FLACTags.Picture {
        var request = URLRequest(url: url)
        request.setValue(BandcampAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, data.count < 30_000_000 else {
            throw DownloadError.notAnImage
        }
        return try await Task.detached {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else { throw DownloadError.notAnImage }
            let width = cgImage.width, height = cgImage.height
            let isJPEG = data.starts(with: [0xFF, 0xD8])
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            if (isJPEG || isPNG), data.count <= 4_000_000, max(width, height) <= 2000 {
                return FLACTags.Picture(data: data, mimeType: isJPEG ? "image/jpeg" : "image/png", width: width, height: height)
            }
            let scale = min(1, 1400 / CGFloat(max(width, height)))
            let size = CGSize(width: (CGFloat(width) * scale).rounded(), height: (CGFloat(height) * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.9) else { throw DownloadError.notAnImage }
            return FLACTags.Picture(data: jpeg, mimeType: "image/jpeg", width: Int(size.width), height: Int(size.height))
        }.value
    }
}
