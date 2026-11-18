import SwiftUI

// App-drawn versions of the system controls that show the accent colour. macOS renders a
// custom `.tint` on segmented pickers, popup buttons, checkboxes, switches, sliders and
// progress bars as a dark, desaturated indigo (#2D28AB-ish for the brand colour, and greyer
// the lighter the tint), and Command Line Tools can't compile the asset catalog an app-wide
// AccentColor would need. So these draw the brand colours themselves.

/// Segmented control: the selected segment is the brand gradient with white text.
struct SegmentedControl<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var icon: String?
    }

    @Binding var selection: Value
    let options: [Option]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 4) {
                        if let icon = option.icon { Image(systemName: icon) }
                        Text(option.title).lineLimit(1)
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background {
                        if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.brandGradient) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// Popup menu field: a white field with the current choice and a light brand-coloured chevron,
/// instead of the system popup's dark accent badge. The menu itself is native (checkmarks).
struct MenuPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .font(controlSize == .small ? .callout : .body)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8).padding(.vertical, controlSize == .small ? 2 : 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(title)
    }
}

/// For text menus (`Menu("导出问题") { … }`): a white bordered button with a light brand-coloured
/// chevron, instead of the system menu button's dark accent badge. Apply with
/// `.menuStyle(.button).buttonStyle(.menuField)`.
struct MenuFieldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.label.lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .font(controlSize == .small ? .callout : .body)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 9).padding(.vertical, controlSize == .small ? 2 : 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.controlFill))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0)))
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
    }
}

extension ButtonStyle where Self == MenuFieldButtonStyle {
    static var menuField: MenuFieldButtonStyle { MenuFieldButtonStyle() }
}

/// Checkbox with a brand-gradient box when on.
struct BrandCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.controlFill))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.primary.opacity(0.25))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Switch: brand gradient track when on. Label on the left and the switch on the right, like
/// a system switch in a grouped Form.
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.15)))
                    .frame(width: 32, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5).padding(2)
                    }
                    .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .buttonStyle(.plain)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == BrandCheckboxStyle {
    static var brandCheckbox: BrandCheckboxStyle { BrandCheckboxStyle() }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}

/// Horizontal slider with a brand-gradient fill.
struct BrandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label = ""
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0
            let knob: CGFloat = 16
            let x = (geo.size.width - knob) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                Capsule().fill(Theme.brandGradient).frame(width: x + knob / 2, height: 4)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(1, max(0, (g.location.x - knob / 2) / max(1, geo.size.width - knob)))
                value = range.lowerBound + span * f
            })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound) * 100))%")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// Thin progress bar with a brand-gradient fill (0…1).
struct BrandProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.brandGradient).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100))%")
    }
}
