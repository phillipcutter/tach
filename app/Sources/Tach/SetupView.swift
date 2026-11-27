import SwiftUI
import TachCore
import UserNotifications

struct DetectedTool: Identifiable {
    var id: String { tool }
    var tool: String
    var found: Bool
    var version: String?
    var signedIn: Bool
    var plan: String?
    var limits: String?
    var note: String?
    var bytes: Int64
}

func parseDetect(_ data: Data) -> [DetectedTool] {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tools = o["tools"] as? [[String: Any]] else { return [] }
    return tools.compactMap { t in
        guard let name = t["tool"] as? String else { return nil }
        return DetectedTool(tool: name, found: t["found"] as? Bool ?? false, version: t["version"] as? String, signedIn: t["signed_in"] as? Bool ?? false,
                            plan: t["plan"] as? String, limits: t["limits"] as? String, note: t["note"] as? String, bytes: (t["bytes"] as? NSNumber)?.int64Value ?? 0)
    }
}

/// First-run setup: what was found on this Mac, other machines, the menu bar item, alerts, import.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    @State var step = 0
    @State private var tools: [DetectedTool]?
    @State private var picked: Set<String> = []
    @State private var tests: [String: String] = [:]
    @State private var testing = false
    @State private var notifications = ""
    var finish: () -> Void = {}

    private let steps = ["Welcome", "Find tools", "Machines", "Menu bar", "Alerts", "Import", "Done"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: 44)   // room for the window buttons
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    Button { go(i) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(Theme.mono(10.5, .medium)).foregroundStyle(i == step ? Color.black : Theme.ink2)
                                .frame(width: 18, height: 18).background(Circle().fill(i == step ? Color.white : .clear)).overlay(Circle().strokeBorder(i == step ? .clear : Theme.ink3, lineWidth: 1))
                            Text(s).font(Theme.ui(13, i == step ? .medium : .regular)).foregroundStyle(i == step ? Theme.ink : Theme.ink2)
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 30).background(RoundedRectangle(cornerRadius: 7).fill(i == step ? Theme.fill3 : .clear)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8).frame(width: 188)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair, lineWidth: 1)))
            .padding(.leading, 8).padding(.vertical, 8)
            VStack(spacing: 0) {
                ScrollView { content.padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .topLeading) }
                HStack {
                    Text("Step \(step + 1) of \(steps.count)").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                    Spacer()
                    if step > 0 { PillButton(title: "Back") { go(step - 1) } }
                    PillButton(title: step == 0 ? "Get started" : step == steps.count - 1 ? "Open Tach" : "Continue", primary: true) {
                        if step == steps.count - 1 { done() } else { go(step + 1) }
                    }
                }
                .padding(.horizontal, 24).frame(height: 56).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
        }
        // fill the whole window, title bar area included; the window itself fixes the size
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window).foregroundStyle(Theme.ink).preferredColorScheme(.dark)
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 580)
    }

    private func go(_ i: Int) {
        if step == 2 { applyMachines() }
        step = i
        if i == 1 && tools == nil { detect() }
        if i == 5 { engine.refresh() }
    }

    private func done() {
        applyMachines()
        engine.settings.onboarded = true
        engine.refresh()
        finish()
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: findTools
        case 2: machines
        case 3: menuBar
        case 4: alerts
        case 5: importing
        default: doneStep
        }
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(Theme.ui(20, .semibold))
            Text(sub).font(Theme.ui(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 18)
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 68).padding(.top, 20)
            Text("Welcome to Tach").font(Theme.ui(22, .semibold))
            Text("Tach sits in your menu bar and shows how much of each AI subscription limit you have used, when it resets, and whether you will run out first. It also keeps usage statistics for every model, on every machine you code on.")
                .font(Theme.ui(13.5)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 440)
            Text("Setup takes about two minutes. Everything Tach reads stays on this Mac.").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            MenuBarStrip(blocks: engine.settings.menu).frame(width: 380).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func detect() {
        guard let c = engine.collector else { tools = []; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = c.local(["detect"], timeout: 30)
            let t = parseDetect(r.out)
            DispatchQueue.main.async { tools = t }
        }
    }

    private var findTools: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Tools on this Mac", "Tach looks for the AI coding tools you already use and the usage logs they write. Nothing needs to be installed or signed in again.")
            if engine.collector == nil {
                Text("The collector is missing from this copy of Tach, so nothing can be read.").font(Theme.ui(13)).foregroundStyle(Theme.warn)
            } else if let tools {
                ForEach(Tool.allCases) { t in
                    let d = tools.first { $0.tool == t.rawValue }
                    HStack(spacing: 12) {
                        ProviderIcon(provider: t.provider, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(t.name).font(Theme.ui(13.5, .medium)); if let v = d?.version { Text(v).font(Theme.mono(11)).foregroundStyle(Theme.ink3) } }
                            Text(toolDetail(t, d)).font(Theme.ui(12)).foregroundStyle(Theme.ink3).lineLimit(2)
                        }
                        Spacer()
                        status(d)
                    }
                    .frame(minHeight: 50).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").font(Theme.ui(13)).foregroundStyle(Theme.ink2) }
            }
            callout("lock", "Sign-ins are read on this Mac and used only to ask each provider for your own usage. Tach never stores them, never refreshes them and never sends them anywhere else. Prompts and code are never read.")
                .padding(.top, 18)
        }
        .onAppear { if tools == nil { detect() } }
    }

    private func toolDetail(_ t: Tool, _ d: DetectedTool?) -> String {
        guard let d, d.found else { return "Not found on this Mac" }
        var parts: [String] = []
        if let p = d.plan, !p.isEmpty { parts.append(p) }
        if d.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file) + " of usage logs") }
        if d.limits != "ok", let n = d.note, !n.isEmpty { parts.append(n) }
        return parts.isEmpty ? "Found" : parts.joined(separator: " · ")
    }

    private func status(_ d: DetectedTool?) -> some View {
        let (text, ok): (String, Bool) = {
            guard let d, d.found else { return ("Not found", false) }
            switch d.limits {
            case "ok": return ("Usage and limits", true)
            case "stale_token": return ("Usage · sign in again for limits", false)
            case "app_closed": return ("Usage · open the app for limits", false)
            default: return (d.signedIn ? "Usage" : "Usage · not signed in", d.signedIn)
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : d?.found == true ? "exclamationmark.circle" : "minus.circle").foregroundStyle(ok ? Theme.ink : Theme.ink3)
            Text(text).font(Theme.ui(12)).foregroundStyle(ok ? Theme.ink : Theme.ink2)
        }
    }

    private func callout(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(width: 18)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill1))
    }

    private var hostChoices: [String] {
        var h = sshConfigHosts()
        for m in engine.settings.machines where !h.contains(m.target) { h.append(m.target) }
        return h
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Other machines", "If you also run agents on other machines, pick them here. These come from your SSH config; more can be added later in Settings.")
            if hostChoices.isEmpty { Text("No hosts found in ~/.ssh/config. You can add machines later in Settings.").font(Theme.ui(13)).foregroundStyle(Theme.ink3) }
            ForEach(hostChoices, id: \.self) { h in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { picked.contains(h) }, set: { on in if on { picked.insert(h) } else { picked.remove(h) } })).labelsHidden().toggleStyle(.checkbox)
                    Text(h).font(Theme.mono(12.5))
                    Spacer()
                    Text(tests[h] ?? (picked.contains(h) ? "Not tested" : "")).font(Theme.ui(12)).foregroundStyle((tests[h] ?? "").hasPrefix("Reachable") ? Theme.ink2 : Theme.ink3).lineLimit(1)
                }
                .frame(height: 34).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
            HStack(spacing: 10) {
                PillButton(title: testing ? "Testing…" : tests.isEmpty ? "Test connections" : "Test again") { testAll() }.disabled(testing || picked.isEmpty)
                Text("Uses your existing SSH keys and config.").font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }.padding(.top, 14)
            callout("desktopcomputer", "What goes on each machine: one small binary in ~/.cache/tach, copied over SSH and run only when Tach asks. No service, no open port, no root. It reads the usage logs your tools already write and returns token counts and timings. It never returns prompts, code or credentials. Delete the folder to remove it.")
                .padding(.top, 16)
        }
        .onAppear { if picked.isEmpty { picked = Set(engine.settings.machines.filter(\.enabled).map(\.target)) } }
    }

    private func applyMachines() {
        var ms = engine.settings.machines
        for h in picked where !ms.contains(where: { $0.target == h }) { ms.append(MachineConfig(name: h, target: h)) }
        for i in ms.indices where hostChoices.contains(ms[i].target) { ms[i].enabled = picked.contains(ms[i].target) }
        if ms != engine.settings.machines { engine.settings.machines = ms }
    }

    private func testAll() {
        guard let c = engine.collector else { return }
        testing = true
        let hosts = Array(picked)
        let existing = engine.settings.machines
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            for h in hosts {
                group.enter()
                DispatchQueue.global().async {
                    let m = existing.first { $0.target == h } ?? MachineConfig(name: h, target: h)
                    let r = c.ssh(m, "uname -sm", timeout: 25)
                    let msg = r.ok ? "Reachable · " + String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : Collector.explain(r)
                    DispatchQueue.main.async { tests[h] = msg }
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async { testing = false }
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Choose what the menu bar shows", "Pick a starting point. In Settings you can rearrange it block by block.")
            let current = MenuPreset.matching(engine.settings.menu)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 4) {
                ForEach(MenuPreset.allCases) { p in
                    Button { engine.settings.menu = p.blocks } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().strokeBorder(current == p ? Theme.accent : Theme.ink3, lineWidth: current == p ? 4.5 : 1.2).frame(width: 14, height: 14).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(Theme.ui(13, .medium))
                                Text(p.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8).frame(maxHeight: .infinity, alignment: .top).background(RoundedRectangle(cornerRadius: 8).fill(current == p ? Theme.fill2 : .clear)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            VStack(spacing: 0) {
                MenuBarStrip(blocks: engine.settings.menu)
                MenuItemView(blocks: engine.settings.menu, scale: 1.5).foregroundStyle(.white).environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity).frame(height: 72).background(Color.black.opacity(0.25))
            }
            .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hair, lineWidth: 1)).padding(.top, 14)
            Text("Shown at 1.5×.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).padding(.top, 6)
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Alerts", "Tach can tell you before a limit gets in the way.")
            AlertSettings()
            HStack(spacing: 10) {
                PillButton(title: "Allow notifications…") {
                    guard Bundle.main.bundleIdentifier != nil else { notifications = "Notifications need the packaged app."; return }
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                        DispatchQueue.main.async { notifications = ok ? "Allowed" : "Not allowed. You can change this in System Settings › Notifications." }
                    }
                }
                Text(notifications).font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }.padding(.top, 18)
            VStack(alignment: .leading, spacing: 6) {
                Text("Example").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                NotificationCard(title: "Claude 5-hour limit at 81%", message: "At this pace you hit the limit at 15:28, 56m before it resets at 16:24.")
            }.padding(.top, 22)
        }
    }

    private var importing: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Importing history", "Tach is reading \(Engine.spanText(engine.settings.backfillDays)) of usage from each machine. You can continue; it carries on in the background.")
            HistoryPicker().padding(.bottom, 16)
            HStack(spacing: 10) {
                if engine.refreshing || engine.importing != nil { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill") }
                Text(engine.importing ?? (engine.refreshing ? "Collecting…" : "Up to date")).font(Theme.ui(13))
            }
            HStack(spacing: 28) {
                stat(Fmt.count(engine.requestCount), "requests")
                stat("\(engine.accounts.count)", "subscriptions")
                stat("\(engine.machines.filter(\.online).count) of \(max(engine.machines.count, 1 + engine.settings.machines.filter(\.enabled).count))", "machines reporting")
            }.padding(.top, 20)
            ForEach(engine.machines) { m in
                HStack(spacing: 10) {
                    Circle().fill(m.online ? Theme.ink : .clear).overlay(Circle().strokeBorder(Theme.ink3, lineWidth: m.online ? 0 : 1.2)).frame(width: 6, height: 6)
                    Text(m.name).font(Theme.mono(12.5))
                    Spacer()
                    if m.reading { ProgressView().controlSize(.mini) }
                    Text(m.online ? "seen " + Fmt.ago(m.lastSeen, now: model.now) : m.reading ? "reading history…" : (m.error ?? "waiting"))
                        .font(Theme.ui(12)).foregroundStyle(m.online || m.reading || m.error == nil ? Theme.ink2 : Theme.warn).lineLimit(1)
                }.frame(height: 32).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }.padding(.top, 14)
            ForEach(engine.notes.prefix(4), id: \.self) { Text($0).font(Theme.ui(12)).foregroundStyle(Theme.ink3).padding(.top, 8) }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(v).font(Theme.mono(20, .medium)); Text(l).font(Theme.ui(12)).foregroundStyle(Theme.ink3) }
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).padding(.top, 30)
            Text("Tach is running").font(Theme.ui(22, .semibold))
            Text("Look for it in the menu bar. Click it for the panel, or open the full window for history.").font(Theme.ui(13.5)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            MenuBarStrip(blocks: engine.settings.menu).frame(width: 380).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 6)
            HStack(spacing: 10) {
                Toggle("", isOn: $engine.settings.launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Text("Open Tach at login").font(Theme.ui(13))
            }.padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AppGlyph: View {
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.235).fill(Color(hex: 0x23262C)).overlay(RoundedRectangle(cornerRadius: size * 0.235).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            Circle().stroke(Color.white.opacity(0.22), lineWidth: size * 0.1125).frame(width: size * 0.5, height: size * 0.5)
            Circle().trim(from: 0, to: 0.66).stroke(Color(hex: 0xF3F5F7), lineWidth: size * 0.1125).rotationEffect(.degrees(-90)).frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}

struct NotificationCard: View {
    let title: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppGlyph(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Tach").font(Theme.ui(11)).foregroundStyle(Theme.ink3); Spacer(); Text("now").font(Theme.ui(11)).foregroundStyle(Theme.ink3) }
                Text(title).font(Theme.ui(13, .semibold))
                Text(message).font(Theme.ui(12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(width: 350, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1E2126)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hair2, lineWidth: 1)))
    }
}
