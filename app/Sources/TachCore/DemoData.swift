import Foundation

/// Sample data for `TACH_DEMO=1`: every limit state and a month of usage, frozen at one moment.
/// It goes through the same ingest path as real collector output.
public enum DemoData {
    public static let moment: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 25; c.hour = 14; c.minute = 36
        return Calendar.current.date(from: c) ?? Date()
    }()

    private struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) & 0xFFFFFF) / Double(0x1000000) } }

    @discardableResult
    public static func seed(_ store: Store) -> Date {
        let now = moment, nowMS = now.ms
        var rng = RNG(s: 42)
        let names = ["macbook-pro", "devbox", "buildbox", "homelab"]
        var ids: [Int64] = []
        for (i, n) in names.enumerated() { ids.append((try? store.ensureMachine(name: n, kind: i == 0 ? "local" : "ssh")) ?? Int64(i + 1)) }
        store.setMeta("local_machine", String(ids[0]))
        store.markMachine(id: ids[0], seen: now, error: nil, version: Collector.version)
        store.markMachine(id: ids[1], seen: now.addingTimeInterval(-20), error: nil, version: Collector.version)
        store.markMachine(id: ids[2], seen: now.addingTimeInterval(-41), error: nil, version: Collector.version)
        store.markMachine(id: ids[3], seen: now.addingTimeInterval(-9.2 * 3600), error: nil, version: "0.0.9")
        store.markMachine(id: ids[3], seen: nil, error: "Connection timed out")

        // model, tool, pool, requests/day, [in, cr, cw5, cw1, out] per request, ttft s, tok/s, timing
        let models: [(String, String, String, Double, [Double], Double, Double, String)] = [
            ("claude-opus-5-5", "claude_code", "claude", 9800, [900, 41000, 800, 2600, 1050], 1.04, 121, "est"),
            ("claude-mythos-5-2", "claude_code", "claude", 5200, [700, 35000, 600, 2500, 1200], 0.92, 102, "est"),
            ("claude-fable-5-2", "claude_code", "claude", 3100, [500, 31000, 500, 2200, 900], 0.66, 114, "est"),
            ("gpt-6.2-astra", "codex", "openai", 2900, [7000, 44000, 0, 0, 2400], 2.5, 72, "none"),
            ("gpt-6.2-sol", "codex", "openai", 1400, [5000, 24000, 0, 0, 1900], 1.4, 143, "none"),
            ("gemini-4-neon", "antigravity", "gemini", 1320, [4700, 49000, 0, 0, 2750], 7.2, 200, "exact"),
        ]
        // hour-of-day activity shape and each machine's share
        let shape: [Double] = [0.5, 0.25, 0.06, 0.04, 0.04, 0.05, 0.1, 0.3, 0.7, 1.0, 1.2, 1.1, 0.8, 1.0, 1.3, 1.2, 1.1, 0.9, 0.7, 0.8, 1.0, 1.1, 0.9, 0.7]
        let machineShare: [Double] = [0.47, 0.36, 0.17, 0]
        let scale = 0.1  // one stored row stands for ten requests, to keep the demo database small
        var lines: [[String]] = Array(repeating: [], count: 4)
        let hours = 30 * 24
        let cal = Calendar.current
        for h in 0..<hours {
            let t0 = nowMS - Int64(h + 1) * 3_600_000
            let hod = cal.component(.hour, from: Date(ms: t0))
            let dayJitter = 0.6 + 0.8 * rng.next()
            for (mi, m) in models.enumerated() {
                // Antigravity has been closed for three hours
                if m.1 == "antigravity" && h < 3 { continue }
                let expect = m.3 / 24 * shape[hod] * dayJitter * scale
                let n = Int(expect) + (rng.next() < expect - Double(Int(expect)) ? 1 : 0)
                for k in 0..<n {
                    let r = rng.next()
                    let mach = r < machineShare[0] ? 0 : r < machineShare[0] + machineShare[1] ? 1 : 2
                    let ts = t0 + Int64(rng.next() * 3_600_000)
                    let j = 0.5 + rng.next()
                    let f = { (x: Double) in Int64(x * j / scale) }
                    let ttft = Int64(m.5 * (0.5 + rng.next() * 1.4) * 1000)
                    let out = max(f(m.4[4]), 1)
                    let dur = ttft + Int64(Double(out) / (m.6 * (0.7 + 0.6 * rng.next())) * 1000)
                    var o = "{\"k\":\"req\",\"tool\":\"\(m.1)\",\"key\":\"demo-\(mi)-\(h)-\(k)\",\"ts\":\(ts),\"model\":\"\(m.0)\",\"pool\":\"\(m.2)\","
                    o += "\"session\":\"s\(mach)\(mi)\",\"in\":\(f(m.4[0])),\"cr\":\(f(m.4[1])),\"cw5\":\(f(m.4[2])),\"cw1\":\(f(m.4[3])),\"out\":\(out),\"think\":\(out / 3),"
                    o += "\"effort\":\"\(rng.next() < 0.7 ? "high" : "medium")\",\"speed\":\"\(rng.next() < 0.9 ? "standard" : "fast")\"" + (rng.next() < 0.25 ? ",\"sub\":true" : "")
                    if m.7 != "none" { o += ",\"dur\":\(dur),\"ttft\":\(ttft),\"tq\":\"\(m.7)\"" } else { o += ",\"tq\":\"none\"" }
                    if rng.next() < 0.004 { o += ",\"err\":\"overloaded\"" }
                    lines[mach].append(o + "}")
                    if m.1 == "codex" && k % 3 == 0 {
                        lines[mach].append("{\"k\":\"turn\",\"tool\":\"codex\",\"key\":\"t-\(mi)-\(h)-\(k)\",\"ts\":\(ts),\"model\":\"\(m.0)\",\"dur\":\(dur * 6),\"ttft\":\(ttft),\"out\":\(out)}")
                    }
                }
            }
        }

        // limits: a rising 5-hour session, a week with two model rows, credits; one OpenAI week; two stale Gemini budgets
        var lim: [String] = []
        func limit(_ p: String, _ plan: String, _ window: String, _ kind: String, _ label: String, group: String = "", groupLabel: String = "",
                   used: Double, resetsIn: Double?, len: Double, ago: Double, src: String = "endpoint", extra: String = "") {
            let ts = nowMS - Int64(ago * 1000)
            var o = "{\"k\":\"limit\",\"provider\":\"\(p)\",\"acct\":\"demo\",\"plan\":\"\(plan)\",\"window\":\"\(window)\",\"kind\":\"\(kind)\",\"label\":\"\(label)\","
            if !group.isEmpty { o += "\"group\":\"\(group)\",\"group_label\":\"\(groupLabel)\"," }
            o += "\"used\":\(used),\"len\":\(Int64(len)),\"ts\":\(ts),\"src\":\"\(src)\""
            if let r = resetsIn { o += ",\"resets\":\(nowMS + Int64(r * 1000))" }
            lim.append(o + extra + "}")
        }
        let h5 = 5.0 * 3600, wk = 7.0 * 86400
        // Claude: session began 3h12m ago, week 4d5h36m ago
        let sessElapsed = 192.0 * 60, weekLeft = (2 * 24 + 18) * 3600.0
        for i in stride(from: 0, through: 38, by: 1) {
            let ago = Double(38 - i) * 300          // every 5 minutes back to the session start
            let frac = (sessElapsed - ago) / sessElapsed
            let u = max(0, 81 * pow(frac, 1.12))
            limit("claude", "Max 20x", "five_hour", "session", "5-hour", used: (u * 10).rounded() / 10, resetsIn: h5 - sessElapsed, len: h5, ago: ago)
            limit("claude", "Max 20x", "weekly", "weekly", "Week", used: (48 + 6 * frac).rounded(), resetsIn: weekLeft, len: wk, ago: ago)
        }
        for d in 1...4 {
            limit("claude", "Max 20x", "weekly", "weekly", "Week", used: 48 - Double(d) * 11.5, resetsIn: weekLeft, len: wk, ago: sessElapsed + Double(d) * 86400)
            limit("claude", "Max 20x", "weekly:opus", "weekly_scoped", "Opus", used: 71 - Double(d) * 16.8, resetsIn: weekLeft, len: wk, ago: Double(d) * 86400)
            limit("claude", "Max 20x", "weekly:fable", "weekly_scoped", "Fable", used: 23 - Double(d) * 5, resetsIn: weekLeft, len: wk, ago: Double(d) * 86400)
        }
        limit("claude", "Max 20x", "weekly:opus", "weekly_scoped", "Opus", used: 71, resetsIn: weekLeft, len: wk, ago: 0)
        limit("claude", "Max 20x", "weekly:fable", "weekly_scoped", "Fable", used: 23, resetsIn: weekLeft, len: wk, ago: 0)
        limit("claude", "Max 20x", "credits", "credits", "Extra usage credits", used: 58.8, resetsIn: 6 * 86400, len: 30 * 86400, ago: 0,
              extra: ",\"amount\":41.2,\"cap\":100,\"currency\":\"USD\"")
        // past 5-hour windows for the history chart
        let peaks: [Double] = [61, 48, 100, 34, 70, 88, 54, 12, 66, 92, 41, 57, 100, 77, 35, 44, 82, 63, 22, 72, 90, 56, 64]
        for (i, p) in peaks.enumerated() {
            let back = Double(peaks.count - i) * h5 + sessElapsed
            limit("claude", "Max 20x", "five_hour", "session", "5-hour", used: p, resetsIn: -back + h5, len: h5, ago: back - h5 + 60, extra: p >= 100 ? ",\"limited\":true" : "")
        }
        let oaLeft = (4 * 24 + 9) * 3600.0
        for d in 0...2 {
            limit("openai", "ChatGPT Pro", "weekly", "weekly", "Week", used: 31 - Double(d) * 11.9, resetsIn: oaLeft, len: wk, ago: Double(d) * 86400, src: "rollout")
        }
        let stale = 3.0 * 3600
        limit("gemini", "Google AI Ultra", "gemini:five_hour", "session", "5-hour", group: "gemini", groupLabel: "Gemini models", used: 44, resetsIn: 16 * 60, len: h5, ago: stale, src: "rpc")
        limit("gemini", "Google AI Ultra", "gemini:weekly", "weekly", "Week", group: "gemini", groupLabel: "Gemini models", used: 38, resetsIn: 26 * 3600, len: wk, ago: stale, src: "rpc")
        limit("gemini", "Google AI Ultra", "gemini:weekly", "weekly", "Week", group: "gemini", groupLabel: "Gemini models", used: 36, resetsIn: 26 * 3600, len: wk, ago: stale + 4.6 * 3600, src: "rpc")
        limit("gemini", "Google AI Ultra", "3p:five_hour", "session", "5-hour", group: "3p", groupLabel: "Claude and GPT models", used: 0, resetsIn: nil, len: h5, ago: stale, src: "rpc")
        limit("gemini", "Google AI Ultra", "3p:weekly", "weekly", "Week", group: "3p", groupLabel: "Claude and GPT models", used: 12, resetsIn: 92 * 3600, len: wk, ago: stale, src: "rpc")
        lines[0] += lim

        // sessions
        let sess: [(Int, String, String, String, String, Double, Double, Double)] = [
            (0, "claude_code", "menubar-app", "claude-opus-5-5", "busy", 102, 64, 1),
            (1, "claude_code", "atlas-api", "claude-mythos-5-2", "busy", 185, 82, 2),
            (0, "codex", "ingest-worker", "gpt-6.2-astra", "busy", 43, 41, 1),
            (1, "codex", "docs-site", "gpt-6.2-sol", "idle", 71, 23, 3),
            (2, "claude_code", "billing-jobs", "claude-fable-5-2", "busy", 16, 12, 1),
            (0, "antigravity", "design-system", "gemini-4-neon", "idle", 228, 57, 184),
        ]
        for s in sess {
            lines[s.0].append("{\"k\":\"session\",\"tool\":\"\(s.1)\",\"id\":\"\(s.2)\",\"cwd\":\"/Users/demo/code/\(s.2)\",\"model\":\"\(s.3)\",\"status\":\"\(s.4)\",\"started\":\(nowMS - Int64(s.5 * 60_000)),\"updated\":\(nowMS - Int64(s.7 * 60_000)),\"ctx\":\(s.6)}")
        }
        for i in 0..<3 {
            _ = try? store.ingest(Data(lines[i].joined(separator: "\n").utf8), machine: ids[i], saveCursor: false)
        }
        return now
    }
}
