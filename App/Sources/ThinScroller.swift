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
    @State private var dragging = false
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
            let visible = hovering || scrolling || dragging
            let widened = thumbHover || dragging
            Capsule()
                .fill(Color.primary.opacity(widened ? (scheme == .dark ? 0.45 : 0.35) : (scheme == .dark ? 0.28 : 0.22)))
                .frame(width: widened ? 7 : 5, height: height)
                .frame(width: 16, alignment: .trailing) // real hit area stays stable as the thumb expands
                // A view of its own takes the drag before the rows below see the mouse: a row's `.draggable` would
                // otherwise start a drag out of the list, and the thumb would never move. It has to be attached
                // before the offset below, or the hit area stays at the top of the track while the thumb moves.
                .overlay {
                    ThumbHandle(progress: progress, track: track, thumbHeight: height, visible: visible,
                                onHover: { thumbHover = $0 },
                                onDrag: { progress in
                                    // Grouped Form/List can report geometry without honoring ScrollPosition.
                                    // Drive their AppKit clip view directly; ordinary SwiftUI scroll views use the binding.
                                    if !nativeDriver.scroll(to: progress) { position.scrollTo(y: progress * maxOffset) }
                                },
                                onEnd: { dragging = false },
                                onBegan: { dragging = true })
                }
                .padding(.trailing, 3)
                .offset(y: 6 + (track - height) * progress)
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: widened)
                .accessibilityHidden(true) // the scroll view itself stays scrollable for VoiceOver
        }
    }
}

extension View {
    /// Hides the system scroller and shows the app's slim one on hover or while scrolling.
    func thinScroller() -> some View { modifier(ThinScroller()) }
}

/// The thumb's drag, in AppKit. A SwiftUI `DragGesture` on the thumb loses the mouse to a row's `.draggable`
/// underneath (the vault list's rows can be dragged into folders), so the drag lives in a view of its own.
private struct ThumbHandle: NSViewRepresentable {
    var progress: CGFloat
    var track: CGFloat
    var thumbHeight: CGFloat
    var visible: Bool
    var onHover: (Bool) -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    var onBegan: () -> Void

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: Handle, context: Context) { apply(to: view) }

    private func apply(to view: Handle) {
        view.progress = progress
        view.track = track
        view.thumbHeight = thumbHeight
        view.visible = visible
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onBegan = onBegan
    }

    final class Handle: NSView {
        var progress: CGFloat = 0
        var track: CGFloat = 1
        var thumbHeight: CGFloat = 36
        var visible = false
        var onHover: (Bool) -> Void = { _ in }
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onBegan: () -> Void = {}

        private var grabY: CGFloat = 0
        private var grabProgress: CGFloat = 0
        private var tracking: NSTrackingArea?

        /// A press on the thumb starts the drag even when the window is not the active one.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) {
            grabY = event.locationInWindow.y
            grabProgress = progress
            onBegan()
        }

        // Measured in window space: the thumb moves under the pointer, so its own space would cancel the drag out.
        override func mouseDragged(with event: NSEvent) {
            let travel = max(track - thumbHeight, 1)
            let delta = (grabY - event.locationInWindow.y) / travel
            onDrag(min(max(grabProgress + delta, 0), 1))
        }

        override func mouseUp(with event: NSEvent) { onEnd() }

        /// Only the thumb takes clicks, and only while it is showing.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard visible, !isHiddenOrHasHiddenAncestor else { return nil }
            return super.hitTest(point)
        }
    }
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
