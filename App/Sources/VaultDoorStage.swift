import AppKit
import SwiftUI

/// A frozen moment of the lock screen, for snapshots: `time` seconds after the door appeared, `opened` seconds into
/// the unlock sequence (nil = still locked).
struct VaultDoorFrozen {
    var time: Double
    var opened: Double?
    /// Seconds into the closing sequence (a lock the user asked for).
    var closed: Double? = nil
    var typed = 0
    var busy = false
    var alert = 0.0
}

extension EnvironmentValues {
    @Entry var vaultDoorFrozen: VaultDoorFrozen?
}

/// The lock screen's door: a round, faintly enchanted vault door. Light from inside the vault leaks through its seams;
/// every typed character lights a pin and turns the tumblers. Unlocking takes the door apart like a transforming
/// machine; locking assembles it again. No shaking anywhere.
struct VaultDoorStage: View {
    let radius: CGFloat
    let center: CGPoint
    let typed: Int
    /// Notches the tumblers have turned: one per typed character, but a paste or a clear takes the short way round.
    let turns: Int
    let busy: Bool
    let errorAt: Date?
    let openedAt: Date?
    let closedAt: Date?
    /// Paint the room (the dark backdrop) across the whole frame; off when the door sits over other content.
    var room = true
    /// A combination dial with a spoked handle in the hub (the login page, where the hub has no password field).
    var dial = false

    /// The room's backdrop, for a panel that shows the room without the door.
    static func roomGradient(dark: Bool) -> LinearGradient {
        let p = DoorPalette(dark: dark)
        // As translucent as the door's own room, so the window's backdrop shows through and the panel melts into it.
        return LinearGradient(colors: [p.backTop.opacity(0.86), p.backBottom.opacity(0.9)], startPoint: .top, endPoint: .bottom)
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vaultDoorFrozen) private var frozen
    @Environment(\.gatePassing) private var gatePassing
    /// Opt-in: the door drifts while it waits. Off (the default), it's still art; typing still turns the tumblers.
    @AppStorage(Pref.fullDoorAnimation) private var animates = false
    /// Stop all frame updates when the app is in the background or this window cannot be seen.
    @State private var animationVisible = false
    @State private var start = Date()

    var body: some View {
        Group {
            if let frozen {
                art(time: frozen.time, opened: frozen.opened, closed: frozen.closed, alert: frozen.alert, typed: frozen.typed,
                    turns: frozen.typed, busy: frozen.busy)
            } else {
                let still = reduceMotion || !animates
                // Inside the gate's halves the door holds still (one frame), so the halves are cheap to move.
                // Inside the gate's halves: still while closing (cheap to move); opening keeps playing, so the last
                // pieces fly out as the halves part.
                let resting = !animationVisible
                TimelineView(.animation(paused: still || resting || (gatePassing && openedAt == nil))) { context in
                    let now = context.date
                    art(time: still ? 0 : now.timeIntervalSince(start),
                        opened: openedAt.map { now.timeIntervalSince($0) },
                        closed: closedAt.map { now.timeIntervalSince($0) },
                        alert: still ? 0 : errorAt.map { Self.alert(now.timeIntervalSince($0)) } ?? 0,
                        typed: typed, turns: turns, busy: busy)
                }
            }
        }
        .background {
            WindowVisibilityProbe(visible: $animationVisible, needsActiveApp: true)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// A wrong password: the light warms to red quickly, then cools back over a second and a half.
    private static func alert(_ s: Double) -> Double {
        s < 0.15 ? max(0, s / 0.15) : max(0, 1 - (s - 0.15) / 1.5)
    }

    private func art(time: Double, opened: Double?, closed: Double?, alert: Double, typed: Int, turns: Int,
                     busy: Bool) -> some View {
        VaultDoorArt(steps: Double(turns), busy: busy ? 1 : 0, time: time, opened: opened, closed: closed, alert: alert,
                     lit: typed, radius: radius, center: center, dark: scheme == .dark, room: room, dial: dial)
            .animation(.easeInOut(duration: 0.4), value: busy)
    }
}

// MARK: - Mechanism

/// Where every moving part is at one instant. The door is built from pieces: the hub (4 plates), the pin ring
/// (4 arcs), the tumbler (12 louvres) and the rune ring (6 segments). Unlocking takes it apart from the inside out,
/// like a transforming machine; locking assembles it from the outside in.
private struct Mechanism {
    /// Per ring (0 hub, 1 pins, 2 tumbler, 3 runes): how far it has turned to its aligned stop (may overshoot).
    var align = [0.0, 0, 0, 0]
    /// Per ring: the furthest any of its pieces has gone, 0 assembled … 1 retracted (see `piece`).
    var parts = [0.0, 0, 0, 0]
    /// The pieces crack apart along their seams, 0…1 (with a small jolt).
    var latch = 0.0
    /// Bolts drawn back into the door, 0 thrown … 1 drawn.
    var bolts = 0.0
    /// The pins, lit one after another (index 0…11), 0…1 each.
    var pinLight = Array(repeating: 0.0, count: 12)
    var pins: Double { pinLight.max() ?? 0 }
    /// The light inside burning brighter, 0…1.
    var light = 0.0
    /// The sealing ripple after a lock, 0…1 (0 or 1 = not showing).
    var seal = 0.0
    /// The hub turning as one before it splits, degrees.
    var twist = 0.0
    /// 歸元: the three notches in line at the top, light running down the keyway, 0…1.
    var keyway = 0.0
    /// An arc of energy running along the seams: its angle (degrees) and strength.
    var sweep = 0.0
    var sweepStrength = 0.0

    /// Opening or closing time, for the pieces' own staggered progress.
    private var openT: Double?
    private var closeT: Double?

    static let pieceCount = [4, 8, 12, 6]

    /// Piece `i` of ring `k`: each ring starts on its own beat and its pieces follow one another (a cascade).
    func piece(_ k: Int, _ i: Int) -> Double {
        let n = Double(Self.pieceCount[k])
        if let e = openT {
            // A tight cascade (every piece is out by ~1.05, ~1.17 s at play speed: DoorMotion). The gate starts parting while the
            // outer rings are still flying out, and its halves keep playing them, so it all reads as one movement.
            let start = [0.52, 0.58, 0.64, 0.7][k] + Double(i) / n * 0.08
            return Ease.inOut(Self.seg(e, start, start + 0.28)) // soft in, soft out: no snap at either end
        }
        if let e = closeT {
            let start = [0.42, 0.3, 0.16, 0.02][k] + Double(i) / n * 0.1
            return 1 - Ease.machine(Self.seg(e, start, start + 0.28))
        }
        return 0
    }

    static func seg(_ e: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (e - a) / (b - a))) }

