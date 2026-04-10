import Foundation

/// Aggregated usage statistics computed from a slice of ``UsageRecord``s.
///
/// One struct handles every scope — per-task, per-day, per-provider, all-time, etc.
/// The `scopeLabel` describes what was summarized; filtering is the caller's job.
/// All cost fields are in USD, computed at summary time via a pricing closure so
/// corrections retroactively apply.
public struct UsageSummary: Sendable, Equatable {
    /// Human label for what this summary represents ("Today", "Task: Foo", etc.).
    public let scopeLabel: String

    /// Number of ``UsageRecord``s aggregated.
    public let callCount: Int
    /// Subset whose cost could not be computed (no pricing data for that provider/model).
    public let unpricedCallCount: Int

    /// Time range of the aggregated records. Nil when `callCount == 0`.
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?

    // MARK: - Token totals

    /// Total input tokens (raw — includes cache read + cache write for Anthropic).
    public let totalInputTokens: Int
    /// Uncached input tokens: `totalInputTokens - cacheReadTokens - cacheWriteTokens`.
    /// This is the portion billed at the full input rate.
    public let totalUncachedInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCacheReadTokens: Int
    public let totalCacheWriteTokens: Int

    // MARK: - Cost breakdown (USD)

    public let inputCostUSD: Double
    public let outputCostUSD: Double
    public let cacheReadCostUSD: Double
    public let cacheWriteCostUSD: Double

    /// Sum of all cost categories.
    public var totalCostUSD: Double {
        inputCostUSD + outputCostUSD + cacheReadCostUSD + cacheWriteCostUSD
    }

    // MARK: - Latency

    /// Cumulative LLM API call latency in milliseconds.
    public let totalLatencyMs: Int

    // MARK: - Tool stats

    /// Total number of tool calls across all turns.
    public let totalToolCalls: Int
    /// Total wall-clock milliseconds spent executing tools.
    public let totalToolExecutionMs: Int
    /// Total characters across all tool-call result strings.
    public let totalToolResultChars: Int

    // MARK: - Character stats

    /// Total characters in LLM text responses.
    public let totalOutputChars: Int
    /// Total characters in tool-call argument strings.
    public let totalToolArgumentChars: Int

    // MARK: - Extremes (per-call max)

    public let maxInputTokens: Int
    public let maxOutputTokens: Int
    public let maxLatencyMs: Int
    public let maxCostUSD: Double

    // MARK: - Derived averages

    public var avgInputTokens: Double { callCount > 0 ? Double(totalInputTokens) / Double(callCount) : 0 }
    public var avgOutputTokens: Double { callCount > 0 ? Double(totalOutputTokens) / Double(callCount) : 0 }
    public var avgLatencyMs: Double { callCount > 0 ? Double(totalLatencyMs) / Double(callCount) : 0 }
    public var avgCostUSD: Double { callCount > 0 ? totalCostUSD / Double(callCount) : 0 }

    /// Fraction of input served from cache: `cacheReadTokens / totalInputTokens`.
    ///
    /// The denominator is the full input token count (uncached + cache read + cache write)
    /// so that cache writes — which are a distinct billing category for Anthropic but
    /// semantically a cache miss for everyone else — count against the hit rate. Returns
    /// 0 when there's no input at all.
    public var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(totalCacheReadTokens) / Double(totalInputTokens)
    }

    /// Empty summary with no data.
    public static func empty(scopeLabel: String = "") -> UsageSummary {
        UsageSummary(
            scopeLabel: scopeLabel, callCount: 0, unpricedCallCount: 0,
            firstTimestamp: nil, lastTimestamp: nil,
            totalInputTokens: 0, totalUncachedInputTokens: 0, totalOutputTokens: 0,
            totalCacheReadTokens: 0, totalCacheWriteTokens: 0,
            inputCostUSD: 0, outputCostUSD: 0, cacheReadCostUSD: 0, cacheWriteCostUSD: 0,
            totalLatencyMs: 0,
            totalToolCalls: 0, totalToolExecutionMs: 0, totalToolResultChars: 0,
            totalOutputChars: 0, totalToolArgumentChars: 0,
            maxInputTokens: 0, maxOutputTokens: 0, maxLatencyMs: 0, maxCostUSD: 0
        )
    }
}
