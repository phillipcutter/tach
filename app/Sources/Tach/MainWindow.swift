import SwiftUI
import TachCore

/// The full window: a sidebar and one view at a time.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                ScrollView { content.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .topLeading) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .frame(minWidth: 1040, minHeight: 660)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 44)   // room for the window buttons
            ForEach(NavItem.allCases.filter { $0 != .settings }) { navRow($0) }
            Spacer()
            navRow(.settings)
        }
        .padding(8)
        .frame(width: 204)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair, lineWidth: 1)))
        .padding(.leading, 8).padding(.vertical, 8)
    }

    private func navRow(_ n: NavItem) -> some View {
        let on = model.nav == n
        return Button { model.nav = n } label: {
            HStack(spacing: 10) {
                Image(systemName: n.symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(on ? Theme.ink : Theme.ink2)
                Text(n.title).font(Theme.ui(13, on ? .medium : .regular))
                Spacer()
                badge(n)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.fill3 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func badge(_ n: NavItem) -> some View {
        switch n {
        case .limits:
            if let t = engine.tightest, t.state != .idle { Text(Fmt.pct(t.used)).font(Theme.mono(10.5)).foregroundStyle(Theme.figure(t.state)) }
        case .machines:
            if engine.machines.count > 1 { Text("\(engine.machines.filter(\.online).count)/\(engine.machines.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3) }
        case .sessions:
            Text("\(engine.liveSessions.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
        default: EmptyView()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(model.nav.title).font(Theme.ui(17, .semibold))
            Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
            Spacer()
            if [.overview, .models, .machines].contains(model.nav) {
                if engine.usage[model.range] == nil { ProgressView().controlSize(.small) }
                RangePicker(range: $model.range)
            }
            Text(engine.refreshing ? "Updating…" : "Updated " + Fmt.ago(engine.updatedAt, now: engine.demo ? model.now.addingTimeInterval(12) : Date()))
                .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
            IconButton(symbol: "arrow.clockwise", label: "Refresh") { engine.refresh() }
        }
        .padding(.horizontal, 28).frame(height: 56)
    }

    private var subtitle: String {
        switch model.nav {
        case .overview: let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f.string(from: model.now)
        case .limits: let n = engine.accounts.flatMap(\.windows).count; return "\(engine.accounts.count) accounts · \(n) limits"
        case .models: return engine.usage[model.range]?.title ?? "adding up usage…"
        case .machines: return "\(engine.machines.filter(\.online).count) of \(engine.machines.count) reporting"
        case .sessions: return "\(engine.liveSessions.count) live"
        case .settings: return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch model.nav {
        case .overview: OverviewView()
        case .limits: LimitsView()
        case .models: ModelsView()
        case .machines: MachinesView()
        case .sessions: SessionsView()
        case .settings: SettingsView()
        }
    }
}

struct AccountHeader: View {
    let account: Account
    let now: Date
    var size: CGFloat = 20
    var body: some View {
        HStack(spacing: 7) {
            ProviderIcon(provider: account.provider, size: size)
            Text(account.provider.name).font(Theme.ui(13, .semibold))
            if let p = account.plan { Text(p).font(Theme.ui(12)).foregroundStyle(Theme.ink3) }
            Spacer()
            if account.isStale { AgeBadge(text: "read " + Fmt.ago(account.readAt, now: now), stale: true) }
        }
        .frame(height: 24)
    }
}

let outsideNote = "Limits include usage outside tracked tools, such as the web and mobile apps. Token statistics do not."

// MARK: overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine

    /// List prices of the plans, used only for the "times the subscription price" line.
    private static let fees: [(String, Double)] = [("max 20x", 200), ("max 5x", 100), ("chatgpt pro", 200), ("chatgpt plus", 20), ("ai ultra", 250), ("ai pro", 20)]

    var body: some View {
        let u = engine.usage[model.range] ?? .empty(model.range, now: model.now)
        let colors = model.colors(for: u.models)
        VStack(alignment: .leading, spacing: 0) {
            if engine.accounts.isEmpty {
                EmptyPanel().frame(maxWidth: 420).frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(engine.accounts.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Rectangle().fill(Theme.hair).frame(width: 1) }
                        accountColumn(a).padding(.leading, i == 0 ? 0 : 20).padding(.trailing, i == engine.accounts.count - 1 ? 0 : 20)
                            .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
                Text(outsideNote).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Tokens by model, " + u.title)
                    HStack(spacing: 22) {
                        fig(Fmt.tokens(u.total.total), "tokens"); fig(Fmt.count(u.requests), "requests")
                        fig(u.total.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "–", "cache hit rate"); fig(Fmt.tokens(u.total.output), "output")
                    }
                    StackChart(series: u.models.reversed().map(\.series), colors: u.models.reversed().map { colors[$0.id] ?? Theme.ink3 }, labels: chartLabels(u), height: 190, leading: 40)
                    FlowLegend(items: u.models.prefix(10).map { ($0.info.name, colors[$0.id] ?? Theme.ink3) })
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Value at API prices")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.cost(u.cost)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Text(u.title).font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                    }
                    ForEach(u.byTool) { t in
                        HStack(spacing: 8) {
                            ProviderIcon(provider: Tool(rawValue: t.id)?.provider, size: 16)
                            Text(t.name).font(Theme.ui(12.5)).frame(width: 96, alignment: .leading)
                            PBar(fraction: u.cost > 0 ? t.cost / u.cost : 0, color: Theme.provider(Tool(rawValue: t.id)?.provider))
                            Text(Fmt.cost(t.cost)).font(Theme.mono(11.5)).frame(width: 62, alignment: .trailing)
                        }.frame(height: 22)
                    }
                    if let note = feeNote(u) { Text(note).font(Theme.ui(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 6) }
                    if u.unpricedTokens > 0 {
                        Text("\(Fmt.tokens(u.unpricedTokens)) tokens are from models with no price set and are not counted.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 330, alignment: .topLeading)
            }
            .padding(.top, 22)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Machines") { Text(Fmt.tokens(engine.machines.map(\.tokensPerHour).reduce(0, +)) + " tokens/h now").font(Theme.mono(11)).foregroundStyle(Theme.ink2) }
                    MachineRows(machines: engine.machines, now: model.now)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Live sessions") { Text("\(engine.liveSessions.count) now").font(Theme.mono(11)).foregroundStyle(Theme.ink2) }
                    SessionRows(sessions: Array(engine.liveSessions.prefix(6)), now: model.now)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 22)
        }
        .onAppear { engine.want(model.range) }
    }

    private func fig(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) { Text(v).font(Theme.mono(13, .medium)); Text(l).font(Theme.ui(12)).foregroundStyle(Theme.ink2) }
    }

    private func accountColumn(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            AccountHeader(account: a, now: model.now)
            HStack(spacing: 14) {
                AccountRing(account: a, size: 76, lineWidth: 6, gap: 3)
                if let t = a.tightest {
                    Text(LimitText.name(t, in: a) + ": " + LimitText.verdict(t, now: model.now)).font(Theme.ui(12)).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 3)
            ForEach(a.pools) { PoolView(pool: $0, now: model.now) }
            if let c = a.credits { CreditsRow(credits: c, now: model.now).padding(.top, 4).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) } }
        }
    }

    private func feeNote(_ u: UsageSummary) -> String? {
        var monthly = 0.0
        for a in engine.accounts {
            guard let plan = a.plan?.lowercased(), let f = Self.fees.first(where: { plan.contains($0.0) || ($0.0.hasPrefix("chatgpt ") && a.provider == .openai && plan.contains($0.0.dropFirst(8))) || ($0.0.hasPrefix("ai ") && a.provider == .gemini && plan.contains($0.0.dropFirst(3))) }) else { return nil }
            monthly += f.1
        }
        guard monthly > 0, u.cost > 0 else { return nil }
        let fee = monthly / 30 * u.days
        let times = u.cost / fee
        let n = engine.accounts.count
        return "\(n == 1 ? "The subscription lists" : "The \(n) subscriptions list") at \(Fmt.cost(fee)) over the same period, so this usage is \(times >= 10 ? String(format: "%.0f", times) : String(format: "%.1f", times))× the subscription price."
    }
}

/// A wrapping legend of colour swatches.
struct FlowLegend: View {
    let items: [(String, Color)]
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 150), alignment: .leading)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(it.1).frame(width: 8, height: 8); Text(it.0).font(Theme.ui(11.5)).foregroundStyle(Theme.ink2).lineLimit(1) }
            }
        }
    }
}

