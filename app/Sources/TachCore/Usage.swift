import Foundation

public enum RangeKey: String, CaseIterable, Codable, Identifiable {
    case h1 = "1h", h6 = "6h", h24 = "24h", d7 = "7d", d30 = "30d", d90 = "90d", all
    public var id: String { rawValue }
    public var short: String { self == .all ? "All" : rawValue }

    /// Window length in seconds; nil for all time.
    public var seconds: Int64? {
        switch self {
        case .h1: 3600
        case .h6: 6 * 3600
        case .h24: 24 * 3600
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        case .d90: 90 * 86400
        case .all: nil
        }
    }

    /// Chart bucket length in seconds.
    public var bucket: Int64 {
        switch self {
        case .h1: 300
        case .h6: 900
        case .h24: 3600
        case .d7: 6 * 3600
        case .d30: 86400
        case .d90, .all: 7 * 86400
        }
    }

    public func title(start: Date) -> String {
        switch self {
        case .h1: return "last hour"
        case .h6: return "last 6 hours"
        case .h24: return "last 24 hours"
        case .d7: return "last 7 days"
        case .d30: return "last 30 days"
        case .d90: return "last 90 days"
        case .all:
            let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
            return "since " + f.string(from: start)
        }
    }
}

public struct Percentiles: Equatable {
    public var p50, p95: Double
    public var n: Int

    /// nil below 20 samples: too few to call a percentile.
    public static func of(_ values: [Double]) -> Percentiles? {
        guard values.count >= 20 else { return nil }
        let s = values.sorted()
        func q(_ p: Double) -> Double {
            let x = p * Double(s.count - 1), lo = Int(x.rounded(.down)), hi = min(lo + 1, s.count - 1)
            return s[lo] + (s[hi] - s[lo]) * (x - Double(lo))
        }
        return Percentiles(p50: q(0.5), p95: q(0.95), n: s.count)
    }
}

public struct ModelUsage: Identifiable, Equatable {
    public var id: String { info.id }
    public var info: ModelInfo
    public var mix = TokenMix()
    public var requests: Int64 = 0
    public var errors: Int64 = 0
    public var subagentRequests: Int64 = 0
    public var cost: Double?
    public var series: [Int64] = []          // tokens per chart bucket
    public var ttft: Percentiles?             // seconds
    public var tps: Percentiles?              // output tokens per second
    public var quality: TimingQuality = .none
    public var tools: Set<String> = []
}

public struct Slice: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var tokens: Int64
    public var cost: Double
    public var requests: Int64
}

public struct UsageSummary: Equatable {
    public var range: RangeKey
    public var start: Date
    public var end: Date
    public var bucketSeconds: Int64
    public var bucketCount: Int
    public var models: [ModelUsage] = []      // sorted by tokens, largest first
    public var byMachine: [Slice] = []
    public var byTool: [Slice] = []
    public var total = TokenMix()
    public var requests: Int64 = 0
    public var errors: Int64 = 0
    public var cost: Double = 0
    public var unpricedTokens: Int64 = 0

    public var title: String { range.title(start: start) }
    /// The title as it reads after a verb: "in the last 24 hours", "since 2 Mar 2026".
    public var phrase: String { range == .all ? title : "in the " + title }
    public var days: Double { end.timeIntervalSince(start) / 86400 }

    public static func empty(_ r: RangeKey, now: Date = Date()) -> UsageSummary {
        UsageSummary(range: r, start: now.addingTimeInterval(-Double(r.seconds ?? 86400)), end: now, bucketSeconds: r.bucket, bucketCount: 1)
    }
}

public struct ModelBreakdown: Equatable {
    public var byEffort: [Slice] = []
    public var bySpeed: [Slice] = []
    public var main: Int64 = 0, subagent: Int64 = 0
    public var ttftSamples: [Double] = []   // seconds
    public var tpsSamples: [Double] = []
    public var mixSeries: [TokenMix] = []   // per chart bucket
    public init() {}
}

public extension Store {
    private func window(_ range: RangeKey, now: Date) -> (start: Int64, end: Int64, bucket: Int64, count: Int) {
        let end = now.ms
        var bucket = range.bucket * 1000
        var start: Int64
        if let s = range.seconds {
            start = end - s * 1000
        } else {
            start = (earliestRequest() ?? now.addingTimeInterval(-7 * 86400)).ms
            while (end - start) / bucket > 60 { bucket *= 2 }
            // align so the last bucket ends now
            let n = max((end - start + bucket - 1) / bucket, 1)
            start = end - n * bucket
        }
        return (start, end, bucket, max(Int((end - start) / bucket), 1))
    }

