import SwiftUI
import TachCore

// MARK: limit bar

/// One limit as a bar: solid = used, faint = projected by reset, white tick = even pace.
/// It fills the row's height so the pace tick can run through neighbouring rows.
struct LimitBar: View {
    let w: LimitWindow
    var height: CGFloat = 6
    var rowHeight: CGFloat = 21
    var tickUp = false
    var tickDown = false
    /// Percent at which this session's share of the week begins.
    var notchAt: Double?

    var body: some View {
        Canvas { ctx, size in
            let y = (size.height - height) / 2, W = size.width
            if w.state == .idle {
                var x: CGFloat = 0
                while x < W { ctx.fill(Path(CGRect(x: x, y: y, width: 3, height: height)), with: .color(Theme.hair2)); x += 6 }
                return
            }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: W, height: height), cornerRadius: height / 2), with: .color(Theme.fill2))
            let col = Theme.state(w.state)
            func seg(_ pct: Double) -> Path {
                let width = pct <= 0 ? 0 : max(W * min(pct, 100) / 100, height)
                return Path(roundedRect: CGRect(x: 0, y: y, width: width, height: height), cornerRadius: height / 2)
            }
            if w.state == .stale {
                ctx.drawLayer { l in
                    l.clip(to: seg(w.used))
                    var x = -height
                    while x < W {
                        var p = Path(); p.move(to: CGPoint(x: x, y: y + height)); p.addLine(to: CGPoint(x: x + height, y: y))
                        l.stroke(p, with: .color(Theme.ink3), lineWidth: 1.5)
                        x += 4
                    }
                }
                return
            }
            if w.projected > w.used { ctx.fill(seg(w.projected), with: .color(col.opacity(0.3))) }
            ctx.fill(seg(w.used), with: .color(col))
            if let n = notchAt, n > 0, n < w.used {
                ctx.fill(Path(CGRect(x: W * n / 100 - 0.75, y: y, width: 1.5, height: height)), with: .color(.black.opacity(0.7)))
            }
            if let e = w.elapsed, w.state != .limited {
                let x = W * e / 100
                let top = tickUp ? 0 : y - 3, bottom = tickDown ? size.height : y + height + 3
                ctx.fill(Path(roundedRect: CGRect(x: x - 2, y: top, width: 4, height: bottom - top), cornerRadius: 1.5), with: .color(.black.opacity(0.6)))
                ctx.fill(Path(roundedRect: CGRect(x: x - 1, y: top, width: 2, height: bottom - top), cornerRadius: 1), with: .color(.white))
            }
        }
        .frame(height: rowHeight)
        .accessibilityElement()
        .accessibilityLabel("\(w.title): \(Fmt.pct(w.used)) used")
    }
}

// MARK: limit group

private struct Wedge: Shape {
    var top: Double, from: Double, to: Double  // fractions of the width
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: r.width * top, y: 0))
        p.addLine(to: CGPoint(x: r.width * to, y: r.height)); p.addLine(to: CGPoint(x: r.width * from, y: r.height))
        p.closeSubpath()
        return p
    }
}

private struct WedgeEdges: Shape {
    var top: Double, from: Double, to: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: r.width * from, y: r.height))
        p.move(to: CGPoint(x: r.width * top, y: 0)); p.addLine(to: CGPoint(x: r.width * to, y: r.height))
        return p
    }
}

/// One budget: the 5-hour session above the week it draws on, joined by a wedge that shows which
/// slice of the week this session has used, with model limits indented under the week.
struct PoolView: View {
    let pool: LimitPool
    let now: Date
    var selected: String?
    var onSelect: ((LimitWindow) -> Void)?
    var labelWidth: CGFloat = 58

