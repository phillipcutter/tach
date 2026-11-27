import SwiftUI
import TachCore

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The sheet that drops from the menu bar item: the limit most at risk first, a ring pair per
/// account, that account's limit groups, then models and machines.
struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .padding(.horizontal, 12)
                .frame(width: 348)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .onPreferenceChange(HeightKey.self) { model.panelHeight = $0 }
        .frame(width: 348)
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder private var content: some View {
        if engine.accounts.isEmpty {
            EmptyPanel()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let top = engine.tightest { HeadlineView(w: top, account: engine.account(top.provider), now: model.now) }
                rings
                if let a = selectedAccount { limits(a) }
                modelsSection
                machinesSection
                footer
            }
        }
    }

    private var selectedAccount: Account? {
        model.panelProvider.flatMap(engine.account) ?? engine.tightest.flatMap { engine.account($0.provider) } ?? engine.accounts.first
    }

    // MARK: rings

    private var rings: some View {
        HStack(spacing: 2) {
            ForEach(engine.accounts) { a in
                let on = a.id == selectedAccount?.id, t = a.tightest
                Button { model.panelProvider = a.provider; model.panelRow = nil } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) { ProviderIcon(provider: a.provider, size: 18); Text(a.provider.name).font(Theme.ui(12.5, .semibold)) }.padding(.bottom, 5)
                        AccountRing(account: a)
                        Text(t.map { LimitText.name($0, in: a) } ?? "No limits").font(Theme.ui(11.5)).lineLimit(1).padding(.top, 5)
                        Text(caption(a, t)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 4).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 11).fill(on ? Theme.fill1 : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? Theme.hair2 : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.provider.name), tightest limit \(t?.title ?? "none"), \(t.map { Fmt.pct($0.used) } ?? "") used")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, -6)
    }

    private func caption(_ a: Account, _ t: LimitWindow?) -> String {
        guard let t else { return "" }
        if t.state == .stale || a.isStale { return "read " + Fmt.ago(a.readAt, now: model.now) }
        if t.state == .idle { return "not started" }
        return t.remaining.map { Fmt.duration($0) + " left" } ?? ""
    }

    // MARK: limits of the selected account

    @ViewBuilder private func limits(_ a: Account) -> some View {
        let n = a.windows.count
        SectionHeader(title: a.provider.name + (a.plan.map { " · " + $0 } ?? "")) {
            if a.isStale { AgeBadge(text: "read " + Fmt.ago(a.readAt, now: model.now), stale: true) } else {
                Text("\(n) limit\(n == 1 ? "" : "s")").font(Theme.mono(11)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(.top, 14).padding(.bottom, 8)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(a.pools) { p in
                PoolView(pool: p, now: model.now, selected: model.panelRow) { w in model.panelRow = model.panelRow == w.id ? nil : w.id }
            }
        }
        if let w = a.windows.first(where: { $0.id == model.panelRow }) { detail(w, in: a) }
        if let c = a.credits { CreditsRow(credits: c, now: model.now) }
        Text("Limits also count usage outside tracked tools.").font(Theme.ui(11)).foregroundStyle(Theme.ink3).padding(.top, 8)
    }

    private func detail(_ w: LimitWindow, in a: Account) -> some View {
        let isTop = w.id == engine.tightest?.id
        let live = w.state != .stale && w.state != .idle
        let pool = a.pool(of: w)
        let share = (w.kind == .session || w.kind == .weekly) ? pool.flatMap(sessionsLeftText) : nil
        return VStack(alignment: .leading, spacing: 3) {
            Text(w.title).font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.ink)
            if !isTop {
                if live, let r = w.resets {
                    Text("Resets \(Fmt.clock(r, now: model.now)) · burning \(Fmt.rate(w.burnPerHour, weekly: w.isWeekly))" + (LimitText.pace(w).map { " · " + $0 } ?? ""))
                }
                Text(LimitText.verdict(w, now: model.now)).foregroundStyle(w.state == .warn || w.state == .crit || w.state == .limited ? Theme.state(w.state) : Theme.ink2)
            }
            if let share { Text(share) }
            if isTop && share == nil { Text(LimitText.pace(w) ?? LimitText.verdict(w, now: model.now)) }
        }
        .font(Theme.ui(11)).foregroundStyle(Theme.ink2).lineSpacing(1.5)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.fill1))
        .padding(.horizontal, -6).padding(.top, 6).padding(.bottom, 4)
    }

    // MARK: models

    @ViewBuilder private var modelsSection: some View {
        let range = engine.settings.panelRange
        let u = engine.usage[range] ?? .empty(range, now: model.now)
        // the current frontier models by name; everything else as one row
        let frontier = u.models.filter(\.info.frontier)
        let shown = frontier.isEmpty ? Array(u.models.prefix(6)) : frontier
        let rest = u.models.filter { m in !shown.contains { $0.id == m.id } }
        let restSeries: [Int64] = rest.reduce(into: Array(repeating: Int64(0), count: u.bucketCount)) { acc, m in for (i, v) in m.series.enumerated() where i < acc.count { acc[i] += v } }
        let colors = model.colors(for: u.models)
        SectionHeader(title: "Models") {
            RangePicker(range: Binding(get: { engine.settings.panelRange }, set: { engine.settings.panelRange = $0; engine.want($0) }), tight: true)
        }
        .padding(.top, 14).padding(.bottom, 8)
        HStack(spacing: 14) {
            fig(Fmt.tokens(u.total.total), "tokens")
            fig(Fmt.cost(u.cost), "at API prices")
            fig(u.total.cacheHitRate.map { Fmt.pct($0 * 100) } ?? "–", "cached")
        }
        .padding(.bottom, 6)
        StackChart(series: (rest.isEmpty ? [] : [restSeries]) + shown.reversed().map(\.series),
                   colors: (rest.isEmpty ? [] : [Theme.ink4]) + shown.reversed().map { colors[$0.id] ?? Theme.ink3 }, labels: chartLabels(u))
        ModelList(models: shown, colors: colors, compact: true,
                  other: rest.isEmpty ? nil : (rest.count, rest.map(\.mix.total).reduce(0, +), rest.compactMap(\.cost).reduce(0, +)))
    }

    private func fig(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(v).font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.ink)
            Text(l).font(Theme.ui(12)).foregroundStyle(Theme.ink2)
        }.lineLimit(1).fixedSize()
    }

    // MARK: machines and footer

    @ViewBuilder private var machinesSection: some View {
        SectionHeader(title: "Machines") {
            Text(Fmt.tokens(engine.machines.map(\.tokensPerHour).reduce(0, +)) + " tokens/h").font(Theme.mono(11)).foregroundStyle(Theme.ink2)
        }
        .padding(.top, 14).padding(.bottom, 6)
        MachineRows(machines: engine.machines, now: model.now)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            PillButton(title: "Open Tach") { model.closePanel(); model.openWindow(nil) }
            Spacer()
            Text(engine.refreshing ? "Updating…" : "Updated " + Fmt.ago(engine.updatedAt, now: engine.demo ? model.now.addingTimeInterval(12) : Date()))
                .font(Theme.ui(11)).foregroundStyle(Theme.ink3).padding(.trailing, 4)
            IconButton(symbol: "arrow.clockwise", label: "Refresh") { engine.refresh() }
            IconButton(symbol: "slider.horizontal.3", label: "Settings") { model.closePanel(); model.openWindow(.settings) }
        }
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        .padding(.top, 12)
    }
}