    /// Totals for a range: per model, per machine, per tool, plus latency percentiles.
    func usage(range: RangeKey, now: Date = Date(), prices: PriceTable = PriceTable()) -> UsageSummary {
        let w = window(range, now: now)
        var out = UsageSummary(range: range, start: Date(ms: w.start), end: now, bucketSeconds: w.bucket / 1000, bucketCount: w.count)
        var models: [String: ModelUsage] = [:]
        var machines: [Int64: Slice] = [:], tools: [String: Slice] = [:]
        var names: [Int64: String] = [:]
        for m in self.machines() { names[m.id] = m.name }

        let sql = """
        SELECT model, tool, machine_id, (ts-?)/? AS b, SUM(tin),SUM(cr),SUM(cw5),SUM(cw1),SUM(tout),SUM(think),COUNT(*),SUM(err IS NOT NULL),SUM(sub)
        FROM request WHERE ts>? AND ts<=? GROUP BY model, tool, machine_id, b
        """
        try? db.query(sql, [.int(w.start), .int(w.bucket), .int(w.start), .int(w.end)]) { r in
            let info = ModelCatalog.info(r.text(0)), tool = r.text(1), mid = r.int(2)
            let b = min(max(Int(r.int(3)), 0), w.count - 1)
            var mix = TokenMix()
            mix.input = r.int(4); mix.cacheRead = r.int(5); mix.cacheWrite5m = r.int(6); mix.cacheWrite1h = r.int(7); mix.output = r.int(8); mix.thinking = r.int(9)
            let n = r.int(10), errs = r.int(11), subs = r.int(12)
            var mu = models[info.id] ?? ModelUsage(info: info, series: Array(repeating: 0, count: w.count))
            mu.mix += mix; mu.requests += n; mu.errors += errs; mu.subagentRequests += subs
            mu.series[b] += mix.total
            mu.tools.insert(tool)
            models[info.id] = mu
            let c = prices.cost(info.id, mix) ?? 0
            var ms = machines[mid] ?? Slice(id: String(mid), name: names[mid] ?? "machine \(mid)", tokens: 0, cost: 0, requests: 0)
            ms.tokens += mix.total; ms.cost += c; ms.requests += n; machines[mid] = ms
            var ts = tools[tool] ?? Slice(id: tool, name: Tool(rawValue: tool)?.name ?? tool, tokens: 0, cost: 0, requests: 0)
            ts.tokens += mix.total; ts.cost += c; ts.requests += n; tools[tool] = ts
            out.total += mix; out.requests += n; out.errors += errs
        }

        // latency: per request where the tool logs it, per turn for Codex
        var ttft: [String: [Double]] = [:], tps: [String: [Double]] = [:]
        try? db.query("SELECT model, ttft, dur, tout FROM request WHERE ts>? AND ts<=? AND tq!='none'", [.int(w.start), .int(w.end)]) { r in
            let id = ModelCatalog.normalize(r.text(0))
            let t = r.intOrNil(1), d = r.intOrNil(2), o = r.int(3)
            if let t, t > 0 { ttft[id, default: []].append(Double(t) / 1000) }
            if let d, o > 0 {
                let gen = Double(d - (t ?? 0)) / 1000
                if gen > 0.2 { tps[id, default: []].append(Double(o) / gen) }
            }
        }
        try? db.query("SELECT model, ttft, dur, tout FROM turn WHERE ts>? AND ts<=? AND model IS NOT NULL", [.int(w.start), .int(w.end)]) { r in
            let id = ModelCatalog.normalize(r.text(0))
            if let t = r.intOrNil(1), t > 0 { ttft[id, default: []].append(Double(t) / 1000) }
        }

        for (id, var mu) in models {
            mu.cost = prices.cost(id, mu.mix)
            if let c = mu.cost { out.cost += c } else { out.unpricedTokens += mu.mix.total }
            mu.ttft = Percentiles.of(ttft[id] ?? [])
            mu.tps = Percentiles.of(tps[id] ?? [])
            let q = mu.tools.compactMap { Tool(rawValue: $0)?.timing }.max { $0.level < $1.level } ?? .none
            mu.quality = (mu.ttft == nil && mu.tps == nil) ? .none : q
            models[id] = mu
        }
        out.models = models.values.sorted { $0.mix.total > $1.mix.total }
        out.byMachine = machines.values.sorted { $0.tokens > $1.tokens }
        out.byTool = tools.values.sorted { $0.tokens > $1.tokens }
        return out
    }

