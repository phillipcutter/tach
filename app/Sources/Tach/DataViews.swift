import SwiftUI
import TachCore

// MARK: models

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine
    private var detail: ModelBreakdown { model.breakdown }

    var body: some View {
        let loaded = engine.usage[model.range]
        let u = loaded ?? .empty(model.range, now: model.now)
        let colors = model.colors(for: u.models)
        let sel = u.models.first { $0.id == model.modelSelection } ?? u.models.first
        VStack(alignment: .leading, spacing: 0) {
            if loaded == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Adding up usage…").font(Theme.ui(13)).foregroundStyle(Theme.ink2) }.padding(.vertical, 40)
            } else if u.models.isEmpty {
                Text("No usage recorded \(u.phrase).").font(Theme.ui(13)).foregroundStyle(Theme.ink3).padding(.vertical, 40)
            } else {
                table(u, colors, sel)
                HStack(spacing: 14) {
                    ForEach([TimingQuality.exact, .turn, .estimated], id: \.self) { q in
                        HStack(spacing: 5) { QualityMark(quality: q); Text(q.label).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3) }
                    }
                    Spacer()
                    Text("Percentiles need at least 20 samples.").font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                }
                .padding(.top, 8)
                if let m = sel {
                    modelDetail(m, u, colors[m.id] ?? Theme.ink2)
                        .onAppear { model.loadModel(m.id) }
                        .onChange(of: m.id) { _, n in model.loadModel(n) }
                        .onChange(of: model.range) { _, _ in model.loadModel(m.id) }
                        .onChange(of: engine.updatedAt) { _, _ in model.loadModel(m.id, force: true) }
                }
            }
        }
        .onAppear { engine.want(model.range) }
    }

    private func table(_ u: UsageSummary, _ colors: [String: Color], _ sel: ModelUsage?) -> some View {
        let total = Double(max(u.total.total, 1))
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 70, alignment: .trailing)
                Text("Share").frame(width: 96, alignment: .leading)
                Text("Requests").frame(width: 70, alignment: .trailing)
                Text("Cache hit").frame(width: 64, alignment: .trailing)
                Text("TTFT p50 / p95").frame(width: 112, alignment: .trailing)
                Text("Out t/s p50 / p95").frame(width: 118, alignment: .trailing)
                Text("Errors").frame(width: 52, alignment: .trailing)
                Text("API value").frame(width: 76, alignment: .trailing)
            }
            .font(Theme.ui(11)).foregroundStyle(Theme.ink3).frame(height: 28).padding(.horizontal, 8)
            ForEach(u.models) { m in
                let on = m.id == sel?.id
                Button { model.modelSelection = m.id } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: 7) {
                            ProviderIcon(provider: m.info.provider, size: 16)
                            RoundedRectangle(cornerRadius: 2).fill(colors[m.id] ?? Theme.ink3).frame(width: 8, height: 8)
                            Text(m.info.name).font(Theme.ui(12.5)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.tokens(m.mix.total)).frame(width: 70, alignment: .trailing)
                        HStack(spacing: 6) {
                            PBar(fraction: Double(m.mix.total) / total, color: colors[m.id] ?? Theme.ink3).frame(width: 52)
                            Text(String(format: Double(m.mix.total) / total < 0.1 ? "%.1f%%" : "%.0f%%", Double(m.mix.total) / total * 100)).foregroundStyle(Theme.ink2)
                        }.frame(width: 96, alignment: .leading)
                        Text(Fmt.count(m.requests)).frame(width: 70, alignment: .trailing)
                        Text(m.mix.cacheHitRate.map { Fmt.pct($0 * 100) } ?? "–").frame(width: 64, alignment: .trailing)
                        latency(m.ttft, m.quality) { Fmt.seconds($0) }.frame(width: 112, alignment: .trailing)
                        latency(m.tps, m.tps == nil ? .none : m.quality) { String(format: "%.0f", $0) }.frame(width: 118, alignment: .trailing)
                        Text(m.errors > 0 ? String(format: "%.1f%%", Double(m.errors) / Double(max(m.requests, 1)) * 100) : "0").foregroundStyle(m.errors > 0 ? Theme.ink : Theme.ink3).frame(width: 52, alignment: .trailing)
                        Text(m.cost.map(Fmt.cost) ?? "unpriced").foregroundStyle(m.cost == nil ? Theme.ink3 : Theme.ink).frame(width: 76, alignment: .trailing)
                    }
                    .font(Theme.mono(11.5)).frame(height: 32).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.fill2 : .clear))
                    .overlay(alignment: .top) { if !on { Rectangle().fill(Theme.hair).frame(height: 1) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, -8)
    }

    private func latency(_ p: Percentiles?, _ q: TimingQuality, _ f: @escaping (Double) -> String) -> some View {
        HStack(spacing: 5) {
            if let p { QualityMark(quality: q); Text("\(f(p.p50)) / \(f(p.p95))") } else { Text("–").foregroundStyle(Theme.ink3) }
        }
        .help(p.map { "\($0.n) samples · \(q.label)" } ?? "Fewer than 20 samples")
    }

    private func modelDetail(_ m: ModelUsage, _ u: UsageSummary, _ color: Color) -> some View {
        let price = engine.settings.prices.price(m.id)
        let parts: [(String, Int64, Double?)] = [
            ("Cache read", m.mix.cacheRead, price.map { $0.cacheRead ?? $0.input }), ("Cache write 5 min", m.mix.cacheWrite5m, price.map { $0.cacheWrite5m ?? $0.input }),
            ("Cache write 1 h", m.mix.cacheWrite1h, price.map { $0.cacheWrite1h ?? $0.cacheWrite5m ?? $0.input }), ("Input", m.mix.input, price?.input), ("Output", m.mix.output, price?.output),
        ]
        let ms = detail.mixSeries
        let series: [[Int64]] = [ms.map { $0.cacheRead }, ms.map { $0.cacheWrite5m }, ms.map { $0.cacheWrite1h }, ms.map { $0.input }, ms.map { $0.output }]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderIcon(provider: m.info.provider, size: 22)
                Text(m.info.name).font(Theme.ui(16, .semibold))
                Text(u.title).font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                Spacer()
                Text(m.tools.compactMap { Tool(rawValue: $0)?.name }.sorted().joined(separator: ", ")).font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }
            .padding(.top, 26).padding(.bottom, 6)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Token mix over time")
                    StackChart(series: series, colors: Theme.tokenTypes.map(\.1), labels: chartLabels(u), height: 170, leading: 40)
                    FlowLegend(items: Theme.tokenTypes.map { ($0.0, $0.1) })
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "Time to first token") { if m.ttft != nil { QualityMark(quality: m.quality) } }
                            Histogram(samples: detail.ttftSamples, unit: "s", color: color)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "Output tokens per second") { if m.tps != nil { QualityMark(quality: m.quality) } }
                            Histogram(samples: detail.tpsSamples, unit: "", color: color)
                        }
                    }
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Tokens and API value").padding(.bottom, 4)
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.tokenTypes[i].1).frame(width: 8, height: 8)
                            Text(p.0).font(Theme.ui(12.5)); Spacer()
                            Text(Fmt.tokens(p.1)).font(Theme.mono(11.5)).frame(width: 64, alignment: .trailing)
                            Text(p.2.map { Fmt.cost(Double(p.1) * $0 / 1e6) } ?? "–").font(Theme.mono(11.5)).foregroundStyle(Theme.ink2).frame(width: 68, alignment: .trailing)
                        }.frame(height: 26)
                    }
                    HStack { Text("Of output, reasoning").font(Theme.ui(12)).foregroundStyle(Theme.ink3); Spacer(); Text(Fmt.tokens(m.mix.thinking)).font(Theme.mono(11.5)).foregroundStyle(Theme.ink2) }.frame(height: 24)
                    HStack { Text("Total").font(Theme.ui(12.5, .medium)); Spacer(); Text(Fmt.tokens(m.mix.total)).font(Theme.mono(11.5)).frame(width: 64, alignment: .trailing)
                        Text(m.cost.map(Fmt.cost) ?? "unpriced").font(Theme.mono(11.5, .medium)).frame(width: 68, alignment: .trailing) }
                        .frame(height: 30).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
                    split("Requests by effort", detail.byEffort.map { ($0.name, $0.requests) })
                    split("Requests by speed", detail.bySpeed.map { ($0.name, $0.requests) })
                    split("Main and subagent", [("main", detail.main), ("subagent", detail.subagent)])
                }
                .frame(width: 330, alignment: .topLeading)
            }
        }
    }

    private func split(_ title: String, _ items: [(String, Int64)]) -> some View {
        let total = Double(max(items.map(\.1).reduce(0, +), 1))
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title).padding(.top, 14)
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 8) {
                    Text(it.0).font(Theme.ui(12.5)).frame(width: 84, alignment: .leading)
                    PBar(fraction: Double(it.1) / total)
                    Text(Fmt.count(it.1)).font(Theme.mono(11.5)).frame(width: 60, alignment: .trailing)
                    Text(Fmt.pct(Double(it.1) / total * 100)).font(Theme.mono(11)).foregroundStyle(Theme.ink3).frame(width: 36, alignment: .trailing)
                }.frame(height: 22)
            }
        }
    }
}