    /// Unlocking, `e` seconds of timeline in (~1.12; played 1.2x, so AppModel hands over to the gate at 0.94 s).
    /// The three rings turn until their notches line up into one keyway at the top, and only then does it open.
    static func opening(_ e: Double) -> Mechanism {
        func seg(_ a: Double, _ b: Double) -> Double { Self.seg(e, a, b) }
        var m = Mechanism()
        m.openT = e
        // Power-up: pins light one after another, energy runs along the seams.
        for i in 0..<12 { m.pinLight[i] = Ease.out(seg(0.012 * Double(i), 0.012 * Double(i) + 0.08)) }
        m.sweep = Ease.inOut(seg(0, 0.42)) * 540 - 90
        m.sweepStrength = sin(.pi * seg(0, 0.42))
        // The combination: heaven (runes), person (tumbler), earth (pins), outside in, each turning until its notch
        // is at the top and stopping with a small overshoot, like a dial clicking home.
        for k in 1..<4 {
            let s = 0.02 + 0.06 * Double(3 - k)
            m.align[k] = Ease.backOut(seg(s, s + 0.3))
        }
        // 歸元: the notches in line, light runs down the keyway to the hub, then gives way to the opening.
        m.keyway = Ease.out(seg(0.4, 0.48)) * (1 - Ease.inOut(seg(0.58, 0.72)))
        // Unlatch: bolts snap back, seams crack with a jolt, the hub turns a little as one.
        m.bolts = Ease.inOut(seg(0.44, 0.54))
        m.latch = Ease.backOut(seg(0.48, 0.58))
        m.twist = 30 * Ease.backOut(seg(0.5, 0.62))
        // Transform: pieces cascade out (see `piece`), leaving the light inside.
        for k in 0..<4 { m.parts[k] = m.piece(k, pieceCount[k] - 1) > 0 ? m.piece(k, 0) : 0 }
        m.light = Ease.out(seg(0.05, 0.7))
        return m
    }

    /// Locking, `e` seconds in (~1.5 s), the opening played backwards: the pieces cascade in from the frame, outside
    /// in, with the three notches still in line and light down the keyway; the hub turns back and locks, the bolts are
    /// thrown, then the rings turn away from each other, inside out, scrambling the combination, the pins go dark one
    /// by one and the seal ripples out.
    static func closing(_ e: Double) -> Mechanism {
        func seg(_ a: Double, _ b: Double) -> Double { Self.seg(e, a, b) }
        var m = Mechanism()
        m.closeT = e
        for k in 0..<4 {
            m.parts[k] = m.piece(k, 0)
            // Pins, tumbler, runes in turn, each spinning off past its rest and settling back (like the dials of a
            // safe given a twist once it's shut).
            let s = 0.84 + 0.07 * Double(k - 1)
            m.align[k] = k == 0 ? 1 : 1 - Ease.backOut(seg(s, s + 0.34))
        }
        // The keyway lights as the last pieces land, and goes dark as the rings leave.
        m.keyway = Ease.out(seg(0.5, 0.62)) * (1 - Ease.inOut(seg(0.84, 0.94)))
        m.twist = 30 * (1 - Ease.backOut(seg(0.68, 0.8)))
        m.latch = 1 - Ease.inOut(seg(0.76, 0.84))
        m.bolts = 1 - Ease.backOut(seg(0.8, 0.92))
        for i in 0..<12 { m.pinLight[i] = 1 - Ease.inOut(seg(0.9 + 0.012 * Double(i), 0.98 + 0.012 * Double(i))) }
        m.light = m.pins
        m.sweep = Ease.inOut(seg(0.84, 1.2)) * -540 - 90
        m.sweepStrength = sin(.pi * seg(0.84, 1.2)) * 0.7
        m.seal = seg(0.98, 1.5)
        return m
    }
}

