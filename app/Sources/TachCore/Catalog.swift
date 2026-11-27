import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, openai, gemini
    public var id: String { rawValue }
    public var name: String { ["claude": "Claude", "openai": "OpenAI", "gemini": "Gemini"][rawValue]! }
    /// The tool whose usage counts toward this subscription.
    public var tool: Tool { self == .claude ? .claudeCode : self == .openai ? .codex : .antigravity }
}

public enum Tool: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude_code", codex, antigravity, geminiCLI = "gemini_cli"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .geminiCLI: "Gemini CLI"
        }
    }
    public var provider: Provider { self == .claudeCode ? .claude : self == .codex ? .openai : .gemini }
    /// How this tool's latency figures are obtained.
    public var timing: TimingQuality { self == .antigravity ? .exact : self == .codex ? .turn : self == .claudeCode ? .estimated : .none }
}

public enum TimingQuality: String, Codable {
    case exact, turn, estimated, none
    public var label: String {
        switch self {
        case .exact: "Measured per request"
        case .turn: "Measured per turn"
        case .estimated: "Estimated from log timestamps"
        case .none: "Not available"
        }
    }
    /// 3 = per request, 2 = per turn, 1 = estimated, 0 = none.
    public var level: Int { self == .exact ? 3 : self == .turn ? 2 : self == .estimated ? 1 : 0 }
}

public struct ModelInfo: Hashable, Identifiable {
    public var id: String        // normalised model id
    public var name: String      // "Claude Opus 5.5"
    public var short: String     // "Opus 5.5"
    public var provider: Provider?
    public var frontier: Bool
}

public enum ModelCatalog {
    private static let known: [(String, String, String, Provider, Bool)] = [
        ("claude-opus-5-5", "Claude Opus 5.5", "Opus 5.5", .claude, true),
        ("claude-fable-5-2", "Claude Fable 5.2", "Fable 5.2", .claude, true),
        ("claude-mythos-5-2", "Claude Mythos 5.2", "Mythos 5.2", .claude, true),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Sonnet 5.5", .claude, false),
        ("claude-haiku-5-5", "Claude Haiku 5.5", "Haiku 5.5", .claude, false),
        ("gpt-6.2-astra", "GPT 6.2 Astra", "GPT 6.2 Astra", .openai, true),
        ("gpt-6.2-sol", "GPT 6.2 Sol", "GPT 6.2 Sol", .openai, true),
        ("gemini-4-neon", "Gemini 4 Neon", "Gemini 4 Neon", .gemini, true),
    ]
    private static let efforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// Names for ids that say little on their own. A display name learned from a tool's own logs wins over these.
    private static let described: [String: (String, String)] = [
        "gemini-flash-worker-agy": ("Gemini 4 Hydrogen (Antigravity background worker)", "Hydrogen worker"),
        "gemini-pro-orchestrator-neon": ("Antigravity Orchestrator (Neon)", "Orchestrator"),
        "codex-auto-review": ("Codex auto-review", "Auto-review"),
    ]

    private static let lock = NSLock()
    private static var learned: [String: String] = [:]
    private static var sameAs: [String: String] = [:]

    /// Display names the tools themselves use, keyed by raw model id; kept by the store.
    /// When a tool's internal id carries the display name of a model that has its own public id
    /// (Antigravity's background worker reports itself as "Gemini 4 Hydrogen"), the two are one model.
    public static func learn(_ names: [String: String]) {
        var byID: [String: String] = [:], alias: [String: String] = [:]
        for (raw, name) in names where !name.isEmpty {
            let id = base(raw)
            byID[id] = name
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            if slug != id, PriceTable.published[slug] != nil { alias[id] = slug }
        }
        lock.lock(); learned = byID; sameAs = alias; lock.unlock()
    }

    /// Strips what differs between logs but names the same model: case, a `models/` prefix,
    /// a context tag like `[1m]`, a trailing date, and a trailing effort level.
    public static func normalize(_ raw: String) -> String {
        let id = base(raw)
        lock.lock(); defer { lock.unlock() }
        return sameAs[id] ?? id
    }

