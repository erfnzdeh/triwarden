import AppKit
import SwiftUI

/// The app's own slim scroll bar, in place of the system scroller (which is wide and always shown with a mouse or
/// "Show scroll bars: Always"). A thin rounded thumb at the trailing edge, shown only while the pointer is over the
/// scroll view or while it scrolls; it can be dragged.
struct ThinScroller: ViewModifier {
    @State private var nativeDriver = NativeScrollDriver()
    @State private var geometry: ScrollGeometry?
    @State private var position = ScrollPosition(edge: .top)
    @State private var hovering = false
    @State private var scrolling = false
    @State private var dragStart: CGFloat?
    @State private var thumbHover = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .background { NativeScrollProbe(driver: nativeDriver) }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, new in geometry = new }
            .onScrollPhaseChange { _, phase in withAnimation(.easeOut(duration: 0.2)) { scrolling = phase.isScrolling } }
            .onHover { inside in withAnimation(.easeOut(duration: 0.2)) { hovering = inside } }
            .overlay(alignment: .topTrailing) {
                // Only the thumb is hit-testable. A full-size overlay would swallow clicks on the rows.
                thumb.fixedSize()
            }
    }

    @ViewBuilder private var thumb: some View {
        if let g = geometry, g.contentSize.height > g.containerSize.height + 1 {
            let track = g.containerSize.height - 12
            let ratio = g.containerSize.height / g.contentSize.height
            let height = max(36, track * ratio)
            let maxOffset = g.contentSize.height - g.containerSize.height
            let progress = min(max((g.contentOffset.y + g.contentInsets.top) / maxOffset, 0), 1)
            let visible = hovering || scrolling || dragStart != nil
            Capsule()
                .fill(Color.primary.opacity(thumbHover || dragStart != nil ? (scheme == .dark ? 0.45 : 0.35) : (scheme == .dark ? 0.28 : 0.22)))
                .frame(width: thumbHover || dragStart != nil ? 7 : 5, height: height)
                .frame(width: 16, alignment: .trailing) // real hit area stays stable as the thumb expands
                .padding(.trailing, 3)
                .offset(y: 6 + (track - height) * progress)
                .contentShape(.rect)
                .onHover { thumbHover = $0 }
                .highPriorityGesture(
                    // Measured in window space: the thumb moves under the pointer, so its own space would cancel the drag out.
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? (g.contentOffset.y + g.contentInsets.top)
                            if dragStart == nil { dragStart = start }
                            let perPoint = maxOffset / max(track - height, 1)
                            let offset = min(max(start + drag.translation.height * perPoint, 0), maxOffset)
                            // Grouped Form/List can report geometry without honoring ScrollPosition.
                            // Drive their AppKit clip view directly; ordinary SwiftUI scroll views use the binding.
                            if !nativeDriver.scroll(to: offset / maxOffset) {
                                position.scrollTo(y: offset)
                            }
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: thumbHover)
                .accessibilityHidden(true) // the scroll view itself stays scrollable for VoiceOver
        }
    }
}

extension View {
    /// Hides the system scroller and shows the app's slim one on hover or while scrolling.
    func thinScroller() -> some View { modifier(ThinScroller()) }
}

/// Resolve the native scroll view belonging to this modifier, without intercepting pointer events.
@MainActor private final class NativeScrollDriver {
    weak var probe: NSView?

    func scroll(to progress: CGFloat) -> Bool {
        guard let probe else { return false }
        var ancestor: NSView? = probe
        while let view = ancestor {
            if let native = view as? NSScrollView { return scroll(native, to: progress) }
            // The background is often a sibling of the Form's scroll view, not its descendant.
            let candidates = scrollViews(in: view).filter { native in
                let frame = native.convert(native.bounds, to: probe)
                let overlap = frame.intersection(probe.bounds)
                let area = min(frame.width * frame.height, probe.bounds.width * probe.bounds.height)
                return area > 0 && !overlap.isNull && overlap.width * overlap.height >= area * 0.5
            }
            if candidates.count == 1 { return scroll(candidates[0], to: progress) }
            if candidates.count > 1 { return false }
            ancestor = view.superview
        }
        return false
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func scroll(_ scroll: NSScrollView, to progress: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let minimum = -scroll.contentInsets.top
        let maximum = max(minimum, document.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let fraction = document.isFlipped ? progress : 1 - progress
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: minimum + (maximum - minimum) * fraction))
        scroll.reflectScrolledClipView(clip)
        return true
    }
}

private struct NativeScrollProbe: NSViewRepresentable {
    let driver: NativeScrollDriver
    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        driver.probe = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { driver.probe = view }
    private final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
