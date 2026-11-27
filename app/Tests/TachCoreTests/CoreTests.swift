import XCTest
@testable import TachCore

final class CoreTests: XCTestCase {
    func tempStore() throws -> Store {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("tach-test-\(UUID().uuidString).sqlite").path
        return try Store(path: p)
    }

    func line(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

    // MARK: ingest

    func testUpsertKeepsFieldMaximaAndIsIdempotent() throws {
        let s = try tempStore(); let m = try s.ensureMachine(name: "mac", kind: "local")
        let now = Date()
        let a = line(["k": "req", "tool": "claude_code", "key": "msg_1", "ts": now.ms - 1000, "model": "claude-opus-5-5", "in": 10, "cr": 100, "out": 0, "tq": "none"])
        let b = line(["k": "req", "tool": "claude_code", "key": "msg_1", "ts": now.ms - 900, "model": "claude-opus-5-5", "in": 2, "cr": 100, "cw1": 50, "out": 400, "think": 100, "dur": 4000, "ttft": 900, "tq": "est"])
        try s.ingest(Data((a + "\n" + b + "\n" + a).utf8), machine: m)
        try s.ingest(Data(line(["k": "req", "tool": "antigravity", "key": "n1", "ts": now.ms - 7_200_000, "model": "gemini-4-carbon", "name": "Gemini 4 Carbon", "in": 1, "out": 1]).utf8), machine: m)
        XCTAssertEqual(s.modelNames(), ["gemini-4-carbon": "Gemini 4 Carbon"])
        try s.db.run("DELETE FROM request WHERE key='n1'")
        XCTAssertEqual(s.requestCount(), 1)
        let u = s.usage(range: .h1, now: now)
        XCTAssertEqual(u.requests, 1)
        XCTAssertEqual(u.total.input, 10); XCTAssertEqual(u.total.cacheRead, 100); XCTAssertEqual(u.total.cacheWrite1h, 50)
        XCTAssertEqual(u.total.output, 400); XCTAssertEqual(u.total.thinking, 100)
        // a later 'none' reading must not erase timing
        var tq = ""; try s.db.query("SELECT tq, dur FROM request") { tq = $0.text(0); XCTAssertEqual($0.int(1), 4000) }
        XCTAssertEqual(tq, "est")
    }

    func testMirrorCopyYieldsMachineToTheRealOne() throws {
        let s = try tempStore()
        let mac = try s.ensureMachine(name: "mac", kind: "local"), box = try s.ensureMachine(name: "box", kind: "ssh")
        let now = Date()
        let base: [String: Any] = ["k": "req", "tool": "claude_code", "key": "msg_9", "ts": now.ms - 5, "model": "claude-fable-5-2", "in": 1, "out": 9]
        var mirror = base; mirror["mirror"] = true
        try s.ingest(Data(line(mirror).utf8), machine: mac)
        try s.ingest(Data(line(base).utf8), machine: box)
        try s.ingest(Data(line(mirror).utf8), machine: mac)   // seeing the mirror again must not take it back
        var owner: Int64 = 0; try s.db.query("SELECT machine_id FROM request") { owner = $0.int(0) }
        XCTAssertEqual(owner, box)
    }

    func testCursorIsSavedWithTheEvents() throws {
        let s = try tempStore(); let m = try s.ensureMachine(name: "mac", kind: "local")
        let r = try s.ingest(Data("{\"k\":\"cursor\",\"v\":\"abc\"}\nnot json\n\n".utf8), machine: m)
        XCTAssertEqual(r.cursor, "abc"); XCTAssertEqual(s.cursor(machine: m), "abc")
        try s.ingest(Data("{\"k\":\"cursor\",\"v\":\"zzz\"}".utf8), machine: m, saveCursor: false)
        XCTAssertEqual(s.cursor(machine: m), "abc")
    }

    // MARK: usage

    func testUsageTotalsCostAndBreakdowns() throws {
        let s = try tempStore()
        let mac = try s.ensureMachine(name: "mac", kind: "local"), box = try s.ensureMachine(name: "box", kind: "ssh")
        let now = Date()
        var a: [String] = [], b: [String] = []
        for i in 0..<30 {
            a.append(line(["k": "req", "tool": "claude_code", "key": "a\(i)", "ts": now.ms - Int64(i) * 60_000, "model": "claude-opus-5-5-20261101", "in": 1000, "cr": 9000, "cw5": 0, "cw1": 0, "out": 500, "dur": 6000, "ttft": 1000, "tq": "est"]))
            b.append(line(["k": "req", "tool": "codex", "key": "b\(i)", "ts": now.ms - Int64(i) * 60_000, "model": "gpt-6.2-sol", "in": 2000, "cr": 0, "out": 100, "tq": "none"]))
        }
        b.append(line(["k": "req", "tool": "codex", "key": "old", "ts": now.ms - 3 * 3_600_000, "model": "mystery-model", "in": 7, "out": 3]))
        try s.ingest(Data(a.joined(separator: "\n").utf8), machine: mac)
        try s.ingest(Data(b.joined(separator: "\n").utf8), machine: box)
        let u = s.usage(range: .h1, now: now)
        XCTAssertEqual(u.requests, 60)
        XCTAssertEqual(u.total.total, Int64(378_000))
        XCTAssertEqual(u.models.map(\.id), ["claude-opus-5-5", "gpt-6.2-sol"])
        XCTAssertEqual(u.models.map(\.mix.total).reduce(0, +), u.total.total)
        XCTAssertEqual(u.byMachine.map(\.tokens).reduce(0, +), u.total.total)
        XCTAssertEqual(u.byTool.map(\.tokens).reduce(0, +), u.total.total)
        XCTAssertEqual(u.models[0].series.reduce(0, +), u.models[0].mix.total)
        // opus: 30 * (1000*4 + 9000*0.20 + 500*20) / 1e6 ; sol: 30 * (2000*2 + 100*10) / 1e6
        let expected: Double = 30.0 * 15800.0 / 1e6 + 30.0 * 5000.0 / 1e6
        XCTAssertEqual(u.cost, expected, accuracy: 1e-9)
        XCTAssertEqual(u.models[0].mix.cacheHitRate!, 0.9, accuracy: 1e-9)
        XCTAssertEqual(u.models[0].ttft!.p50, 1.0, accuracy: 1e-9)
        XCTAssertEqual(u.models[0].tps!.p50, 100, accuracy: 1e-9)   // 500 tokens over 5 s
        XCTAssertEqual(u.models[0].quality, .estimated)
        XCTAssertNil(u.models[1].tps)
        // an unpriced model is counted in tokens and reported, never priced at zero silently
        let d = s.usage(range: .h6, now: now)
        XCTAssertEqual(d.unpricedTokens, 10)
        XCTAssertNil(d.models.first { $0.id == "mystery-model" }!.cost)
        let all = s.usage(range: .all, now: now)
        XCTAssertEqual(all.requests, 61)
        XCTAssertEqual(all.models.map { $0.series.reduce(0, +) }.reduce(0, +), all.total.total)
    }

    func testModelNormalisation() {
        XCTAssertEqual(ModelCatalog.normalize("claude-opus-5-5-20261101"), "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.normalize("Claude-Opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.normalize("gemini-4-neon-high"), "gemini-4-neon")
        XCTAssertEqual(ModelCatalog.normalize("models/gemini-4-neon"), "gemini-4-neon")
        XCTAssertEqual(ModelCatalog.normalize("gpt-6.2-sol"), "gpt-6.2-sol")
        XCTAssertEqual(ModelCatalog.info("gpt-6.2-astra").provider, .openai)
        XCTAssertEqual(ModelCatalog.info("claude-sonnet-9-9").short, "Sonnet 9.9")
        XCTAssertEqual(ModelCatalog.info("claude-fable-5-1").name, "Claude Fable 5.1")
        XCTAssertEqual(ModelCatalog.info("claude-sonnet-5").name, "Claude Sonnet 5")
        XCTAssertEqual(ModelCatalog.info("gpt-6.1-terra").name, "GPT 6.1 Terra")
        XCTAssertEqual(ModelCatalog.info("gemini-3-flash-preview").name, "Gemini 3 Flash Preview")
        XCTAssertNil(ModelCatalog.info("deepseek-flash").provider)
        XCTAssertTrue(ModelCatalog.info("claude-mythos-5-2").frontier)
        XCTAssertEqual(ModelCatalog.normalize("gemini-4-hydrogen-tiered-high"), "gemini-4-hydrogen")
        XCTAssertEqual(ModelCatalog.info("gemini-flash-worker-agy").name, "Gemini 4 Hydrogen (Antigravity background worker)")
        // once the tool's own name is known, an internal id is the same model as the public id with that name
        ModelCatalog.learn(["gemini-flash-worker-agy": "Gemini 4 Hydrogen", "gemini-pro-orchestrator-neon": "Orchestrator"])
        XCTAssertEqual(ModelCatalog.normalize("gemini-flash-worker-agy"), "gemini-4-hydrogen")
        XCTAssertEqual(ModelCatalog.info("gemini-flash-worker-agy").name, "Gemini 4 Hydrogen")
        XCTAssertEqual(ModelCatalog.info("gemini-pro-orchestrator-neon").name, "Orchestrator")
        XCTAssertEqual(ModelCatalog.normalize("gemini-pro-orchestrator-neon"), "gemini-pro-orchestrator-neon")
        ModelCatalog.learn([:])
        // a name the tool itself logs wins over a prettified id, but never over the known frontier names
        ModelCatalog.learn(["gemini-4-carbon-high": "Gemini 4 Carbon", "claude-opus-5-5": "Something else", "gemini-flash-worker-agy": "Gemini 3.8 Flash"])
        XCTAssertEqual(ModelCatalog.info("gemini-4-carbon").name, "Gemini 4 Carbon")
        XCTAssertEqual(ModelCatalog.info("gemini-flash-worker-agy").name, "Gemini 3.8 Flash")
        XCTAssertEqual(ModelCatalog.info("claude-opus-5-5").name, "Claude Opus 5.5")
        ModelCatalog.learn([:])
    }

    func testBundledPricesCoverTheModelsInUse() {
        let t = PriceTable()
        for id in ModelCatalog.frontierIDs + ["gpt-6.1-terra", "gemini-4-hydrogen", "gemini-4-carbon", "claude-sonnet-5-5", "gpt-6-astra", "gpt-6.1-sol", "deepseek-flash", "claude-haiku-5-5"] {
            XCTAssertNotNil(t.price(id), id)
        }
        XCTAssertEqual(t.price("claude-opus-5-5"), Price(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8))
        // internal ids are priced as the public model they run on, and variants as their base model
        XCTAssertEqual(t.price("gemini-pro-orchestrator-neon"), t.price("gemini-4-neon"))
        XCTAssertNotNil(t.price("gemini-flash-worker-agy"))
        XCTAssertEqual(t.price(ModelCatalog.normalize("gemini-4-hydrogen-tiered-high")), t.price("gemini-4-hydrogen"))
        XCTAssertEqual(t.price(ModelCatalog.normalize("claude-opus-4-6-thinking")), t.price("claude-opus-4-6"))
        XCTAssertNil(t.price("mystery-model"))
        // an override still wins, including for an aliased id's target
        XCTAssertEqual(PriceTable(overrides: ["gemini-4-neon": Price(input: 1, output: 2)]).price("gemini-pro-orchestrator-neon")?.input, 1)
    }

    func testPercentilesNeedTwentySamples() {
        XCTAssertNil(Percentiles.of(Array(repeating: 1, count: 19)))
        let p = Percentiles.of((1...101).map(Double.init))!
        XCTAssertEqual(p.p50, 51); XCTAssertEqual(p.p95, 96)
    }

    // MARK: limits

    func sample(_ window: String = "five_hour", kind: String = "session", used: Double, resetsIn: TimeInterval?, len: TimeInterval = 18000, ago: TimeInterval = 0,
                now: Date, provider: String = "claude", group: String? = nil, limited: Bool = false) -> LimitSample {
        LimitSample(provider: provider, acct: "a", window: window, kind: kind, label: window, group: group, groupLabel: nil, plan: "Max", currency: nil,
                    used: used, resets: resetsIn.map { now.addingTimeInterval($0) }, length: len, limited: limited, amount: nil, cap: nil,
                    ts: now.addingTimeInterval(-ago), src: "t")
    }

    func testProjectionHitsBeforeReset() {
        let now = Date()
        // 60% thirty minutes ago, 81% now, 108 minutes left: 42 points/hour reaches 100% in ~27 minutes
        let h = [sample(used: 60, resetsIn: 108 * 60, ago: 1800, now: now), sample(used: 81, resetsIn: 108 * 60, now: now)]
        let w = LimitMath.derive(latest: h[1], history: h, now: now)!
        XCTAssertEqual(w.burnPerHour, 42, accuracy: 0.01)
        XCTAssertEqual(w.state, .warn)
        let toFull: Double = 19.0 / 42.0 * 3600.0
        XCTAssertEqual(w.hitAt!.timeIntervalSince(now), toFull, accuracy: 1)
        XCTAssertEqual(w.shortBy!, 6480.0 - toFull, accuracy: 1)
        XCTAssertEqual(w.elapsed!, 64, accuracy: 0.01)
        XCTAssertEqual(w.pace!, 17, accuracy: 0.01)
        XCTAssertEqual(w.projected, 100)
    }

    func testSafeThroughResetAndThresholds() {
        let now = Date()
        let h = [sample(used: 29, resetsIn: 3600, ago: 1800, now: now), sample(used: 31, resetsIn: 3600, now: now)]
        let w = LimitMath.derive(latest: h[1], history: h, now: now)!
        XCTAssertEqual(w.state, .ok); XCTAssertNil(w.hitAt); XCTAssertEqual(w.projected, 35, accuracy: 0.01)
        XCTAssertEqual(LimitMath.derive(latest: sample(used: 96, resetsIn: 60, now: now), history: [], now: now)!.state, .crit)
        XCTAssertEqual(LimitMath.derive(latest: sample(used: 100, resetsIn: 600, now: now), history: [], now: now)!.state, .limited)
        XCTAssertEqual(LimitMath.derive(latest: sample(used: 40, resetsIn: 600, now: now, limited: true), history: [], now: now)!.state, .limited)
        // custom thresholds
        XCTAssertEqual(LimitMath.derive(latest: sample(used: 55, resetsIn: 17000, now: now), history: [], now: now, thresholds: Thresholds(warn: 50, crit: 90))!.state, .warn)
    }

    func testStaleIdleAndRolledOver() {
        let now = Date()
        XCTAssertEqual(LimitMath.derive(latest: sample(used: 44, resetsIn: 960, ago: 3 * 3600, now: now, provider: "gemini"), history: [], now: now)!.state, .stale)
        let idle = LimitMath.derive(latest: sample(used: 0, resetsIn: nil, now: now, provider: "gemini"), history: [], now: now)!
        XCTAssertEqual(idle.state, .idle); XCTAssertNil(idle.resets)
        // read at 90% an hour ago, but that window ended ten minutes ago: nothing is known about the new one
        let rolled = LimitMath.derive(latest: sample(used: 90, resetsIn: -600, ago: 3600, now: now), history: [], now: now)!
        XCTAssertEqual(rolled.state, .idle); XCTAssertEqual(rolled.used, 0)
    }

    func testBurnIgnoresReadingsFromThePreviousWindow() {
        let now = Date()
        // previous window ended at 95%; the new one is at 5% twenty minutes in
        let old = sample(used: 95, resetsIn: -1200, ago: 1500, now: now)
        let cur = sample(used: 5, resetsIn: 18000 - 1200, now: now)
        let w = LimitMath.derive(latest: cur, history: [old, cur], now: now)!
        XCTAssertEqual(w.burnPerHour, 15, accuracy: 0.01)   // falls back to the window average
        XCTAssertEqual(w.state, .ok)
    }

    func testWeeklyBurnUsesALongBaseline() {
        let now = Date(), week = 7.0 * 86400
        func wk(_ used: Double, ago: TimeInterval) -> LimitSample { sample("weekly", kind: "weekly", used: used, resetsIn: 3 * 86400, len: week, ago: ago, now: now) }
        // 6 points in the last three hours, but only 10 over the last day
        let h = [wk(44, ago: 26 * 3600), wk(48, ago: 3 * 3600), wk(54, ago: 0)]
        let w = LimitMath.derive(latest: h[2], history: h, now: now)!
        XCTAssertEqual(w.burnPerHour, 10.0 / 26.0, accuracy: 1e-6)
        XCTAssertNil(w.hitAt)
        // with only three hours of history, fall back to the window's average rather than extrapolate the burst
        let short = LimitMath.derive(latest: h[2], history: [h[1], h[2]], now: now)!
        XCTAssertEqual(short.burnPerHour, 54.0 / 96.0, accuracy: 1e-6)
    }

    func testYoungWindowDoesNotPredictAnEarlyLimit() {
        let now = Date(), week = 7.0 * 86400
        // four hours into a week, 15% used: a burst, not a trend
        let a = sample("weekly", kind: "weekly", used: 14, resetsIn: week - 4 * 3600 + 240, len: week, ago: 240, now: now)
        let b = sample("weekly", kind: "weekly", used: 15, resetsIn: week - 4 * 3600, len: week, now: now)
        let w = LimitMath.derive(latest: b, history: [a, b], now: now)!
        XCTAssertNil(w.hitAt); XCTAssertEqual(w.state, .ok); XCTAssertEqual(w.projected, 15)
        // the same reading a day and a half in does project
        let c = sample("weekly", kind: "weekly", used: 62, resetsIn: week - 1.5 * 86400, len: week, now: now)
        XCTAssertNotNil(LimitMath.derive(latest: c, history: [c], now: now)!.hitAt)
    }

    func testWindowsNotSeenLatelyAreDroppedAndThePlanIsTheNewest() {
        let now = Date(), week = 7.0 * 86400
        var current = sample("weekly", kind: "weekly", used: 30, resetsIn: 2 * 86400, len: week, now: now); current.plan = "Ultra"
        // found only in logs from two months ago: an old plan's 5-hour limit and a retired per-model limit
        var oldSession = sample(used: 100, resetsIn: -58 * 86400, ago: 58 * 86400, now: now); oldSession.plan = "Max"
        let retired = sample("weekly:spark", kind: "weekly_scoped", used: 0, resetsIn: -60 * 86400, len: week, ago: 70 * 86400, now: now)
        // read a day ago by a slower source: still current for a weekly window
        let scoped = sample("weekly:fable", kind: "weekly_scoped", used: 17, resetsIn: 2 * 86400, len: week, ago: 86400, now: now)
        let a = LimitMath.accounts(latest: [oldSession, retired, current, scoped], now: now) { s, _ in [s] }
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].windows.map(\.window), ["weekly", "weekly:fable"])
        XCTAssertEqual(a[0].plan, "Ultra")
    }

    func testAccountsGroupBudgetsAndWeekShare() {
        let now = Date()
        let week = 7.0 * 86400
        let latest = [
            sample(used: 81, resetsIn: 108 * 60, now: now),
            sample("weekly", kind: "weekly", used: 54, resetsIn: 2 * 86400, len: week, now: now),
            sample("weekly:opus", kind: "weekly_scoped", used: 71, resetsIn: 2 * 86400, len: week, now: now),
            sample("gemini:five_hour", used: 10, resetsIn: 3600, now: now, provider: "gemini", group: "gemini"),
            sample("3p:weekly", kind: "weekly", used: 12, resetsIn: 86400, len: week, now: now, provider: "gemini", group: "3p"),
            sample("weekly", kind: "weekly", used: 31, resetsIn: 4 * 86400, len: week, now: now, provider: "openai"),
        ]
        let weekBefore = sample("weekly", kind: "weekly", used: 48, resetsIn: 2 * 86400, len: week, ago: 4 * 3600, now: now)
        let accts = LimitMath.accounts(latest: latest, now: now) { s, _ in
            s.provider == "claude" && s.window == "weekly" ? [weekBefore, s] : [s]
        }
        XCTAssertEqual(accts.map(\.provider), [.claude, .openai, .gemini])
        let c = accts[0]
        XCTAssertEqual(c.pools.count, 1)
        XCTAssertEqual(c.pools[0].scoped.map(\.label), ["weekly:opus"])
        XCTAssertEqual(c.pools[0].session!.weekShare!, 6, accuracy: 1e-9)
        XCTAssertEqual(c.tightest!.window, "five_hour")
        XCTAssertNil(accts[1].pools[0].session)
        XCTAssertEqual(accts[2].pools.count, 2)
    }

    // MARK: alerts

    func account(_ ws: [LimitWindow]) -> Account {
        var p = LimitPool(id: "p"); p.session = ws.first { $0.kind == .session }; p.week = ws.first { $0.kind == .weekly }
        var a = Account(provider: .claude, acct: "a"); a.pools = [p]; return a
    }

    func win(used: Double, ago: TimeInterval = 0, before: Double? = nil, resetsIn: TimeInterval = 108 * 60, now: Date, limited: Bool = false) -> LimitWindow {
        var h: [LimitSample] = []
        if let b = before { h.append(sample(used: b, resetsIn: resetsIn, ago: 1800, now: now)) }
        let s = sample(used: used, resetsIn: resetsIn, ago: ago, now: now, limited: limited)
        return LimitMath.derive(latest: s, history: h + [s], now: now)!
    }

    func testAlertsFireOnceOnCrossingAndNotOnTheFirstReading() {
        let now = Date(), s = AppSettings()
        // 40% with nothing predicted, then 81% and on course to run out
        let low = account([win(used: 40, now: now)]), high = account([win(used: 81, before: 60, now: now)])
        XCTAssertNil(low.windows[0].hitAt); XCTAssertNotNil(high.windows[0].hitAt)
        XCTAssertTrue(LimitAlerts.events(old: [], new: [high], settings: s, now: now).isEmpty)
        let e = LimitAlerts.events(old: [low], new: [high], settings: s, now: now)
        XCTAssertEqual(e.map(\.title), ["Claude 5-hour limit at 81%", "Claude 5-hour limit will run out early"])
        XCTAssertTrue(e[0].body.hasPrefix("At this pace you hit the limit at "))
        // no change, no alert; and the keys are stable so a repeat would be dropped by the notifier
        XCTAssertTrue(LimitAlerts.events(old: [high], new: [high], settings: s, now: now).isEmpty)
        XCTAssertEqual(e.map(\.key), LimitAlerts.events(old: [low], new: [high], settings: s, now: now).map(\.key))
        // jumping past both thresholds reports the higher one only
        let crit = account([win(used: 97, before: 60, now: now)])
        XCTAssertEqual(LimitAlerts.events(old: [low], new: [crit], settings: s, now: now).filter { $0.key.hasSuffix("|95") }.count, 1)
        XCTAssertTrue(LimitAlerts.events(old: [low], new: [crit], settings: s, now: now).allSatisfy { !$0.key.hasSuffix("|80") })
    }

    func testAlertsRespectSettingsResetsAndStaleReadings() {
        let now = Date()
        var off = AppSettings(); off.notifyThresholds = false; off.notifyShort = false
        let low = account([win(used: 70, now: now)]), high = account([win(used: 81, before: 60, now: now)])
        XCTAssertTrue(LimitAlerts.events(old: [low], new: [high], settings: off, now: now).isEmpty)
        // a new window starting at 85% is not a crossing of the old window's threshold
        let next = account([win(used: 85, resetsIn: 5 * 3600, now: now)])
        XCTAssertTrue(LimitAlerts.events(old: [low], new: [next], settings: AppSettings(), now: now).filter { $0.title.contains(" at ") }.isEmpty)
        // a stale reading raises nothing
        let stale = account([win(used: 90, ago: 3 * 3600, now: now)])
        XCTAssertTrue(LimitAlerts.events(old: [low], new: [stale], settings: AppSettings(), now: now).isEmpty)
        // limited, then usable again
        let limited = account([win(used: 100, now: now, limited: true)]), fresh = account([win(used: 3, resetsIn: 5 * 3600 - 60, now: now)])
        XCTAssertEqual(LimitAlerts.events(old: [limited], new: [fresh], settings: AppSettings(), now: now).map(\.title), ["Claude 5-hour limit has reset"])
    }

    // MARK: plumbing

    func testShellSplitAndBinaryNames() {
        XCTAssertEqual(Shell.split("-p 2222 -o 'ProxyCommand=nc -X 5 -x localhost:1055 %h %p' -J \"a b\""), ["-p", "2222", "-o", "ProxyCommand=nc -X 5 -x localhost:1055 %h %p", "-J", "a b"])
        XCTAssertEqual(Shell.split("  "), [])
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Collector.binaryName(uname: "Linux x86_64"), "tach-collector-linux-amd64")
        XCTAssertEqual(Collector.binaryName(uname: "Linux aarch64"), "tach-collector-linux-arm64")
        XCTAssertEqual(Collector.binaryName(uname: "Darwin arm64"), "tach-collector-darwin-arm64")
        XCTAssertNil(Collector.binaryName(uname: "FreeBSD amd64"))
        XCTAssertEqual(Collector.explain(ProcessResult(status: 255, out: Data(), err: "nc: connection failed, SOCKS error 1\nConnection closed by UNKNOWN port 65535\n")), "Could not connect")
        XCTAssertEqual(Collector.explain(ProcessResult(status: 255, out: Data(), err: "user@host: Permission denied (publickey).\n")), "SSH key not accepted")
        XCTAssertEqual(Collector.explain(ProcessResult(status: 1, out: Data(), err: "", timedOut: true)), "Timed out")
        let r = Shell.run("/bin/cat", [], stdin: Data(repeating: 65, count: 3_000_000), timeout: 20)
        XCTAssertEqual(r.out.count, 3_000_000)
        XCTAssertTrue(Shell.run("/bin/sleep", ["5"], timeout: 0.3).timedOut)
    }

    func testSettingsRoundTripAndDefaults() throws {
        var s = AppSettings(); s.machines = [MachineConfig(name: "box", target: "box", options: "-p 22")]; s.menu = MenuPreset.all.blocks; s.warnAt = 70
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tach-\(UUID().uuidString).json")
        s.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), s)
        try Data("{\"warnAt\":60}".utf8).write(to: url)
        let d = AppSettings.load(from: url)
        XCTAssertEqual(d.warnAt, 60); XCTAssertEqual(MenuPreset.matching(d.menu), .quota); XCTAssertEqual(d.backfillDays, 30)
        XCTAssertNil(MenuPreset.matching(Array(MenuPreset.all.blocks.reversed())))
        // settings written before the icon option existed still load, with their blocks intact
        try Data("{\"menu\":[{\"kind\":\"limit\",\"account\":\"claude\",\"which\":\"week\",\"show\":\"ring\",\"range\":\"24h\",\"id\":\"8E0C1C1B-3C5E-4A53-9B62-6E5B8B0E2A11\"},{\"kind\":\"cost\"}]}".utf8).write(to: url)
        let old = AppSettings.load(from: url)
        XCTAssertEqual(old.menu.map(\.kind), [.limit, .cost]); XCTAssertEqual(old.menu[0].which, .week); XCTAssertFalse(old.menu[0].icon)
        XCTAssertEqual(MenuPreset.matching(MenuPreset.icons.blocks), .icons)
        XCTAssertTrue(MenuPreset.rings.blocks.allSatisfy { $0.which == .both && $0.show == .ring })
        // a block saved with the double-ring choice round-trips
        var two = AppSettings(); two.menu = [MenuBlock(.limit, account: "gemini", which: .both, show: .ring, icon: true)]
        two.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url).menu.first?.which, .both)
        XCTAssertTrue(MenuPreset.icons.blocks.allSatisfy(\.icon))
    }

    func testDemoDataIsCoherent() throws {
        let s = try tempStore()
        let now = DemoData.seed(s)
        let accts = s.accounts(now: now)
        XCTAssertEqual(accts.map(\.provider), [.claude, .openai, .gemini])
        let claude = accts[0]
        XCTAssertEqual(claude.plan, "Max 20x")
        XCTAssertEqual(claude.pools[0].session!.used, 81); XCTAssertEqual(claude.pools[0].session!.state, .warn)
        XCTAssertNotNil(claude.pools[0].session!.hitAt)
        XCTAssertEqual(claude.pools[0].session!.weekShare!, 6, accuracy: 0.01)
        XCTAssertEqual(claude.pools[0].scoped.map(\.label), ["Opus", "Fable"])
        // a busy afternoon must not be projected across the whole week
        XCTAssertEqual(claude.pools[0].week!.state, .ok); XCTAssertNil(claude.pools[0].week!.hitAt)
        XCTAssertEqual(claude.pools[0].scoped[0].state, .warn)
        XCTAssertEqual(accts[2].pools.map(\.name), ["Gemini models", "Claude and GPT models"])
        XCTAssertEqual(claude.credits!.amount, 41.2)
        XCTAssertNil(accts[1].pools[0].session)
        XCTAssertEqual(Set(accts[2].pools.compactMap(\.name)), ["Claude and GPT models", "Gemini models"])
        XCTAssertTrue(accts[2].isStale)
        XCTAssertEqual(accts[2].pools.first { $0.id.hasSuffix("3p") }!.session!.state, .idle)
        let all = accts.flatMap(\.windows).sorted(by: LimitMath.moreUrgent)
        XCTAssertEqual(all.first!.id, "claude|demo|five_hour")
        let u = s.usage(range: .h24, now: now)
        XCTAssertEqual(Set(u.models.map(\.id)), Set(ModelCatalog.frontierIDs))
        XCTAssertGreaterThan(u.cost, 0)
        XCTAssertEqual(u.byMachine.count, 3)
        XCTAssertEqual(s.windowPeaks(claude.pools[0].session!).count, 24)
        XCTAssertGreaterThan(s.trajectory(claude.pools[0].session!).count, 30)
    }
}
