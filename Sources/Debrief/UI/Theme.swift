import AppKit
import SwiftUI

/// Colours and shared styles, taken from the app icon (lavender → sky blue, pink accents).
enum Theme {
    static let lavender = Color(hex: 0xC7B6FF)
    static let sky = Color(hex: 0x7FB8FF)
    static let pink = Color(hex: 0xFF7FA8)
    /// Controls, links, selection. Darker than the icon colours so white text on it stays readable.
    static let accent = Color(hex: 0x6E62E8)
    /// Recording state: a pinkish red that sits well next to the brand colours.
    static let record = Color(hex: 0xF4517A)
    /// Selected row in the content lists: light sky blue, readable in light and dark mode.
    static let selection = Color(hex: 0x7FB8FF, opacity: 0.26)

    /// Light gradient (icon background).
    static let softGradient = LinearGradient(colors: [lavender, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Stronger gradient for filled buttons with white content.
    static let brandGradient = LinearGradient(colors: [Color(hex: 0x8E7CFF), Color(hex: 0x5C9DFF)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let recordGradient = LinearGradient(colors: [Color(hex: 0xFF7E9D), record],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Rounded card: the basic container on content pages.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small heading above a card.
struct SectionLabel: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.accent) }
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

/// Capsule tag (category, status…).
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

/// Light-blue selection for content lists. The native List selection paints the row in the
/// strong system accent, which makes coloured pills unreadable, so the lists draw their own.
struct SelectableRow: ViewModifier {
    let selected: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.selection : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Theme.sky.opacity(0.55) : Color.clear))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    func selectableRow(_ selected: Bool, action: @escaping () -> Void) -> some View {
        modifier(SelectableRow(selected: selected, action: action))
    }
}

/// App-wide light / dark override, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appAppearance"
    var id: String { rawValue }
    var title: String { L10n.tr("appearance.\(rawValue)") }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppAppearance.init) ?? .system
    }

    /// Applies to every window, the floating button and the menu bar popover.
    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