    private static func base(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "/", options: .backwards) { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "[") { s = String(s[..<r.lowerBound]) }
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        if let last = parts.last, efforts.contains(last), parts.count > 2 { parts.removeLast() }
        if parts.last == "tiered" || parts.last == "thinking", parts.count > 2 { parts.removeLast() }   // a tier or mode of the same model
        return parts.joined(separator: "-")
    }

    public static func info(_ raw: String) -> ModelInfo {
        let id = normalize(raw)
        if let k = known.first(where: { $0.0 == id }) {
            return ModelInfo(id: id, name: k.1, short: k.2, provider: k.3, frontier: k.4)
        }
        lock.lock(); let taught = learned[id]; lock.unlock()
        let p: Provider? = id.hasPrefix("claude") ? .claude : (id.hasPrefix("gpt") || id.hasPrefix("codex") || id.hasPrefix("o")) && !id.hasPrefix("other") ? .openai : id.hasPrefix("gemini") ? .gemini : nil
        // "claude-fable-5-1" reads as "Claude Fable 5.1": two short numbers in a row are a version
        var words: [String] = []
        for w in id.split(separator: "-").map(String.init) {
            if let last = words.last, last.count <= 2, w.count <= 2, Int(last) != nil, Int(w) != nil {
                words[words.count - 1] = last + "." + w
            } else if w == "gpt" {
                words.append("GPT")
            } else {
                words.append(w.first!.isNumber ? w : w.prefix(1).uppercased() + w.dropFirst())
            }
        }
        let pretty = words.joined(separator: " ")
        if let t = taught { return ModelInfo(id: id, name: t, short: p == .claude && t.hasPrefix("Claude ") ? String(t.dropFirst(7)) : t, provider: p, frontier: false) }
        if let d = described[id] { return ModelInfo(id: id, name: d.0, short: d.1, provider: p, frontier: false) }
        let short = p == .claude && pretty.hasPrefix("Claude ") ? String(pretty.dropFirst(7)) : pretty
        return ModelInfo(id: id, name: pretty, short: short, provider: p, frontier: false)
    }

    public static var frontierIDs: [String] { known.filter { $0.4 }.map { $0.0 } }
}

/// US dollars per million tokens.
public struct Price: Codable, Equatable {
    public var input, output: Double
    public var cacheRead: Double?
    public var cacheWrite5m: Double?
    public var cacheWrite1h: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
    }
}

public struct TokenMix: Equatable {
    public var input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0, output: Int64 = 0, thinking: Int64 = 0
    public init() {}
    public var total: Int64 { input + cacheRead + cacheWrite5m + cacheWrite1h + output }
    /// Share of prompt tokens served from cache.
    public var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheWrite5m + cacheWrite1h
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }
    public static func += (a: inout TokenMix, b: TokenMix) {
        a.input += b.input; a.cacheRead += b.cacheRead; a.cacheWrite5m += b.cacheWrite5m; a.cacheWrite1h += b.cacheWrite1h
        a.output += b.output; a.thinking += b.thinking
    }
}

/// Published API prices, used only to say what subscription usage would have cost through the API.
public struct PriceTable {
    /// The bundled table: every chat model in LiteLLM's public price list, regenerated by scripts/update-prices.py.
    public static let published: [String: Price] = {
        var out: [String: Price] = [:]
        if let raw = try? JSONSerialization.jsonObject(with: Data(PriceData.json.utf8)) as? [String: [Any]] {
            for (id, v) in raw where v.count == 5 {
                func n(_ i: Int) -> Double? { (v[i] as? NSNumber)?.doubleValue }
                guard let input = n(0), let output = n(1) else { continue }
                out[id] = Price(input: input, output: output, cacheRead: n(2), cacheWrite5m: n(3), cacheWrite1h: n(4))
            }
        }
        return out
    }()

    /// Ids a tool uses internally, priced as the public model they run on.
    /// The orchestrator names its model; the background worker reports itself as Gemini 4 Hydrogen.
    static let aliases: [String: String] = [
        "gemini-pro-orchestrator-neon": "gemini-4-neon",
        "gemini-flash-worker-agy": "gemini-4-hydrogen",
    ]

    public var overrides: [String: Price]
    public init(overrides: [String: Price] = [:]) { self.overrides = overrides }

    public func price(_ modelID: String) -> Price? {
        overrides[modelID] ?? Self.published[modelID] ?? Self.aliases[modelID].flatMap { overrides[$0] ?? Self.published[$0] }
    }

    /// nil when the model has no price: show tokens and "unpriced", never $0.
    public func cost(_ modelID: String, _ m: TokenMix) -> Double? {
        guard let p = price(modelID) else { return nil }
        let cr = p.cacheRead ?? p.input, w5 = p.cacheWrite5m ?? p.input, w1 = p.cacheWrite1h ?? w5
        let d = Double(m.input) * p.input + Double(m.cacheRead) * cr + Double(m.cacheWrite5m) * w5 + Double(m.cacheWrite1h) * w1 + Double(m.output) * p.output
        return d / 1_000_000
    }
}
