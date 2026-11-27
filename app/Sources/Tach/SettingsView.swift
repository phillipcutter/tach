import ServiceManagement
import SwiftUI
import TachCore

private struct FrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// A stand-in for the right end of the menu bar, with the item in place at real size.
struct MenuBarStrip: View {
    let blocks: [MenuBlock]
    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            MenuItemView(blocks: blocks)
            Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Image(systemName: "switch.2")
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 24)
        .background(LinearGradient(colors: [Color(hex: 0x3C5871), Color(hex: 0x1B2A3A)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }
}

/// Edits the menu bar item in place: drag blocks to reorder, drag one out to remove it,
/// drag a new one in from the palette.
struct MenuBarEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    @State private var frames: [UUID: CGRect] = [:]
    @State private var strip: CGRect = .zero
    @State private var dragging: UUID?
    @State private var newKind: MenuBlock.Kind?
    @State private var offset: CGSize = .zero
    @State private var insertAt: Int?
    @State private var outside = false
    @State private var width: CGFloat = 0
    private let zoom: CGFloat = 2

    private var blocks: [MenuBlock] { engine.settings.menu }
    private var selected: MenuBlock? { blocks.first { $0.id == model.menuSelection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                MenuBarStrip(blocks: blocks)
                stripView
                HStack {
                    Text("Drag blocks to reorder them. Drag one out of the bar to remove it.")
                    Spacer()
                    Text("Width in the menu bar"); Text("\(Int(width.rounded())) pt").font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.ink)
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).padding(.horizontal, 12).frame(height: 32)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
                if model.menuCompaction > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                        Text("The menu bar has no room for this at the moment, so Tach is showing a shorter version:")
                        MenuItemView(blocks: compactMenu(blocks, level: model.menuCompaction)).foregroundStyle(.white)
                        Spacer()
                    }
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.ink2).padding(.horizontal, 12).frame(height: 32)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
                }
            }
            .background(Color.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair, lineWidth: 1))
            .background(MenuItemView(blocks: blocks).hidden().background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, n in width = n } }))
            HStack(alignment: .top, spacing: 24) {
                palette.frame(maxWidth: .infinity, alignment: .topLeading).zIndex(newKind != nil ? 2 : 0)
                inspector.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 6) {
                Text("Start from").font(Theme.ui(12)).foregroundStyle(Theme.ink3)
                let current = MenuPreset.matching(blocks)
                ForEach(MenuPreset.allCases) { p in
                    PillButton(title: p.title, small: true) { engine.settings.menu = p.blocks; model.menuSelection = engine.settings.menu.first?.id }
                        .overlay(Capsule().strokeBorder(current == p ? Theme.accent : .clear, lineWidth: 1.5))
                }
            }
        }
        .onAppear { if selected == nil { model.menuSelection = blocks.first?.id } }
    }

    // MARK: the editable strip

    private var stripView: some View {
        ZStack {
            HStack(spacing: 4) {
                if blocks.isEmpty { Text("Drag a block here").font(Theme.ui(12)).foregroundStyle(Theme.ink3) }
                ForEach(blocks) { b in
                    let on = b.id == model.menuSelection, isDragging = dragging == b.id
                    MenuBlockView(block: b, scale: zoom)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.fill2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Theme.accent : .clear, lineWidth: 1.5))
                        .background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: [b.id: g.frame(in: .global)]) })
                        .contentShape(Rectangle())
                        .opacity(isDragging && outside ? 0.35 : 1)
                        .offset(isDragging ? offset : .zero)
                        .zIndex(isDragging ? 2 : 0)
                        .onTapGesture { model.menuSelection = b.id }
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { v in dragging = b.id; model.menuSelection = b.id; offset = v.translation; track(v.location, moving: b.id) }
                            .onEnded { v in drop(v.location, moving: b.id) })
                        .accessibilityLabel(b.title)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            if let x = caretX {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2, height: 56).position(x: x - strip.minX, y: strip.height / 2).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(insertAt != nil ? Theme.accent.opacity(0.08) : .clear)
        .background(GeometryReader { g in Color.clear.onAppear { strip = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, n in strip = n } })
        .onPreferenceChange(FrameKey.self) { frames = $0 }
        .environment(\.colorScheme, .dark)
    }

    /// Frames of the blocks other than the one being moved, left to right.
    private func others(_ moving: UUID?) -> [CGRect] { blocks.filter { $0.id != moving }.compactMap { frames[$0.id] } }

    private var caretX: CGFloat? {
        guard let i = insertAt else { return nil }
        let o = others(dragging)
        if i < o.count { return o[i].minX - 2 }
        return (o.last?.maxX ?? strip.midX) + 2
    }

    private func track(_ p: CGPoint, moving: UUID?) {
        let inside = strip.insetBy(dx: -12, dy: -12).contains(p)
        outside = !inside
        guard inside else { insertAt = nil; return }
        let o = others(moving)
        insertAt = o.firstIndex { p.x < $0.midX } ?? o.count
    }

    private func drop(_ p: CGPoint, moving id: UUID) {
        track(p, moving: id)
        var m = engine.settings.menu
        if let from = m.firstIndex(where: { $0.id == id }) {
            let b = m.remove(at: from)
            if let i = insertAt { m.insert(b, at: min(i, m.count)) } else { if model.menuSelection == id { model.menuSelection = m.first?.id } }
        }
        engine.settings.menu = m
        dragging = nil; offset = .zero; insertAt = nil; outside = false
    }

    // MARK: palette

    private var palette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a block").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(MenuBlock.Kind.allCases, id: \.self) { k in
                    let d = MenuBlock.describe(k), isNew = newKind == k
                    VStack(spacing: 8) {
                        MenuBlockView(block: MenuBlock(k), scale: 1.3).foregroundStyle(.white)
                        Text(d.name).font(Theme.ui(11.5, .medium)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 68).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(isNew ? Theme.fill3 : Theme.fill1))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair, lineWidth: 1))
                    .contentShape(Rectangle())
                    .offset(isNew ? offset : .zero)
                    .zIndex(isNew ? 2 : 0)
                    .help(d.detail)
                    .onTapGesture { add(k, at: nil) }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { v in newKind = k; offset = v.translation; track(v.location, moving: nil) }
                        .onEnded { v in
                            track(v.location, moving: nil)
                            if let i = insertAt { add(k, at: i) }
                            newKind = nil; offset = .zero; insertAt = nil; outside = false
                        })
                    .accessibilityLabel("Add \(d.name)")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .environment(\.colorScheme, .dark)
            Text("Drag one into the bar, or click to add it at the end.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
        }
    }

    private func add(_ k: MenuBlock.Kind, at i: Int?) {
        let b = MenuBlock(k)
        var m = engine.settings.menu
        m.insert(b, at: min(i ?? m.count, m.count))
        engine.settings.menu = m
        model.menuSelection = b.id
        if k == .cost || k == .tokens { engine.want(b.range) }
    }

    // MARK: inspector

    private func bind<T>(_ kp: WritableKeyPath<MenuBlock, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { selected?[keyPath: kp] ?? fallback }, set: { v in
            guard let i = engine.settings.menu.firstIndex(where: { $0.id == model.menuSelection }) else { return }
            engine.settings.menu[i][keyPath: kp] = v
            if let r = v as? RangeKey { engine.want(r) }
        })
    }

    private func option<T: Hashable>(_ label: String, _ options: [(T, String)], _ b: Binding<T>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.ink2).frame(width: 86, alignment: .leading)
            Segmented(options: options, selection: b)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected block").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink2)
            if let s = selected {
                Text(s.title).font(Theme.ui(13, .semibold))
                Text(MenuBlock.describe(s.kind).detail).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
                if s.kind == .limit || s.kind == .reset {
                    option("Subscription", [("top", "Tightest")] + Provider.allCases.map { ($0.rawValue, $0.name) }, bind(\.account, "top"))
                }
                if s.kind == .limit {
                    option("Limit", [(MenuBlock.Which.tightest, "Tightest"), (.session, "5-hour"), (.week, "Week"), (.both, "Both rings")], bind(\.which, .tightest))
                    if s.which == .both {
                        Text(s.show == .ring || s.show == .ringPct ? "Outer ring is the week, inner ring the 5-hour session. A subscription with no 5-hour limit shows one ring." : "Both rings need “Ring” or “Ring + %” below.")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true).padding(.leading, 94)
                    }
                    option("Show as", [(MenuBlock.Show.ringPct, "Ring + %"), (.ring, "Ring"), (.barPct, "Bar + %"), (.pct, "% only")], bind(\.show, .ringPct))
                    option("App icon", [(false, "Off"), (true, s.show == .ring || s.show == .ringPct ? "Inside the ring" : "Before the figure")], bind(\.icon, false))
                }
                if s.kind == .cost || s.kind == .tokens {
                    option("Period", [(RangeKey.h1, "1h"), (.h24, "24h"), (.d7, "7d"), (.d30, "30d")], bind(\.range, .h24))
                }
                if s.kind == .tps || s.kind == .live { Text("This block has no options.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3) }
                let i = blocks.firstIndex { $0.id == s.id } ?? 0
                HStack(spacing: 6) {
                    PillButton(title: "Move left", small: true) { move(-1) }.disabled(i == 0).opacity(i == 0 ? 0.4 : 1)
                    PillButton(title: "Move right", small: true) { move(1) }.disabled(i >= blocks.count - 1).opacity(i >= blocks.count - 1 ? 0.4 : 1)
                    Spacer()
                    PillButton(title: "Remove", small: true) {
                        engine.settings.menu.removeAll { $0.id == s.id }
                        model.menuSelection = engine.settings.menu.first?.id
                    }
                }.padding(.top, 4)
            } else {
                Text("Select a block in the bar to change what it shows.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func move(_ d: Int) {
        var m = engine.settings.menu
        guard let i = m.firstIndex(where: { $0.id == model.menuSelection }), m.indices.contains(i + d) else { return }
        m.swapAt(i, i + d)
        engine.settings.menu = m
    }
}

/// Host aliases from ~/.ssh/config, wildcards excluded.
func sshConfigHosts() -> [String] {
    if ProcessInfo.processInfo.environment["TACH_DEMO"] == "1" { return ["devbox", "buildbox", "homelab"] }
    guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8) else { return [] }
    var out: [String] = []
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix("host ") else { continue }
        for h in t.dropFirst(5).split(separator: " ") where !h.contains("*") && !h.contains("?") && !out.contains(String(h)) { out.append(String(h)) }
    }
    return out
}