// MARK: machines

struct MachinesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        let u = engine.usage[model.range] ?? .empty(model.range, now: model.now)
        let total = Double(max(u.total.total, 1))
        VStack(alignment: .leading, spacing: 0) {
            Text("Limits belong to the account, so a machine shows only its share of usage.").font(Theme.ui(12)).foregroundStyle(Theme.ink3).padding(.bottom, 10)
            HStack(spacing: 10) {
                Text("Machine").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 190, alignment: .leading)
                Text("Live").frame(width: 44, alignment: .trailing)
                Text("Tokens/h now").frame(width: 96, alignment: .trailing)
                Text("Tokens, " + model.range.short).frame(width: 96, alignment: .trailing)
                Text("Share").frame(width: 110, alignment: .leading)
                Text("API value").frame(width: 80, alignment: .trailing)
                Text("Collector").frame(width: 70, alignment: .trailing)
            }
            .font(Theme.ui(11)).foregroundStyle(Theme.ink3).frame(height: 28)
            ForEach(engine.machines) { m in
                let slice = u.byMachine.first { $0.id == String(m.id) }
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(m.online ? Theme.ink : .clear).overlay(Circle().strokeBorder(Theme.ink3, lineWidth: m.online ? 0 : 1.2)).frame(width: 7, height: 7)
                        Text(m.name).font(Theme.mono(12.5)).foregroundStyle(m.online ? Theme.ink : Theme.ink2).lineLimit(1).truncationMode(.middle)
                        if m.isLocal { Text("this Mac").font(Theme.ui(11)).foregroundStyle(Theme.ink3) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(m.online ? "Reporting · seen " + Fmt.ago(m.lastSeen, now: model.now) : m.reading ? "Reading history…" : (m.error ?? "Not reporting") + (m.lastSeen == nil ? "" : " · last seen " + Fmt.ago(m.lastSeen, now: model.now)))
                        .font(Theme.ui(11.5)).foregroundStyle(m.online || m.reading ? Theme.ink2 : Theme.warn).lineLimit(2).frame(width: 190, alignment: .leading)
                    Text("\(m.live)").frame(width: 44, alignment: .trailing)
                    Text(Fmt.tokens(m.tokensPerHour)).frame(width: 96, alignment: .trailing)
                    Text(Fmt.tokens(slice?.tokens ?? 0)).frame(width: 96, alignment: .trailing)
                    HStack(spacing: 6) { PBar(fraction: Double(slice?.tokens ?? 0) / total).frame(width: 64); Text(Fmt.pct(Double(slice?.tokens ?? 0) / total * 100)).foregroundStyle(Theme.ink2) }.frame(width: 110, alignment: .leading)
                    Text(Fmt.cost(slice?.cost ?? 0)).frame(width: 80, alignment: .trailing)
                    Text(m.version ?? "–").foregroundStyle(m.version == Collector.version ? Theme.ink3 : Theme.warn).frame(width: 70, alignment: .trailing)
                }
                .font(Theme.mono(11.5)).frame(minHeight: 38).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
            HStack(spacing: 10) {
                PillButton(title: "Add a machine…") { model.nav = .settings }
                Text("Machines are reached over SSH with your own keys and config.").font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }.padding(.top, 16)
            SectionHeader("Tokens by tool, " + u.title).padding(.top, 26).padding(.bottom, 4)
            ForEach(u.byTool) { t in
                HStack(spacing: 10) {
                    ProviderIcon(provider: Tool(rawValue: t.id)?.provider, size: 16)
                    Text(t.name).font(Theme.ui(12.5)).frame(width: 110, alignment: .leading)
                    PBar(fraction: Double(t.tokens) / total, color: Theme.provider(Tool(rawValue: t.id)?.provider)).frame(maxWidth: 360)
                    Text(Fmt.tokens(t.tokens)).font(Theme.mono(11.5)).frame(width: 70, alignment: .trailing)
                    Text(Fmt.count(t.requests) + " requests").font(Theme.mono(11.5)).foregroundStyle(Theme.ink2).frame(width: 130, alignment: .trailing)
                    Text(Fmt.cost(t.cost)).font(Theme.mono(11.5)).frame(width: 80, alignment: .trailing)
                    Spacer()
                }.frame(height: 28)
            }
        }
        .onAppear { engine.want(model.range) }
    }
}

