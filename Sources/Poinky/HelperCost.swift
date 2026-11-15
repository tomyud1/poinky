import Foundation

/// A helper's cost while it works, ESTIMATED from its tokens and list prices (Claude Code's own figure,
/// `total_cost_usd`, only comes at the end of each turn). On a subscription it counts toward the plan's
/// limits, not a bill. Only for showing "about $0.12 so far": never for anything that matters.
enum HelperCost {
    /// Dollars per million tokens: input, output, cache read, cache write (5-minute).
    /// API list prices (Nov 2026). Matched by the model id's start; an unknown model gets no estimate.
    static let prices: [(prefix: String, input: Double, output: Double, cacheRead: Double, cacheWrite: Double)] = [
        ("claude-fable-5-2", 8, 40, 0.20, 10),
        ("claude-fable-5-1", 10, 50, 0.25, 12.5),
        ("claude-fable-5", 10, 50, 1.00, 12.5),
        ("claude-opus-5-5", 4, 20, 0.20, 5),
        ("claude-opus-5", 5, 25, 0.50, 6.25),
        ("claude-opus-4", 5, 25, 0.50, 6.25),
        ("claude-sonnet-5-5", 2, 10, 0.10, 2.5),
        ("claude-sonnet-5", 2, 10, 0.20, 2.5),
        ("claude-sonnet-4", 3, 15, 0.30, 3.75),
        ("claude-haiku-5-5", 0.10, 0.50, 0.01, 0.125),
        ("claude-haiku-4", 1, 5, 0.10, 1.25),
    ]

    /// One reply's tokens.
    struct Usage: Equatable {
        var model = ""
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    }

    static func price(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)? {
        let m = model.lowercased().replacingOccurrences(of: "anthropic.", with: "")
        guard let p = prices.first(where: { m.hasPrefix($0.prefix) }) else { return nil }
        return (p.input, p.output, p.cacheRead, p.cacheWrite)
    }

    /// Dollars for these replies, or nil if none of their models is in the table.
    static func estimate(_ replies: [Usage], fallbackModel: String = "") -> Double? {
        var total = 0.0, known = false
        for u in replies {
            guard let p = price(for: u.model.isEmpty ? fallbackModel : u.model) else { continue }
            known = true
            total += (Double(u.input) * p.input + Double(u.output) * p.output
                      + Double(u.cacheRead) * p.cacheRead + Double(u.cacheWrite) * p.cacheWrite) / 1_000_000
        }
        return known ? total : nil
    }

    /// What to show while it works: Claude Code's figure from its last finished turn plus an estimate of
    /// what came after it (`estimateAtCost`: this run's estimate when that figure came).
    static func live(cost: Double?, estimate: Double?, estimateAtCost: Double) -> (dollars: Double, estimated: Bool)? {
        guard let estimate else { return cost.map { ($0, false) } }
        let extra = max(0, estimate - estimateAtCost)
        if let cost { return (cost + extra, extra > 0.0005) }
        return (estimate, true)
    }
}