    /// Detail for one model: splits by effort, speed and subagent, raw latency samples and the token mix over time.
    func breakdown(modelID: String, range: RangeKey, now: Date = Date()) -> ModelBreakdown {
        let w = window(range, now: now)
        var out = ModelBreakdown()
        out.mixSeries = Array(repeating: TokenMix(), count: w.count)
        var eff: [String: Slice] = [:], spd: [String: Slice] = [:]
        let sql = """
        SELECT model, COALESCE(effort,''), COALESCE(speed,''), sub, (ts-?)/? AS b, SUM(tin),SUM(cr),SUM(cw5),SUM(cw1),SUM(tout),SUM(think),COUNT(*)
        FROM request WHERE ts>? AND ts<=? GROUP BY model, 2, 3, sub, b
        """
        try? db.query(sql, [.int(w.start), .int(w.bucket), .int(w.start), .int(w.end)]) { r in
            guard ModelCatalog.normalize(r.text(0)) == modelID else { return }
            var mix = TokenMix()
            mix.input = r.int(5); mix.cacheRead = r.int(6); mix.cacheWrite5m = r.int(7); mix.cacheWrite1h = r.int(8); mix.output = r.int(9); mix.thinking = r.int(10)
            let n = r.int(11), e = r.text(1).isEmpty ? "default" : r.text(1), s = r.text(2).isEmpty ? "standard" : r.text(2)
            var es = eff[e] ?? Slice(id: e, name: e, tokens: 0, cost: 0, requests: 0); es.tokens += mix.total; es.requests += n; eff[e] = es
            var ss = spd[s] ?? Slice(id: s, name: s, tokens: 0, cost: 0, requests: 0); ss.tokens += mix.total; ss.requests += n; spd[s] = ss
            if r.int(3) != 0 { out.subagent += n } else { out.main += n }
            out.mixSeries[min(max(Int(r.int(4)), 0), w.count - 1)] += mix
        }
        out.byEffort = eff.values.sorted { $0.requests > $1.requests }
        out.bySpeed = spd.values.sorted { $0.requests > $1.requests }
        try? db.query("SELECT model, ttft, dur, tout FROM request WHERE ts>? AND ts<=? AND tq!='none'", [.int(w.start), .int(w.end)]) { r in
            guard ModelCatalog.normalize(r.text(0)) == modelID else { return }
            let t = r.intOrNil(1), d = r.intOrNil(2), o = r.int(3)
            if let t, t > 0 { out.ttftSamples.append(Double(t) / 1000) }
            if let d, o > 0 { let g = Double(d - (t ?? 0)) / 1000; if g > 0.2 { out.tpsSamples.append(Double(o) / g) } }
        }
        try? db.query("SELECT model, ttft FROM turn WHERE ts>? AND ts<=? AND model IS NOT NULL", [.int(w.start), .int(w.end)]) { r in
            guard ModelCatalog.normalize(r.text(0)) == modelID else { return }
            if let t = r.intOrNil(1), t > 0 { out.ttftSamples.append(Double(t) / 1000) }
        }
        return out
    }

    /// Output tokens per second across every machine, over the last `seconds`.
    func throughput(now: Date = Date(), seconds: Int64 = 300) -> Double {
        let n = (try? db.scalarInt("SELECT SUM(tout) FROM request WHERE ts>? AND ts<=?", [.int(now.ms - seconds * 1000), .int(now.ms)])) ?? nil
        return Double(n ?? 0) / Double(seconds)
    }

    /// Tokens per machine over the last hour, for the Machines list.
    func machineRates(now: Date = Date()) -> [Int64: Int64] {
        var out: [Int64: Int64] = [:]
        try? db.query("SELECT machine_id, SUM(tin+cr+cw5+cw1+tout) FROM request WHERE ts>? GROUP BY machine_id", [.int(now.ms - 3_600_000)]) { r in out[r.int(0)] = r.int(1) }
        return out
    }
}
