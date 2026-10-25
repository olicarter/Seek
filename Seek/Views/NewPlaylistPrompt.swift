import SwiftData
import SwiftUI

/// Context menus close as soon as an item is picked, so "New Playlist…" hands its song to
/// this shared prompt, which a long-lived view presents as a name alert.
@MainActor
@Observable
final class NewPlaylistPrompt {
    var isPresented = false
    var name = ""
    /// The song to put in the new playlist: its library path (perhaps reserved for one still
    /// downloading) and its title.
    private(set) var song: (path: String, title: String)?

    func ask(adding track: Track) {
        ask(adding: track.path, title: track.title)
    }

    func ask(adding path: String, title: String) {
        song = (path, title)
        name = ""
        isPresented = true
    }

    fileprivate func finish() {
        song = nil
        name = ""
    }
}

private struct NewPlaylistAlert: ViewModifier {
    @Environment(NewPlaylistPrompt.self) private var prompt
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        @Bindable var prompt = prompt
        content.alert("New Playlist", isPresented: $prompt.isPresented) {
            TextField("Name", text: $prompt.name)
            Button("Cancel", role: .cancel) { prompt.finish() }
            Button("Create") {
                let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let playlist = Playlist(name: name.isEmpty ? "Untitled Playlist" : name)
                if let song = prompt.song { playlist.trackPaths = [song.path] }
                context.insert(playlist)
                prompt.finish()
            }
        } message: {
            if let song = prompt.song {
                Text("“\(song.title)” will be added to it.")
            }
        }
    }
}

extension View {
    func newPlaylistPrompt() -> some View {
        modifier(NewPlaylistAlert())
    }
}