    var body: some View {
        let share = (pool.session?.weekShare).flatMap { $0 > 0.05 && pool.session?.state != .idle ? $0 : nil }
        VStack(alignment: .leading, spacing: 0) {
            if let n = pool.name {
                Text(n).font(Theme.ui(11)).foregroundStyle(Theme.ink3).frame(height: 18)
            }
            if let s = pool.session {
                row(s, "5-hour")
                if let share, let wk = pool.week { wedge(s, wk, share) }
            }
            if let wk = pool.week {
                row(wk, "Week", notch: share.map { wk.used - $0 }, tickDown: !pool.scoped.isEmpty)
            }
            ForEach(Array(pool.scoped.enumerated()), id: \.element.id) { i, k in
                row(k, k.label, kid: i, tickUp: sameWindow(k), tickDown: i < pool.scoped.count - 1 && sameWindow(k))
            }
            if pool.session == nil, pool.week != nil {
                Text("No 5-hour limit reported for this plan.").font(Theme.ui(11)).foregroundStyle(Theme.ink3)
                    .padding(.leading, labelWidth + 8).frame(height: 19)
            }
        }
    }

    private func sameWindow(_ k: LimitWindow) -> Bool {
        guard let a = k.resets, let b = pool.week?.resets else { return false }
        return abs(a.timeIntervalSince(b)) < 120
    }

    @ViewBuilder
    private func row(_ w: LimitWindow, _ label: String, kid: Int? = nil, notch: Double? = nil, tickUp: Bool = false, tickDown: Bool = false) -> some View {
        let h: CGFloat = kid == nil ? 21 : 19
        let on = selected == w.id
        let content = HStack(spacing: 8) {
            Text(label).font(Theme.ui(12)).lineLimit(1)
                .foregroundStyle(kid != nil || w.state == .stale || w.state == .idle ? Theme.ink2 : Theme.ink)
                .padding(.leading, kid == nil ? 0 : 15)
                .frame(width: labelWidth, height: h, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    if let kid {
                        Path { p in
                            let top: CGFloat = kid == 0 ? -2 : -h / 2
                            p.move(to: CGPoint(x: 3.5, y: top)); p.addLine(to: CGPoint(x: 3.5, y: h / 2 - 4))
                            p.addQuadCurve(to: CGPoint(x: 7.5, y: h / 2), control: CGPoint(x: 3.5, y: h / 2))
                            p.addLine(to: CGPoint(x: 11, y: h / 2))
                        }.stroke(Theme.ink4, lineWidth: 1)
                    }
                }
            LimitBar(w: w, height: kid == nil ? 6 : 4, rowHeight: h, tickUp: tickUp, tickDown: tickDown, notchAt: notch)
            if w.state == .idle {
                Text("not started").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).frame(width: 88, alignment: .trailing)
            } else {
                Text(Fmt.pct(w.used)).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.figure(w.state)).frame(width: 34, alignment: .trailing)
                Text(kid == nil ? (w.remaining.map(Fmt.duration) ?? "") : "").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.fill2 : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        if let onSelect {
            Button { onSelect(w) } label: { content }.buttonStyle(.plain)
                .accessibilityLabel("\(w.title), \(Fmt.pct(w.used)) used")
        } else {
            content
        }
    }

    private func wedge(_ s: LimitWindow, _ wk: LimitWindow, _ share: Double) -> some View {
        let col = s.state == .stale ? Theme.ink3 : Theme.state(s.state)
        let top = min(s.used, 100) / 100, to = min(wk.used, 100) / 100, from = max(wk.used - share, 0) / 100
        return HStack(spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 1)
            ZStack {
                Wedge(top: top, from: from, to: to).fill(col.opacity(0.14))
                WedgeEdges(top: top, from: from, to: to).stroke(col.opacity(0.55), lineWidth: 1)
            }
            .frame(height: 26).padding(.vertical, -7.5)
            Text("\(Int(share.rounded()))% of the week").font(Theme.ui(10)).foregroundStyle(Theme.ink3).lineLimit(1)
                .frame(width: 88, alignment: .trailing)
        }
        .frame(height: 11)
        .allowsHitTesting(false)
    }
}

