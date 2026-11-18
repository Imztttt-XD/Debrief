import AppKit
import SwiftUI

/// Colours and shared styles. One brand hue, a light blue-violet (periwinkle) from the icon;
/// everything else is a quiet neutral or a muted status colour, so pages stay calm.
///
/// Two layers of the brand colour:
/// - `accent`: text, icons and outlines. As light as it can be while staying readable: 5.0:1 on
///   white, ~4.4:1 on the grouped-form grey, pill tints and the selection wash (lighter in dark
///   mode, but kept deep so it doesn't glare on dark backgrounds: 4.6:1 on dark cards).
/// - `periwinkle` / `selection` / gradients: the soft fills that give the light blue-violet feel.
/// Status colours have light and dark variants, all ≥ 4.5:1 as text and as pill text.
enum Theme {
    static let accent = Color.dynamic(light: 0x5862DE, dark: 0x8088F0)
    /// System-drawn filled controls (switches, default buttons, segmented selection): the
    /// middle of `brandGradient`, so they match the brand buttons.
    static let control = Color.dynamic(light: 0x7185F0, dark: 0x434CB8)
    /// Decorative brand colour: dots, gradient ends, large icons on tints.
    static let periwinkle = Color.dynamic(light: 0x8E95F7, dark: 0x6A72DC)
    /// A second hue from the same family, for telling two things apart (e.g. the two speakers).
    static let blue = Color.dynamic(light: 0x2C63C2, dark: 0x6F98E8)

    static let success = Color.dynamic(light: 0x1B7460, dark: 0x52B394)
    static let warning = Color.dynamic(light: 0x8F570C, dark: 0xCFA055)
    static let danger = Color.dynamic(light: 0xB0344F, dark: 0xE6788E)
    /// Low-key labels and pills (applied, withdrawn, counts, resume items).
    static let neutral = Color.dynamic(light: 0x5E6172, dark: 0x9396A8)
    /// Solid red behind white text (error banner, destructive fills).
    static let dangerFill = Color(hex: 0xC0405C)

    /// Recording state.
    static let record = Color(hex: 0xE5506E)
    /// Selected row in content lists: a soft periwinkle wash, no outline.
    static let selection = Color.dynamic(light: 0xECEEFE, dark: 0x3F47B5, darkOpacity: 0.45)
    /// Accent-coloured text on `selection` (sidebar): the dark wash is deep, so the text is lighter there.
    static let selectedText = Color.dynamic(light: 0x5862DE, dark: 0xB3B8FF)

    // Surfaces. Light mode keeps the system colours; dark mode uses a deep violet-tinted set
    // (window darkest, cards lighter, fields between). Text colours above stay ≥ 5:1 on all of them.
    /// Window / page background.
    static let windowBackground = Color.dynamic(lightSystem: .windowBackgroundColor, dark: 0x15141F)
    /// Sidebar. Light mode: clear, so the system sidebar material shows.
    static let sidebarBackground = Color.dynamic(lightSystem: .clear, dark: 0x1A1926)
    /// Cards.
    static let card = Color.dynamic(lightSystem: .controlBackgroundColor, dark: 0x232232)
    /// Text input areas.
    static let field = Color.dynamic(lightSystem: .textBackgroundColor, dark: 0x1C1B29)
    /// Calendar marker for interviews that have already ended: a very light grey.
    static let endedMark = Color.dynamic(light: 0xC9CAD3, dark: 0x4A4960)
    /// Background of a day whose interviews have all ended.
    static let endedDay = Color.dynamic(light: 0xF1F1F4, dark: 0x22212E)

    /// Data marks (the usage page's bars): ≥ 3:1 on the card in both modes (checked with the
    /// dataviz validator; the dark-mode `control` indigo was only 2.2:1 on a dark card).
    static let chartBar = Color.dynamic(light: 0x7185F0, dark: 0x6E78E6)
    /// Bar tracks and recessive grid lines.
    static let chartTrack = Color.primary.opacity(0.07)

    /// Ordinary (non-brand) buttons: white in light mode, a violet grey in dark mode.
    static let buttonFill = Color.dynamic(lightSystem: .controlBackgroundColor, dark: 0x2F2D42)
    /// Small control fills: popup fields, menu buttons, unchecked checkboxes.
    static let controlFill = Color.dynamic(lightSystem: .controlBackgroundColor, dark: 0x2A2939)

