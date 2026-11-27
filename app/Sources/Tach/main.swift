import AppKit
import Combine
import SwiftUI
import TachCore
import UserNotifications

/// Posts notifications when a limit crosses a threshold, is on pace to run out early, or resets.
final class Notifier {
    private var sent = Set<String>()
    private var offline = Set<Int64>()
    private let enabled = Bundle.main.bundleIdentifier != nil

    func post(_ title: String, _ body: String, key: String) {
        guard enabled, !sent.contains(key) else { return }
        sent.insert(key)
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: c, trigger: nil))
    }

    func limits(old: [Account], new: [Account], settings s: AppSettings, now: Date) {
        for e in LimitAlerts.events(old: old, new: new, settings: s, now: now) { post(e.title, e.body, key: e.key) }
    }

    func machines(_ ms: [MachineStatus], settings s: AppSettings) {
        for m in ms where !m.isLocal {
            if !m.online, m.lastSeen != nil, !offline.contains(m.id) {
                offline.insert(m.id)
                if s.notifyStale { post("\(m.name) stopped reporting", m.error ?? "Tach could not reach it.", key: "machine|\(m.id)|\(Int(Date().timeIntervalSince1970 / 3600))") }
            } else if m.online { offline.remove(m.id) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var status: StatusItemController!
    var window: NSWindow?
    var setup: NSWindow?
    let notifier = Notifier()
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        let env = ProcessInfo.processInfo.environment
        let engine: Engine
        do { engine = try Engine() } catch {
            let a = NSAlert(); a.messageText = "Tach could not open its database"; a.informativeText = String(describing: error); a.runModal()
            NSApp.terminate(nil); return
        }
        model = AppModel(engine: engine)
        model.openWindow = { [weak self] nav in self?.showWindow(nav) }
        model.openSetup = { [weak self] in self?.showSetup() }
        engine.onLimits = { [weak self] old, new in
            guard let self else { return }
            self.notifier.limits(old: old, new: new, settings: engine.settings, now: engine.now())
        }
        engine.$machines.sink { [weak self] ms in self?.notifier.machines(ms, settings: engine.settings) }.store(in: &bag)

        if let dir = env["TACH_SNAPSHOT"] {
            engine.start()
            // a timer, not a main-queue block: the nested run loops in Snapshots must be able to drain the main queue
            let started = Date(), wait = Double(env["TACH_SNAPSHOT_WAIT"] ?? "") ?? 0
            Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { t in
                let age = Date().timeIntervalSince(started)
                guard age >= 1.2, age >= wait || (!engine.refreshing && engine.updatedAt != nil && engine.importing == nil && age > 4) || wait == 0 else { return }
                t.invalidate()
                FileHandle.standardError.write(Data("snapshot at \(Int(age))s refreshing=\(engine.refreshing) importing=\(engine.importing ?? "nil") requests=\(engine.requestCount)\n".utf8))
                Snapshots(model: self.model).run(into: dir)
            }
            return
        }
        status = StatusItemController(model: model)
        model.closePanel = { [weak self] in self?.status.close() }
        engine.start()
        if env["TACH_DEBUG"] == "1" {
            for t in [2.0, 8.0, 16.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { FileHandle.standardError.write(Data("status item: level=\(self.model.menuCompaction) \(self.status.describePlacement())\n".utf8)) } }
        }
        if !engine.settings.onboarded { showSetup() }
        switch env["TACH_OPEN"] {
        case "window": showWindow(env["TACH_NAV"].flatMap(NavItem.init(rawValue:)))
        case "panel": DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.status.show() }
        case "setup": showSetup()
        default: break
        }
    }

    /// A dark window whose content runs under a transparent title bar. The empty unified toolbar
    /// gives the title bar its taller height, which puts the window buttons inside the sidebar panel
    /// instead of on its corner.
    private func makeWindow(size: NSSize, title: String, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = title
        let tb = NSToolbar(identifier: "tach.\(title)")
        tb.showsBaselineSeparator = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(red: 0.106, green: 0.114, blue: 0.129, alpha: 1)
        w.isMovableByWindowBackground = true
        w.delegate = self
        return w
    }

    func showWindow(_ nav: NavItem?) {
        if let nav { model.nav = nav }
        if window == nil {
            let w = makeWindow(size: NSSize(width: 1220, height: 800), title: "Tach", resizable: true)
            w.contentView = NSHostingView(rootView: MainView().environmentObject(model).environmentObject(model.engine))
            w.setContentSize(NSSize(width: 1220, height: 800))
            w.setFrameAutosaveName("TachMain")
            w.center()
            window = w
        }
        present(window!)
    }

    func showSetup() {
        if setup == nil {
            setup = makeWindow(size: NSSize(width: 800, height: 580), title: "Set up Tach", resizable: false)
        }
        let view = SetupView(finish: { [weak self] in self?.setup?.close(); self?.showWindow(.overview) })
        setup!.contentView = NSHostingView(rootView: view.environmentObject(model).environmentObject(model.engine))
        setup!.setContentSize(NSSize(width: 800, height: 580))
        setup!.center()
        present(setup!)
    }

    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let open = [self.window, self.setup].compactMap { $0 }.contains { $0.isVisible }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(nil) }
        return true
    }
}

