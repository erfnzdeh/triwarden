import SwiftUI

/// A secret that decodes as it's shown: every character flickers through random glyphs and settles, left to right
/// (~0.4 s). With Reduce Motion it just appears. The glyphs are random, so the flicker gives nothing away.
struct DecodingText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Rolling(text) { Text(verbatim: $0) }
    }
}

/// A secret that rolls into view from the left. Hiding runs that same roll from the right, into dots.
struct MaskedSecret: View {
    let secret: String
    let revealed: Bool
    /// How many dots stand in for the secret while it is hidden.
    var dots = 12

    @State private var shown: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mask: String {
        // One dot per character, so the row does not shrink when the flicker finishes.
        String(repeating: "•", count: max(secret.count, dots))
    }
    private static let glyphs = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    init(secret: String, revealed: Bool, dots: Int = 12) {
        self.secret = secret
        self.revealed = revealed
        self.dots = dots
        let mask = String(repeating: "•", count: max(secret.count, dots))
        _shown = State(initialValue: revealed ? secret : mask)
    }

    var body: some View {
        Text(verbatim: shown)
            .task(id: revealed) { await roll(to: revealed ? secret : mask, fromLeft: revealed) }
    }

    /// Same roll either way. Revealing locks the secret in from the left. Hiding locks dots in from the right.
    /// Characters the wave has not reached yet keep flickering.
    private func roll(to target: String, fromLeft: Bool) async {
        guard Motion.plays, !reduceMotion, shown != target else { shown = target; return }
        let steps = 12
        let from = Array(shown)
        let to = Array(target)
        let count = max(from.count, to.count, 1)
        for step in 0...steps {
            let settled = count * step / steps
            shown = String((0..<count).map { index in
                let done = fromLeft ? index < settled : index >= count - settled
                if done { return index < to.count ? to[index] : "•" }
                return Self.glyphs.randomElement()!
            })
            try? await Task.sleep(for: .milliseconds(26))
            if Task.isCancelled { return }
        }
        // Hiding must not end shorter than the roll that just played.
        if !fromLeft, to.count < count {
            shown = String(repeating: "•", count: count)
        } else {
            shown = target
        }
    }
}

/// Draws `text` through `content`, rolling every character through random glyphs whenever it changes, settling left
/// to right like a slot machine. `keep`: characters that stay put (spaces, a passphrase's separators).
struct Rolling<Content: View>: View {
    let text: String
    var keep: Set<Character> = [" "]
    @ViewBuilder let content: (String) -> Content
    @State private var shown: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var glyphs: [Character] { Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789#$%&*+=?") }

    init(_ text: String, keep: Set<Character> = [" "], @ViewBuilder content: @escaping (String) -> Content) {
        self.text = text
        self.keep = keep
        self.content = content
        _shown = State(initialValue: Motion.plays ? Self.scramble(text, keeping: 0, keep: keep) : text)
    }

    var body: some View {
        content(shown)
            .task(id: text) {
                guard Motion.plays, !reduceMotion, !text.isEmpty else { shown = text; return }
                let steps = 14
                for step in 0...steps {
                    // Settled characters lead; the rest keep flickering.
                    shown = Self.scramble(text, keeping: text.count * step / steps, keep: keep)
                    try? await Task.sleep(for: .milliseconds(28))
                    if Task.isCancelled { return }
                }
                shown = text
            }
    }

    private static func scramble(_ text: String, keeping settled: Int, keep: Set<Character>) -> String {
        String(text.enumerated().map { index, char in
            index < settled || keep.contains(char) ? char : glyphs.randomElement()!
        })
    }
}

/// Ticks once *this* control's copy has landed (after any master-password prompt): `copied` turns on for a moment,
/// with a light tap on the trackpad. Call `arm()` just before copying.
struct CopyTick: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var armed: Int?
    @Binding var copied: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: model.copyCount) { _, now in
                guard let armed, now > armed else { return }
                self.armed = nil
                withAnimation(.snappy(duration: 0.25)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    if model.copyCount == now { withAnimation(.snappy(duration: 0.3)) { copied = false } }
                }
            }
            .sensoryFeedback(.alignment, trigger: copied) { _, new in new }
    }
}

extension View {
    func copyTick(armed: Binding<Int?>, copied: Binding<Bool>) -> some View {
        modifier(CopyTick(armed: armed, copied: copied))
    }
}

/// A row that has just been created pops once as it lands in the list.
struct ArrivalPop: ViewModifier {
    let arrived: Bool
    @State private var beat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 1.0, trigger: beat) { row, scale in
                row.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.94, duration: 0.08)
                    SpringKeyframe(1.03, duration: 0.18, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
            }
            .onAppear { if arrived, !reduceMotion { beat += 1 } }
            .onChange(of: arrived) { _, now in if now, !reduceMotion { beat += 1 } }
    }
}

/// A scroll view that clips only at its top and bottom: content sitting flush with its sides keeps its shadow.
struct SideOverflowClip: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollClipDisabled().clipShape(SidesOpen())
    }

    private struct SidesOpen: Shape {
        func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -40, dy: 0)) }
    }
}

/// Off for snapshots and self-tests, which render one frame and must show everything in place.
enum Motion {
    static let plays = !CommandLine.arguments.contains { $0 == "--snapshot" || $0.hasPrefix("--selftest") }
}

/// A block that rises into place a beat after the one above it (`index`), as a new item opens.
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = !Motion.plays
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(.spring(duration: 0.45, bounce: 0.15).delay(0.04 + Double(min(index, 6)) * 0.045)) { shown = true }
            }
    }
}

/// A VStack whose children stagger in, top to bottom.
struct StaggeredStack<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview.modifier(StaggerIn(index: index))
                }
            }
        }
    }
}

/// A firm side-to-side shake each time `trigger` changes: the field said no.
struct Shake<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-9, duration: 0.06)
                    CubicKeyframe(8, duration: 0.08)
                    CubicKeyframe(-6, duration: 0.08)
                    CubicKeyframe(4, duration: 0.07)
                    SpringKeyframe(0, duration: 0.25, spring: .bouncy)
                }
            }
        }
    }
}

extension View {
    func shake<T: Equatable>(on trigger: T) -> some View { modifier(Shake(trigger: trigger)) }
}

/// A whole number that counts its way to a new value as it animates (rather than swapping digits).
struct CountingNumber: View, @MainActor Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: "\(Int(value.rounded()))").monospacedDigit()
    }
}

/// Little sparks flying out of a symbol (a star being set): `trigger` fires a burst. Plain dots, no glow.
struct Burst<Trigger: Equatable>: View {
    let trigger: Trigger
    var color: Color = .yellow
    var count = 8
    var reach: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            KeyframeAnimator(initialValue: 1.0, trigger: trigger) { progress in
                ZStack {
                    ForEach(0..<count, id: \.self) { i in
                        let angle = Angle.degrees(Double(i) / Double(count) * 360 - 90)
                        let distance = 5 + reach * progress
                        Circle()
                            .fill(color)
                            .frame(width: i.isMultiple(of: 2) ? 3.5 : 2.5, height: i.isMultiple(of: 2) ? 3.5 : 2.5)
                            .offset(x: cos(angle.radians) * distance, y: sin(angle.radians) * distance)
                            .scaleEffect(1 - 0.5 * progress)
                    }
                }
                .opacity(progress >= 1 ? 0 : 1 - progress * 0.9)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.001)
                    CubicKeyframe(1, duration: 0.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

