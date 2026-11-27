import AppKit
import Combine
import SwiftUI
import TachCore

// MARK: glyphs

/// The small ring of a limit block. Neutral until warning; stale readings are dashed.
struct MiniRing: View {
    let used: Double
    let state: LimitState
    var scale: CGFloat = 1
    /// A thinner ring with nothing drawn in the middle, to hold an app icon.
    var plain = false

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 16
            let c = CGPoint(x: 8 * s, y: 8 * s), r = (plain ? 6.4 : 5.5) * s, lw = (plain ? 1.9 : 2.4) * s
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let primary = GraphicsContext.Shading.style(.primary)
            let dashed = state == .stale || state == .idle
            ctx.opacity = 0.3
            ctx.stroke(circle, with: primary, style: StrokeStyle(lineWidth: lw, dash: dashed ? [1.6 * s, 1.9 * s] : []))
            ctx.opacity = 1
            guard state != .idle else { return }
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(used, 100) / 100), clockwise: false)
            switch state {
            case .warn: ctx.stroke(arc, with: .color(Theme.warn), lineWidth: lw)
            case .crit, .limited: ctx.stroke(arc, with: .color(Theme.crit), lineWidth: lw)
            case .stale: ctx.opacity = 0.55; ctx.stroke(arc, with: primary, lineWidth: lw); ctx.opacity = 1
            default: ctx.stroke(arc, with: primary, lineWidth: lw)
            }
            if state == .limited, !plain {
                ctx.fill(Path(roundedRect: CGRect(x: 6 * s, y: 6 * s, width: 4 * s, height: 4 * s), cornerRadius: 0.8 * s), with: .color(Theme.crit))
            }
        }
        .frame(width: 16 * scale, height: 16 * scale)
    }
}

/// Two rings for one subscription: the week outside and the 5-hour session inside.
/// With no session limit only the outer ring is drawn, at the same size, so a row of them lines up.
struct MiniDualRing: View {
    let week: LimitWindow?
    let session: LimitWindow?
    var scale: CGFloat = 1
    /// Leave the middle free for an app icon: thinner rings, slightly larger overall.
    var hollow = false

    static func size(hollow: Bool) -> CGFloat { hollow ? 21 : 18 }

    var body: some View {
        let side = Self.size(hollow: hollow) * scale
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let lw = (hollow ? 1.9 : 2.2) * scale, gap = 0.9 * scale
            let outer = size.width / 2 - lw / 2 - 0.4 * scale
            func draw(_ w: LimitWindow?, _ r: CGFloat) {
                let state = w?.state ?? .idle, used = w?.used ?? 0
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                let primary = GraphicsContext.Shading.style(.primary)
                ctx.opacity = 0.3
                ctx.stroke(circle, with: primary, style: StrokeStyle(lineWidth: lw, dash: state == .stale || state == .idle ? [1.5 * scale, 1.7 * scale] : []))
                ctx.opacity = 1
                guard state != .idle, used > 0 else { return }
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(used, 100) / 100), clockwise: false)
                switch state {
                case .warn: ctx.stroke(arc, with: .color(Theme.warn), lineWidth: lw)
                case .crit, .limited: ctx.stroke(arc, with: .color(Theme.crit), lineWidth: lw)
                case .stale: ctx.opacity = 0.55; ctx.stroke(arc, with: primary, lineWidth: lw); ctx.opacity = 1
                default: ctx.stroke(arc, with: primary, lineWidth: lw)
                }
            }
            draw(week ?? session, outer)
            if week != nil, session != nil { draw(session, outer - lw - gap) }
        }
        .frame(width: side, height: side)
    }
}