private enum Ease {
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// Heavy mechanical travel: eases away, glides, settles firmly (no overshoot).
    static func machine(_ x: Double) -> Double { x < 0.5 ? 8 * pow(x, 4) : 1 - pow(-2 * x + 2, 4) / 2 }
    /// Arrives with a small overshoot and settles back: a part clicking into place.
    static func backOut(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        return x <= 0 ? 0 : 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

// MARK: - Palette

private struct RGB {
    var r, g, b: Double
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    func callAsFunction(_ opacity: Double = 1) -> Color { Color(red: r, green: g, blue: b).opacity(opacity) }
}

private struct DoorPalette {
    let dark: Bool
    var backTop: Color { dark ? Color(red: 0.05, green: 0.08, blue: 0.13) : Color(red: 0.95, green: 0.97, blue: 0.99) }
    var backBottom: Color { dark ? Color(red: 0.02, green: 0.03, blue: 0.06) : Color(red: 0.83, green: 0.89, blue: 0.95) }
    var metal: [Color] {
        dark ? [Color(red: 0.30, green: 0.32, blue: 0.36), Color(red: 0.13, green: 0.14, blue: 0.17)]
             : [Color(red: 0.99, green: 0.99, blue: 1), Color(red: 0.76, green: 0.80, blue: 0.85)]
    }
    var frame: [Color] {
        dark ? [Color(red: 0.20, green: 0.21, blue: 0.24), Color(red: 0.07, green: 0.08, blue: 0.10)]
             : [Color(red: 0.90, green: 0.93, blue: 0.96), Color(red: 0.68, green: 0.75, blue: 0.82)]
    }
    var recess: [Color] {
        dark ? [Color(red: 0.03, green: 0.05, blue: 0.08), Color(red: 0.08, green: 0.11, blue: 0.16)]
             : [Color(red: 0.86, green: 0.91, blue: 0.95), Color(red: 0.97, green: 0.98, blue: 1)]
    }
    var bolt: [Color] {
        dark ? [Color(red: 0.62, green: 0.68, blue: 0.75), Color(red: 0.30, green: 0.35, blue: 0.42)]
             : [Color(red: 1, green: 1, blue: 1), Color(red: 0.70, green: 0.76, blue: 0.83)]
    }
    var edge: Color { dark ? .black.opacity(0.55) : Color(red: 0.20, green: 0.30, blue: 0.42).opacity(0.28) }
    var shine: Color { .white.opacity(dark ? 0.14 : 0.9) }
    var engrave: Color { dark ? .black.opacity(0.6) : Color(red: 0.15, green: 0.22, blue: 0.32).opacity(0.38) }
    /// The catch of light along the lower lip of an engraved line.
    var engraveLip: Color { .white.opacity(dark ? 0.10 : 0.8) }
    /// The light inside the vault: the tail sky (a deeper sky on light steel), warming to red for a wrong password.
    func glow(alert: Double) -> RGB {
        let sky = dark ? RGB(r: 0.50, g: 0.77, b: 0.94) : RGB(r: 0.18, g: 0.56, b: 0.83)
        let red = dark ? RGB(r: 1.0, g: 0.45, b: 0.45) : RGB(r: 0.88, g: 0.27, b: 0.27)
        return sky.mix(red, alert)
    }
}

// MARK: - Drawing

/// Proportions of the door, as fractions of its radius.
enum DoorGeometry {
    static let frameOuter = 1.13
    static let runes = (inner: 0.845, outer: 0.985)
    static let tumbler = (inner: 0.715, outer: 0.83)
    static let pins = (inner: 0.595, outer: 0.70)
    /// The recessed hub that holds the password field.
    static let core = 0.58
}

/// The unlock sequence's tempo, shared by the door and the gate (AppModel) so they stay in step.
enum DoorMotion {
    /// How fast the written opening plays (it's written over ~1.05 s): below 1 is slower, unhurried.
    static let openSpeed = 0.9
    /// When the gate starts parting: while the outer rings are still flying out (0.864 s into the written sequence).
    static var gateDelay: Double { 0.864 / openSpeed }
    /// How long the gate's halves take to part.
    static let gateParting = 0.85
    /// The hub's release as the door starts to open.
    static let release = 0.6
}

private struct VaultDoorArt: View, Animatable {
    var steps: Double
    var busy: Double
    let time: Double
    let opened: Double?
    let closed: Double?
    let alert: Double
    let lit: Int
    let radius: CGFloat
    let center: CGPoint
    let dark: Bool
    var room = true
    var dial = false

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(steps, busy) }
        set { steps = newValue.first; busy = newValue.second }
    }

    /// ♈︎ … ♓︎ around the tumbler.
    private static let zodiac = Array("♈♉♊♋♌♍♎♏♐♑♒♓")

    /// The twelve pins, one Elder Futhark rune each.
    private static let runes = Array("ᚠᚢᚦᚨᚱᚲᚷᚹᚺᚾᛁᛉ")

    static var openSpeed: Double { DoorMotion.openSpeed }

