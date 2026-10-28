import SwiftUI

extension View {
    /// Says when an album wasn't added because a song wasn't in any copy. On the root view, and
    /// on sheets that can add albums, since an alert can't show from beneath a sheet.
    func albumAddFailureAlert() -> some View { modifier(AlbumAddFailureAlert()) }
}

private struct AlbumAddFailureAlert: ViewModifier {
    @Environment(AlbumAdder.self) private var adder

    func body(content: Content) -> some View {
        content.alert(
            "Songs Missing",
            isPresented: Binding(get: { adder.failure != nil }, set: { if !$0 { adder.failure = nil } })
        ) {
            Button("OK") {}
        } message: {
            if let failure = adder.failure {
                Text("Not all \(failure.songs) songs of “\(failure.album.title)” can be downloaded from Soulseek right now, so nothing was added.")
            }
        }
    }
}
