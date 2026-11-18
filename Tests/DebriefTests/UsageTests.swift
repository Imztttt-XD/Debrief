import Foundation
import Testing
@testable import Debrief

@Suite("Token usage")
struct UsageTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    @Test func parsesOpenAIStyleWithReasoningAndCache() {
        let u = TokenUsage.parse(["prompt_tokens": 1200, "completion_tokens": 800, "total_tokens": 2000,
                                  "completion_tokens_details": ["reasoning_tokens": 500], "prompt_cache_hit_tokens": 300])
        #expect(u == TokenUsage(input: 1200, output: 800, reasoning: 500, cached: 300))
        let openAI = TokenUsage.parse(["prompt_tokens": 10, "completion_tokens": 5, "prompt_tokens_details": ["cached_tokens": 4]])
        #expect(openAI?.cached == 4)
    }

    @Test func parsesDashScopeASR() {
        let u = TokenUsage.parse(["input_tokens": 90, "output_tokens": 12, "seconds": 7])
        #expect(u == TokenUsage(input: 90, output: 12, audioSeconds: 7))
    }

    @Test func fallsBackToTotalAndIgnoresEmpty() {
        #expect(TokenUsage.parse(["total_tokens": 42])?.total == 42)
        #expect(TokenUsage.parse(nil) == nil)
        #expect(TokenUsage.parse(NSNull()) == nil)
        #expect(TokenUsage.parse(["prompt_tokens": 0, "completion_tokens": 0]) == nil)
    }

    @Test func summarizesAPeriod() {
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
        func e(_ day: String, _ fn: AIFunction, _ model: String, _ input: Int, _ output: Int, reasoning: Int = 0) -> UsageEntry {
            UsageEntry(day: day, function: fn.rawValue, provider: "DeepSeek", model: model, requests: 1,
                       input: input, output: output, reasoning: reasoning)
        }
        let entries = [
            e("2026-11-18", .review, "deepseek-v4-pro", 5000, 3000, reasoning: 2000),
            e("2026-11-18", .mockInterview, "deepseek-flash", 800, 200),
            e("2026-11-16", .review, "deepseek-v4-pro", 1000, 1000),
            e("2026-11-01", .review, "deepseek-v4-pro", 9999, 1),     // outside 7 days
        ]
        let week = UsageSummary.make(entries, period: .week, now: now, calendar: utc)
        #expect(week.total.total == 11_000 && week.total.requests == 3 && week.total.reasoning == 2000)
        #expect(week.byModel.map(\.model) == ["deepseek-v4-pro", "deepseek-flash"])
        #expect(week.byModel[0].total == 10_000)
        #expect(week.byDay.count == 7)                                       // every day, gaps as zero
        #expect(week.byDay.map(\.day).first == "2026-11-12" && week.byDay.last?.day == "2026-11-18")
        #expect(week.byDay.first { $0.day == "2026-11-17" }?.total == 0)
        #expect(week.byDay.first { $0.day == "2026-11-16" }?.total == 2000)
        #expect(week.rows.map(\.function) == [AIFunction.review.rawValue, AIFunction.mockInterview.rawValue])

        let today = UsageSummary.make(entries, period: .today, now: now, calendar: utc)
        #expect(today.total.total == 9000 && today.byDay.count == 1)
        let all = UsageSummary.make(entries, period: .all, now: now, calendar: utc)
        #expect(all.total.total == 21_000 && all.byDay.first?.day == "2026-11-01" && all.byDay.count == 18)
    }

    @Test func entriesAccumulate() {
        var e = UsageEntry(day: "2026-11-18", function: "review", provider: "p", model: "m")
        e.add(TokenUsage(input: 10, output: 5, reasoning: 2))
        e.add(TokenUsage(input: 1, output: 1, audioSeconds: 3))
        #expect(e.requests == 2 && e.total == 17 && e.reasoning == 2 && e.audioSeconds == 3)
    }
}
