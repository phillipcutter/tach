import Foundation

/// Counts of what one ingest wrote.
public struct IngestResult {
    public var requests = 0, turns = 0, limits = 0, sessions = 0
    public var cursor: String?
    public var logs: [(level: String, source: String, message: String)] = []
}

public struct MachineRow: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var kind: String  // local | ssh
    public var lastSeen: Date?
    public var lastError: String?
    public var collectorVersion: String?
}

public struct LimitSample: Equatable {
    public var provider, acct, window, kind, label: String
    public var group, groupLabel, plan, currency: String?
    public var used: Double
    public var resets: Date?
    public var length: TimeInterval
    public var limited: Bool
    public var amount, cap: Double?
    public var ts: Date
    public var src: String
}

public struct SessionRow: Identifiable, Equatable {
    public var id: String { "\(machineID)|\(tool)|\(sessionID)" }
    public var machineID: Int64
    public var machine: String
    public var tool, sessionID: String
    public var cwd, model: String?
    public var status: String
    public var started: Date?
    public var updated: Date
    public var ctx: Double?
    public var tokens: Int64?
}

/// Everything Tach keeps. One SQLite file; raw request events plus limit readings.
public final class Store {
    public let db: Database

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS machine (
          id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
          last_seen INTEGER, last_error TEXT, cursor TEXT, collector_version TEXT);
        CREATE TABLE IF NOT EXISTS request (
          tool TEXT NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL,
          machine_id INTEGER NOT NULL, mirror INTEGER NOT NULL DEFAULT 0,
          provider TEXT, model TEXT NOT NULL, pool TEXT, acct TEXT, session TEXT, cwd TEXT, sub INTEGER NOT NULL DEFAULT 0,
          tin INTEGER NOT NULL DEFAULT 0, cr INTEGER NOT NULL DEFAULT 0, cw5 INTEGER NOT NULL DEFAULT 0, cw1 INTEGER NOT NULL DEFAULT 0,
          tout INTEGER NOT NULL DEFAULT 0, think INTEGER NOT NULL DEFAULT 0,
          dur INTEGER, ttft INTEGER, tq TEXT NOT NULL DEFAULT 'none',
          stop TEXT, err TEXT, retries INTEGER NOT NULL DEFAULT 0, tier TEXT, speed TEXT, effort TEXT,
          PRIMARY KEY (tool, key)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS request_ts ON request(ts);
        CREATE TABLE IF NOT EXISTS turn (
          tool TEXT NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL, machine_id INTEGER NOT NULL,
          model TEXT, dur INTEGER, ttft INTEGER, tout INTEGER, status TEXT,
          PRIMARY KEY (tool, key)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS turn_ts ON turn(ts);
        CREATE TABLE IF NOT EXISTS limit_sample (
          provider TEXT NOT NULL, acct TEXT NOT NULL, window TEXT NOT NULL, ts INTEGER NOT NULL,
          used REAL NOT NULL, resets INTEGER, len INTEGER NOT NULL DEFAULT 0, limited INTEGER NOT NULL DEFAULT 0,
          kind TEXT NOT NULL, label TEXT NOT NULL, grp TEXT, grp_label TEXT, plan TEXT,
          amount REAL, cap REAL, currency TEXT, src TEXT NOT NULL,
          PRIMARY KEY (provider, acct, window, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS model_name (model TEXT PRIMARY KEY, name TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS session (
          machine_id INTEGER NOT NULL, tool TEXT NOT NULL, id TEXT NOT NULL,
          cwd TEXT, model TEXT, status TEXT NOT NULL, started INTEGER, updated INTEGER NOT NULL, ctx REAL, tokens INTEGER,
          PRIMARY KEY (machine_id, tool, id)) WITHOUT ROWID;
        """)
    }

    // MARK: meta

    public func meta(_ k: String) -> String? {
        var v: String?
        try? db.query("SELECT v FROM meta WHERE k=?", [.text(k)]) { v = $0.textOrNil(0) }
        return v
    }

    public func setMeta(_ k: String, _ v: String?) {
        try? db.run("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", [.text(k), .from(v)])
    }

    // MARK: machines

    @discardableResult
    public func ensureMachine(name: String, kind: String) throws -> Int64 {
        try db.run("INSERT INTO machine(name,kind) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET kind=excluded.kind", [.text(name), .text(kind)])
        return try db.scalarInt("SELECT id FROM machine WHERE name=?", [.text(name)]) ?? 0
    }

    public func renameMachine(id: Int64, to name: String) throws {
        try db.run("UPDATE machine SET name=? WHERE id=?", [.text(name), .int(id)])
    }

    public func machines() -> [MachineRow] {
        var out: [MachineRow] = []
        try? db.query("SELECT id,name,kind,last_seen,last_error,collector_version FROM machine ORDER BY kind, name") { r in
            out.append(MachineRow(id: r.int(0), name: r.text(1), kind: r.text(2),
                                  lastSeen: r.intOrNil(3).map(Date.init(ms:)), lastError: r.textOrNil(4), collectorVersion: r.textOrNil(5)))
        }
        return out
    }

    public func cursor(machine: Int64) -> String? {
        var v: String?
        try? db.query("SELECT cursor FROM machine WHERE id=?", [.int(machine)]) { v = $0.textOrNil(0) }
        return v
    }

    public func markMachine(id: Int64, seen: Date?, error: String?, version: String? = nil) {
        if let seen {
            try? db.run("UPDATE machine SET last_seen=?, last_error=?, collector_version=COALESCE(?,collector_version) WHERE id=?",
                        [.int(seen.ms), .from(error), .from(version), .int(id)])
        } else {
            try? db.run("UPDATE machine SET last_error=? WHERE id=?", [.from(error), .int(id)])
        }
    }

    // MARK: ingest

    /// Parses collector NDJSON and writes it in one transaction. When `saveCursor` is set, the
    /// cursor line is stored with the same commit, so a crash can never skip events.
    @discardableResult
    public func ingest(_ data: Data, machine: Int64, saveCursor: Bool = true) throws -> IngestResult {
        var res = IngestResult()
        let reqSQL = """
        INSERT INTO request(tool,key,ts,machine_id,mirror,provider,model,pool,acct,session,cwd,sub,tin,cr,cw5,cw1,tout,think,dur,ttft,tq,stop,err,retries,tier,speed,effort)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(tool,key) DO UPDATE SET
          ts=excluded.ts,
          machine_id=CASE WHEN request.mirror=1 AND excluded.mirror=0 THEN excluded.machine_id ELSE request.machine_id END,
          mirror=MIN(request.mirror, excluded.mirror),
          model=excluded.model, provider=COALESCE(excluded.provider,request.provider), pool=COALESCE(excluded.pool,request.pool),
          acct=COALESCE(excluded.acct,request.acct), session=COALESCE(excluded.session,request.session), cwd=COALESCE(excluded.cwd,request.cwd),
          sub=MAX(request.sub,excluded.sub),
          tin=MAX(request.tin,excluded.tin), cr=MAX(request.cr,excluded.cr), cw5=MAX(request.cw5,excluded.cw5), cw1=MAX(request.cw1,excluded.cw1),
          tout=MAX(request.tout,excluded.tout), think=MAX(request.think,excluded.think),
          dur=COALESCE(excluded.dur,request.dur), ttft=COALESCE(excluded.ttft,request.ttft),
          tq=CASE WHEN excluded.tq='none' THEN request.tq ELSE excluded.tq END,
          stop=COALESCE(excluded.stop,request.stop), err=COALESCE(excluded.err,request.err), retries=MAX(request.retries,excluded.retries),
          tier=COALESCE(excluded.tier,request.tier), speed=COALESCE(excluded.speed,request.speed), effort=COALESCE(excluded.effort,request.effort)
        """
        let turnSQL = """
        INSERT INTO turn(tool,key,ts,machine_id,model,dur,ttft,tout,status) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(tool,key) DO UPDATE SET ts=excluded.ts, model=COALESCE(excluded.model,turn.model), dur=COALESCE(excluded.dur,turn.dur),
          ttft=COALESCE(excluded.ttft,turn.ttft), tout=MAX(COALESCE(turn.tout,0),COALESCE(excluded.tout,0)), status=COALESCE(excluded.status,turn.status)
        """
        let limSQL = """
        INSERT OR REPLACE INTO limit_sample(provider,acct,window,ts,used,resets,len,limited,kind,label,grp,grp_label,plan,amount,cap,currency,src)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let sesSQL = """
        INSERT OR REPLACE INTO session(machine_id,tool,id,cwd,model,status,started,updated,ctx,tokens) VALUES(?,?,?,?,?,?,?,?,?,?)
        """
        var sawSession = false
        var names: [String: String] = [:]
        try db.transaction {
            let req = try db.statement(reqSQL), turn = try db.statement(turnSQL), lim = try db.statement(limSQL), ses = try db.statement(sesSQL)
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var start = 0
                let n = raw.count
                while start < n {
                    var end = start
                    while end < n && raw[end] != 0x0A { end += 1 }
                    defer { start = end + 1 }
                    guard end > start else { continue }
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!.advanced(by: start)), count: end - start, deallocator: .none)
                    guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let k = o["k"] as? String else { continue }
                    func s(_ key: String) -> String? { (o[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                    func i(_ key: String) -> Int64? { (o[key] as? NSNumber)?.int64Value }
                    func d(_ key: String) -> Double? { (o[key] as? NSNumber)?.doubleValue }
                    func b(_ key: String) -> Bool { (o[key] as? NSNumber)?.boolValue ?? false }
                    switch k {
                    case "req":
                        guard let tool = s("tool"), let key = s("key"), let ts = i("ts"), let model = s("model") else { continue }
                        try req.run([.text(tool), .text(key), .int(ts), .int(machine), .int(b("mirror") ? 1 : 0), .from(s("provider")), .text(model),
                                     .from(s("pool")), .from(s("acct")), .from(s("session")), .from(s("cwd")), .int(b("sub") ? 1 : 0),
                                     .int(i("in") ?? 0), .int(i("cr") ?? 0), .int(i("cw5") ?? 0), .int(i("cw1") ?? 0), .int(i("out") ?? 0), .int(i("think") ?? 0),
                                     .from(i("dur")), .from(i("ttft")), .text(s("tq") ?? "none"), .from(s("stop")), .from(s("err")), .int(i("retries") ?? 0),
                                     .from(s("tier")), .from(s("speed")), .from(s("effort"))])
                        res.requests += 1
                        if let n = s("name") { names[model] = n }
                    case "turn":
                        guard let tool = s("tool"), let key = s("key"), let ts = i("ts") else { continue }
                        try turn.run([.text(tool), .text(key), .int(ts), .int(machine), .from(s("model")), .from(i("dur")), .from(i("ttft")), .from(i("out")), .from(s("status"))])
                        res.turns += 1
                    case "limit":
                        guard let p = s("provider"), let w = s("window"), let ts = i("ts") else { continue }
                        try lim.run([.text(p), .text(s("acct") ?? ""), .text(w), .int(ts), .double(d("used") ?? 0), .from(i("resets")), .int(i("len") ?? 0),
                                     .int(b("limited") ? 1 : 0), .text(s("kind") ?? "weekly"), .text(s("label") ?? w), .from(s("group")), .from(s("group_label")),
                                     .from(s("plan")), .from(d("amount")), .from(d("cap")), .from(s("currency")), .text(s("src") ?? "")])
                        res.limits += 1
                    case "session":
                        guard let tool = s("tool"), let id = s("id"), let upd = i("updated") else { continue }
                        if !sawSession {
                            sawSession = true
                            try db.run("DELETE FROM session WHERE machine_id=?", [.int(machine)])
                        }
                        try ses.run([.int(machine), .text(tool), .text(id), .from(s("cwd")), .from(s("model")), .text(s("status") ?? "idle"),
                                     .from(i("started")), .int(upd), .from(d("ctx")), .from(i("tokens"))])
                        res.sessions += 1
                    case "cursor":
                        res.cursor = s("v")
                    case "log":
                        res.logs.append((s("level") ?? "info", s("src") ?? "", s("msg") ?? ""))
                    default: break
                    }
                }
            }
            for (m, n) in names {
                try db.run("INSERT INTO model_name(model,name) VALUES(?,?) ON CONFLICT(model) DO UPDATE SET name=excluded.name", [.text(m), .text(n)])
            }
            if saveCursor, let c = res.cursor {
                try db.run("UPDATE machine SET cursor=? WHERE id=?", [.text(c), .int(machine)])
            }
        }
        return res
    }

    // MARK: limits

    /// The newest reading of every window.
    public func latestLimits() -> [LimitSample] {
        var out: [LimitSample] = []
        let sql = """
        SELECT l.provider,l.acct,l.window,l.kind,l.label,l.grp,l.grp_label,l.plan,l.currency,l.used,l.resets,l.len,l.limited,l.amount,l.cap,l.ts,l.src
        FROM limit_sample l JOIN (SELECT provider,acct,window,MAX(ts) AS m FROM limit_sample GROUP BY provider,acct,window) x
          ON x.provider=l.provider AND x.acct=l.acct AND x.window=l.window AND x.m=l.ts
        """
        try? db.query(sql) { r in out.append(Self.sample(r)) }
        return out
    }

    /// Readings of one window since `since`, oldest first.
    public func limitHistory(provider: String, acct: String, window: String, since: Date) -> [LimitSample] {
        var out: [LimitSample] = []
        let sql = """
        SELECT provider,acct,window,kind,label,grp,grp_label,plan,currency,used,resets,len,limited,amount,cap,ts,src
        FROM limit_sample WHERE provider=? AND acct=? AND window=? AND ts>=? ORDER BY ts
        """
        try? db.query(sql, [.text(provider), .text(acct), .text(window), .int(since.ms)]) { r in out.append(Self.sample(r)) }
        return out
    }

    private static func sample(_ r: Row) -> LimitSample {
        LimitSample(provider: r.text(0), acct: r.text(1), window: r.text(2), kind: r.text(3), label: r.text(4),
                    group: r.textOrNil(5), groupLabel: r.textOrNil(6), plan: r.textOrNil(7), currency: r.textOrNil(8),
                    used: r.double(9), resets: r.intOrNil(10).map(Date.init(ms:)), length: TimeInterval(r.int(11)),
                    limited: r.int(12) != 0, amount: r.doubleOrNil(13), cap: r.doubleOrNil(14), ts: Date(ms: r.int(15)), src: r.text(16))
    }

    // MARK: sessions

    public func sessions(activeSince: Date) -> [SessionRow] {
        var out: [SessionRow] = []
        let sql = """
        SELECT s.machine_id,m.name,s.tool,s.id,s.cwd,s.model,s.status,s.started,s.updated,s.ctx,s.tokens
        FROM session s JOIN machine m ON m.id=s.machine_id WHERE s.updated>=? OR s.status='busy' ORDER BY (s.status='busy') DESC, s.updated DESC
        """
        try? db.query(sql, [.int(activeSince.ms)]) { r in
            out.append(SessionRow(machineID: r.int(0), machine: r.text(1), tool: r.text(2), sessionID: r.text(3), cwd: r.textOrNil(4), model: r.textOrNil(5),
                                  status: r.text(6), started: r.intOrNil(7).map(Date.init(ms:)), updated: Date(ms: r.int(8)), ctx: r.doubleOrNil(9), tokens: r.intOrNil(10)))
        }
        return out
    }

    /// Display names the tools use for their models, by raw model id.
    public func modelNames() -> [String: String] {
        var out: [String: String] = [:]
        try? db.query("SELECT model, name FROM model_name") { out[$0.text(0)] = $0.text(1) }
        return out
    }

    public func requestCount() -> Int64 { ((try? db.scalarInt("SELECT COUNT(*) FROM request")) ?? nil) ?? 0 }
    public func earliestRequest() -> Date? { ((try? db.scalarInt("SELECT MIN(ts) FROM request")) ?? nil).map(Date.init(ms:)) }
}

public extension Date {
    init(ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
    var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
