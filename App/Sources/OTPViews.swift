import SwiftUI
import TriCrypto

/// A one-time code as two halves with a still dot between them: "485 • 657".
struct OTPCode: View {
    let code: String
    var size: CGFloat = 26
    /// Last seconds of the period: the dot (grey otherwise) turns orange.
    var urgent = false

    var body: some View {
        let split = code.count / 2
        HStack(spacing: size * 0.3) {
            half(String(code.prefix(split)), from: 0)
            Circle().fill(urgent ? Color.orange : Color.secondary) // grey; orange near the end
                .frame(width: size * 0.24, height: size * 0.24)
            half(String(code.suffix(code.count - split)), from: split)
        }
        .font(.system(size: size, weight: .semibold, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: code))
    }
}

extension OTPCode {
    /// Each half keeps the width of its digit count, so the dot never shifts while digits roll over (each digit rolls
    /// on its own, like a flip clock).
    fileprivate func half(_ digits: String, from start: Int) -> some View {
        Text(verbatim: String(repeating: "0", count: digits.count))
            .fixedSize() // never squeezed narrower than the digits drawn over it
            .hidden()
            .overlay(alignment: .leading) {
                Text(verbatim: digits)
                    .contentTransition(.numericText())
                    .fixedSize()
                    .animation(Motion.plays ? .spring(duration: 0.45, bounce: 0.2).delay(Double(start) * 0.06) : nil, value: digits)
            }
    }
}

/// Seconds left in the code's period, as a ring that drains clockwise with the number inside.
/// It pops when a new code starts the ring again, and ticks with a smaller pop through the last five seconds.
struct CountdownRing: View {
    let fraction: Double
    let seconds: Int
    var size: CGFloat = 38
    /// The seconds' size against the ring's: larger for a small ring that stands on its own.
    var digits: CGFloat = 0.32
    /// The seconds roll and the ring pops when a new code starts and through the last seconds.
    var lively = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0
    @State private var beatScale = 1.0

    var body: some View {
        let urgent = seconds <= 5
        ZStack {
            Circle().stroke(Color.brand.opacity(0.14), lineWidth: size * 0.09)
            Circle()
                .trim(from: 1 - fraction, to: 1)
                .stroke(urgent ? Color.orange : Color.brand, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(seconds)")
                .font(.system(size: size * digits, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(urgent ? Color.orange : .secondary)
                .contentTransition(Motion.plays && lively ? .numericText(countsDown: true) : .identity)
                .animation(Motion.plays && lively ? .snappy : nil, value: seconds)
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: 1.0, trigger: beat) { ring, scale in
            ring.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(beatScale, duration: 0.1)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
        }
        .onChange(of: seconds) { old, new in
            guard !reduceMotion, lively else { return }
            if new > old { beatScale = 1.16; beat += 1 }           // a new code
            else if new <= 5 { beatScale = 1.07; beat += 1 }       // the last seconds
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(seconds) seconds left"))
    }
}

/// One clock for every one-time code in the app (the codes page, an item's code tile, the menu bar, the palette),
/// instead of a timer per view. It ticks once a second, on the second, while anything shows a code, and the codes read
/// it. A tick so refreshes just those small views — never a list or grid around them — however many codes there are.
@MainActor @Observable
final class OTPClock {
    static let shared = OTPClock()

    /// Whole seconds since 1970; changes once a second.
    private(set) var second = Int(Date.now.timeIntervalSince1970)

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var users = 0

    /// A view showing a code appeared: the clock runs while there's at least one.
    func retain() {
        users += 1
        guard timer == nil, Motion.plays else { return }
        tick()
        let next = Date.now.timeIntervalSince1970.rounded(.up)
        let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { OTPClock.shared.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common) // keeps ticking while a menu is open or a scroll is tracking
        self.timer = timer
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

    private func tick() {
        let s = Int(Date.now.timeIntervalSince1970.rounded())
        if s != second { second = s }
    }
}

/// A one-time code on the shared clock: refreshed once a second.
struct LiveOTPCode: View {
    let totp: TOTP
    var size: CGFloat = 26
    private let clock = OTPClock.shared

    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(clock.second))
        OTPCode(code: totp.code(at: date), size: size, urgent: totp.secondsRemaining(at: date) <= 5)
            .onAppear { clock.retain() }
            .onDisappear { clock.release() }
    }
}

/// A code's countdown ring, drawn like the clipboard's countdown: SwiftUI redraws it 15 times a second (the arc
/// drains smoothly, the seconds roll, the ring pops on a new code). Only a few show at once — one in the codes page's
/// header, one per code elsewhere — so that's cheap; the codes themselves stay on the shared once-a-second clock.
/// It rests while its window can't be seen: the palette and the menu bar panel stay built after they close, with a
/// ring still in them.
struct LiveCountdownRing: View {
    let totp: TOTP
    var size: CGFloat = 38
    /// The seconds' size against the ring's.
    var digits: CGFloat = 0.32
    var lively = true
    @Environment(\.windowVisible) private var windowVisible

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !Motion.plays || !windowVisible)) { context in
            let period = Double(totp.period)
            let into = context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
            CountdownRing(fraction: 1 - into / period, seconds: totp.secondsRemaining(at: context.date), size: size,
                          digits: digits, lively: lively)
        }
        .frame(width: size, height: size)
    }
}
