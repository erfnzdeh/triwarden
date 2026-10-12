import SwiftUI

// Shared controls so every screen speaks the same visual language: soft panel capsules, a tail-sky primary,
// raised white thumbs, no system chrome where it clashes with the window backdrop.

/// Flat buttons: primary is solid tail sky with a white label, secondary a quiet neutral capsule. No gradients or glows.
struct AppButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    var small = false
    /// Full-width form buttons (same height as the login button).
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    /// Increase Contrast: navy on the light tail sky (7.9:1) instead of white on the deeper sky.
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        // A button with the destructive role (Log Out, Remove…) is red whatever kind it was given.
        let kind = configuration.role == .destructive && self.kind == .secondary ? Kind.destructive : self.kind
        return configuration.label
            .font(.system(size: small ? 12 : large ? 14 : 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: !large, vertical: false) // a label never truncates; neighbours give way instead
            .padding(.horizontal, small ? 12 : 16)
            .frame(maxWidth: large ? .infinity : nil)
            .frame(height: small ? 28 : large ? 40 : 36)
            .foregroundStyle(foreground(dark, kind))
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(contrast == .increased ? Color.brandFill : Color.brandButton)
                        .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                case .secondary:
                    Capsule().fill(Color.primary.opacity(configuration.isPressed ? (dark ? 0.16 : 0.10) : (dark ? 0.10 : 0.06)))
                case .destructive:
                    Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.18 : 0.10))
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && Motion.animation(.default) != nil ? 0.97 : 1)
            .animation(Motion.animation(.snappy(duration: 0.15)), value: configuration.isPressed)
            .contentShape(.capsule)
    }

    private func foreground(_ dark: Bool, _ kind: Kind) -> Color {
        switch kind {
        case .primary: contrast == .increased ? Color.onBrandFill : .white
        case .secondary: dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.16)
        case .destructive: .red
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var appPrimary: AppButtonStyle { AppButtonStyle(kind: .primary) }
    static var appSecondary: AppButtonStyle { AppButtonStyle(kind: .secondary) }
    static var appPrimarySmall: AppButtonStyle { AppButtonStyle(kind: .primary, small: true) }
    static var appSecondarySmall: AppButtonStyle { AppButtonStyle(kind: .secondary, small: true) }
    static var appDestructive: AppButtonStyle { AppButtonStyle(kind: .destructive) }
}

/// A switch at the end of its row, like the app's other inputs (label on the left, control on the right).
struct TrailingSwitchStyle: ToggleStyle {
    var size: ControlSize = .small

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(size)
                .tint(.brand) // on = the brand fill; other system controls stay graphite
                .labelsHidden()
        }
        .contentShape(.rect)
        .onTapGesture { configuration.isOn.toggle() } // the whole row toggles, as in System Settings
    }
}

extension ToggleStyle where Self == TrailingSwitchStyle {
    static var trailingSwitch: TrailingSwitchStyle { TrailingSwitchStyle() }
}

/// A form row with its label and its control centred on each other. The grouped form lines a label up with the
/// top of a control taller than one line (a capsule button), so the label sat high; here they share a centre.
/// A second line in the label (a description) is set smaller and secondary, as the form does.
struct CenteredRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                configuration.label
            }
            .labelStyle(.titleAndIcon)
            Spacer(minLength: 8)
            configuration.content
                .foregroundStyle(.secondary)
        }
    }
}

extension LabeledContentStyle where Self == CenteredRowStyle {
    static var centeredRow: CenteredRowStyle { CenteredRowStyle() }
}

/// The system switch, filled with the brand colour when on (for forms, where rows lay it out themselves).
struct BrandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(.brand)
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brandSwitch: BrandSwitchStyle { BrandSwitchStyle() }
}

/// Capsule tabs with a raised thumb that slides between options.
struct AppSegmented<Value: Hashable>: View {
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value
    var compact = false
    @Environment(\.colorScheme) private var scheme
    /// One thumb for every segment. A thumb that only exists on the selected segment pops when the
    /// selection jumps backward, because that view is removed and a new one is inserted.
    @State private var widths: [Int: CGFloat] = [:]

    private var selectedIndex: Int { options.firstIndex { $0.0 == selection } ?? 0 }

    private var thumbOffset: CGFloat {
        (0..<selectedIndex).reduce(CGFloat(0)) { partial, index in
            partial + (widths[index] ?? 0) + 2
        }
    }

    var body: some View {
        let dark = scheme == .dark
        let motion = Motion.animation(.spring(duration: 0.3, bounce: 0.15))
        let row: CGFloat = compact ? 22 : 30
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button { withAnimation(motion) { selection = option.0 } } label: {
                    Text(option.1)
                        .font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity).frame(height: row)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(key: SegmentWidthKey.self, value: [index: geo.size.width])
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(alignment: .leading) {
            Capsule()
                .fill(dark ? Color.white.opacity(0.16) : Color.white)
                .shadow(color: .black.opacity(dark ? 0.3 : 0.10), radius: 4, y: 1)
                .frame(width: widths[selectedIndex] ?? 0, height: row)
                .offset(x: thumbOffset)
        }
        .padding(compact ? 2 : 3)
        .background(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05), in: .capsule)
        .onPreferenceChange(SegmentWidthKey.self) { new in
            let changed = new.count != widths.count || new.contains { index, width in
                abs((widths[index] ?? 0) - width) > 0.5
            }
            if changed { widths = new }
        }
        // The thumb slides whenever the selection changes, even when it arrives outside an animation (a binding
        // backed by @AppStorage updates a moment later, which made it jump).
        .animation(motion, value: selection)
    }
}

private struct SegmentWidthKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// An on/off chip (e.g. "A-Z"): tail-sky fill when on, outline when off.
struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { withAnimation(Motion.animation(.snappy(duration: 0.15))) { isOn.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                Text(verbatim: title).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isOn ? Color.onBrandFill : .secondary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(isOn ? Color.brandFill : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.primary.opacity(scheme == .dark ? 0.18 : 0.14)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// A number in the app's rounded field with − / + on either side, clamped to its range.
struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value = max(value - 1, range.lowerBound) }
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 40)
            stepButton("plus", enabled: value < range.upperBound) { value = min(value + 1, range.upperBound) }
        }
        .frame(height: 32)
        .background(scheme == .dark ? Color.white.opacity(0.07) : Color.white, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : .secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? Text("Increase") : Text("Decrease"))
    }
}

/// A slim segmented level bar (strength 1–4) or a smooth fraction bar (countdown).
struct LevelBar: View {
    var level: Int? = nil
    var fraction: Double? = nil
    var color: Color = .brand

    var body: some View {
        if let level {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i < level ? color : Color.primary.opacity(0.10)).frame(height: 4)
                }
            }
        } else {
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.10))
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: g.size.width * (fraction ?? 0)) }
            }
            .frame(height: 4)
        }
    }
}