/// How far back to read each machine's logs. Choosing a longer period reads the older logs again.
struct HistoryPicker: View {
    @EnvironmentObject var engine: Engine
    static let choices: [(Int, String)] = [(30, "30 days"), (90, "90 days"), (365, "1 year"), (36500, "Everything")]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Import history going back").font(Theme.ui(13))
                Segmented(options: Self.choices.map { ($0.0, $0.1) }, selection: Binding(get: {
                    Self.choices.last { $0.0 <= engine.settings.backfillDays }?.0 ?? 30
                }, set: { engine.settings.backfillDays = $0 }))
                if let t = engine.importing { ProgressView().controlSize(.small); Text(t).font(Theme.ui(12)).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
            Text("A longer period reads the older logs on every machine again and adds what is missing. Tools delete their own old logs, so how far back each one goes varies.")
                .font(Theme.ui(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Number field bound to a Double.
struct NumberField: View {
    @Binding var value: Double
    var width: CGFloat = 52
    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.plain).font(Theme.mono(12)).multilineTextAlignment(.trailing)
            .padding(.horizontal, 6).frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair2, lineWidth: 1))
    }
}

struct AlertSettings: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Toggle("", isOn: $engine.settings.notifyThresholds).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                Text("Notify when any limit reaches"); NumberField(value: $engine.settings.warnAt); Text("% and again at"); NumberField(value: $engine.settings.critAt); Text("%")
            }
            toggle("Warn me when I am on pace to run out before a reset", $engine.settings.notifyShort)
            toggle("Tell me when a limit I hit has reset", $engine.settings.notifyReset)
            toggle("Tell me when a machine stops reporting", $engine.settings.notifyStale)
        }
        .font(Theme.ui(13))
    }
    private func toggle(_ t: String, _ b: Binding<Bool>) -> some View {
        HStack(spacing: 10) { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent); Text(t) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    @State private var tests: [UUID: String] = [:]
    @State private var testing: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Menu bar item") {
                Button("Reset to default") { engine.settings.menu = MenuPreset.quota.blocks; model.menuSelection = engine.settings.menu.first?.id }
                    .buttonStyle(.plain).font(Theme.ui(11, .medium)).foregroundStyle(Color(hex: 0x7FB4FF))
            }.padding(.bottom, 10)
            MenuBarEditor()
            SectionHeader("Alerts").padding(.top, 26).padding(.bottom, 10)
            AlertSettings()
            SectionHeader("Subscriptions").padding(.top, 26).padding(.bottom, 4)
            subscriptions
            SectionHeader("Machines").padding(.top, 26).padding(.bottom, 4)
            machines
            SectionHeader(title: "API prices, $ per million tokens") {
                Button("Reset to published prices") { engine.settings.priceOverrides = [:] }.buttonStyle(.plain).font(Theme.ui(11, .medium)).foregroundStyle(Color(hex: 0x7FB4FF))
            }.padding(.top, 26).padding(.bottom, 4)
            prices
            Text("Prices are only used to work out what your usage would have cost through the API. Change one and every cost figure follows.")
                .font(Theme.ui(12)).foregroundStyle(Theme.ink2).padding(.top, 10)
            SectionHeader("General").padding(.top, 26).padding(.bottom, 10)
            general
        }
        .frame(maxWidth: 820, alignment: .leading)
        .onAppear { engine.want(.d30) }
    }

    private var subscriptions: some View {
        VStack(spacing: 0) {
            if engine.accounts.isEmpty { Text("No subscription found yet.").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3).frame(maxWidth: .infinity, alignment: .leading).frame(height: 34) }
            ForEach(engine.accounts) { a in
                let n = a.windows.count
                HStack(spacing: 10) {
                    ProviderIcon(provider: a.provider, size: 20)
                    Text(a.provider.name).font(Theme.ui(13, .semibold)).frame(width: 70, alignment: .leading)
                    Text(a.plan ?? "–").font(Theme.ui(12.5)).frame(width: 130, alignment: .leading)
                    Text("\(n) limit\(n == 1 ? "" : "s")\(a.credits != nil ? " and a credit balance" : "") · read from \(Fmt.source(a.windows.first?.source ?? "", provider: a.provider))").font(Theme.ui(12)).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(a.isStale ? Color.clear : Theme.ink).overlay(Circle().strokeBorder(Theme.ink3, lineWidth: a.isStale ? 1.2 : 0)).frame(width: 6, height: 6)
                        Text(a.isStale ? "Read \(Fmt.ago(a.readAt, now: model.now)) · open \(a.provider.tool.name)" : "Connected").font(Theme.ui(12)).foregroundStyle(a.isStale ? Theme.ink3 : Theme.ink)
                    }
                }
                .frame(height: 38).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
        }
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Theme.ink).frame(width: 6, height: 6)
                TextField("Name", text: $engine.settings.localName).textFieldStyle(.plain).font(Theme.mono(12)).frame(width: 150)
                Text("This Mac").font(Theme.ui(12)).foregroundStyle(Theme.ink3)
                Spacer()
            }
            .frame(height: 38).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            ForEach($engine.settings.machines) { $m in
                HStack(spacing: 10) {
                    Toggle("", isOn: $m.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    field("Name", $m.name, 130)
                    field("ssh target, e.g. user@host", $m.target, 170)
                    field("extra ssh options", $m.options, 190)
                    Text(testing.contains(m.id) ? "Testing…" : tests[m.id] ?? "").font(Theme.ui(11.5)).foregroundStyle((tests[m.id] ?? "").hasPrefix("Reachable") ? Theme.ink2 : Theme.warn).lineLimit(2)
                    Spacer(minLength: 0)
                    PillButton(title: "Test", small: true) { test(m) }
                    IconButton(symbol: "minus.circle", label: "Remove \(m.name)") { engine.settings.machines.removeAll { $0.id == m.id } }
                }
                .frame(minHeight: 42).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
            HStack(spacing: 8) {
                PillButton(title: "Add a machine", small: true) { engine.settings.machines.append(MachineConfig(name: "", target: "")) }
                let known = Set(engine.settings.machines.map(\.target))
                let hosts = sshConfigHosts().filter { !known.contains($0) }
                if !hosts.isEmpty {
                    Menu("From your SSH config") {
                        ForEach(hosts, id: \.self) { h in Button(h) { engine.settings.machines.append(MachineConfig(name: h, target: h)) } }
                    }.menuStyle(.borderlessButton).fixedSize().font(Theme.ui(12))
                }
                Spacer()
            }.padding(.top, 10)
            Text("Tach copies one small binary to ~/.cache/tach on each machine and runs it over SSH. It reads the usage logs your tools already write and sends back token counts and timings. It never sends prompts, code or credentials, and installs no service.")
                .font(Theme.ui(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }

    private func field(_ placeholder: String, _ b: Binding<String>, _ w: CGFloat) -> some View {
        TextField(placeholder, text: b).textFieldStyle(.plain).font(Theme.mono(11.5)).padding(.horizontal, 7).frame(width: w, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28))).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair2, lineWidth: 1))
    }

    private func test(_ m: MachineConfig) {
        guard let c = engine.collector else { tests[m.id] = "The collector is missing from this copy of Tach"; return }
        testing.insert(m.id)
        DispatchQueue.global(qos: .userInitiated).async {
            var msg: String
            do {
                let uname = try c.ensureRemote(m)
                let r = c.remote(m, ["detect"], timeout: 40)
                let found = ((try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any]).flatMap { $0["tools"] as? [[String: Any]] }?
                    .filter { ($0["found"] as? Bool) == true }.compactMap { ($0["tool"] as? String).flatMap { Tool(rawValue: $0)?.name } } ?? []
                msg = "Reachable · \(uname)" + (found.isEmpty ? " · no tools found" : " · " + found.joined(separator: ", "))
            } catch { msg = String(describing: error) }
            DispatchQueue.main.async { testing.remove(m.id); tests[m.id] = msg; engine.refresh() }
        }
    }

    private var prices: some View {
        let seen = (engine.usage[.d30]?.models.map(\.id) ?? [])
        let ids = ModelCatalog.frontierIDs + seen.filter { !ModelCatalog.frontierIDs.contains($0) }.prefix(18)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["Input", "Cache read", "Cache write 5 min", "Cache write 1 h", "Output"], id: \.self) { Text($0).frame(width: 104, alignment: .trailing) }
            }.font(Theme.ui(11)).foregroundStyle(Theme.ink3).frame(height: 28)
            ForEach(ids, id: \.self) { id in
                let info = ModelCatalog.info(id)
                HStack(spacing: 10) {
                    HStack(spacing: 7) { ProviderIcon(provider: info.provider, size: 16); Text(info.name).font(Theme.ui(12.5)).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                    priceField(id, \.input).frame(width: 104, alignment: .trailing)
                    priceField(id, \.cacheRead).frame(width: 104, alignment: .trailing)
                    priceField(id, \.cacheWrite5m).frame(width: 104, alignment: .trailing)
                    priceField(id, \.cacheWrite1h).frame(width: 104, alignment: .trailing)
                    priceField(id, \.output).frame(width: 104, alignment: .trailing)
                }.frame(height: 34).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
        }
    }

    private func priceBinding(_ id: String, get: @escaping (Price) -> Double?, set: @escaping (inout Price, Double) -> Void) -> Binding<Double> {
        Binding(get: { engine.settings.prices.price(id).flatMap(get) ?? 0 }, set: { v in
            var p = engine.settings.prices.price(id) ?? Price(input: 0, output: 0)
            set(&p, max(v, 0))
            engine.settings.priceOverrides[id] = p
        })
    }

    @ViewBuilder private func priceField(_ id: String, _ kp: WritableKeyPath<Price, Double>) -> some View {
        NumberField(value: priceBinding(id, get: { $0[keyPath: kp] }, set: { $0[keyPath: kp] = $1 }), width: 64)
    }

    @ViewBuilder private func priceField(_ id: String, _ kp: WritableKeyPath<Price, Double?>) -> some View {
        NumberField(value: priceBinding(id, get: { $0[keyPath: kp] }, set: { $0[keyPath: kp] = $1 }), width: 64)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { engine.settings.launchAtLogin }, set: { on in
                    engine.settings.launchAtLogin = on
                    if Bundle.main.bundleIdentifier != nil { try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Text("Open Tach at login")
            }
            HistoryPicker()
            HStack(spacing: 10) {
                PillButton(title: "Run setup again…", small: true) { model.openSetup() }
                Text("\(Fmt.count(engine.requestCount)) requests stored in \(Paths.home.path)").font(Theme.ui(12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
            }
            ForEach(engine.notes.prefix(4), id: \.self) { Text($0).font(Theme.ui(12)).foregroundStyle(Theme.ink3) }
        }
        .font(Theme.ui(13))
    }
}
