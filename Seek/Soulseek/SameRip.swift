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
    /// same rip, otherwise nil. The songs can be some of an album (the ones being added), and
    /// the other copy can hold more (a bonus track, the rest of the album): each song is paired
    /// with its counterpart by name, then track number.
    static func match(_ songs: [RemoteFile], in other: [RemoteFile]) -> [String: RemoteFile]? {
        let mine = audio(songs), theirs = audio(other)
        guard mine.count >= 2, theirs.count >= mine.count else { return nil }
        // The whole album both sides: in album order. Otherwise each song by name and number.
        let pairs = mine.count == theirs.count
            ? Dictionary(uniqueKeysWithValues: zip(mine, theirs).map { ($0.id, $1) })
            : paired(mine, in: theirs)
        guard pairs.count == mine.count else { return nil }
        var deltas: [Int64] = []
        for a in mine {
            guard let b = pairs[a.id], a.fileExtension == b.fileExtension, a.duration == b.duration,
                  a.sampleRate == b.sampleRate, a.bitDepth == b.bitDepth, a.isVBR == b.isVBR else { return nil }
            // A constant-bitrate MP3's size follows from its length alone, whatever the source,
            // so only byte-identical files count.
            if !a.isLossless && !a.isVBR {
                guard a.bitrate == b.bitrate, a.size == b.size else { return nil }
            }
            deltas.append(Int64(a.size) - Int64(b.size))
        }
        guard let low = deltas.min(), let high = deltas.max(), high - low <= tagSlack else { return nil }
        return pairs
    }

    /// Each song's counterpart, each file used once: same name and number, then same number,
    /// then same name. Names are read once per file (reading them is the slow part).
    private static func paired(_ mine: [RemoteFile], in theirs: [RemoteFile]) -> [String: RemoteFile] {
        func key(_ file: RemoteFile) -> (name: String, number: Int?) {
            (ReleaseText.fold(ReleaseDetailView.trackName(file.name)), MissingTracks.leadingNumber(file.name))
        }
        let candidates = theirs.map { (file: $0, key: key($0)) }
        var used = Set<String>()
        var result: [String: RemoteFile] = [:]
        for song in mine {
            let wanted = key(song)
            let tests: [((name: String, number: Int?)) -> Bool] = [
                { $0.name == wanted.name && $0.number == wanted.number },
                { wanted.number != nil && $0.number == wanted.number },
                { $0.name == wanted.name },
            ]
            for test in tests {
                if let match = candidates.first(where: { !used.contains($0.file.id) && test($0.key) }) {
                    used.insert(match.file.id)
                    result[song.id] = match.file
                    break
                }
            }
        }
        return result
    }

    /// Songs in album order: numbered names sort the same way in both copies.
    private static func audio(_ files: [RemoteFile]) -> [RemoteFile] {
        files.filter { AudioFormats.playable.contains($0.fileExtension) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