struct MiniBar: View {
    let used: Double
    let state: LimitState
    var scale: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            let s = size.height / 16
            let primary = GraphicsContext.Shading.style(.primary)
            ctx.opacity = 0.3
            ctx.fill(Path(roundedRect: CGRect(x: 1 * s, y: 2.5 * s, width: 4 * s, height: 11 * s), cornerRadius: s), with: primary)
            ctx.opacity = state == .stale ? 0.45 : 1
            guard state != .idle else { return }
            let h = max(11 * min(used, 100) / 100, 1) * s
            let rect = Path(roundedRect: CGRect(x: 1 * s, y: 13.5 * s - h, width: 4 * s, height: h), cornerRadius: s)
            switch state {
            case .warn: ctx.fill(rect, with: .color(Theme.warn))
            case .crit, .limited: ctx.fill(rect, with: .color(Theme.crit))
            default: ctx.fill(rect, with: primary)
            }
        }
        .frame(width: 6 * scale, height: 16 * scale)
    }
}

struct MiniRate: View {
    var scale: CGFloat = 1
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 16
            for (i, h) in [4.0, 7, 5, 9, 6, 11, 8].enumerated() {
                ctx.opacity = i > 4 ? 1 : 0.55
                ctx.fill(Path(roundedRect: CGRect(x: (1 + Double(i) * 2.1) * s, y: (13.5 - h) * s, width: 1.3 * s, height: h * s), cornerRadius: 0.5 * s), with: .style(.primary))
            }
        }
        .frame(width: 16 * scale, height: 16 * scale)
    }
}

// MARK: blocks

extension Engine {
    /// The limit a menu bar block follows.
    func window(for b: MenuBlock) -> LimitWindow? {
        let pair = windows(for: b)
        switch b.which {
        case .session: return pair.session ?? pair.week
        case .week: return pair.week ?? pair.session
        case .tightest:
            guard let p = Provider(rawValue: b.account) else { return tightest }
            return account(p)?.tightest
        case .both:
            return [pair.week, pair.session].compactMap { $0 }.sorted(by: LimitMath.moreUrgent).first
        }
    }

    /// The week and 5-hour session a block draws from: those of the budget holding the account's
    /// tightest limit (Gemini has two budgets), or of the tightest limit overall.
    func windows(for b: MenuBlock) -> (week: LimitWindow?, session: LimitWindow?) {
        let a = Provider(rawValue: b.account).flatMap(account) ?? tightest.flatMap { account($0.provider) }
        guard let a else { return (nil, nil) }
        let pool = a.tightest.flatMap { a.pool(of: $0) } ?? a.pools.first
        return (pool?.week, pool?.session)
    }
}

/// One block of the menu bar item, drawn at `scale` times its real size.
struct MenuBlockView: View {
    let block: MenuBlock
    var scale: CGFloat = 1
    @EnvironmentObject var engine: Engine