// MARK: sessions

struct SessionsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: Engine

    var body: some View {
        let live = Set(engine.liveSessions.map(\.id))
        let rows = model.sessionFilter == "live" ? engine.sessions.filter { live.contains($0.id) } : engine.sessions
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Segmented(options: [("all", "Recent"), ("live", "Live")], selection: $model.sessionFilter)
                Text("Sessions whose process is still running, and any active in the last day.").font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }.padding(.bottom, 10)
            HStack(spacing: 10) {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tool").frame(width: 110, alignment: .leading)
                Text("Model").frame(width: 130, alignment: .leading)
                Text("Machine").frame(width: 130, alignment: .leading)
                Text("Status").frame(width: 70, alignment: .leading)
                Text("Running").frame(width: 76, alignment: .trailing)
                Text("Last active").frame(width: 90, alignment: .trailing)
                Text("Context").frame(width: 110, alignment: .leading)
            }
            .font(Theme.ui(11)).foregroundStyle(Theme.ink3).frame(height: 28)
            if rows.isEmpty { Text("No sessions.").font(Theme.ui(12.5)).foregroundStyle(Theme.ink3).padding(.vertical, 24) }
            ForEach(rows) { s in
                let isLive = live.contains(s.id)
                HStack(spacing: 10) {
                    Text(projectName(s)).font(Theme.ui(12.5, .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(s.cwd ?? "")
                    HStack(spacing: 6) { ProviderIcon(provider: Tool(rawValue: s.tool)?.provider, size: 15); Text(Tool(rawValue: s.tool)?.name ?? s.tool) }.font(Theme.ui(12)).frame(width: 110, alignment: .leading)
                    Text(s.model.map { ModelCatalog.info($0).short } ?? "–").font(Theme.ui(12)).lineLimit(1).frame(width: 130, alignment: .leading)
                    Text(s.machine).font(Theme.mono(11.5)).lineLimit(1).frame(width: 130, alignment: .leading)
                    HStack(spacing: 5) { Circle().fill(isLive ? Theme.ink : Theme.ink4).frame(width: 6, height: 6); Text(isLive ? (s.status == "busy" ? "Working" : "Live") : "Idle") }
                        .font(Theme.ui(12)).foregroundStyle(isLive ? Theme.ink : Theme.ink3).frame(width: 70, alignment: .leading)
                    Text(s.started.map { Fmt.duration(model.now.timeIntervalSince($0)) } ?? "–").font(Theme.mono(11.5)).frame(width: 76, alignment: .trailing)
                    Text(Fmt.ago(s.updated, now: model.now)).font(Theme.mono(11.5)).foregroundStyle(Theme.ink2).frame(width: 90, alignment: .trailing)
                    HStack(spacing: 6) {
                        if let c = s.ctx { PBar(fraction: c / 100, color: c >= 80 ? Theme.warn : Theme.ink2).frame(width: 60); Text(Fmt.pct(c)).font(Theme.mono(11.5)) } else if let t = s.tokens, t > 0 { Text(Fmt.tokens(t) + " tokens").font(Theme.mono(11.5)).foregroundStyle(Theme.ink2).help("Tokens in the latest request; the context window size is not logged") } else { Text("–").foregroundStyle(Theme.ink3) }
                    }.frame(width: 110, alignment: .leading)
                }
                .frame(height: 36).overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
        }
    }
}