/// "This session has used 6% of the week. A full session uses about 7%, so the week has room for about 6 more."
func sessionsLeftText(_ pool: LimitPool) -> String? {
    guard let s = pool.session, let wk = pool.week, let share = s.weekShare, share > 0.05, s.used > 1, s.state != .stale, s.state != .idle else { return nil }
    let full = share / s.used * 100
    guard full > 0.1 else { return nil }
    let left = Int(((100 - wk.used) / full).rounded(.down))
    return "This session has used \(Int(share.rounded()))% of the week. A full session uses about \(Int(full.rounded()))%, so the week has room for about \(left) more."
}

// MARK: ring

/// Concentric rings, outermost first: the week outside, the 5-hour session inside.
struct RingView: View {
    let windows: [LimitWindow]
    var size: CGFloat = 66
    var lineWidth: CGFloat = 5
    var gap: CGFloat = 2.5
    var text: String?
    var textState: LimitState = .ok

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            for (i, w) in windows.enumerated() {
                let r = sz.width / 2 - 3 - lineWidth / 2 - CGFloat(i) * (lineWidth + gap)
                let none = w.state == .idle
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(circle, with: .color(Theme.fill2), style: StrokeStyle(lineWidth: lineWidth, dash: none ? [2, 3] : []))
                if none { continue }
                func arc(_ pct: Double) -> Path {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(pct, 100) / 100), clockwise: false)
                    return p
                }
                let col = Theme.state(w.state)
                if w.state == .stale {
                    ctx.stroke(arc(w.used), with: .color(Theme.ink3), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 2]))
                    continue
                }
                if w.projected > w.used { ctx.stroke(arc(w.projected), with: .color(col.opacity(0.3)), lineWidth: lineWidth) }
                if w.used > 0 { ctx.stroke(arc(w.used), with: .color(col), lineWidth: lineWidth) }
                if let e = w.elapsed, w.state != .limited {
                    let a = e / 100 * 2 * .pi - .pi / 2
                    let r1 = r - lineWidth / 2 - 0.5, r2 = r + lineWidth / 2 + (i == 0 ? 2.5 : 1.5)
                    var t = Path()
                    t.move(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a))); t.addLine(to: CGPoint(x: c.x + r2 * cos(a), y: c.y + r2 * sin(a)))
                    ctx.stroke(t, with: .color(.black.opacity(0.6)), lineWidth: 3.4)
                    ctx.stroke(t, with: .color(.white), lineWidth: 1.4)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let text {
                Text(text).font(.system(size: size < 70 ? 14 : 16.5, weight: .semibold)).fontWidth(windows.count > 1 ? .condensed : .standard).monospacedDigit()
                    .foregroundStyle(textState == .stale || textState == .idle ? Theme.ink3 : Theme.ink)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(windows.map { "\($0.title) \(Fmt.pct($0.used)) used" }.joined(separator: ", "))
    }
}

/// The ring pair for an account: week outside, 5-hour inside, the tightest limit's figure in the middle.
struct AccountRing: View {
    let account: Account
    var size: CGFloat = 66
    var lineWidth: CGFloat = 5
    var gap: CGFloat = 2.5

    var body: some View {
        let t = account.tightest
        let pool = t.flatMap { account.pool(of: $0) } ?? account.pools.first
        let ws = [pool?.week, pool?.session].compactMap { $0 }
        RingView(windows: ws.isEmpty ? (t.map { [$0] } ?? []) : ws, size: size, lineWidth: lineWidth, gap: gap,
                 text: t.map { $0.state == .idle ? "–" : Fmt.pct($0.used) } ?? "–", textState: t?.state ?? .idle)
    }
}

// MARK: small pieces

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(Theme.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.ink3).lineLimit(1).fixedSize()
            Rectangle().fill(Theme.hair).frame(height: 1)
            trailing()
        }
        .frame(minHeight: 22)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// A compact segmented control.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var tight = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button { selection = o.0 } label: {
                    Text(o.1).font(Theme.ui(11.5, .medium)).foregroundStyle(on ? Theme.ink : Theme.ink2).lineLimit(1).fixedSize()
                        .padding(.horizontal, tight ? 6 : 8).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.fill3 : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill1))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hair, lineWidth: 0.5))
        .fixedSize()
    }
}

