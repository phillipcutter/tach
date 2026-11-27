import AppKit
import SwiftUI
import TachCore

enum NavItem: String, CaseIterable, Identifiable {
    case overview, limits, models, machines, sessions, settings
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .limits: "circle.dotted.circle"
        case .models: "chart.bar"
        case .machines: "desktopcomputer"
        case .sessions: "list.bullet"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// What the views share: the engine plus what is selected in the panel and the window.
final class AppModel: ObservableObject {
    let engine: Engine

    // panel
    @Published var panelProvider: Provider?
    @Published var panelRow: String?
    @Published var panelHeight: CGFloat = 0

    // window
    @Published var nav: NavItem = .overview
    @Published var range: RangeKey = .h24 { didSet { engine.want(range) } }
    @Published var limitSelection: String?
    @Published var modelSelection: String?
    @Published var sessionFilter = "all"
    @Published var menuSelection: UUID?
    /// 0 = the menu bar item as configured; higher = shortened because the menu bar has no room for it.
    @Published var menuCompaction = 0

    // detail data, loaded off the main thread
    @Published var trajectory: [(Date, Double)] = []
    @Published var peaks: [(resets: Date, peak: Double, limited: Bool)] = []
    @Published var breakdown = ModelBreakdown()
    private var limitKey = "", modelKey = ""

    func loadLimit(_ w: LimitWindow, force: Bool = false) {
        guard force || limitKey != w.id else { return }
        if limitKey != w.id { trajectory = []; peaks = [] }
        limitKey = w.id
        engine.limitDetail(w) { [weak self] t, p in
            guard let self, self.limitKey == w.id else { return }
            self.trajectory = t; self.peaks = p
        }
    }

    func loadModel(_ id: String, force: Bool = false) {
        let key = id + "|" + range.rawValue
        guard force || modelKey != key else { return }
        if modelKey != key { breakdown = ModelBreakdown() }
        modelKey = key
        engine.breakdown(modelID: id, range: range) { [weak self] b in
            guard let self, self.modelKey == key else { return }
            self.breakdown = b
        }
    }

    var openWindow: (NavItem?) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var closePanel: () -> Void = {}

    init(engine: Engine) {
        self.engine = engine
        engine.want(.h24)
    }

    var now: Date { engine.now() }

    func panelOpened() {
        if panelProvider == nil || engine.account(panelProvider!) == nil { panelProvider = engine.tightest?.provider ?? engine.accounts.first?.provider }
        panelRow = nil
        engine.want(engine.settings.panelRange)
    }

    /// Colour for each model of a summary: its subscription's hue, lighter for later models.
    func colors(for models: [ModelUsage]) -> [String: Color] {
        var rank: [Provider?: Int] = [:], out: [String: Color] = [:]
        for m in models {
            let r = rank[m.info.provider, default: 0]
            out[m.id] = Theme.model(m.info, rank: r)
            rank[m.info.provider] = r + 1
        }
        return out
    }
}

// MARK: sentences about a limit

enum LimitText {
    static func headline(_ w: LimitWindow) -> (before: String, strong: String, after: String) {
        switch w.state {
        case .limited: return ("Limited for ", w.remaining.map(Fmt.duration) ?? "now", "")
        case .stale: return ("Last read ", Fmt.duration(w.readNow.timeIntervalSince(w.readAt)), " ago")
        case .idle: return ("Not started", "", "")
        default:
            if let s = w.shortBy { return ("Runs out ", Fmt.duration(s), " before reset") }
            return ("Safe through reset", "", "")
        }
    }

    static func short(_ w: LimitWindow, now: Date) -> String {
        switch w.state {
        case .stale: return "\(Fmt.pct(w.used)) used at \(Fmt.clock(w.readAt, now: now)) · open \(w.provider.tool.name) to refresh"
        case .idle: return "Starts with your next request"
        case .limited: return w.resets.map { "Resets \(Fmt.clock($0, now: now))" } ?? "Limit reached"
        default:
            let first = w.hitAt.map { "Limit at \(Fmt.clock($0, now: now))" } ?? "Ends at \(Fmt.pct(w.projected))"
            let reset = w.resets.map { " · resets \(Fmt.clock($0, now: now))" } ?? ""
            return first + reset + " · burning \(Fmt.rate(w.burnPerHour, weekly: w.isWeekly))"
        }
    }

    static func pace(_ w: LimitWindow) -> String? {
        w.pace.map { "\(Int(abs($0).rounded())) pts \($0 >= 0 ? "ahead of" : "behind") pace" }
    }

    /// A full sentence: "At this pace you hit the limit at 15:28, 56m before reset."
    static func verdict(_ w: LimitWindow, now: Date) -> String {
        switch w.state {
        case .stale: return "Last read \(Fmt.duration(now.timeIntervalSince(w.readAt))) ago. Open \(w.provider.tool.name) to refresh."
        case .idle: return "Not started. The window begins with your next request."
        case .limited: return "Limit reached." + (w.resets.map { " Resets \(Fmt.clock($0, now: now)), in \(Fmt.duration($0.timeIntervalSince(now)))." } ?? "")
        default:
            if let h = w.hitAt, let s = w.shortBy { return "At this pace you hit the limit at \(Fmt.clock(h, now: now)), \(Fmt.duration(s)) before reset." }
            return "Safe through reset. On pace to end at \(Fmt.pct(w.projected))."
        }
    }

    /// The name used under a ring and in lists: "5-hour session", "Gemini models, 5h".
    static func name(_ w: LimitWindow, in a: Account?) -> String {
        if let n = a?.pool(of: w)?.name { return "\(n), \(w.kind == .session ? "5h" : w.kind == .weekly ? "week" : w.label)" }
        return w.title
    }
}
