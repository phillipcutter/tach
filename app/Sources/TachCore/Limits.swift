import Foundation

public enum LimitState: String, Codable {
    case ok, warn, crit, limited, stale, idle
    /// Lower sorts first: most urgent.
    var rank: Int { [.limited: 0, .crit: 1, .warn: 2, .ok: 3, .stale: 4, .idle: 5][self]! }
}

public enum LimitKind: String, Codable { case session, weekly, weeklyScoped = "weekly_scoped", credits }

/// One limit window with everything derived from its readings.
public struct LimitWindow: Identifiable, Equatable {
    public var id: String { "\(provider.rawValue)|\(acct)|\(window)" }
    public var provider: Provider
    public var acct: String
    public var window: String
    public var kind: LimitKind
    public var label: String
    public var group: String
    public var used: Double              // percent, 0-100
    public var resets: Date?
    public var length: TimeInterval
    public var readAt: Date
    public var source: String
    public var amount: Double?
    public var cap: Double?
    public var currency: String?

    // derived
    public var state: LimitState = .ok
    public var elapsed: Double?          // percent of the window elapsed
    public var burnPerHour: Double = 0   // points per hour, recent
    public var averagePerHour: Double = 0
    public var projected: Double = 0     // percent at reset if the recent burn continues (capped at 100)
    public var hitAt: Date?              // when it reaches 100% at the recent burn, if before reset
    /// Session windows only: points of the enclosing week this session has used so far.
    public var weekShare: Double?

    public var remaining: TimeInterval? { resets.map { $0.timeIntervalSince(readNow) } }
    public var readNow = Date()
    /// Points ahead (+) or behind (−) an even pace.
    public var pace: Double? { elapsed.map { used - $0 } }
    public var shortBy: TimeInterval? { guard let h = hitAt, let r = resets else { return nil }; return r.timeIntervalSince(h) }
    public var start: Date? { resets.map { $0.addingTimeInterval(-length) } }
    /// Points per hour that would land exactly on 100% at reset.
    public var sustainablePerHour: Double? { remaining.flatMap { $0 > 0 ? (100 - used) / ($0 / 3600) : nil } }
    public var isWeekly: Bool { length > 6 * 3600 }

    /// Full name for sentences: "5-hour session", "Weekly, Opus".
    public var title: String {
        switch kind {
        case .session: "5-hour session"
        case .weekly: "Weekly"
        case .weeklyScoped: "Weekly, \(label)"
        case .credits: label
        }
    }
}

/// One budget: an optional session inside a week, plus model limits that share the week's window.
public struct LimitPool: Identifiable, Equatable {
    public var id: String
    public var name: String?
    public var session: LimitWindow?
    public var week: LimitWindow?
    public var scoped: [LimitWindow] = []
    public var windows: [LimitWindow] { [session, week].compactMap { $0 } + scoped }
}

public struct Account: Identifiable, Equatable {
    public var id: String { "\(provider.rawValue)|\(acct)" }
    public var provider: Provider
    public var acct: String
    public var plan: String?
    public var pools: [LimitPool] = []
    public var credits: LimitWindow?
    public var readAt: Date?
    public var windows: [LimitWindow] { pools.flatMap(\.windows) }
    public var tightest: LimitWindow? { windows.sorted(by: LimitMath.moreUrgent).first }
    public var isStale: Bool { !windows.isEmpty && windows.allSatisfy { $0.state == .stale || $0.state == .idle } && windows.contains { $0.state == .stale } }
    public func pool(of w: LimitWindow) -> LimitPool? { pools.first { $0.windows.contains { $0.id == w.id } } }
}

public struct Thresholds: Equatable {
    public var warn: Double = 80, crit: Double = 95
    public init(warn: Double = 80, crit: Double = 95) { self.warn = warn; self.crit = crit }
}

public enum LimitMath {
    /// A reading older than this is shown as stale.
    public static func staleAfter(_ p: Provider) -> TimeInterval { p == .gemini ? 10 * 60 : 20 * 60 }

    public static func moreUrgent(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
        let ah = a.hitAt?.timeIntervalSince1970 ?? .infinity, bh = b.hitAt?.timeIntervalSince1970 ?? .infinity
        if ah != bh { return ah < bh }
        return a.projected > b.projected
    }

