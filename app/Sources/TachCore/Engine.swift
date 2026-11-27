import Combine
import Foundation

public struct MachineStatus: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var isLocal: Bool
    public var online: Bool
    public var lastSeen: Date?
    public var error: String?
    public var live: Int
    public var tokensPerHour: Int64
    public var share: Double
    public var version: String?
    /// Its history is being read for the first time.
    public var reading = false
}

/// Collects on a timer, keeps the store current and publishes what the UI shows.
public final class Engine: ObservableObject {
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var machines: [MachineStatus] = []
    @Published public private(set) var sessions: [SessionRow] = []
    @Published public private(set) var usage: [RangeKey: UsageSummary] = [:]
    @Published public private(set) var liveTPS: Double = 0
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var refreshing = false
    /// Non-nil while the first import is running; a short description of progress.
    @Published public private(set) var importing: String?
    @Published public private(set) var notes: [String] = []
    @Published public private(set) var requestCount: Int64 = 0
    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            let s = settings
            if !demo { s.save(to: Paths.settings) }
            let further = s.backfillDays > oldValue.backfillDays
            queue.async {
                self.publish()
                if further, !self.demo { self.cycle(forceLimits: false) }   // reach back for the older history now
            }
        }
    }

    public let store: Store
    public let collector: Collector?
    public let demo: Bool
    /// Called on the main queue with the previous and new accounts whenever limits are recomputed.
    public var onLimits: (([Account], [Account]) -> Void)?
    /// The clock, replaceable so the demo data stays frozen at one moment.
    public var now: () -> Date = { Date() }

    private let queue = DispatchQueue(label: "tach.engine", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var wanted: Set<RangeKey> = []
    private var verified: Set<UUID> = []
    private var running = false
    /// Machines whose first import is in progress. Engine queue only.
    private var readingIDs: Set<Int64> = []

    public init(demo: Bool = ProcessInfo.processInfo.environment["TACH_DEMO"] == "1") throws {
        self.demo = demo
        if demo {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tach-demo-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try Store(path: dir.appendingPathComponent("demo.sqlite").path)
            var s = AppSettings(); s.onboarded = ProcessInfo.processInfo.environment["TACH_ONBOARD"] != "1"; s.localName = "macbook-pro"
            settings = s
            collector = nil
            let t = DemoData.seed(store)
            now = { t }
        } else {
            Paths.ensure()
            store = try Store(path: Paths.database.path)
            settings = AppSettings.load(from: Paths.settings)
            collector = Collector()
        }
    }

    public func start() {
        queue.async { self.publish() }
        guard !demo else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 60, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.cycle(forceLimits: false) }
        t.resume()
        timer = t
    }

    /// Collects now, including a fresh limits reading.
    public func refresh() {
        queue.async { self.demo ? self.publish() : self.cycle(forceLimits: true) }
    }

    /// Asks for a range to be kept up to date; computes it straight away.
    public func want(_ range: RangeKey) {
        queue.async {
            guard !self.wanted.contains(range) else { return }
            self.wanted.insert(range)
            let s = self.settingsCopy()
            let u = self.store.usage(range: range, now: self.now(), prices: s.prices)
            DispatchQueue.main.async { self.usage[range] = u }
        }
    }

    public func breakdown(modelID: String, range: RangeKey, _ done: @escaping (ModelBreakdown) -> Void) {
        queue.async {
            let b = self.store.breakdown(modelID: modelID, range: range, now: self.now())
            DispatchQueue.main.async { done(b) }
        }
    }

    public func limitDetail(_ w: LimitWindow, _ done: @escaping (_ trajectory: [(Date, Double)], _ peaks: [(resets: Date, peak: Double, limited: Bool)]) -> Void) {
        queue.async {
            let t = self.store.trajectory(w), p = self.store.windowPeaks(w)
            DispatchQueue.main.async { done(t, p) }
        }
    }

    private func settingsCopy() -> AppSettings {
        Thread.isMainThread ? settings : DispatchQueue.main.sync { settings }
    }

    // MARK: collection

    private let debug = ProcessInfo.processInfo.environment["TACH_DEBUG"] == "1"
    private let born = Date()
    private func log(_ s: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data(String(format: "[%6.1fs] %@\n", Date().timeIntervalSince(born), s()).utf8)) }
    }

    private func cycle(forceLimits: Bool) {
        guard !running else { return }
        running = true
        log("cycle \(tick) start")
        defer { running = false; tick += 1 }
        let s = settingsCopy()
        DispatchQueue.main.async { self.refreshing = true }
        var notes: [String] = []
        let localID = localMachineID(s.localName)
        let since = "\(max(s.backfillDays, 1) * 24)h"

        let days = s.backfillDays
        let span = Self.spanText(days)
        if let c = collector {
            var cur = store.cursor(machine: localID) ?? ""
            if needsOlderHistory(localID, cur, days) { cur = "" }
            if cur.isEmpty { DispatchQueue.main.async { self.importing = "Reading \(span) on this Mac" } }
            let r = c.local(["scan", "--cursor", "-", "--since", since], stdin: Data(cur.utf8), timeout: 1800)
            log("local scan done: \(r.out.count) bytes, ok=\(r.ok)")
            if r.ok, let res = try? store.ingest(r.out, machine: localID) {
                log("local ingest: \(res.requests) req, \(res.limits) limits, \(res.sessions) sessions")
                store.markMachine(id: localID, seen: now(), error: nil, version: Collector.version)
                store.setMeta("backfill:\(localID)", String(days))
                notes += res.logs.filter { $0.level != "info" }.map { "\($0.source): \($0.message)" }
            } else {
                store.markMachine(id: localID, seen: nil, error: r.timedOut ? "Scan timed out" : (r.err.isEmpty ? "Collector failed" : r.err))
            }
            if forceLimits || tick % 2 == 0 {
                let l = c.local(["limits"], timeout: 60)
                log("local limits done: \(l.out.count) bytes")
                if let res = try? store.ingest(l.out, machine: localID, saveCursor: false) {
                    notes += res.logs.filter { $0.level != "info" }.map { $0.message }
                }
            }
        } else {
            notes.append("The collector is missing from this copy of Tach.")
        }
        publish(notes: notes)

        // remotes: run concurrently; store and show each one as it finishes, so a slow or
        // unreachable machine never holds back the others
        let remotes = s.machines.filter { $0.enabled && !$0.target.isEmpty }
        if let c = collector, !remotes.isEmpty {
            let lock = NSLock(), done = DispatchSemaphore(value: 0)
            var results: [(MachineConfig, Int64, Result<Data, Error>)] = []
            var pending: [Int64: String] = [:]
            let withLimits = forceLimits || tick % 5 == 0
            let install = installID()
            readingIDs = []
            for m in remotes {
                guard let mid = try? store.ensureMachine(name: m.name, kind: "ssh") else { continue }
                let saved = store.cursor(machine: mid) ?? ""
                let again = needsOlderHistory(mid, saved, days)
                let cur = again ? "" : saved
                let needsCheck = !verified.contains(m.id) || tick % 30 == 0
                pending[mid] = m.name
                if cur.isEmpty { readingIDs.insert(mid) }
                DispatchQueue.global(qos: .utility).async {
                    var out: Result<Data, Error>
                    do {
                        if needsCheck { try c.ensureRemote(m) }
                        // The cursor stays on the remote (it lists every log file and runs to hundreds of KB);
                        // what travels is a short token confirming the previous scan was stored.
                        let commit = cur.isEmpty || cur.count > 64 ? "" : " --commit \(cur)"
                        // niced: a first scan reads gigabytes and the machine may be busy with real work
                        let cmd = "nice -n 19 \(Collector.remotePath) scan --state ~/.cache/tach --id \(install)\(commit)\(again ? " --reset" : "") --since \(since)" + (withLimits ? "; \(Collector.remotePath) limits" : "")
                        let r = c.ssh(m, cmd, timeout: 1800)
                        out = r.ok ? .success(r.out) : .failure(Collector.RemoteError(description: Collector.explain(r)))
                    } catch { out = .failure(error) }
                    self.log("remote \(m.name): \(out)".prefix(160).description)
                    lock.lock(); results.append((m, mid, out)); lock.unlock()
                    done.signal()
                }
            }
            func announce() {
                let names = pending.filter { readingIDs.contains($0.key) }.values.sorted()
                let text = names.isEmpty ? nil : "Reading \(span) on " + names.joined(separator: ", ")
                DispatchQueue.main.async { self.importing = text }
            }
            announce()
            publish(notes: notes)   // the machines appear straight away, marked as being read
            for _ in 0..<pending.count {
                done.wait()
                lock.lock(); let (m, mid, r) = results.removeFirst(); lock.unlock()
                switch r {
                case .success(let data):
                    if (try? store.ingest(data, machine: mid)) != nil {
                        store.markMachine(id: mid, seen: now(), error: nil, version: Collector.version)
                        store.setMeta("backfill:\(mid)", String(days))
                        verified.insert(m.id)
                    }
                case .failure(let e):
                    store.markMachine(id: mid, seen: nil, error: String(describing: e))
                    verified.remove(m.id)
                }
                pending[mid] = nil
                readingIDs.remove(mid)
                announce()
                publish(notes: notes)
            }
        }
        log("cycle end")
        DispatchQueue.main.async { self.refreshing = false; self.importing = nil }
    }

    /// "the last 30 days", or "all history" once the period is longer than anyone's logs.
    public static func spanText(_ days: Int) -> String { days >= 3650 ? "all history" : "the last \(days) days" }

    /// True when a machine was imported with a shorter history than is now asked for, so its logs
    /// must be read again from the start. Storing is idempotent, so re-reading only adds what is missing.
    private func needsOlderHistory(_ machine: Int64, _ cursor: String, _ days: Int) -> Bool {
        guard !cursor.isEmpty else { return false }   // never imported: the coming scan is a full one anyway
        let had = Int(store.meta("backfill:\(machine)") ?? "") ?? 30
        return days > had
    }

    /// Identifies this copy of the database to remote collectors, so each keeps a cursor for it.
    private func installID() -> String {
        if let v = store.meta("install_id"), !v.isEmpty { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        store.setMeta("install_id", v)
        return v
    }

    /// The local machine keeps its row when the user renames it.
    private func localMachineID(_ name: String) -> Int64 {
        if let v = store.meta("local_machine"), let id = Int64(v) {
            try? store.renameMachine(id: id, to: name)
            return id
        }
        let id = (try? store.ensureMachine(name: name, kind: "local")) ?? 1
        store.setMeta("local_machine", String(id))
        return id
    }

    // MARK: snapshot

    private func publish(notes: [String]? = nil) {
        ModelCatalog.learn(store.modelNames())
        log("publish start")
        defer { log("publish end") }
        let s = settingsCopy(), t = now()
        let accounts = store.accounts(now: t, thresholds: s.thresholds)
        let sessions = store.sessions(activeSince: t.addingTimeInterval(-24 * 3600))
        let rates = store.machineRates(now: t)
        let totalRate = max(rates.values.reduce(0, +), 1)
        let configured = Set(s.machines.filter(\.enabled).map(\.name))
        let machines: [MachineStatus] = store.machines().compactMap { m in
            let isLocal = m.kind == "local"
            guard isLocal || configured.contains(m.name) || demo else { return nil }
            let fresh = m.lastSeen.map { t.timeIntervalSince($0) < 5 * 60 } ?? false
            let live = sessions.filter { $0.machineID == m.id && ($0.status == "busy" || t.timeIntervalSince($0.updated) < 5 * 60) }.count
            return MachineStatus(id: m.id, name: m.name, isLocal: isLocal, online: isLocal ? true : (fresh && m.lastError == nil), lastSeen: m.lastSeen,
                                 error: m.lastError, live: live, tokensPerHour: rates[m.id] ?? 0, share: Double(rates[m.id] ?? 0) / Double(totalRate), version: m.collectorVersion, reading: readingIDs.contains(m.id))
        }.sorted { ($0.isLocal ? 0 : 1, $0.online ? 0 : 1, -$0.tokensPerHour, $0.name) < ($1.isLocal ? 0 : 1, $1.online ? 0 : 1, -$1.tokensPerHour, $1.name) }
        var ranges = wanted
        ranges.insert(s.panelRange)
        for b in s.menu where b.kind == .cost || b.kind == .tokens { ranges.insert(b.range) }
        wanted = ranges
        var usage: [RangeKey: UsageSummary] = [:]
        for r in ranges { usage[r] = store.usage(range: r, now: t, prices: s.prices) }
        let tps = store.throughput(now: t), count = store.requestCount()
        DispatchQueue.main.async {
            let old = self.accounts
            self.accounts = accounts
            self.machines = machines
            self.sessions = sessions
            self.usage = usage
            self.liveTPS = tps
            self.requestCount = count
            self.updatedAt = t
            if let notes { self.notes = notes }
            self.onLimits?(old, accounts)
        }
    }

    // MARK: derived helpers for views

    public var allWindows: [LimitWindow] { accounts.flatMap(\.windows).sorted(by: LimitMath.moreUrgent) }
    /// The limit most at risk across every account.
    public var tightest: LimitWindow? { allWindows.first }
    public func account(_ p: Provider) -> Account? { accounts.first { $0.provider == p } }
    public var liveSessions: [SessionRow] {
        let t = now()
        return sessions.filter { $0.status == "busy" || t.timeIntervalSince($0.updated) < 5 * 60 }
    }
}
