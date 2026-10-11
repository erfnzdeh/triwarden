import SwiftUI

/// The app's own slim scroll bar, in place of the system scroller (which is wide and always shown with a mouse or
/// "Show scroll bars: Always"). A thin rounded thumb at the trailing edge, shown only while the pointer is over the
/// scroll view or while it scrolls; it can be dragged.
struct ThinScroller: ViewModifier {
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
                .padding(.trailing, 3)
                .offset(y: 6 + (track - height) * progress)
                .contentShape(.rect.inset(by: -6))
                .onHover { thumbHover = $0 }
                .gesture(
                    // Measured in window space: the thumb moves under the pointer, so its own space would cancel the drag out.
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? (g.contentOffset.y + g.contentInsets.top)
                            if dragStart == nil { dragStart = start }
                            let perPoint = maxOffset / max(track - height, 1)
                            position.scrollTo(y: min(max(start + drag.translation.height * perPoint, 0), maxOffset))
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