    /// Icon colours, kept for the icon-matching gradient.
    static let lavender = Color(hex: 0xC7B6FF)
    static let sky = Color(hex: 0x7FB8FF)
    /// Light gradient (icon background).
    static let softGradient = LinearGradient(colors: [lavender, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Filled brand surfaces with white content: buttons, the record button, the floating
    /// button, avatars, chat bubbles. Light blue-violet in light mode (white bold text 3.2–3.5:1,
    /// the bar for bold UI text); deep indigo in dark mode so it doesn't glare (6.2–7.2:1).
    static let brandGradient = LinearGradient(colors: [Color.dynamic(light: 0x7F86F2, dark: 0x4E54C4),
                                                       Color.dynamic(light: 0x6383EE, dark: 0x3B4FB0)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let recordGradient = LinearGradient(colors: [Color(hex: 0xF27A93), record],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let successGradient = LinearGradient(colors: [Color(hex: 0x6FD3B4), Color(hex: 0x2F9F82)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// A system colour in light mode, a fixed colour in dark mode.
    static func dynamic(lightSystem: NSColor, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return lightSystem }
            return NSColor(srgbRed: CGFloat((dark >> 16) & 0xFF) / 255, green: CGFloat((dark >> 8) & 0xFF) / 255,
                           blue: CGFloat(dark & 0xFF) / 255, alpha: 1)
        })
    }

    /// A colour that follows the window's light / dark appearance.
    static func dynamic(light: UInt32, dark: UInt32, darkOpacity: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkOpacity : 1)
        })
    }
}

/// The app's primary button: the brand gradient with white semibold text, like the floating
/// record button. Used instead of `.borderedProminent`, which renders the tint as a much
/// darker purple than the brand colour.
struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let (font, h, v, corner): (Font, CGFloat, CGFloat, CGFloat) = switch controlSize {
        case .mini, .small: (.caption.weight(.semibold), 9, 4, 6)
        case .large, .extraLarge: (.body.weight(.semibold), 16, 9, 9)
        default: (.callout.weight(.semibold), 12, 6, 7)
        }
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, h).padding(.vertical, v)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Theme.brandGradient))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
}

/// Ordinary buttons (取消, 播放, 练习这道题…): a soft bordered button that sits on the
/// violet-tinted dark surfaces instead of the system's neutral grey. Destructive buttons get
/// danger-coloured text. Set app-wide in MainView, so buttons without their own style use it.
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let (font, h, v, corner): (Font, CGFloat, CGFloat, CGFloat) = switch controlSize {
        case .mini, .small: (.caption, 8, 3, 6)
        case .large, .extraLarge: (.body, 16, 8, 9)
        default: (.callout, 11, 5, 7)
        }
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        configuration.label
            .font(font)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Color.primary)
            .padding(.horizontal, h).padding(.vertical, v)
            .background(shape.fill(Theme.buttonFill))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.11)))
            .overlay(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
            .shadow(color: .black.opacity(0.05), radius: 0.5, y: 0.5)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

/// Rounded card: the basic container on content pages.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
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
            .background(Capsule().fill(color.opacity(0.08)))
            .foregroundStyle(color)
    }
}

/// Multi-line text box for longer text (JD, notes, answers): looser line spacing, breathing
/// room, and a placeholder shown while it's empty.
/// - In a grouped Form (default) it has no box of its own: the form's grey row is the field.
///   Hovering turns the row white, and while typing it stays white with an accent outline, so
///   it's clear where you can type and which field you're in.
/// - `boxed` draws its own field background, for places with no form card behind it.
struct NoteEditor: View {
    /// How the field is highlighted. `highlight` forces one (snapshots can't hover or focus).
    enum Highlight { case none, hover, focus }

    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 100
    /// Spoken name, since the placeholder disappears once there's text.
    var label = ""
    var boxed = false
    var highlight: Highlight?

    @FocusState private var focused: Bool
    /// A class rather than @State (see NavigationModel).
    @StateObject private var hover = HoverState()
    final class HoverState: ObservableObject { @Published var isHovering = false }

    /// TextEditor draws its text 5 pt in from its own edge; the placeholder must match.
    private static let lineFragmentPadding: CGFloat = 5
    private static let corner: CGFloat = 8
    /// A grouped Form insets row content by 10 pt on every side (measured on macOS 27). The
    /// form ignores listRowBackground / listRowInsets here, so the highlight is drawn from the
    /// editor outward by this much to cover the whole grey row.
    private static let rowInset: CGFloat = 10
    private static let rowCorner: CGFloat = 6
    private var padding: EdgeInsets {
        // In a form, the row already insets its content; pull back by the editor's own 5 pt so
        // the text lines up with the other rows' labels.
        boxed ? EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
              : EdgeInsets(top: 6, leading: -Self.lineFragmentPadding, bottom: 6, trailing: -Self.lineFragmentPadding)
    }

    private var state: Highlight {
        highlight ?? (focused ? .focus : hover.isHovering ? .hover : .none)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(padding)
            .frame(minHeight: minHeight)
            .background {
                if boxed {
                    field(Color.secondary.opacity(0.22), width: 1, corner: Self.corner)
                } else if state != .none {
                    field(state == .focus ? Theme.accent.opacity(0.7) : Color.secondary.opacity(0.2),
                          width: state == .focus ? 2 : 1, corner: Self.rowCorner)
                        .padding(-Self.rowInset)
                }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, padding.leading + Self.lineFragmentPadding)
                        .padding(.top, padding.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if boxed && state == .focus {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 2)
                }
            }
            .onHover { hover.isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: state)
            .accessibilityLabel(label.isEmpty ? placeholder : label)
    }

    private func field(_ stroke: Color, width: CGFloat, corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return shape.fill(Theme.field).overlay(shape.strokeBorder(stroke, lineWidth: width))
    }
}

/// Soft periwinkle selection for content lists, without an outline. The native List selection paints the row in the
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