struct SessionRows: View {
    let sessions: [SessionRow]
    let now: Date
    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty { Text("No live sessions").font(Theme.ui(12)).foregroundStyle(Theme.ink3).frame(maxWidth: .infinity, alignment: .leading).frame(height: 22) }
            ForEach(sessions) { s in
                HStack(spacing: 8) {
                    ProviderIcon(provider: Tool(rawValue: s.tool)?.provider, size: 15)
                    Text(projectName(s)).font(Theme.ui(12.5, .medium)).lineLimit(1)
                    Text([s.model.map { ModelCatalog.info($0).short }, s.machine].compactMap { $0 }.joined(separator: " · ")).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer(minLength: 4)
                    if let st = s.started { Text(Fmt.duration(now.timeIntervalSince(st))).font(Theme.mono(11)).foregroundStyle(Theme.ink2) }
                    if let c = s.ctx {
                        PBar(fraction: c / 100, color: c >= 80 ? Theme.warn : Theme.ink2).frame(width: 44).help("Context window fill")
                        Text(Fmt.pct(c)).font(Theme.mono(11)).frame(width: 32, alignment: .trailing)
                    } else if let t = s.tokens, t > 0 {
                        Text(Fmt.tokens(t)).font(Theme.mono(11)).foregroundStyle(Theme.ink3).help("Tokens in the latest request")
                    }
                }.frame(height: 23)
            }
        }
    }
}