/// The one sentence about the limit most at risk.
struct HeadlineView: View {
    let w: LimitWindow
    let account: Account?
    let now: Date
    var large = false

    var body: some View {
        let h = LimitText.headline(w)
        let strong = w.state == .warn || w.state == .crit || w.state == .limited ? Theme.state(w.state) : Theme.ink
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderIcon(provider: w.provider)
                Text("\(w.provider.name) · \(LimitText.name(w, in: account))").font(Theme.ui(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer()
                Text(w.state == .idle ? "" : Fmt.pct(w.used) + " used").font(Theme.mono(11.5)).foregroundStyle(Theme.ink2)
            }
            (Text(h.before) + Text(h.strong).foregroundColor(strong) + Text(h.after))
                .font(.system(size: large ? 24 : 19, weight: .semibold)).tracking(-0.3).padding(.top, 7).padding(.bottom, 3)
            Text(LimitText.short(w, now: now)).font(Theme.ui(11.5)).foregroundStyle(Theme.ink2).lineLimit(2)
        }
        .padding(.top, 14).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

struct CreditsRow: View {
    let credits: LimitWindow
    let now: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Extra usage credits").font(Theme.ui(12)).fixedSize().layoutPriority(2)
            Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.ink3).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 2)
            Text(credits.amount.map { Fmt.cost($0) + " left" } ?? Fmt.pct(credits.used) + " used").font(Theme.mono(11, .medium)).fixedSize().layoutPriority(2)
        }
        .frame(height: 21)
    }
    private var detail: String {
        var parts: [String] = []
        if let c = credits.cap { parts.append("of " + Fmt.cost(c).replacingOccurrences(of: ".00", with: "")) }
        if let r = credits.resets { let f = DateFormatter(); f.dateFormat = "d MMM"; parts.append("renews " + f.string(from: r)) }
        return parts.joined(separator: ", ")
    }
}

