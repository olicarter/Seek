import Foundation

/// Whether two users' copies of an album are the very same files, so songs from each can be
/// mixed into one album. Files go round Soulseek by being shared on, so most popular rips are
/// held by many users, though often re-tagged on the way. Tags add about the same number of
/// bytes to every song, so the same audio differs in size by the same amount on each song; a
/// different master or encode differs by a different amount on each.
nonisolated enum SameRip {
    /// How far the per-song size difference may wander: tags of different lengths per song.
    static let tagSlack: Int64 = 64 * 1024

    /// The other copy's file for each song (keyed by the song's id) when both copies are the
    /// same rip, otherwise nil.
    static func match(_ songs: [RemoteFile], in other: [RemoteFile]) -> [String: RemoteFile]? {
        let mine = audio(songs), theirs = audio(other)
        guard mine.count >= 2, mine.count == theirs.count else { return nil }
        var result: [String: RemoteFile] = [:]
        var deltas: [Int64] = []
        for (a, b) in zip(mine, theirs) {
            guard a.fileExtension == b.fileExtension, a.duration == b.duration,
                  a.sampleRate == b.sampleRate, a.bitDepth == b.bitDepth, a.isVBR == b.isVBR else { return nil }
            // A constant-bitrate MP3's size follows from its length alone, whatever the source,
            // so only byte-identical files count.
            if !a.isLossless && !a.isVBR {
                guard a.bitrate == b.bitrate, a.size == b.size else { return nil }
            }
            deltas.append(Int64(a.size) - Int64(b.size))
            result[a.id] = b
        }
        guard let low = deltas.min(), let high = deltas.max(), high - low <= tagSlack else { return nil }
        return result
    }

    /// Songs in album order: numbered names sort the same way in both copies.
    private static func audio(_ files: [RemoteFile]) -> [RemoteFile] {
        files.filter { AudioFormats.playable.contains($0.fileExtension) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