struct RangePicker: View {
    @Binding var range: RangeKey
    var tight = false
    var body: some View { Segmented(options: RangeKey.allCases.map { ($0, $0.short) }, selection: $range, tight: tight) }
}

/// A thin proportion bar.
struct PBar: View {
    var fraction: Double
    var color: Color = Theme.ink2
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill2)
                Capsule().fill(color).frame(width: fraction > 0 ? max(g.size.width * min(fraction, 1), 3) : 0)
            }
        }
        .frame(height: 4)
    }
}

/// Where a latency figure comes from: three bars = measured per request, two = per turn, one = estimated.
struct QualityMark: View {
    let quality: TimingQuality
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5).fill(i < quality.level ? Theme.ink2 : Theme.ink4)
                    .frame(width: 2.2, height: 3 + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 9, alignment: .bottom)
        .help(quality.label)
        .accessibilityLabel(quality.label)
    }
}

struct AgeBadge: View {
    let text: String
    var stale = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(stale ? Color.clear : Theme.ink2).overlay(Circle().strokeBorder(Theme.ink3, lineWidth: stale ? 1 : 0)).frame(width: 5, height: 5)
            Text(text).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink3)
        }
    }
}

struct PillButton: View {
    let title: String
    var primary = false
    var small = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.ui(small ? 11.5 : 12.5, .medium)).foregroundStyle(primary ? .white : Theme.ink)
                .padding(.horizontal, small ? 10 : 12).frame(height: small ? 22 : 26)
                .background(Capsule().fill(primary ? Theme.accent : Theme.fill2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2).frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

// MARK: charts

/// Stacked bars of tokens per time bucket, one colour per model.
struct StackChart: View {
    /// One series per model, bottom to top.
    let series: [[Int64]]
    let colors: [Color]
    let labels: [String]   // start, middle, end
    var height: CGFloat = 62
    var leading: CGFloat = 30

    var body: some View {
        Canvas { ctx, size in
            let n = series.first?.count ?? 0
            let bottom: CGFloat = 14, top: CGFloat = 4
            let ph = size.height - bottom - top, pw = size.width - leading
            var maxV: Int64 = 1
            for i in 0..<n { maxV = max(maxV, series.reduce(0) { $0 + $1[i] }) }
            let nice = niceCeil(Double(maxV))
            for f in [0.0, 0.5, 1.0] {
                let y = top + ph * (1 - f)
                var l = Path(); l.move(to: CGPoint(x: leading, y: y)); l.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(l, with: .color(Theme.hair), lineWidth: 1)
                ctx.draw(Text(f == 0 ? "0" : Fmt.axis(nice * f)).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: leading - 5, y: y), anchor: .trailing)
            }
            guard n > 0 else { return }
            let bw = pw / CGFloat(n)
            for i in 0..<n {
                var y = top + ph
                for (si, s) in series.enumerated() where s[i] > 0 {
                    let h = max(CGFloat(Double(s[i]) / nice) * ph, 0.5)
                    y -= h
                    ctx.fill(Path(roundedRect: CGRect(x: leading + CGFloat(i) * bw + bw * 0.14, y: y, width: bw * 0.72, height: h), cornerRadius: min(1.5, h / 2)), with: .color(colors[si]))
                }
            }
            let ly = size.height - 5
            if labels.count == 3 {
                ctx.draw(Text(labels[0]).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: leading, y: ly), anchor: .leading)
                ctx.draw(Text(labels[1]).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: leading + pw / 2, y: ly), anchor: .center)
                ctx.draw(Text(labels[2]).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: size.width, y: ly), anchor: .trailing)
            }
        }
        .frame(height: height)
    }
}

func niceCeil(_ v: Double) -> Double {
    guard v > 0 else { return 1 }
    let p = pow(10, floor(log10(v))), m = v / p
    return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p
}