    private func num(_ t: String, dim: Bool = false, color: Color? = nil) -> some View {
        Text(t).font(.system(size: 12.5 * scale, weight: .medium)).monospacedDigit()
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)).opacity(dim ? 0.6 : 1).fixedSize()
    }

    /// The ring, with the subscription's app icon in the middle when the block asks for it.
    @ViewBuilder private func ring(_ used: Double, _ state: LimitState, _ provider: Provider?) -> some View {
        if block.icon {
            ZStack {
                MiniRing(used: used, state: state, scale: scale * 1.19, plain: true)
                ProviderIcon(provider: provider, size: 10.5 * scale).clipShape(Circle()).opacity(state == .stale || state == .idle ? 0.6 : 1)
            }
        } else {
            MiniRing(used: used, state: state, scale: scale)
        }
    }

    /// Week outside, 5-hour inside, with the app icon in the middle when the block asks for it.
    @ViewBuilder private func dualRing(_ provider: Provider?) -> some View {
        let pair = engine.windows(for: block)
        ZStack {
            MiniDualRing(week: pair.week, session: pair.session, scale: scale, hollow: block.icon)
            if block.icon {
                let two = pair.week != nil && pair.session != nil
                let dim = [pair.week, pair.session].compactMap { $0 }.allSatisfy { $0.state == .stale || $0.state == .idle }
                ProviderIcon(provider: provider, size: (two ? 9.2 : 12.6) * scale).clipShape(Circle()).opacity(dim ? 0.6 : 1)
            }
        }
    }

    private func appIcon(_ provider: Provider?) -> some View {
        ProviderIcon(provider: provider, size: 15 * scale)
    }

    var body: some View {
        HStack(spacing: 4 * scale) {
            switch block.kind {
            case .limit:
                let w = engine.window(for: block)
                let state = w?.state ?? .idle, used = w?.used ?? 0
                let hot = state == .crit || state == .limited
                let figure = num(w == nil || state == .idle ? "–" : state == .limited ? "100%" : Fmt.pct(used), dim: state == .stale || state == .idle, color: hot ? Theme.crit : nil)
                let provider = Provider(rawValue: block.account) ?? w?.provider
                switch block.show {
                case .ring where block.which == .both: dualRing(provider)
                case .ringPct where block.which == .both: dualRing(provider); figure
                case .ring: ring(used, state, provider)
                case .ringPct: ring(used, state, provider); figure
                case .barPct: if block.icon { appIcon(provider) }; MiniBar(used: used, state: state, scale: scale); figure
                case .pct: if block.icon { appIcon(provider) }; figure
                }
            case .reset:
                Image(systemName: "clock").font(.system(size: 12 * scale, weight: .medium))
                num(engine.window(for: block)?.remaining.map(Fmt.duration) ?? "–")
            case .cost:
                num(engine.usage[block.range].map { Fmt.cost($0.cost) } ?? "$–")
            case .tokens:
                num(engine.usage[block.range].map { Fmt.tokens($0.total.total) } ?? "–")
                num("tok", dim: true)
            case .tps:
                MiniRate(scale: scale)
                num("\(Int(engine.liveTPS.rounded())) t/s")
            case .live:
                Image(systemName: "terminal").font(.system(size: 11.5 * scale, weight: .medium))
                num("\(engine.liveSessions.count)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.title)
    }
}

/// The whole menu bar item: the configured blocks in a row.
struct MenuItemView: View {
    let blocks: [MenuBlock]
    var scale: CGFloat = 1
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 9 * scale) {
            if blocks.isEmpty {
                MiniRing(used: engine.tightest?.used ?? 0, state: engine.tightest?.state ?? .idle, scale: scale)
            } else {
                ForEach(blocks) { MenuBlockView(block: $0, scale: scale) }
            }
        }
        .fixedSize()
    }
}

/// Shorter versions of the item for a crowded menu bar. macOS hides a status item outright when it
/// does not fit (next to the notch, for instance), so a shorter item beats an invisible one.
func compactMenu(_ blocks: [MenuBlock], level: Int) -> [MenuBlock] {
    switch level {
    case ...0: return blocks
    case 1: return blocks.map { var b = $0; if b.kind == .limit, b.show != .pct { b.show = .ring }; return b }
    case 2:
        let rings = blocks.filter { $0.kind == .limit }.map { b -> MenuBlock in var b = b; b.show = .ring; return b }
        return rings.isEmpty ? [MenuBlock(.limit, show: .ring)] : rings
    default: return [MenuBlock(.limit, show: .ring)]
    }
}

private struct LiveMenuItem: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var model: AppModel
    var body: some View { MenuItemView(blocks: compactMenu(engine.settings.menu, level: model.menuCompaction)) }
}

// MARK: status item