/// Rows of models: colour, name, share bar, tokens, speed, API value.
struct ModelList: View {
    let models: [ModelUsage]
    let colors: [String: Color]
    var compact = false
    /// Every other model as one row: how many, their tokens and their API value.
    var other: (count: Int, tokens: Int64, cost: Double)?

    var body: some View {
        let mx = Double(max(models.map(\.mix.total).max() ?? 1, other?.tokens ?? 0, 1))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28, height: 1)
                Text("Tokens").frame(width: 46, alignment: .trailing)
                Text("Out t/s").frame(width: 46, alignment: .trailing)
                Text("API $").frame(width: 50, alignment: .trailing)
            }
            .font(Theme.ui(10.5)).foregroundStyle(Theme.ink3).frame(height: 20)
            ForEach(models) { m in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ProviderIcon(provider: m.info.provider, size: 14)
                        Text(m.info.short).font(Theme.ui(12)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    PBar(fraction: Double(m.mix.total) / mx, color: colors[m.id] ?? Theme.ink3).frame(width: 28)
                    Text(Fmt.tokens(m.mix.total)).frame(width: 46, alignment: .trailing)
                    HStack(spacing: 4) {
                        if let t = m.tps { QualityMark(quality: m.quality); Text(String(Int(t.p50.rounded()))) } else { Text("–").foregroundStyle(Theme.ink3) }
                    }.frame(width: 46, alignment: .trailing)
                    Text(m.cost.map(Fmt.cost) ?? "–").foregroundStyle(m.cost == nil ? Theme.ink3 : Theme.ink).frame(width: 50, alignment: .trailing).help(m.cost == nil ? "No price set for this model" : "")
                }
                .font(Theme.mono(11.5)).frame(height: 20)
            }
            if let o = other {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.ink4).frame(width: 11, height: 11).frame(width: 14)
                        Text("\(o.count) other model\(o.count == 1 ? "" : "s")").font(Theme.ui(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    PBar(fraction: Double(o.tokens) / mx, color: Theme.ink3).frame(width: 28)
                    Text(Fmt.tokens(o.tokens)).frame(width: 46, alignment: .trailing)
                    Text("").frame(width: 46)
                    Text(Fmt.cost(o.cost)).frame(width: 50, alignment: .trailing)
                }
                .font(Theme.mono(11.5)).foregroundStyle(Theme.ink2).frame(height: 20)
            }
        }
    }
}

struct MachineRows: View {
    let machines: [MachineStatus]
    let now: Date
    var body: some View {
        VStack(spacing: 0) {
            ForEach(machines) { m in
                HStack(spacing: 8) {
                    Circle().fill(m.online ? Theme.ink : .clear).overlay(Circle().strokeBorder(Theme.ink3, lineWidth: m.online ? 0 : 1.2)).frame(width: 6, height: 6)
                    Text(m.name).font(Theme.mono(11.5)).foregroundStyle(m.online ? Theme.ink : Theme.ink3).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(m.name)
                    if m.online {
                        Text("\(m.live) live").font(Theme.ui(11)).foregroundStyle(Theme.ink2).fixedSize()
                        Text(Fmt.tokens(m.tokensPerHour) + "/h").font(Theme.mono(11.5)).frame(width: 56, alignment: .trailing)
                        PBar(fraction: m.share).frame(width: 32)
                        Text(Fmt.pct(m.share * 100)).font(Theme.mono(11)).foregroundStyle(Theme.ink2).frame(width: 30, alignment: .trailing)
                    } else {
                        Text(m.reading ? "reading history…" : m.lastSeen == nil ? (m.error ?? "waiting") : "no data · last seen " + Fmt.ago(m.lastSeen, now: now))
                            .font(Theme.ui(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                .frame(height: 21)
                .help(m.error ?? "")
            }
        }
    }
}

/// Shown before any subscription has been found.
struct EmptyPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    var body: some View {
        VStack(spacing: 6) {
            Text(engine.importing != nil ? "Reading your usage" : "Nothing to show yet").font(Theme.ui(13, .semibold))
            Text(engine.importing ?? "Tach has not found a signed-in tool on this Mac. Connect a subscription to see its limits here.")
                .font(Theme.ui(12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if engine.importing == nil {
                PillButton(title: "Set up Tach…", primary: true) { model.closePanel(); model.openSetup() }.padding(.top, 8)
            } else {
                ProgressView().controlSize(.small).padding(.top, 8)
            }
            ForEach(engine.notes.prefix(3), id: \.self) { Text($0).font(Theme.ui(11)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 20)
    }
}