/// Axis labels for a usage chart: start, middle and "now".
func chartLabels(_ u: UsageSummary) -> [String] {
    let f = DateFormatter()
    f.dateFormat = u.bucketSeconds < 86400 && u.days <= 1.01 ? "HH:mm" : u.days <= 8 ? "EEE HH:mm" : "d MMM"
    let mid = u.start.addingTimeInterval(u.end.timeIntervalSince(u.start) / 2)
    return [f.string(from: u.start), f.string(from: mid), "now"]
}

/// Usage so far against the even-pace diagonal, with the projection dashed.
struct TrajectoryChart: View {
    let w: LimitWindow
    let points: [(Date, Double)]
    let now: Date
    var height: CGFloat = 220
    var axes = true

    var body: some View {
        Canvas { ctx, size in
            guard let start = w.start, let resets = w.resets, w.length > 0 else { return }
            let l: CGFloat = axes ? 34 : 0, b: CGFloat = axes ? 18 : 0, t: CGFloat = axes ? 16 : 2
            let pw = size.width - l - 2, ph = size.height - t - b
            func X(_ d: Date) -> CGFloat { l + pw * CGFloat(min(max(d.timeIntervalSince(start) / w.length, 0), 1)) }
            func Y(_ v: Double) -> CGFloat { t + ph * CGFloat(1 - min(max(v, 0), 100) / 100) }
            let col = Theme.state(w.state == .stale ? .ok : w.state)
            if axes {
                for v in [0.0, 50, 100] {
                    var g = Path(); g.move(to: CGPoint(x: l, y: Y(v))); g.addLine(to: CGPoint(x: size.width, y: Y(v)))
                    ctx.stroke(g, with: .color(v == 100 ? Theme.ink3 : Theme.hair), lineWidth: 1)
                    ctx.draw(Text(v == 0 ? "0" : v == 50 ? "50" : "100%").font(Theme.mono(9.5)).foregroundColor(Theme.ink3), at: CGPoint(x: l - 6, y: Y(v)), anchor: .trailing)
                }
            }
            // even pace
            var pace = Path(); pace.move(to: CGPoint(x: X(start), y: Y(0))); pace.addLine(to: CGPoint(x: X(resets), y: Y(100)))
            ctx.stroke(pace, with: .color(Theme.ink3), style: StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
            // usage so far
            var pts = points.filter { $0.0 >= start && $0.0 <= now }
            if pts.first.map({ $0.0.timeIntervalSince(start) > 60 }) ?? true { pts.insert((start, 0), at: 0) }
            pts.append((min(now, resets), w.used))
            var line = Path(), area = Path()
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: X(p.0), y: Y(p.1))
                if i == 0 { line.move(to: pt); area.move(to: CGPoint(x: pt.x, y: Y(0))); area.addLine(to: pt) } else { line.addLine(to: pt); area.addLine(to: pt) }
            }
            let nx = X(min(now, resets))
            area.addLine(to: CGPoint(x: nx, y: Y(0))); area.closeSubpath()
            ctx.fill(area, with: .color(col.opacity(0.14)))
            ctx.stroke(line, with: .color(col), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            if axes {
                var nl = Path(); nl.move(to: CGPoint(x: nx, y: Y(0))); nl.addLine(to: CGPoint(x: nx, y: Y(w.used)))
                ctx.stroke(nl, with: .color(Theme.hair2), lineWidth: 1)
            }
            // projection
            if w.state != .stale, w.state != .limited, w.burnPerHour > 0 {
                var proj = Path(); proj.move(to: CGPoint(x: nx, y: Y(w.used)))
                if let hit = w.hitAt {
                    proj.addLine(to: CGPoint(x: X(hit), y: Y(100)))
                    ctx.stroke(proj, with: .color(col), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                    var flat = Path(); flat.move(to: CGPoint(x: X(hit), y: Y(100))); flat.addLine(to: CGPoint(x: X(resets), y: Y(100)))
                    ctx.stroke(flat, with: .color(col), lineWidth: 2.4)
                    ctx.fill(Path(ellipseIn: CGRect(x: X(hit) - 3, y: Y(100) - 3, width: 6, height: 6)), with: .color(Theme.window))
                    ctx.stroke(Path(ellipseIn: CGRect(x: X(hit) - 3, y: Y(100) - 3, width: 6, height: 6)), with: .color(col), lineWidth: 1.6)
                    if axes {
                        ctx.draw(Text("limit at " + Fmt.clock(hit, now: now)).font(Theme.mono(10)).foregroundColor(col), at: CGPoint(x: min(X(hit), size.width - 46), y: Y(100) - 9), anchor: .center)
                    }
                } else {
                    proj.addLine(to: CGPoint(x: X(resets), y: Y(w.projected)))
                    ctx.stroke(proj, with: .color(col), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: nx - 3, y: Y(w.used) - 3, width: 6, height: 6)), with: .color(col))
            if axes {
                let ly = size.height - 5
                ctx.draw(Text(Fmt.clock(start, now: now)).font(Theme.mono(9.5)).foregroundColor(Theme.ink3), at: CGPoint(x: l, y: ly), anchor: .leading)
                ctx.draw(Text("now").font(Theme.mono(9.5)).foregroundColor(Theme.ink3), at: CGPoint(x: min(max(nx, l + 60), size.width - 90), y: ly), anchor: .center)
                ctx.draw(Text("resets " + Fmt.clock(resets, now: now)).font(Theme.mono(9.5)).foregroundColor(Theme.ink3), at: CGPoint(x: size.width, y: ly), anchor: .trailing)
            }
        }
        .frame(height: height)
    }
}

/// Counts of samples in log-spaced buckets, with the median marked.
struct Histogram: View {
    let samples: [Double]
    let unit: String
    var color: Color = Theme.ink2
    var height: CGFloat = 110

