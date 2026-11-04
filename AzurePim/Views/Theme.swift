import AppKit
import SwiftUI

/// Design tokens shared by the menu bar panel and the windows (DesignBrief, Juicy / Claude Cockpit look):
/// rounded cards, a large hero figure, collapsible sections, a settings-style action list.
enum Theme {
    // MARK: Layout
    static let panelWidth: CGFloat = 360
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 12

    // MARK: Colours
    /// Azure blue — primary emphasis.
    static let accent = adaptive(light: 0x0F6CBD, dark: 0x4CA3F0)
    /// Active role (the hero figure, countdowns with time left).
    static let active = adaptive(light: 0x12A150, dark: 0x34C66B)
    static let warning = adaptive(light: 0xD9730D, dark: 0xF5A524)
    static let danger = adaptive(light: 0xD13438, dark: 0xF1545A)
    /// Favorites, PIM groups.
    static let violet = adaptive(light: 0x7A5AF8, dark: 0x9B84FF)

    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.12)
    static let slate = adaptive(light: 0x5B6470, dark: 0x9AA3AE)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Countdown tint: green with time left, orange ≤ 15 min, red ≤ 5 min.
    static func remaining(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return active }
        if seconds <= 300 { return danger }
        if seconds <= 900 { return warning }
        return active
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Containers

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Uppercase tracked label (« TEMPS RESTANT »).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.slate)
    }
}

/// KPI tile: label, big value, optional note.
struct StatTile: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = .primary
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                SectionLabel(text: label)
            }
            Text(value)
                .font(.display(26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.slate).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

/// Collapsible card with an icon, a title, an optional count and a chevron.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var count: Int?
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.track, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)\(count.map { ", \($0)" } ?? ""), \(expanded ? "expanded" : "collapsed")")
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .card()
    }
}

/// Settings-list row with a leading SF Symbol (footer of the panel).
struct ActionRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Thin divider between rows of a card, inset past the leading icon.
struct RowDivider: View {
    var inset: CGFloat = 34
    var body: some View { Divider().opacity(0.5).padding(.leading, inset) }
}

/// Progress track with a rounded fill (hero card).
struct ProgressTrack: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: max(8, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
