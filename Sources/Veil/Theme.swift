import SwiftUI
import AppKit

typealias RGB = (CGFloat, CGFloat, CGFloat)

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    // Order is the order shown in Settings. Graphite is the default.
    case graphite = "Graphite", clay = "Clay", sage = "Sage", ocean = "Ocean", plum = "Plum"
    var id: String { rawValue }
    var colors: (light: RGB, dark: RGB) {
        switch self {
        case .graphite: return ((0.33, 0.33, 0.35), (0.72, 0.72, 0.74))
        case .clay: return ((0.80, 0.45, 0.27), (0.93, 0.58, 0.40))
        case .sage: return ((0.33, 0.54, 0.42), (0.55, 0.76, 0.62))
        case .ocean: return ((0.22, 0.47, 0.70), (0.45, 0.66, 0.88))
        case .plum: return ((0.55, 0.35, 0.60), (0.75, 0.57, 0.81))
        }
    }
    /// The Dock icon for this accent. Graphite is the app icon itself; the others are PNGs in the
    /// app's Resources/DockIcons. nil when the bundle has no icons (e.g. `swift run`).
    var iconURL: URL? {
        let name: String
        switch self {
        case .graphite: return Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        case .clay: name = "veil-icon-clay"
        case .sage: name = "veil-icon-forest"
        case .ocean: name = "veil-icon-ocean"
        case .plum: name = "veil-icon-plum"
        }
        return Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "DockIcons")
    }
}

enum SurfaceChoice: String, CaseIterable, Identifiable {
    case warm = "Warm", neutral = "Neutral"
    var id: String { rawValue }
}

/// Warm, calm, minimal. One accent color, used sparingly. The accent and surface tone
/// are user settings; views re-render via `AppModel.themeID` when they change.
enum Theme {
    nonisolated(unsafe) static var accentChoice = AccentChoice.graphite
    nonisolated(unsafe) static var surface = SurfaceChoice.warm

    static var accent: Color { Color(nsColor: dynamic(light: accentChoice.colors.light, dark: accentChoice.colors.dark)) }
    static var window: Color { tone(warm: ((0.976, 0.969, 0.957), (0.115, 0.11, 0.105)), neutral: ((0.965, 0.965, 0.97), (0.11, 0.11, 0.115))) }
    static var card: Color { tone(warm: ((1, 1, 1), (0.165, 0.158, 0.15)), neutral: ((1, 1, 1), (0.16, 0.16, 0.165))) }
    static var hairline: Color { tone(warm: ((0.89, 0.875, 0.855), (0.25, 0.24, 0.23)), neutral: ((0.87, 0.87, 0.88), (0.25, 0.25, 0.26))) }
    static var subtle: Color { tone(warm: ((0.945, 0.933, 0.914), (0.2, 0.19, 0.18)), neutral: ((0.93, 0.93, 0.94), (0.19, 0.19, 0.2))) }

    private static func tone(warm: (RGB, RGB), neutral: (RGB, RGB)) -> Color {
        let c = surface == .warm ? warm : neutral
        return Color(nsColor: dynamic(light: c.0, dark: c.1))
    }
    static let caution = Color(nsColor: dynamic(light: (0.72, 0.36, 0.22), dark: (0.95, 0.6, 0.45)))
    static let calm = Color(nsColor: dynamic(light: (0.33, 0.55, 0.42), dark: (0.55, 0.78, 0.62)))
    static let bubble = Color(nsColor: .systemBlue)

    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// Soft avatar tints, chosen by name so each person keeps a color.
    static let avatarTints: [Color] = [
        Color(red: 0.86, green: 0.62, blue: 0.48), Color(red: 0.55, green: 0.68, blue: 0.62), Color(red: 0.62, green: 0.62, blue: 0.78),
        Color(red: 0.80, green: 0.66, blue: 0.45), Color(red: 0.72, green: 0.55, blue: 0.66), Color(red: 0.52, green: 0.64, blue: 0.76),
    ]
}

struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct Avatar: View {
    let name: String
    var isGroup = false
    var size: CGFloat = 32
    var body: some View {
        let tint = Theme.avatarTints[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Theme.avatarTints.count]
        ZStack {
            Circle().fill(tint.opacity(0.28))
            if isGroup {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.38)).foregroundStyle(tint)
            } else if let initials = Self.initials(name) {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .saturation(1.4)
    }

    static func initials(_ name: String) -> String? {
        let letters = name.split(separator: " ").compactMap { $0.first }.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(2)).uppercased()
    }
}

/// A row with an icon, a plain-language title, a one-line explanation, and a switch.
struct ToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : .secondary)
                .frame(width: 30, height: 30)
                .background((isOn ? Theme.accent.opacity(0.12) : Theme.subtle), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent).controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .contentShape(Rectangle())
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.subtle.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension Date {
    var relative: String {
        let s = -timeIntervalSinceNow
        if s < 60 { return "just now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
    var clock: String { formatted(date: .omitted, time: .shortened) }
}