/// Renders every screen to PNG files without showing anything, for checking the UI.
/// Run with `TACH_SNAPSHOT=<dir>`, usually together with `TACH_DEMO=1`.
final class Snapshots {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL, wait: TimeInterval = 0.6) {
        let host = NSHostingView(rootView: view.environmentObject(model).environmentObject(model.engine))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(wait))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }

    func run(into dir: String) {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let e = model.engine
        for r in RangeKey.allCases { e.want(r) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        model.panelOpened()
        let wall = LinearGradient(colors: [Color(hex: 0x41607C), Color(hex: 0x172433)], startPoint: .topLeading, endPoint: .bottomTrailing)
        func panel(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let h = max(model.panelHeight, 300)
            render(PanelView().background(Color(hex: 0x1A1D22)), size: NSSize(width: 348, height: h), to: base.appendingPathComponent(name))
        }
        panel("panel-claude.png")
        print("panel height", model.panelHeight)
        for p in Provider.allCases where e.account(p) != nil {
            model.panelProvider = p; model.panelRow = e.account(p)?.pools.first?.week?.id
            panel("panel-\(p.rawValue)-week.png")
        }
        model.panelProvider = .claude; model.panelRow = e.account(.claude)?.pools.first?.session?.id
        panel("panel-claude-session.png")
        if let t = e.tightest { model.loadLimit(t) }
        if let m = e.usage[model.range]?.models.first { model.loadModel(m.id) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        for n in NavItem.allCases {
            model.nav = n
            render(MainView(), size: NSSize(width: 1220, height: n == .settings ? 1500 : n == .models ? 1100 : 900), to: base.appendingPathComponent("window-\(n.rawValue).png"))
        }
        model.nav = .limits
        for (i, w) in e.accounts.flatMap(\.windows).enumerated() where [1, 4, 6, 7].contains(i) {
            model.limitSelection = w.id
            model.loadLimit(w)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            render(MainView(), size: NSSize(width: 1220, height: 900), to: base.appendingPathComponent("window-limits-\(i).png"))
        }
        for s in 0..<7 {
            render(SetupView(step: s), size: NSSize(width: 800, height: 580), to: base.appendingPathComponent("setup-\(s).png"), wait: s == 1 ? 4 : 0.6)
        }
        for p in MenuPreset.allCases {
            render(MenuBarStrip(blocks: p.blocks).frame(width: 520), size: NSSize(width: 520, height: 24), to: base.appendingPathComponent("menubar-\(p.rawValue).png"))
        }
        let light = HStack { Spacer(); MenuItemView(blocks: MenuPreset.all.blocks) }.padding(.horizontal, 12).frame(width: 520, height: 24).background(Color(white: 0.92)).environment(\.colorScheme, .light)
        render(light, size: NSSize(width: 520, height: 24), to: base.appendingPathComponent("menubar-light.png"))
        _ = wall
        render(AppGlyph(size: 512).padding(0), size: NSSize(width: 512, height: 512), to: base.appendingPathComponent("icon.png"))
        print("snapshots written to", dir)
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