func projectName(_ s: SessionRow) -> String {
    guard let c = s.cwd, !c.isEmpty else { return s.sessionID.count > 14 ? String(s.sessionID.prefix(8)) : s.sessionID }
    let parts = c.split(separator: "/")
    // a session started in the home folder has no project: show ~ rather than the user's name
    if parts.count == 2, parts[0] == "Users" || parts[0] == "home" { return "~" }
    if c == "/root" || c == "/" { return c == "/" ? "/" : "~" }
    return URL(fileURLWithPath: c).lastPathComponent
}

// MARK: limits

struct LimitsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    private var trajectory: [(Date, Double)] { model.trajectory }
    private var peaks: [(resets: Date, peak: Double, limited: Bool)] { model.peaks }

    private var selected: LimitWindow? {
        let all = engine.accounts.flatMap(\.windows)
        return all.first { $0.id == model.limitSelection } ?? engine.tightest
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(engine.accounts) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        AccountHeader(account: a, now: model.now)
                        ForEach(a.pools) { p in PoolView(pool: p, now: model.now, selected: selected?.id) { model.limitSelection = $0.id } }
                        if let c = a.credits { CreditsRow(credits: c, now: model.now) }
                    }
                }
                Text(outsideNote).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300, alignment: .topLeading)
            if let w = selected {
                detail(w).frame(maxWidth: .infinity, alignment: .topLeading)
                    .onAppear { model.loadLimit(w) }
                    .onChange(of: w.id) { _, _ in model.loadLimit(w) }
                    .onChange(of: engine.updatedAt) { _, _ in model.loadLimit(w, force: true) }
            } else {
                EmptyPanel().frame(maxWidth: .infinity)
            }
        }
    }

    private func detail(_ w: LimitWindow) -> some View {
        let a = engine.account(w.provider), now = model.now
        let live = w.state != .stale && w.state != .idle && w.state != .limited
        let idle = w.state == .idle
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderIcon(provider: w.provider, size: 22)
                Text("\(w.provider.name) · \(LimitText.name(w, in: a))").font(Theme.ui(16, .semibold))
                StateTag(state: w.state)
                Spacer()
                AgeBadge(text: Fmt.ago(w.readAt, now: now), stale: w.state == .stale)
            }
            HStack(alignment: .center, spacing: 36) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(idle ? "–" : "\(Int(w.used.rounded()))").font(.system(size: 46, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.figure(w.state))
                    if !idle { Text("%").font(Theme.ui(20)).foregroundStyle(Theme.ink2) }
                    Text("used").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3).padding(.leading, 4)
                }
                kv([("Elapsed", idle ? "–" : w.elapsed.map { "\(Fmt.pct($0)) · \(Fmt.duration(w.length * $0 / 100)) of \(w.isWeekly ? "7d" : "5h")" } ?? "–"),
                    ("Resets", w.resets.map { "\(Fmt.clock($0, now: now)) · in \(Fmt.duration($0.timeIntervalSince(now)))" } ?? "no reset time yet"),
                    ("Pace", live ? (LimitText.pace(w) ?? "–") : "–")])
                kv([("Burn now", live ? Fmt.rate(w.burnPerHour, weekly: w.isWeekly) : "–"),
                    ("Window average", idle ? "–" : Fmt.rate(w.averagePerHour, weekly: w.isWeekly)),
                    ("Sustainable to reset", live ? (w.sustainablePerHour.map { "≤ " + Fmt.rate($0, weekly: w.isWeekly) } ?? "–") : "–")])
            }
            .padding(.vertical, 10)
            if w.resets != nil {
                TrajectoryChart(w: w, points: trajectory, now: now)
                HStack(spacing: 16) {
                    Circle().fill(Theme.state(w.state)).frame(width: 7, height: 7)
                    Text(LimitText.verdict(w, now: now)).font(Theme.ui(12.5)).foregroundStyle(Theme.ink)
                    Spacer()
                    legendItem("used", dash: []); legendItem("projected", dash: [4, 3]); legendItem("even pace", dash: [1.5, 3])
                }.padding(.top, 6)
            } else {
                Text(LimitText.verdict(w, now: now)).font(Theme.ui(13)).foregroundStyle(Theme.ink2).padding(.vertical, 20)
            }
            if live, w.resets != nil {
                SectionHeader("Forecast").padding(.top, 20).padding(.bottom, 4)
                forecast(w)
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Peak of the last \(peaks.count) \(w.isWeekly ? "weeks" : "5-hour windows")")
                    PeaksChart(peaks: peaks.map { ($0.peak, $0.limited) })
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    let hits = peaks.filter(\.limited).reversed()
                    SectionHeader(title: "Times this limit was reached") { Text("\(hits.count)").font(Theme.mono(11)).foregroundStyle(Theme.ink2) }.padding(.bottom, 4)
                    if hits.isEmpty { Text("Not reached in the recorded history.").font(Theme.ui(12)).foregroundStyle(Theme.ink3).padding(.top, 6) }
                    ForEach(Array(hits.prefix(6).enumerated()), id: \.offset) { _, h in
                        HStack { Text(dateTime(h.resets.addingTimeInterval(-w.length))).font(Theme.mono(11.5)); Spacer(); Text("window ending " + Fmt.clock(h.resets, now: now)).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3) }
                            .frame(height: 28).overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 22)
        }
    }

    private func dateTime(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f.string(from: d) }

    private func legendItem(_ t: String, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 18, y: 4)) }.stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.6, dash: dash)).frame(width: 18, height: 8)
            Text(t).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
        }
    }

    private func kv(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow { Text(r.0).font(Theme.ui(12)).foregroundStyle(Theme.ink3); Text(r.1).font(Theme.mono(11.5)).gridColumnAlignment(.trailing) }
            }
        }
    }

    private func forecast(_ w: LimitWindow) -> some View {
        let now = model.now, rem = w.remaining ?? 0
        func result(_ rate: Double) -> (String, Bool) {
            guard rate > 0 else { return ("ends at \(Fmt.pct(w.used))", false) }
            let toFull = (100 - w.used) / rate * 3600
            if toFull < rem - 30 { return ("limit at \(Fmt.clock(now.addingTimeInterval(toFull), now: now)), \(Fmt.duration(rem - toFull)) early", true) }
            return ("ends at \(Fmt.pct(min(w.used + rate * rem / 3600, 100)))", false)
        }
        let rows: [(String, Double)] = [("The current burn rate", w.burnPerHour), ("This window’s average so far", w.averagePerHour), ("The most that still reaches the reset", w.sustainablePerHour ?? 0)]
        return VStack(spacing: 0) {
            HStack { Text("If you continue at"); Spacer(); Text("Rate").frame(width: 110, alignment: .trailing); Text("Result").frame(width: 250, alignment: .trailing) }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3).frame(height: 28)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                let res = result(r.1)
                HStack {
                    Text(r.0).font(Theme.ui(12.5)); Spacer()
                    Text(Fmt.rate(r.1, weekly: w.isWeekly)).font(Theme.mono(11.5)).frame(width: 110, alignment: .trailing)
                    Text(res.0).font(Theme.mono(11.5)).foregroundStyle(res.1 ? Theme.warn : Theme.ink).frame(width: 250, alignment: .trailing)
                }
                .frame(height: 32).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
        }
    }
}

