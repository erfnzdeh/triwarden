import AppKit
import SwiftUI

// The vault sidebar, drawn by the app rather than by `List`: a group (All Items, My Folders, a folder, a shared
// vault) opens and closes like an accordion. Its rows are clipped to a height that springs between zero and their
// own, fading and settling as they go, and the rows below ride along. A click anywhere on a group's row opens or
// closes it; one with a destination of its own is picked too.

/// The sidebar's motion: 350 ms on the soft ease-out cubic-bezier(0.215, 0.61, 0.355, 1), the chevron turning with
/// the rows. Reduce Motion: groups open and close at once.
enum SidebarMotion {
    static let duration: TimeInterval = 0.35
    static let fold = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: duration)

    @MainActor static var animation: Animation? { Motion.animation(fold) }
}

/// One row's look: a 28 pt pill with the label inside, quiet fills for hover and selection (no brand blue), and
/// the same pill height and gap the `List` sidebar had.
struct SidebarRow<Label: View>: View {
    var depth = 0
    /// nil: a plain row with no chevron. Otherwise the group's open state, which the chevron shows and a click flips.
    var expanded: Binding<Bool>?
    var selected = false
    var dropTargeted = false
    var action: () -> Void = {}
    @ViewBuilder let label: Label

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// The same pill height and gap as the Settings sidebar (SidebarCalmSelection), so the two match.
    static var height: CGFloat { SidebarCalmSelection.Finder.pillHeight }
    static var gap: CGFloat { SidebarCalmSelection.Finder.pillGap }
    /// Indent per level, and the chevron's slot at each row's start (so labels line up with or without one).
    private static var indent: CGFloat { 14 }
    private static var chevronSlot: CGFloat { 14 }

    private var fill: Color {
        let dark = scheme == .dark
        if dropTargeted { return Color.brand.opacity(0.18) }
        if selected { return dark ? .white.opacity(0.12) : .black.opacity(0.075) }
        if hovering { return dark ? .white.opacity(0.06) : .black.opacity(0.04) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 2) {
            Group {
                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .animation(SidebarMotion.animation, value: expanded.wrappedValue)
                }
            }
            .frame(width: Self.chevronSlot)
            label
                .labelStyle(SidebarLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4 + CGFloat(depth) * Self.indent)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(fill, in: .rect(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(selected ? (scheme == .dark ? 0.12 : 0.04) : 0), radius: 4, y: 2)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            action()
            if let expanded {
                withAnimation(SidebarMotion.animation) { expanded.wrappedValue.toggle() }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(expanded.map { Text($0.wrappedValue ? "expanded" : "collapsed") } ?? Text(verbatim: ""))
    }
}

/// The icon in the text's quiet secondary colour at the sidebar's size, the title in the body font.
private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .font(.system(size: 13))
                .frame(width: 18)
            configuration.title
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }
}

/// A group's rows under its own: clipped to a height that animates between nothing and what they need, so they
/// fold up into the group (and unfold out of it) while the rows below follow. Closed, they're gone from the tree.
struct SidebarFold<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        // The fold animates itself whenever `expanded` flips, whatever changed it: a group kept in `@AppStorage`
        // (All Items, My Folders) updates outside the click's animation, so `withAnimation` alone left it instant.
        FoldLayout(progress: expanded ? 1 : 0) {
            VStack(spacing: SidebarRow<EmptyView>.gap) { content }
                .padding(.top, SidebarRow<EmptyView>.gap)
                .opacity(expanded ? 1 : 0)
                .offset(y: expanded ? 0 : -6)
        }
        .clipped()
        .animation(SidebarMotion.animation, value: expanded)
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
    }
}

/// Lays its rows out at their full height and takes `progress` of it. The height is worked out on every frame of the
/// animation, so a fold inside a fold follows its inner one's current height (measuring it once let the outer clip
/// jump to the end and cut the inner fold off).
private struct FoldLayout: Layout {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? full.width, height: full.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A section's heading ("Items", "Tools"…): a title, not a row to pick or hover.
struct SidebarHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