    private static let runeSymbols = ["key.fill", "person.badge.key.fill", "terminal.fill",
                                      "creditcard.fill", "envelope.fill", "note.text"]

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) } symbols: { glyphSymbols }
            .drawingGroup() // rendered with Metal: smooth at 120 Hz while the pieces move
    }

    // MARK: Glyphs, laid out once

    /// Every engraved glyph (pin runes, zodiac signs, the six inlaid icons) in its three looks — the lip of light, the
    /// cut, and the glow — as Canvas symbols: laid out once, then only placed each frame. (Resolving text in the frame
    /// itself cost hundreds of layouts per frame while the pieces moved, since each piece redraws its whole ring.)
    @ViewBuilder private var glyphSymbols: some View {
        let p = DoorPalette(dark: dark)
        let glow = p.glow(alert: alert)
        // One flat list with a unique id per symbol (nested ForEach ranges would repeat ids, which Canvas rejects).
        ForEach(Self.glyphIDs, id: \.self) { id in
            let parts = id.split(separator: "-")
            let kind = parts[0], i = Int(parts[1]) ?? 0, look = Int(parts[2]) ?? 0
            let color: Color = switch look {
            case 0: p.engraveLip
            case 1: kind == "icon" ? p.engrave.opacity(0.75) : p.engrave.opacity(0.8)
            default: glow(1)
            }
            Group {
                switch kind {
                case "rune":
                    Text(String(Self.runes[i])).font(.custom("Apple Symbols", size: radius * 0.062))
                case "number":
                    Text(verbatim: "\(i * 10)").font(.system(size: radius * 0.03, weight: .semibold, design: .rounded))
                case "zodiac":
                    // U+FE0E asks for the text form, not the emoji.
                    Text(String(Self.zodiac[i]) + "\u{FE0E}").font(.custom("Apple Symbols", size: radius * 0.062))
                default:
                    Image(systemName: Self.runeSymbols[i]).resizable().scaledToFit()
                        .frame(width: radius * 0.064, height: radius * 0.064)
                }
            }
            .foregroundStyle(color)
            .tag(id)
        }
    }

    /// "rune-3-1": the glyph kind, its index, and the look (0 lip, 1 cut, 2 glow).
    private static let glyphIDs: [String] = (0..<3).flatMap { look in
        (0..<12).flatMap { ["rune-\($0)-\(look)", "zodiac-\($0)-\(look)"] } + (0..<6).map { "icon-\($0)-\(look)" }
    } + (0..<10).map { "number-\($0)-1" }

    /// The glyphs resolved for this frame (cheap: the layout is already done).
    struct Glyphs {
        var runes: [[GraphicsContext.ResolvedSymbol?]] = []
        var zodiac: [[GraphicsContext.ResolvedSymbol?]] = []
        var icons: [[GraphicsContext.ResolvedSymbol?]] = []
        var numbers: [GraphicsContext.ResolvedSymbol?] = []

        init(_ ctx: GraphicsContext) {
            runes = (0..<12).map { i in (0..<3).map { ctx.resolveSymbol(id: "rune-\(i)-\($0)") } }
            zodiac = (0..<12).map { i in (0..<3).map { ctx.resolveSymbol(id: "zodiac-\(i)-\($0)") } }
            icons = (0..<6).map { i in (0..<3).map { ctx.resolveSymbol(id: "icon-\(i)-\($0)") } }
            numbers = (0..<10).map { ctx.resolveSymbol(id: "number-\($0)-1") }
        }

        /// Draws one glyph as an engraving: lip, cut, then the glow at `light` strength.
        static func engrave(_ looks: [GraphicsContext.ResolvedSymbol?], in g: GraphicsContext, light: Double) {
            if let lip = looks[0] { g.draw(lip, at: CGPoint(x: 0, y: 0.7), anchor: .center) }
            if let cut = looks[1] { g.draw(cut, at: .zero, anchor: .center) }
            if light > 0, let glow = looks[2] {
                var lit = g
                lit.opacity = min(1, light)
                lit.draw(glow, at: .zero, anchor: .center)
            }
        }
    }

    private var mechanism: Mechanism {
        // The opening plays a little faster than its timeline is written (~0.85 s): brisk, but every step readable.
        if let opened { return .opening(opened * Self.openSpeed) }
        if let closed { return .closing(closed) }
        return Mechanism()
    }

    // Ring angles in degrees. The tumbler drifts and turns half a notch per character; the pin ring only moves when
    // typing, bringing the newest lit pin to the marker at the top. Unlocking turns each until its notch is at the top.
    private func idle(_ k: Int, at t: Double) -> Double {
        switch k {
        case 3: t * 2.2
        case 2: -t * 3.2 + steps * 15
        case 1: -steps * 30 + 30
        default: 0
        }
    }
    /// Where each ring's notch is cut, on the ring itself (degrees; 0° = 3 o'clock, clockwise): between two pins,
    /// between two signs, at a seam of the rune ring. Turned to the top, the three make one keyway.
    private static let notch: [Double] = [0, -75, -90, -90]

    private func angle(_ k: Int, _ m: Mechanism) -> Double {
        guard k > 0 else { return 0 }
        let a0: Double
        if let e = opened {
            a0 = idle(k, at: time - e)
        } else if closed != nil {
            a0 = idle(k, at: time) // turning away from the keyway, back to where it rests
        } else {
            return idle(k, at: time)
        }
        // The shorter way round to bring the notch to the top.
        var d = (-90 - Self.notch[k] - a0).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return a0 + d * m.align[k]
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let p = DoorPalette(dark: dark)
        let m = mechanism
        let R = radius
        let glow = p.glow(alert: alert)
        let breathe = 0.5 + 0.5 * sin(time * 1.1)
        // How bright the light inside is: breathing at rest, quicker while the key is derived, blazing as it opens.
        // (Opening only lifts it a little: no flare, no spreading wave as the pieces part.)
        let inner = min(1, 0.5 + 0.12 * breathe + busy * (0.18 + 0.12 * sin(time * 5)) + 0.5 * alert + 0.15 * m.light)

        // Room: translucent, so the lock reads as a layer over the window.
        let full = Path(CGRect(origin: .zero, size: size))
        if room { ctx.fill(full, with: .linearGradient(Gradient(colors: [p.backTop.opacity(0.86), p.backBottom.opacity(0.9)]),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))) }

        var c = ctx
        c.translateBy(x: center.x, y: center.y)

        // A neutral contact shadow under the door, no coloured halo.
        c.fill(circle(R * 1.24), with: .radialGradient(
            Gradient(stops: [.init(color: .black.opacity(dark ? 0.35 : 0.1), location: 0), .init(color: .clear, location: 1)]),
            center: .zero, startRadius: R * DoorGeometry.frameOuter * 0.97, endRadius: R * 1.24))

        // The light inside the vault: it shows through the seams and the tumbler's slots, then through the opening.
        let open = m.parts[0]
        c.fill(circle(1.0 * R), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.4 * inner + 0.12 * open), glow(inner), glow(inner * 0.75)]),
            center: .zero, startRadius: 0, endRadius: R))

        // Locking bolts: thrown into the frame; drawn back into the door as it unlocks.
        let pull = R * 0.22 * m.bolts
        for i in 0..<12 {
            var b = c
            b.opacity = 1 - m.parts[3]
            b.rotate(by: .degrees(Double(i) * 30 + 15))
            let rect = CGRect(x: R * 0.9 - pull, y: -R * 0.026, width: R * 0.165, height: R * 0.052)
            let shape = Path(roundedRect: rect, cornerRadius: R * 0.018)
            b.fill(shape, with: .linearGradient(Gradient(colors: p.bolt), startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                                endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
            b.stroke(shape, with: .color(p.edge), lineWidth: 0.8)
        }


        // The pieces, inside out, so each slides out under the next; the rune segments retract into the frame.
        c.clip(to: circle(1.0 * R))
        let turn = (0..<4).map { angle($0, m) }
        // The notches show the light inside; brighter as the keyway lines up.
        let slot = min(1, 0.3 + 0.4 * inner + 0.7 * m.keyway)
        let glyphs = Glyphs(ctx)
        pieces(c, ring: 0, m: m, p: p, count: 4, cut: 0, inner: 0, outer: DoorGeometry.core) { drawCore(&$0, p: p, glow: glow, m: m, glyphs: glyphs) }
        pieces(c, ring: 1, m: m, p: p, count: 8, cut: 0, inner: DoorGeometry.pins.inner, outer: DoorGeometry.pins.outer) {
            drawPins(&$0, p: p, m: m, glyphs: glyphs, turn: turn[1])
            drawNotch(&$0, ring: 1, inner: DoorGeometry.pins.inner, outer: DoorGeometry.pins.outer, p: p, glow: glow, light: slot)
        }
        pieces(c, ring: 2, m: m, p: p, count: 12, cut: 15, inner: DoorGeometry.tumbler.inner, outer: DoorGeometry.tumbler.outer) {
            drawTumbler(&$0, p: p, glyphs: glyphs, inner: inner, turn: turn[2])
            drawNotch(&$0, ring: 2, inner: DoorGeometry.tumbler.inner, outer: DoorGeometry.tumbler.outer, p: p, glow: glow, light: slot)
        }
        pieces(c, ring: 3, m: m, p: p, count: 6, cut: 30, inner: DoorGeometry.runes.inner, outer: DoorGeometry.runes.outer) {
            drawRunes(&$0, p: p, m: m, glyphs: glyphs, turn: turn[3])
            drawNotch(&$0, ring: 3, inner: DoorGeometry.runes.inner, outer: DoorGeometry.runes.outer, p: p, glow: glow, light: slot)
        }

        // Seams glow onto the steel around them (while the door is whole).
        if m.latch < 1 {
            var l = c
            if dark { l.blendMode = .plusLighter }
            let a = (0.35 + 0.5 * inner) * (1 - m.latch)
            // Hairlines of light between the rings: present, never loud.
            for f in [0.9925, 0.8375, 0.7075, DoorGeometry.core + 0.0075] {
                l.stroke(circle(R * f), with: .color(glow(a * (dark ? 0.35 : 0.4))), lineWidth: 1)
            }
        }

        // 歸元: light runs down the lined-up notches, from the rim to the hub's marker.
        if m.keyway > 0.01 {
            var k = c
            if dark { k.blendMode = .plusLighter }
            var beam = Path()
            beam.move(to: CGPoint(x: 0, y: -R * DoorGeometry.runes.outer))
            beam.addLine(to: CGPoint(x: 0, y: -R * DoorGeometry.core * 0.9))
            k.stroke(beam, with: .color(glow(0.22 * m.keyway)), style: StrokeStyle(lineWidth: R * 0.03, lineCap: .round))
            k.stroke(beam, with: .color(.white.opacity(0.9 * m.keyway)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }

        // Energy running along the seams (power-up when opening, power-down when closing).
        if m.sweepStrength > 0.01 {
            var e = c
            if dark { e.blendMode = .plusLighter }
            for (n, f) in [DoorGeometry.core, DoorGeometry.pins.outer, DoorGeometry.tumbler.outer, DoorGeometry.runes.outer].enumerated() {
                let head = m.sweep + Double(n) * 22 * (n % 2 == 0 ? 1 : -1)
                var arc = Path()
                arc.addArc(center: .zero, radius: R * f, startAngle: .degrees(head - 46), endAngle: .degrees(head), clockwise: false)
                e.stroke(arc, with: .color(glow(0.22 * m.sweepStrength)), style: StrokeStyle(lineWidth: R * 0.03, lineCap: .round))
                e.stroke(arc, with: .color(glow(0.95 * m.sweepStrength)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                let tip = CGPoint(x: cos(head * .pi / 180) * R * f, y: sin(head * .pi / 180) * R * f)
                e.fill(circle(R * 0.012, at: tip), with: .color(.white.opacity(0.9 * m.sweepStrength)))
            }
        }

        // The frame the door sits in.
        c = ctx
        c.translateBy(x: center.x, y: center.y)
        fillBand(&c, inner: 1.0 * R, outer: DoorGeometry.frameOuter * R, colors: p.frame, turn: 0)
        c.stroke(circle(DoorGeometry.frameOuter * R), with: .color(p.shine), lineWidth: 1)
        c.stroke(circle(1.1 * R), with: .color(p.engrave.opacity(0.5)), lineWidth: 0.6)

        // Sealed: one ring of light ripples out from the frame.
        if m.seal > 0, m.seal < 1 {
            let k = Ease.out(m.seal)
            let ripple = circle(R * (DoorGeometry.frameOuter + 0.55 * k))
            c.stroke(ripple, with: .color(glow(0.18 * (1 - m.seal))), lineWidth: R * 0.07 * (1 - k * 0.6))
            c.stroke(ripple, with: .color(glow(0.9 * (1 - m.seal))), lineWidth: 1.5)
        }
    }

    // MARK: Pieces

    /// Draws ring `ring` (turned to its angle; `inner`/`outer` as fractions of the radius) as `count` pieces cut at `cut` + multiples of 360/count degrees, each
    /// moved by the mechanism. Whole and unmoved, it's drawn in one go.
    private func pieces(_ c: GraphicsContext, ring k: Int, m: Mechanism, p: DoorPalette, count: Int, cut: Double,
                        inner: CGFloat, outer: CGFloat, draw: (inout GraphicsContext) -> Void) {
        let R = radius
        var base = c
        base.rotate(by: .degrees(angle(k, m) + (k == 0 ? m.twist : 0)))
        let progress = (0..<count).map { m.piece(k, $0) }
        guard m.latch > 0 || (progress.max() ?? 0) > 0 else { draw(&base); return }
        let span = 360 / Double(count)
        for i in 0..<count {
            let u = progress[i]
            guard u < 1 else { continue }
            let mid = cut + (Double(i) + 0.5) * span
            let rad = mid * .pi / 180
            let dir = CGPoint(x: cos(rad), y: sin(rad))
            var l = base
            // Every piece first cracks a hair away from the centre…
            var push = R * 0.02 * m.latch
            // …then each ring transforms its own way.
            switch k {
            case 0: // hub plates: each turns a little and rides its piston out diagonally
                l.rotate(by: .degrees(18 * u * (i % 2 == 0 ? 1 : -1)))
                push += R * 0.62 * u
                l.opacity = 1 - max(0, (u - 0.6) / 0.4)
            case 1: // pin arcs lift (grow a touch), turn away and slide out
                l.scaleBy(x: 1 + 0.07 * sin(u * .pi), y: 1 + 0.07 * sin(u * .pi))
                l.rotate(by: .degrees(32 * u * (i % 2 == 0 ? 1 : -1)))
                push += R * 0.36 * u
                l.opacity = 1 - max(0, (u - 0.55) / 0.45)
            case 2: // tumbler louvres flip edge-on, one after another
                push += R * 0.1 * u
                let mr = R * (inner + outer) / 2
                let pivot = CGPoint(x: dir.x * mr, y: dir.y * mr)
                l.translateBy(x: dir.x * push, y: dir.y * push)
                push = 0
                l.translateBy(x: pivot.x, y: pivot.y)
                l.rotate(by: .degrees(mid))
                l.scaleBy(x: 1, y: max(0.04, cos(u * .pi / 2)))
                l.rotate(by: .degrees(-mid))
                l.translateBy(x: -pivot.x, y: -pivot.y)
                l.opacity = 1 - max(0, (u - 0.6) / 0.4)
            default: // rune segments telescope into the frame: a short step, a beat, then the rest of the way
                let step = u < 0.45 ? 0.35 * Ease.out(u / 0.45) : 0.35 + 0.65 * Ease.inOut((u - 0.45) / 0.55)
                l.rotate(by: .degrees(-10 * u))
                push += R * 0.3 * step
            }
            l.translateBy(x: dir.x * push, y: dir.y * push)
            let shape = sector(inner == 0 ? 0 : R * inner - 1, R * outer + 1, mid - span / 2, mid + span / 2)
            // Thick steel: a soft shadow on the light behind, then the piece, then its machined cut faces.
            let lift = R * 0.014 * max(m.latch, u)
            if lift > 0 {
                var s = l
                s.translateBy(x: 0, y: lift)
                s.fill(shape, with: .color(.black.opacity(dark ? 0.35 : 0.16)))
                s.translateBy(x: 0, y: lift)
                s.fill(shape, with: .color(.black.opacity(dark ? 0.18 : 0.08)))
            }
            var piece = l
            piece.clip(to: shape)
            draw(&piece)
            let faces = max(m.latch, min(1, u * 4))
            if faces > 0 {
                l.stroke(shape, with: .linearGradient(Gradient(colors: [p.shine.opacity(faces), p.edge.opacity(faces)]),
                                                      startPoint: CGPoint(x: 0, y: -R), endPoint: CGPoint(x: 0, y: R)),
                         lineWidth: 1.2)
            }
        }
    }

    private func sector(_ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var path = Path()
        path.addArc(center: .zero, radius: r1, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        if r0 > 0 {
            path.addArc(center: .zero, radius: r0, startAngle: .degrees(a1), endAngle: .degrees(a0), clockwise: true)
        } else {
            path.addLine(to: .zero)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Rings (drawn already turned to their angle)

    private func drawRunes(_ r: inout GraphicsContext, p: DoorPalette, m: Mechanism, glyphs: Glyphs, turn: Double) {
        let R = radius
        fillBand(&r, inner: DoorGeometry.runes.inner * R, outer: DoorGeometry.runes.outer * R, colors: p.metal, turn: turn)
        for i in 0..<6 {
            // Inlaid icons: a quiet cut at rest, lit only while the door opens.
            var g = r
            g.rotate(by: .degrees(Double(i) * 60))
            g.translateBy(x: R * 0.893, y: 0)
            g.rotate(by: .degrees(90))
            Glyphs.engrave(glyphs.icons[i], in: g, light: m.light * 0.9)
        }
    }

    private func drawTumbler(_ r: inout GraphicsContext, p: DoorPalette, glyphs: Glyphs, inner: Double, turn: Double) {
        let R = radius
        fillBand(&r, inner: DoorGeometry.tumbler.inner * R, outer: DoorGeometry.tumbler.outer * R, colors: p.metal, turn: turn)
        // The twelve signs of the zodiac, engraved upright to the centre around the tumbler.
        for i in 0..<12 {
            let t = (Double(i) * 30 + 15) * .pi / 180
            var g = r
            g.translateBy(x: cos(t) * R * 0.7725, y: sin(t) * R * 0.7725)
            g.rotate(by: .radians(t + .pi / 2))
            Glyphs.engrave(glyphs.zodiac[i], in: g, light: inner > 0.75 ? (inner - 0.75) * 2 : 0)
        }
    }

    private func drawPins(_ r: inout GraphicsContext, p: DoorPalette, m: Mechanism, glyphs: Glyphs, turn: Double) {
        let R = radius
        // While the key is derived, a light chases around the pins.
        let head = (time * 1.6).truncatingRemainder(dividingBy: 1) * 12
        fillBand(&r, inner: DoorGeometry.pins.inner * R, outer: DoorGeometry.pins.outer * R, colors: p.metal, turn: turn)
        for i in 0..<12 {
            // Pin i sits at the top when it's the newest lit one (the ring turns 30° per character).
            let t = (Double(i) * 30 - 90) * .pi / 180
            let pt = CGPoint(x: cos(t) * R * 0.627, y: sin(t) * R * 0.627)
            var d = abs(Double(i) - head)
            d = min(d, 12 - d)
            let chase = busy * max(0, 1 - d / 2.2)
            let typedLit = lit > i ? (lit > 12 ? 1 : (i == lit - 1 ? 1 : 0.75)) : 0
            let on = min(1, max(typedLit, chase, m.pinLight[i]))
            // Each pin is a rune cut into the ring, upright to the centre; typing fills it with light.
            var g = r
            g.translateBy(x: pt.x, y: pt.y)
            g.rotate(by: .radians(t + .pi / 2))
            Glyphs.engrave(glyphs.runes[i], in: g, light: on)
        }
    }

    private func drawCore(_ l: inout GraphicsContext, p: DoorPalette, glow: RGB, m: Mechanism, glyphs: Glyphs) {
        let R = radius
        let rc = DoorGeometry.core * R
        l.fill(circle(rc), with: .linearGradient(Gradient(colors: p.recess), startPoint: CGPoint(x: 0, y: -rc),
                                                 endPoint: CGPoint(x: 0, y: rc)))
        // Recessed: shadowed from the top, a catch of light along the bottom lip.
        l.stroke(circle(rc - 1), with: .linearGradient(Gradient(colors: [p.edge, .clear]), startPoint: CGPoint(x: 0, y: -rc),
                                                       endPoint: CGPoint(x: 0, y: rc * 0.2)), lineWidth: 3)
        l.stroke(circle(rc - 0.5), with: .linearGradient(Gradient(colors: [.clear, p.shine]), startPoint: CGPoint(x: 0, y: 0),
                                                         endPoint: CGPoint(x: 0, y: rc)), lineWidth: 1)
        l.stroke(circle(rc * 0.9), with: .color(glow(dark ? 0.12 : 0.16)), lineWidth: 1)
        // The plates' seams: faint until the hub splits.
        var cross = Path()
        cross.move(to: CGPoint(x: -rc, y: 0)); cross.addLine(to: CGPoint(x: rc, y: 0))
        cross.move(to: CGPoint(x: 0, y: -rc)); cross.addLine(to: CGPoint(x: 0, y: rc))
        l.stroke(cross, with: .color(p.engrave.opacity(0.35)), lineWidth: 0.6)
        // The index the pins turn to.
        var marker = Path()
        marker.move(to: CGPoint(x: 0, y: -rc * 0.955))
        marker.addLine(to: CGPoint(x: -R * 0.016, y: -rc * 0.915))
        marker.addLine(to: CGPoint(x: R * 0.016, y: -rc * 0.915))
        marker.closeSubpath()
        l.fill(marker, with: .color(glow(0.9)))
        if dial { drawDial(&l, p: p, glow: glow, m: m, glyphs: glyphs) }
    }

    /// The combination dial: a numbered disc that turns slowly at rest and spins a full turn as the door opens, under
    /// a four-spoke handle with a lit hub.
    private func drawDial(_ l: inout GraphicsContext, p: DoorPalette, glow: RGB, m: Mechanism, glyphs: Glyphs) {
        let rd = DoorGeometry.core * radius * 0.72
        let spin = opened.map { Ease.inOut(Mechanism.seg($0 * Self.openSpeed, 0.05, 0.6)) * 360 } ?? 0
        let angle = time * 4 + spin
        // The disc, raised: a soft shadow, turned metal, a bright lip.
        var shadow = l
        shadow.translateBy(x: 0, y: rd * 0.04)
        shadow.fill(circle(rd), with: .color(.black.opacity(dark ? 0.45 : 0.15)))
        fillBand(&l, inner: 0.001, outer: rd, colors: p.metal, turn: angle)
        var d = l
        d.rotate(by: .degrees(angle))
        // Fifty ticks, every fifth long and numbered 0…90.
        for k in 0..<50 {
            let long = k % 5 == 0
            let a = Double(k) / 50 * 2 * .pi - .pi / 2
            var tick = Path()
            tick.move(to: CGPoint(x: cos(a) * rd * (long ? 0.83 : 0.88), y: sin(a) * rd * (long ? 0.83 : 0.88)))
            tick.addLine(to: CGPoint(x: cos(a) * rd * 0.95, y: sin(a) * rd * 0.95))
            engrave(&d, tick, p: p, width: long ? 1.2 : 0.7)
            if long, let number = glyphs.numbers[k / 5] {
                var n = d
                n.translateBy(x: cos(a) * rd * 0.7, y: sin(a) * rd * 0.7)
                n.rotate(by: .radians(a + .pi / 2))
                n.draw(number, at: .zero, anchor: .center)
            }
        }
        // The handle: a ring, four spokes with knobs, a hub that holds the light.
        let reach = rd * 0.5
        var spokes = Path()
        for q in 0..<4 {
            let a = Double(q) * .pi / 2 + .pi / 4
            spokes.move(to: .zero)
            spokes.addLine(to: CGPoint(x: cos(a) * reach, y: sin(a) * reach))
        }
        var h = d
        h.translateBy(x: 0, y: rd * 0.02)
        h.stroke(spokes, with: .color(.black.opacity(dark ? 0.5 : 0.18)), style: StrokeStyle(lineWidth: rd * 0.09, lineCap: .round))
        h.stroke(circle(rd * 0.3), with: .color(.black.opacity(dark ? 0.5 : 0.18)), lineWidth: rd * 0.07)
        let steel = GraphicsContext.Shading.linearGradient(Gradient(colors: p.bolt), startPoint: CGPoint(x: 0, y: -reach),
                                                           endPoint: CGPoint(x: 0, y: reach))
        d.stroke(spokes, with: steel, style: StrokeStyle(lineWidth: rd * 0.075, lineCap: .round))
        d.stroke(circle(rd * 0.3), with: steel, lineWidth: rd * 0.055)
        for q in 0..<4 {
            let a = Double(q) * .pi / 2 + .pi / 4
            let knob = CGPoint(x: cos(a) * reach, y: sin(a) * reach)
            d.fill(circle(rd * 0.075, at: knob), with: steel)
            d.stroke(circle(rd * 0.075, at: knob), with: .color(p.edge), lineWidth: 0.8)
        }
        d.fill(circle(rd * 0.16), with: steel)
        d.stroke(circle(rd * 0.16), with: .color(p.edge), lineWidth: 1)
        d.fill(circle(rd * 0.06), with: .color(glow(0.9)))
        d.fill(circle(rd * 0.025), with: .color(.white.opacity(0.9)))
    }

    /// Ring `k`'s notch: a fine radial cut through the band, lit from inside like the seams between the rings.
    /// Drawn in the ring's own (turned) coordinates.
    private func drawNotch(_ r: inout GraphicsContext, ring k: Int, inner: CGFloat, outer: CGFloat, p: DoorPalette,
                           glow: RGB, light: Double) {
        let R = radius
        let a = Self.notch[k] * .pi / 180
        var cut = Path()
        cut.move(to: CGPoint(x: cos(a) * R * (inner + 0.012), y: sin(a) * R * (inner + 0.012)))
        cut.addLine(to: CGPoint(x: cos(a) * R * (outer - 0.012), y: sin(a) * R * (outer - 0.012)))
        engrave(&r, cut, p: p, width: R * 0.014)
        r.stroke(cut, with: .color(glow(light)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    // MARK: Helpers

    private func circle(_ r: CGFloat, at p: CGPoint = .zero) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    /// A band of turned steel, lit from a fixed light above whatever `turn` the ring is at: a fine concentric
    /// satin finish, a soft cross-shaped sheen, a raised outer lip and a chamfered inner edge.
    private func fillBand(_ c: inout GraphicsContext, inner: CGFloat, outer: CGFloat, colors: [Color], turn: Double) {
        let p = DoorPalette(dark: dark)
        var band = circle(outer)
        band.addPath(circle(inner))
        let style = FillStyle(eoFill: true)
        // Light direction in the ring's own (turned) coordinates.
        let back = -turn * .pi / 180
        func lit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * cos(back) - y * sin(back), y: x * sin(back) + y * cos(back))
        }
        c.fill(band, with: .linearGradient(Gradient(colors: colors), startPoint: lit(-outer * 0.35, -outer),
                                           endPoint: lit(outer * 0.35, outer)), style: style)
        // Anisotropic sheen: bright lobes top-left and bottom-right, darker ones across.
        let hi = Color.white.opacity(dark ? 0.05 : 0.3)
        let lo = Color.black.opacity(dark ? 0.08 : 0.03)
        c.fill(band, with: .conicGradient(Gradient(colors: [hi, .clear, lo, .clear, hi, .clear, lo, .clear, hi]),
                                          center: .zero, angle: .degrees(-135 - turn)), style: style)
        // Raised outer lip (lit at the top), chamfered inner edge (lit at the bottom).
        c.stroke(circle(outer - 0.75), with: .linearGradient(Gradient(colors: [p.shine, p.edge.opacity(0.6)]),
                                                             startPoint: lit(0, -outer), endPoint: lit(0, outer)), lineWidth: 1.5)
        c.stroke(circle(inner + 0.75), with: .linearGradient(Gradient(colors: [p.edge, p.shine.opacity(0.7)]),
                                                             startPoint: lit(0, -inner), endPoint: lit(0, inner)), lineWidth: 1.5)
    }

    /// An engraved line: the cut, with a lip of light along its lower edge.
    private func engrave(_ c: inout GraphicsContext, _ path: Path, p: DoorPalette, width: CGFloat) {
        c.stroke(path.offsetBy(dx: 0, dy: 0.6), with: .color(p.engraveLip), lineWidth: width)
        c.stroke(path, with: .color(p.engrave), lineWidth: width)
    }
}

// MARK: - Login

/// The login screen's side panel: the same vault door, closed, under the brand and a caption. A successful sign-in
/// opens it like an unlock.
struct LoginDoorStage: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let ink = dark ? Color.white : Color(red: 0.05, green: 0.16, blue: 0.27)
        ZStack {
            // A panel like the app's own, on the window's base, edged by a hairline: two flat surfaces, nothing blending.
            Color.panel
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(dark ? 0.08 : 0.06)).frame(width: 1) }
            // The welcome: the app's icon, its name and promise, and what it keeps — centred, quiet.
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: BrandIcon.image)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 18, y: 10)
                    .padding(.bottom, 22)
                Text(verbatim: "Triwarden")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink.opacity(0.6))
                    .padding(.bottom, 6)
                Text("Every login,\nbehind one door.")
                    .font(.system(size: 30, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 26)
                VStack(alignment: .leading, spacing: 14) {
                    feature("key.horizontal", "Passwords and passkeys, filled in anywhere")
                    feature("clock.badge.checkmark", "One-time codes, one click away")
                    feature("terminal", "SSH keys that sign without leaving the vault")
                }
                .foregroundStyle(ink.opacity(0.7))
            }
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.horizontal, 44)
        }

        .accessibilityElement(children: .combine)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
            Text(text).font(.system(size: 13))
        }
    }
}