    /// Derives pace, burn, projection and state for one window.
    /// `history` holds readings of the same window, oldest first, and may include `latest`.
    public static func derive(latest s: LimitSample, history: [LimitSample], now: Date, thresholds t: Thresholds = Thresholds()) -> LimitWindow? {
        guard let provider = Provider(rawValue: s.provider) else { return nil }
        var w = LimitWindow(provider: provider, acct: s.acct, window: s.window, kind: LimitKind(rawValue: s.kind) ?? .weekly, label: s.label,
                            group: s.group ?? "", used: min(max(s.used, 0), 100), resets: s.resets, length: s.length, readAt: s.ts, source: s.src,
                            amount: s.amount, cap: s.cap, currency: s.currency)
        w.readNow = now
        w.projected = w.used
        if w.kind == .credits { w.state = .ok; return w }

        // The window rolled over after the last reading: nothing is known about the new one yet.
        if let r = w.resets, r <= now {
            w.used = 0; w.projected = 0; w.resets = nil; w.state = .idle
            return w
        }
        guard let resets = w.resets, w.length > 0 else {
            // No reset time and nothing used: the window has not started. The account's own age badge says how old the reading is.
            w.state = w.used <= 0 ? .idle : now.timeIntervalSince(s.ts) > staleAfter(provider) ? .stale : .ok
            return w
        }
        let remaining = resets.timeIntervalSince(now)
        let elapsedS = max(w.length - remaining, 0)
        w.elapsed = min(elapsedS / w.length * 100, 100)
        w.averagePerHour = elapsedS > 60 ? w.used / (elapsedS / 3600) : 0

        if now.timeIntervalSince(s.ts) > staleAfter(provider) {
            w.state = .stale
            return w
        }

        // Recent burn: the change over a lookback that scales with the window, using only
        // readings from this same window instance.
        let lookback = min(max(w.length * 0.15, 20 * 60), 24 * 3600)
        let same = history.filter { h in
            guard let hr = h.resets else { return false }
            return abs(hr.timeIntervalSince(resets)) < 120 && h.ts <= s.ts
        }
        // Baseline: the last reading at least one lookback old, else the oldest of this window. A baseline
        // much younger than the lookback would turn one busy stretch into a rate for the whole window,
        // so in that case fall back to the window's average.
        let cutoff = s.ts.addingTimeInterval(-lookback)
        let base = same.last { $0.ts <= cutoff } ?? same.first
        let span = base.map { s.ts.timeIntervalSince($0.ts) } ?? 0
        if let base, span >= 5 * 60, span >= min(lookback, elapsedS) * 0.5 {
            w.burnPerHour = max(0, (s.used - base.used) / (span / 3600))
        } else {
            w.burnPerHour = w.averagePerHour
        }
        if s.limited || w.used >= 99.5 {   // shown as 100%, so treated as reached
            w.projected = 100; w.state = .limited
            return w
        }
        // A young window with little history says nothing reliable about where it will end:
        // a burst in its first hours would otherwise read as "runs out days early".
        let mature = elapsedS >= w.length * 0.1 || span >= lookback * 0.5
        if w.burnPerHour > 0, mature {
            let toFull = (100 - w.used) / w.burnPerHour * 3600
            if toFull < remaining {
                w.hitAt = now.addingTimeInterval(toFull); w.projected = 100
            } else {
                w.projected = min(w.used + w.burnPerHour * remaining / 3600, 100)
            }
        }
        w.state = w.used >= t.crit ? .crit : (w.used >= t.warn || w.hitAt != nil) ? .warn : .ok
        return w
    }

