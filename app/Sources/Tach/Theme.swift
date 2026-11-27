import AppKit
import SwiftUI
import TachCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Colours and type for the panel and window. The app is dark in both system appearances.
enum Theme {
    static let ink = Color.white.opacity(0.93)
    static let ink2 = Color.white.opacity(0.66)
    static let ink3 = Color.white.opacity(0.46)
    static let ink4 = Color.white.opacity(0.24)
    static let hair = Color.white.opacity(0.085)
    static let hair2 = Color.white.opacity(0.15)
    static let fill1 = Color.white.opacity(0.055)
    static let fill2 = Color.white.opacity(0.095)
    static let fill3 = Color.white.opacity(0.16)
    static let window = Color(hex: 0x1B1D21)
    static let accent = Color(hex: 0x2F84F6)

    // limit state: neutral until it matters
    static let level = Color(hex: 0xE3E8EE)
    static let warn = Color(hex: 0xF4B13C)
    static let crit = Color(hex: 0xFF5B4A)

    static func state(_ s: LimitState) -> Color {
        switch s {
        case .ok: level
        case .warn: warn
        case .crit, .limited: crit
        case .stale: ink3
        case .idle: ink4
        }
    }

    /// Text colour for a figure in a given state: only warning and critical take colour.
    static func figure(_ s: LimitState) -> Color {
        switch s {
        case .warn: warn
        case .crit, .limited: crit
        case .stale, .idle: ink2
        case .ok: ink
        }
    }

    static func provider(_ p: Provider?) -> Color {
        switch p {
        case .claude: Color(hex: 0xD97757)
        case .openai: Color(hex: 0x4C8DF6)
        case .gemini: Color(hex: 0x10A37F)
        case nil: Color(hex: 0x8C98AE)
        }
    }

    private static let modelColors: [String: UInt32] = [
        "claude-opus-5-5": 0xD97757, "claude-mythos-5-2": 0xEBA689, "claude-fable-5-2": 0xF8D9CB,
        "gpt-6.2-astra": 0x4C8DF6, "gpt-6.2-sol": 0xA3C6FB, "gemini-4-neon": 0x10A37F,
    ]

    /// One hue per subscription, lighter steps for further models. `rank` is the model's position among its provider's models.
    static func model(_ info: ModelInfo, rank: Int = 0) -> Color {
        if let h = modelColors[info.id] { return Color(hex: h) }
        let base = provider(info.provider)
        return base.opacity(max(0.3, 0.75 - Double(rank) * 0.15))
    }

    /// Token types: a neutral ramp, dark to light.
    static let tokenTypes: [(String, Color)] = [
        ("Cache read", Color(hex: 0x434C5C)), ("Cache write 5 min", Color(hex: 0x66728A)), ("Cache write 1 h", Color(hex: 0x8C98AE)),
        ("Input", Color(hex: 0xBBC5D4)), ("Output", Color(hex: 0xF4F6F9)),
    ]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

enum Fmt {
    static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        if v >= 1e12 { return String(format: "%.2fT", v / 1e12) }
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e8 { return String(format: "%.0fM", v / 1e6) }
        if v >= 1e7 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e6 { return String(format: "%.2fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return String(n)
    }

    static func cost(_ d: Double) -> String {
        if d >= 100 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.locale = Locale(identifier: "en_US")
            return "$" + (f.string(from: NSNumber(value: d.rounded())) ?? String(Int(d)))
        }
        return String(format: "$%.2f", d)
    }

    static func count(_ n: Int64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// "2d 18h", "1h 48m", "16m", "40s".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded()), 0)
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// "15:28" today, "Fri 08:02" otherwise.
    static func clock(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// "12s ago", "9m ago", "3h ago", "2d ago": one unit, since the age of a reading needs no more.
    static func ago(_ d: Date?, now: Date) -> String {
        guard let d else { return "never" }
        let s = Int(max(now.timeIntervalSince(d), 0))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// Axis labels: "50M", "2.5M", "500K".
    static func axis(_ n: Double) -> String {
        func t(_ v: Double, _ u: String) -> String { (v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)) + u }
        if n >= 1e9 { return t(n / 1e9, "B") }
        if n >= 1e6 { return t(n / 1e6, "M") }
        if n >= 1e3 { return t(n / 1e3, "K") }
        return String(format: "%.0f", n)
    }

    /// Where a limit reading came from, in words.
    static func source(_ src: String, provider: Provider) -> String {
        switch src {
        case "rollout": "Codex logs"
        case "rpc": "the Antigravity app"
        case "cli": "the claude command"
        case "history": "Claude Desktop’s history"
        case "transcript": "Claude Code logs"
        default: "\(provider.name)’s usage service"
        }
    }

    /// Burn rate in the window's natural unit.
    static func rate(_ perHour: Double, weekly: Bool) -> String {
        weekly ? String(format: "%.1f%%/day", perHour * 24) : String(format: "%.0f%%/h", perHour)
    }

    static func seconds(_ s: Double) -> String { s >= 10 ? String(format: "%.0fs", s) : String(format: "%.1fs", s) }
}

/// The real icons of the apps installed on this Mac. Nothing is bundled.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let bundles: [Provider: [String]] = [
        .claude: ["com.anthropic.claudefordesktop"],
        .openai: ["com.openai.codex", "com.openai.chat"],
        .gemini: ["com.google.antigravity"],
    ]
    private static let names: [Provider: [String]] = [.claude: ["Claude"], .openai: ["Codex", "ChatGPT"], .gemini: ["Antigravity"]]

    static func icon(_ p: Provider) -> NSImage? {
        if let c = cache[p.rawValue] { return c }
        var url: URL?
        for b in bundles[p] ?? [] where url == nil { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) }
        for n in names[p] ?? [] where url == nil {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let path = "\(dir)/\(n).app"
                if FileManager.default.fileExists(atPath: path) { url = URL(fileURLWithPath: path); break }
            }
        }
        guard let url else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[p.rawValue] = img
        return img
    }
}

/// A provider's app icon, or a coloured monogram when the app is not installed.
struct ProviderIcon: View {
    let provider: Provider?
    var size: CGFloat = 16

    var body: some View {
        if let p = provider, let img = AppIcons.icon(p) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24).fill(Theme.provider(provider))
                .frame(width: size * 0.82, height: size * 0.82)
                .overlay(Text(String((provider?.name ?? "?").prefix(1))).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }
}
