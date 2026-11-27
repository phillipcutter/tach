import Foundation

/// One block of the menu bar item.
public struct MenuBlock: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case limit, reset, cost, tokens, tps, live }
    public enum Show: String, Codable, CaseIterable { case ringPct, ring, barPct, pct }
    /// `both` draws two rings: the week outside and the 5-hour session inside, where the subscription has one.
    public enum Which: String, Codable, CaseIterable { case tightest, session, week, both }

    public var id = UUID()
    public var kind: Kind
    /// "top" for whichever limit is tightest overall, or a provider id.
    public var account = "top"
    public var which: Which = .tightest
    public var show: Show = .ringPct
    public var range: RangeKey = .h24
    /// Limit blocks: show the subscription's app icon, inside the ring or before the figure.
    public var icon = false

    public init(_ kind: Kind, account: String = "top", which: Which = .tightest, show: Show = .ringPct, range: RangeKey = .h24, icon: Bool = false) {
        self.kind = kind; self.account = account; self.which = which; self.show = show; self.range = range; self.icon = icon
    }

    // Fields added after the first release are optional when reading, so older settings keep loading.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? "top"
        which = try c.decodeIfPresent(Which.self, forKey: .which) ?? .tightest
        show = try c.decodeIfPresent(Show.self, forKey: .show) ?? .ringPct
        range = try c.decodeIfPresent(RangeKey.self, forKey: .range) ?? .h24
        icon = try c.decodeIfPresent(Bool.self, forKey: .icon) ?? false
    }

    public var title: String {
        let who = Provider(rawValue: account)?.name ?? "Tightest"
        switch kind {
        case .limit: return "\(who) limit"
        case .reset: return "\(who) reset"
        case .cost: return "API value"
        case .tokens: return "Tokens"
        case .tps: return "Tokens per second"
        case .live: return "Live sessions"
        }
    }

    public static func describe(_ k: Kind) -> (name: String, detail: String) {
        switch k {
        case .limit: ("Limit", "How full one subscription’s limit is, as a ring, a bar or a figure.")
        case .reset: ("Reset countdown", "Time until a limit resets.")
        case .cost: ("API value", "What your usage would have cost at API prices.")
        case .tokens: ("Tokens", "Total tokens over a period.")
        case .tps: ("Tokens per second", "Live output speed across every machine.")
        case .live: ("Live sessions", "How many agent sessions are running now.")
        }
    }
}

public enum MenuPreset: String, CaseIterable, Identifiable {
    case quota, top, rings, icons, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .quota: "Three quotas and API value"
        case .top: "Tightest limit only"
        case .rings: "Three rings"
        case .icons: "Three app icons"
        case .all: "Everything"
        }
    }
    public var detail: String {
        switch self {
        case .quota: "Each subscription’s tightest limit, then what the last 24 hours would have cost through the API. The default."
        case .top: "One ring and one figure: the limit closest to running out."
        case .rings: "No figures. The week outside, the 5-hour session inside; colour tells you when to look."
        case .icons: "Each subscription’s app icon inside its ring, with the figure beside it."
        case .all: "Quotas, the next reset, API value and live speed."
        }
    }
    public var blocks: [MenuBlock] {
        let three = { (show: MenuBlock.Show) in Provider.allCases.map { MenuBlock(.limit, account: $0.rawValue, show: show) } }
        switch self {
        case .quota: return three(.ringPct) + [MenuBlock(.cost)]
        case .top: return [MenuBlock(.limit)]
        case .rings: return Provider.allCases.map { MenuBlock(.limit, account: $0.rawValue, which: .both, show: .ring) }
        case .icons: return Provider.allCases.map { MenuBlock(.limit, account: $0.rawValue, which: .both, show: .ringPct, icon: true) }
        case .all: return three(.ringPct) + [MenuBlock(.reset), MenuBlock(.cost), MenuBlock(.tps)]
        }
    }
    /// The preset a block list matches, ignoring ids.
    public static func matching(_ blocks: [MenuBlock]) -> MenuPreset? {
        func sig(_ b: [MenuBlock]) -> [String] { b.map { "\($0.kind)|\($0.account)|\($0.which)|\($0.show)|\($0.range)|\($0.icon)" } }
        return allCases.first { sig($0.blocks) == sig(blocks) }
    }
}

/// A remote machine reached over SSH.
public struct MachineConfig: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// What to pass to ssh: a host alias from ~/.ssh/config or user@host.
    public var target: String
    /// Extra ssh options, e.g. `-o 'ProxyCommand=nc -X 5 -x localhost:1055 %h %p'`.
    public var options = ""
    public var enabled = true

    public init(name: String, target: String, options: String = "", enabled: Bool = true) {
        self.name = name; self.target = target; self.options = options; self.enabled = enabled
    }
}

public struct AppSettings: Codable, Equatable {
    public var menu: [MenuBlock] = MenuPreset.quota.blocks
    public var machines: [MachineConfig] = []
    public var localName: String = Host.current().localizedName ?? "This Mac"
    public var warnAt: Double = 80
    public var critAt: Double = 95
    public var notifyThresholds = true
    public var notifyShort = true
    public var notifyReset = true
    public var notifyStale = false
    public var launchAtLogin = false
    public var onboarded = false
    public var panelRange: RangeKey = .h24
    public var backfillDays = 30
    public var priceOverrides: [String: Price] = [:]

    public init() {}

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        menu = try c.decodeIfPresent([MenuBlock].self, forKey: .menu) ?? def.menu
        machines = try c.decodeIfPresent([MachineConfig].self, forKey: .machines) ?? []
        localName = try c.decodeIfPresent(String.self, forKey: .localName) ?? def.localName
        warnAt = try c.decodeIfPresent(Double.self, forKey: .warnAt) ?? 80
        critAt = try c.decodeIfPresent(Double.self, forKey: .critAt) ?? 95
        notifyThresholds = try c.decodeIfPresent(Bool.self, forKey: .notifyThresholds) ?? true
        notifyShort = try c.decodeIfPresent(Bool.self, forKey: .notifyShort) ?? true
        notifyReset = try c.decodeIfPresent(Bool.self, forKey: .notifyReset) ?? true
        notifyStale = try c.decodeIfPresent(Bool.self, forKey: .notifyStale) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        panelRange = try c.decodeIfPresent(RangeKey.self, forKey: .panelRange) ?? .h24
        backfillDays = try c.decodeIfPresent(Int.self, forKey: .backfillDays) ?? 30
        priceOverrides = try c.decodeIfPresent([String: Price].self, forKey: .priceOverrides) ?? [:]
    }

    public var thresholds: Thresholds { Thresholds(warn: warnAt, crit: critAt) }
    public var prices: PriceTable { PriceTable(overrides: priceOverrides) }

    public static func load(from url: URL) -> AppSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    public func save(to url: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: url, options: .atomic) }
    }
}

/// Where Tach keeps its files. `TACH_HOME` overrides the default for tests and development.
public enum Paths {
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["TACH_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tach", isDirectory: true)
    }
    public static var database: URL { home.appendingPathComponent("tach.sqlite") }
    public static var settings: URL { home.appendingPathComponent("settings.json") }
    public static func ensure() { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
}