    /// Groups windows into accounts and budgets. `history` returns readings for a window id since a date.
    public static func accounts(latest: [LimitSample], now: Date, thresholds: Thresholds = Thresholds(),
                                history: (LimitSample, Date) -> [LimitSample]) -> [Account] {
        var byAccount: [String: Account] = [:]
        var order: [String] = []
        struct PoolBuild { var name: String?; var session: LimitWindow?; var week: LimitWindow?; var scoped: [LimitWindow] = []; var weekHistory: [LimitSample] = [] }
        var pools: [String: [String: PoolBuild]] = [:]
        var poolOrder: [String: [String]] = [:]

        // A provider reports every current window in each reading. A window last seen long before the
        // account's newest reading no longer exists (an old plan's limit, or one found only in old logs).
        var newest: [String: Date] = [:], planAt: [String: Date] = [:]
        for s in latest { let k = "\(s.provider)|\(s.acct)"; newest[k] = max(newest[k] ?? s.ts, s.ts) }
        for s in latest.sorted(by: { ($0.provider, $0.acct, $0.window) < ($1.provider, $1.acct, $1.window) }) {
            if let n = newest["\(s.provider)|\(s.acct)"], n.timeIntervalSince(s.ts) > max(s.length * 2, 24 * 3600) { continue }
            let lookback = now.addingTimeInterval(-max(s.length, 6 * 3600) - 3600)
            let hist = history(s, lookback)
            guard let w = derive(latest: s, history: hist, now: now, thresholds: thresholds) else { continue }
            let key = "\(s.provider)|\(s.acct)"
            if byAccount[key] == nil { byAccount[key] = Account(provider: w.provider, acct: s.acct); order.append(key) }
            if let p = s.plan, !p.isEmpty, s.ts >= (planAt[key] ?? .distantPast) { byAccount[key]!.plan = p; planAt[key] = s.ts }
            if byAccount[key]!.readAt == nil || s.ts > byAccount[key]!.readAt! { byAccount[key]!.readAt = s.ts }
            if w.kind == .credits { byAccount[key]!.credits = w; continue }
            let g = s.group ?? ""
            if pools[key]?[g] == nil { pools[key, default: [:]][g] = PoolBuild(name: s.groupLabel); poolOrder[key, default: []].append(g) }
            switch w.kind {
            case .session: pools[key]![g]!.session = w
            case .weekly: pools[key]![g]!.week = w; pools[key]![g]!.weekHistory = hist
            default: pools[key]![g]!.scoped.append(w)
            }
        }
        return order.compactMap { key in
            guard var a = byAccount[key] else { return nil }
            // the provider's own budget first, then the others by name
            let groups = (poolOrder[key] ?? []).sorted { (($0.isEmpty || $0 == a.provider.rawValue) ? 0 : 1, $0) < (($1.isEmpty || $1 == a.provider.rawValue) ? 0 : 1, $1) }
            for g in groups {
                guard var pb = pools[key]?[g] else { continue }
                // How much of the week this session has used: the week's reading now minus its reading when the session began.
                if var s = pb.session, let wk = pb.week, let st = s.start, s.state != .idle, wk.state != .idle {
                    // the week's reading closest in time to the moment the session began
                    let prior = pb.weekHistory.last { $0.ts <= st }, next = pb.weekHistory.first { $0.ts > st }
                    let before: LimitSample? = {
                        guard let p = prior else { return next }
                        guard let n = next else { return p }
                        return st.timeIntervalSince(p.ts) <= n.ts.timeIntervalSince(st) ? p : n
                    }()
                    if let b = before, wk.resets != nil, b.resets.map({ abs($0.timeIntervalSince(wk.resets!)) < 120 }) ?? false {
                        s.weekShare = max(0, wk.used - b.used)
                        pb.session = s
                    }
                }
                a.pools.append(LimitPool(id: key + "|" + g, name: pb.name, session: pb.session, week: pb.week, scoped: pb.scoped.sorted { ($0.used, $1.label) > ($1.used, $0.label) }))
            }
            return a
        }.sorted { (Provider.allCases.firstIndex(of: $0.provider) ?? 9) < (Provider.allCases.firstIndex(of: $1.provider) ?? 9) }
    }
}

public extension Store {
    func accounts(now: Date = Date(), thresholds: Thresholds = Thresholds()) -> [Account] {
        LimitMath.accounts(latest: latestLimits(), now: now, thresholds: thresholds) { s, since in
            self.limitHistory(provider: s.provider, acct: s.acct, window: s.window, since: since)
        }
    }

    /// Usage over time for the current instance of a window, for the usage-against-pace chart.
    func trajectory(_ w: LimitWindow) -> [(Date, Double)] {
        guard let start = w.start, let resets = w.resets else { return [] }
        return limitHistory(provider: w.provider.rawValue, acct: w.acct, window: w.window, since: start.addingTimeInterval(-60))
            .filter { $0.resets.map { abs($0.timeIntervalSince(resets)) < 120 } ?? false }
            .map { ($0.ts, $0.used) }
    }

    /// Peak usage of each past instance of a window, oldest first.
    func windowPeaks(_ w: LimitWindow, count: Int = 24) -> [(resets: Date, peak: Double, limited: Bool)] {
        var out: [(Date, Double, Bool)] = []
        let sql = """
        SELECT (resets/120000)*120000 AS r, MAX(used), MAX(limited) FROM limit_sample
        WHERE provider=? AND acct=? AND window=? AND resets IS NOT NULL GROUP BY r ORDER BY r DESC LIMIT ?
        """
        try? db.query(sql, [.text(w.provider.rawValue), .text(w.acct), .text(w.window), .int(Int64(count))]) { r in
            out.append((Date(ms: r.int(0)), r.double(1), r.int(2) != 0 || r.double(1) >= 100))
        }
        return out.reversed()
    }
}