struct StateTag: View {
    let state: LimitState
    var body: some View {
        let name: String = switch state { case .ok: "OK"; case .warn: "Warning"; case .crit: "Critical"; case .limited: "Limited now"; case .stale: "Stale"; case .idle: "Not started" }
        let c = state == .warn ? Theme.warn : state == .crit || state == .limited ? Theme.crit : Theme.ink3
        Text(name.uppercased()).font(Theme.ui(9.5, .semibold)).tracking(0.5).foregroundStyle(c)
            .padding(.horizontal, 6).frame(height: 17).background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.16)))
    }
}

/// Peak usage of past windows, coloured by how close each came.
struct PeaksChart: View {
    let peaks: [(Double, Bool)]
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 30, t: CGFloat = 8, b: CGFloat = 16, pw = size.width - l, ph = size.height - t - b
            for v in [0.0, 50, 100] {
                let y = t + ph * (1 - v / 100)
                var g = Path(); g.move(to: CGPoint(x: l, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(g, with: .color(v == 100 ? Theme.ink3 : Theme.hair), lineWidth: 1)
                ctx.draw(Text("\(Int(v))%").font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: l - 5, y: y), anchor: .trailing)
            }
            guard !peaks.isEmpty else { return }
            let bw = pw / CGFloat(max(peaks.count, 12))
            for (i, p) in peaks.enumerated() where p.0 > 0 {
                let h = CGFloat(min(p.0, 100) / 100) * ph
                let c = p.1 || p.0 >= 100 ? Theme.crit : p.0 >= 80 ? Theme.warn : Theme.level
                ctx.fill(Path(roundedRect: CGRect(x: l + CGFloat(i) * bw + bw * 0.14, y: t + ph - h, width: bw * 0.72, height: h), cornerRadius: 1.5), with: .color(c.opacity(i == peaks.count - 1 ? 1 : 0.8)))
            }
            ctx.draw(Text("\(peaks.count) ago").font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: l, y: size.height - 5), anchor: .leading)
            ctx.draw(Text("current").font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: l + bw * CGFloat(peaks.count), y: size.height - 5), anchor: .trailing)
        }
        .frame(height: 140)
    }
}
