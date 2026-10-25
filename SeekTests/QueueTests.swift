import Testing
@testable import Seek

struct QueueTests {
    @Test func longOrStillQueuesAreLookedPast() {
        #expect(SoulseekClient.shouldLookElsewhere(place: 18709, queuedFor: 0))
        #expect(SoulseekClient.shouldLookElsewhere(place: 50, queuedFor: 0))
        #expect(!SoulseekClient.shouldLookElsewhere(place: 3, queuedFor: 60))
        #expect(!SoulseekClient.shouldLookElsewhere(place: nil, queuedFor: 120))
        #expect(SoulseekClient.shouldLookElsewhere(place: nil, queuedFor: 300))
        #expect(SoulseekClient.shouldLookElsewhere(place: 2, queuedFor: 600))
    }
}