private final class PassthroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns the status item and the panel that drops from it.
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// macOS remembers a status item's place under its autosave name. The pinned name is used once the
    /// item has had to claim a place near the system icons because the menu bar was full.
    private static let freeName = "TachItem", pinnedName = "TachItemPinned", pinnedKey = "TachItemIsPinned"
    private var item: NSStatusItem!
    private let model: AppModel
    private var hosting: NSView!
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()
        let h = PassthroughHostingView(rootView: LiveMenuItem().environmentObject(model.engine).environmentObject(model))
        h.translatesAutoresizingMaskIntoConstraints = false
        hosting = h
        install()

        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let root = PanelView().environmentObject(model).environmentObject(model.engine)
        popover.contentViewController = NSHostingController(rootView: root)
        popover.contentSize = NSSize(width: 348, height: 600)

        model.engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }.store(in: &bag)
        model.$panelHeight.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] h in
            guard let self, h > 0 else { return }
            let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 24
            self.popover.contentSize = NSSize(width: 348, height: min(h, maxH))
        }.store(in: &bag)
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.fit() }
        RunLoop.main.add(t, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.fit() }
    }

    /// Creates the status item and puts the SwiftUI view inside its button.
    private func install() {
        let d = UserDefaults.standard
        let pinned = d.bool(forKey: Self.pinnedKey)
        if pinned, d.object(forKey: "NSStatusItem Preferred Position \(Self.pinnedName)") == nil {
            d.set(320, forKey: "NSStatusItem Preferred Position \(Self.pinnedName)")
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = pinned ? Self.pinnedName : Self.freeName
        guard let button = item.button else { return }
        hosting.removeFromSuperview()
        button.addSubview(hosting)
        NSLayoutConstraint.activate([hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor), hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel("Tach")
        resize()
    }

    private func resize() {
        hosting.layoutSubtreeIfNeeded()
        let w = hosting.fittingSize.width
        item.length = max(w + 14, 28)
    }

    /// macOS gives a status item it has no room for a window on no screen at all.
    private var isHidden: Bool {
        guard let w = item.button?.window else { return false }
        return w.screen == nil
    }

    private var lastGrow = Date.distantPast
    private var configured: [MenuBlock] = []
    private var relocated = false

    /// Keeps the item visible. A crowded menu bar hides items from the left, new ones first, so:
    /// shorten the item step by step; if even a bare ring is hidden the bar is simply full, so
    /// re-create the item once at a position near the system icons, where it is shown.
    /// Every couple of minutes a shortened item tries one step longer again.
    private func fit() {
        if model.engine.settings.menu != configured {   // the user changed it: start again from what they asked for
            configured = model.engine.settings.menu
            if model.menuCompaction != 0 { setLevel(0); return }
        }
        if isHidden {
            if model.menuCompaction < 3 {
                setLevel(model.menuCompaction + 1)
            } else if !relocated, !UserDefaults.standard.bool(forKey: Self.pinnedKey) {
                relocated = true
                NSStatusBar.system.removeStatusItem(item)
                UserDefaults.standard.set(true, forKey: Self.pinnedKey)
                install()
                setLevel(0)
            }
        } else if model.menuCompaction > 0, Date().timeIntervalSince(lastGrow) > 120 {
            lastGrow = Date()
            let previous = model.menuCompaction
            setLevel(previous - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isHidden else { return }
                self.setLevel(previous)
            }
        }
    }

    private func setLevel(_ l: Int) {
        model.menuCompaction = l
        DispatchQueue.main.async { [weak self] in
            self?.resize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.fit() }
        }
    }

    /// For diagnosing a hidden item: where macOS has put the status item's window.
    func describePlacement() -> String {
        guard let win = item.button?.window else { return "no window" }
        return "length=\(item.length) frame=\(win.frame) onScreen=\(win.screen != nil) relocated=\(relocated)"
    }

    var isShown: Bool { popover.isShown }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        show()
    }

    func show() {
        guard let button = item.button, !popover.isShown else { return }
        model.panelOpened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if ProcessInfo.processInfo.environment["TACH_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let w = self.popover.contentViewController?.view.window
                FileHandle.standardError.write(Data("popover: shown=\(self.popover.isShown) size=\(self.popover.contentSize) window=\(String(describing: w?.frame)) onScreen=\(w?.screen != nil) panelHeight=\(self.model.panelHeight)\n".utf8))
            }
        }
    }

    func close() { popover.performClose(nil) }
}
