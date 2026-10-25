import Foundation
import Testing
@testable import Seek

struct PaypalOnlyTests {
    private func page(cardable: [Bool]) -> String {
        let packages = cardable.map { "{&quot;title&quot;:&quot;Tape&quot;,&quot;is_cardable&quot;:\($0)}" }.joined(separator: ",")
        return """
            <html><div data-band-currency="SEK"></div>
            <div data-tralbum="{&quot;artist&quot;:&quot;KEMI&quot;,&quot;current&quot;:{&quot;minimum_price&quot;:30.0},&quot;packages&quot;:[\(packages)],&quot;trackinfo&quot;:[]}"></div></html>
            """
    }

    @Test func sellerWithoutCardsIsPaypalOnly() throws {
        let price = try #require(BandcampAPI.parseRelease(page(cardable: [false, false]))?.price)
        #expect(price.amount == 30 && price.currency == "SEK")
        #expect(price.paypalOnly)
    }

    @Test func cardsOrNoSignAreNot() throws {
        #expect(BandcampAPI.parseRelease(page(cardable: [true, false]))?.price?.paypalOnly == false)
        // Digital-only releases don't say; Seek tries the card and stops if it meets PayPal.
        #expect(BandcampAPI.parseRelease(page(cardable: []))?.price?.paypalOnly == false)
    }
}
