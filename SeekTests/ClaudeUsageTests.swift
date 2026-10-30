import Foundation
import Testing
@testable import Seek

/// Each answer's usage is counted, and its cost estimated from the model's price.
@MainActor
struct ClaudeUsageTests {
    @Test func costsFollowTheModelsPrice() {
        let haiku = ClaudeUsage.Tally(requests: 1, inputTokens: 1_000_000, outputTokens: 100_000)
        #expect(abs(ClaudeUsage.Price.cost(haiku, model: "claude-haiku-5-5") - 1.5) < 0.0001)
        let sonnet = ClaudeUsage.Tally(requests: 1, inputTokens: 10_000, outputTokens: 2_000, webSearches: 3)
        // 0.03 + 0.03 + 0.03
        #expect(abs(ClaudeUsage.Price.cost(sonnet, model: "claude-sonnet-5-5") - 0.09) < 0.0001)
        let cached = ClaudeUsage.Tally(requests: 1, cacheWriteTokens: 1_000_000, cacheReadTokens: 1_000_000)
        #expect(abs(ClaudeUsage.Price.cost(cached, model: "claude-haiku-5-5") - 1.35) < 0.0001)
    }

    @Test func answersAreCountedByPurpose() {
        let usage = ClaudeUsage.shared
        let before = usage.total(month: ClaudeUsage.month()).requests
        usage.record(["model": "claude-haiku-5-5",
                      "usage": ["input_tokens": 1200, "output_tokens": 300, "server_tool_use": ["web_search_requests": 1]]],
                     purpose: "Similar albums")
        #expect(usage.total(month: ClaudeUsage.month()).requests == before + 1)
        #expect(usage.byPurpose().contains { $0.purpose == "Similar albums" && $0.tally.webSearches >= 1 })
        #expect(ClaudeUsageSection.tokens(1500) == "2k")
        #expect(ClaudeUsageSection.cost(0.004) == "< $0.01")
    }
}