    var body: some View {
        Canvas { ctx, size in
            let v = samples.filter { $0 > 0 }.sorted()
            guard v.count >= 5, let lo = v.first, let hi = v.last, hi > lo else {
                ctx.draw(Text("Not enough samples").font(Theme.ui(11)).foregroundColor(Theme.ink3), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let a = log(v[Int(Double(v.count - 1) * 0.01)]), b = log(v[Int(Double(v.count - 1) * 0.99)])
            guard b > a else { return }
            let n = 24
            var bins = Array(repeating: 0, count: n)
            for x in v { bins[min(max(Int((log(x) - a) / (b - a) * Double(n)), 0), n - 1)] += 1 }
            let m = CGFloat(bins.max() ?? 1), bottom: CGFloat = 16, ph = size.height - bottom - 4, bw = size.width / CGFloat(n)
            for (i, c) in bins.enumerated() where c > 0 {
                let h = max(CGFloat(c) / m * ph, 1)
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * bw + 1, y: 4 + ph - h, width: bw - 2, height: h), cornerRadius: 1.5), with: .color(color.opacity(0.85)))
            }
            let med = v[v.count / 2], mx = CGFloat((log(med) - a) / (b - a)) * size.width
            var ml = Path(); ml.move(to: CGPoint(x: mx, y: 0)); ml.addLine(to: CGPoint(x: mx, y: 4 + ph))
            ctx.stroke(ml, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            func lab(_ x: Double) -> String { x >= 100 ? String(format: "%.0f", x) : x >= 10 ? String(format: "%.0f", x) : String(format: "%.1f", x) }
            let ly = size.height - 5
            ctx.draw(Text(lab(exp(a)) + unit).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: 0, y: ly), anchor: .leading)
            ctx.draw(Text("median " + lab(med) + unit).font(Theme.mono(9)).foregroundColor(Theme.ink2), at: CGPoint(x: min(max(mx, 40), size.width - 40), y: ly), anchor: .center)
            ctx.draw(Text(lab(exp(b)) + unit).font(Theme.mono(9)).foregroundColor(Theme.ink3), at: CGPoint(x: size.width, y: ly), anchor: .trailing)
        }
        .frame(height: height)
    }
}
