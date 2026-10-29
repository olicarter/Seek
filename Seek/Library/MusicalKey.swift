import Foundation

/// A song's key: one of 24, kept as its Camelot code ("8A" is A minor, "8B" C major). DJs mix
/// by it: keys next to each other on the wheel (one number either way, or A to B at the same
/// number) sound right together.
struct MusicalKey: Hashable, Codable, Sendable {
    /// 1–12, round the wheel.
    let number: Int
    let isMinor: Bool

    init?(number: Int, isMinor: Bool) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.isMinor = isMinor
    }

    /// From a pitch class (0 = C … 11 = B) and mode: how the analysis finds it.
    init(pitchClass: Int, isMinor: Bool) {
        let pitch = ((pitchClass % 12) + 12) % 12
        // Round the wheel in fifths: C major is 8B, A minor 8A.
        let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        self.number = isMinor ? minorNumbers[pitch] : majorNumbers[pitch]
        self.isMinor = isMinor
    }

    /// "8A", "08A", "Am", "A minor", "Amin", "F#m", "G♭", "Bbmaj", as tags write them.
    init?(_ text: String) {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if let match = raw.firstMatch(of: /^0?([1-9]|1[0-2])\s*([AaBb])$/), let number = Int(match.1) {
            self.init(number: number, isMinor: match.2.lowercased() == "a")
            return
        }
        guard let match = raw.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            .firstMatch(of: /^([A-Ga-g])\s*([#b]?)\s*(m|min|minor|maj|major|M)?$/) else { return nil }
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitch = letters[Character(match.1.uppercased())] else { return nil }
        if match.2 == "#" { pitch += 1 } else if match.2 == "b" { pitch -= 1 }
        let mode = match.3.map(String.init)
        self.init(pitchClass: pitch, isMinor: mode == "m" || mode == "min" || mode == "minor")
    }

    var camelot: String { "\(number)\(isMinor ? "A" : "B")" }

    /// The pitch class of the key's tonic (0 = C).
    var pitchClass: Int {
        let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        return (isMinor ? minorNumbers : majorNumbers).firstIndex(of: number) ?? 0
    }

    /// "A minor", "F♯ major": sharps for the sharp keys, flats for the flat ones, as written.
    var musical: String {
        let sharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let flats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        // Flat keys: F, B♭, E♭, A♭, D♭ major and their relative minors.
        let flatMajors: Set<Int> = [5, 10, 3, 8, 1]
        let relativeMajor = isMinor ? (pitchClass + 3) % 12 : pitchClass
        let names = flatMajors.contains(relativeMajor) ? flats : sharps
        return "\(names[pitchClass]) \(isMinor ? "minor" : "major")"
    }

    /// As the person chose to see keys (Settings).
    func shown(as notation: Notation) -> String {
        switch notation {
        case .camelot: camelot
        case .musical: musical
        }
    }

    enum Notation: String, CaseIterable, Identifiable {
        case camelot, musical
        var id: String { rawValue }
        static let defaultsKey = "keyNotation"
        var name: String {
            switch self {
            case .camelot: "Camelot (8A)"
            case .musical: "Musical (A minor)"
            }
        }
    }
}
