import Foundation

/// A notification to post. `key` identifies it so the same one is never posted twice.
public struct LimitAlert: Equatable {
    public var title: String
    public var body: String
    public var key: String
}

/// Decides which notifications a change in limits calls for.
public enum LimitAlerts {
    static func clock(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    static func span(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded()), 0)
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
        return "\(max(s / 60, 1))m"
    }

    static func name(_ w: LimitWindow, in a: Account) -> String {
        let pool = a.pool(of: w)?.name.map { $0 + " " } ?? ""
        let kind: String
        switch w.kind {
        case .session: kind = "5-hour"
        case .weekly: kind = "weekly"
        case .weeklyScoped: kind = "weekly \(w.label)"
        case .credits: kind = "credits"
        }
        return "\(w.provider.name) \(pool)\(kind) limit"
    }

    /// Compares two readings of every limit. Nothing is raised on the first reading, for stale
    /// readings, or across a reset (the percentage falling is not a threshold being crossed).
    public static func events(old: [Account], new: [Account], settings s: AppSettings, now: Date) -> [LimitAlert] {
        guard !old.isEmpty else { return [] }
        let before = Dictionary(old.flatMap(\.windows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [LimitAlert] = []
        for a in new {
            for w in a.windows {
                guard let o = before[w.id] else { continue }
                let label = name(w, in: a)
                let instance = "\(w.id)|\(Int((w.resets ?? o.resets ?? now).timeIntervalSince1970 / 120))"
                let same = w.resets != nil && o.resets != nil && abs(w.resets!.timeIntervalSince(o.resets!)) < 120
                if s.notifyThresholds, same, w.state != .stale, o.state != .stale {
                    // only the highest threshold crossed in this step
                    if let t = [s.critAt, s.warnAt].first(where: { o.used < $0 && w.used >= $0 }) {
                        var body = "Resets \(w.resets.map { clock($0, now: now) } ?? "later")."
                        if let h = w.hitAt, let short = w.shortBy { body = "At this pace you hit the limit at \(clock(h, now: now)), \(span(short)) before it resets." }
                        out.append(LimitAlert(title: "\(label) at \(Int(w.used.rounded()))%", body: body, key: "\(instance)|\(Int(t))"))
                    }
                }
                if s.notifyShort, same, o.hitAt == nil, w.state == .warn || w.state == .crit, let h = w.hitAt, let short = w.shortBy, short > 10 * 60 {
                    out.append(LimitAlert(title: "\(label) will run out early", body: "On pace to hit the limit \(clock(h, now: now)), \(span(short)) before it resets.", key: instance + "|short"))
                }
                if s.notifyReset, o.state == .limited, w.state != .limited, w.state != .stale {
                    out.append(LimitAlert(title: "\(label) has reset", body: "You can use it again.", key: "\(w.id)|reset|\(Int(now.timeIntervalSince1970 / 600))"))
                }
            }
        }
        return out
    }
}
