import Foundation
import Testing
@testable import Seek

/// Album pages and Now Playing take their colour from the artwork, as Apple Music's do.
struct ArtworkColorTests {
    private func pixels(_ parts: [((r: Double, g: Double, b: Double), Int)]) -> [(r: Double, g: Double, b: Double)] {
        parts.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    private func hue(_ c: ArtworkColor.RGB) -> Double {
        let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
        guard high > low else { return 0 }
        var h: Double
        if high == c.red { h = (c.green - c.blue) / (high - low) }
        else if high == c.green { h = 2 + (c.blue - c.red) / (high - low) }
        else { h = 4 + (c.red - c.green) / (high - low) }
        return (h < 0 ? h + 6 : h) * 60
    }

    @Test func lightArtworkGivesADarkPageOfItsColour() throws {
        // Mostly light blue, as the Resident Advisor cover.
        let color = try #require(ArtworkColor.color(of: pixels([((0.45, 0.78, 0.97), 400), ((0, 0, 0), 100), ((1, 1, 1), 76)])))
        #expect((180...225).contains(hue(color)))
        #expect(max(color.red, color.green, color.blue) <= 0.45)
    }

    @Test func colourWinsOverAWhiteBorder() throws {
        // Marcelus: a purple ring on black, inside a white border.
        let color = try #require(ArtworkColor.color(of: pixels([((1, 1, 1), 250), ((0, 0, 0), 230), ((0.55, 0.15, 0.95), 96)])))
        #expect((260...290).contains(hue(color)))
    }

    @Test func blackAndGreyArtworkGivesANearBlackPage() throws {
        let color = try #require(ArtworkColor.color(of: pixels([((0.05, 0.05, 0.05), 400), ((0.6, 0.6, 0.6), 150), ((0.9, 0.7, 0.65), 6)])))
        #expect(max(color.red, color.green, color.blue) < 0.12)
    }

    @Test func hexRoundTrips() {
        let color = ArtworkColor.RGB(red: 0.2, green: 0.4, blue: 0.6)
        #expect(ArtworkColor.RGB(hex: color.hex).map { abs($0.blue - 0.6) < 0.01 } == true)
    }
}
