import SwiftUI

/// The gate between the vault and the lock screen: two plates — the lock screen's frosted room and its door, cut at
/// the middle — that slide in to meet when locking and part when unlocking. Drawn only while they move, from cheap
/// parts (the door holds still inside them), so the motion stays smooth; the real lock screen, with its fields and
/// Touch ID, appears or leaves underneath while the plates cover it.
struct GatePlates: View {
    @Environment(AppModel.self) private var model
    /// Snapshots: how far apart, 0…1 (the app animates model.gateApart instead).
    var progress: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let travel = size.height / 2 + 60
            let apart: CGFloat = progress ?? (model.gateApart ? 1 : 0)
            ZStack {
                plate(size: size, top: true).offset(y: -apart * travel)
                plate(size: size, top: false).offset(y: apart * travel)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func face(size: CGSize) -> some View {
        let (radius, center) = UnlockView.doorLayout(size)
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // Closing: the door is still apart (its assembly starts when the plates have met).
            // Opening: the door as it was the moment it unlatched.
            // Calm (no door sequence): the door exactly as typed, so nothing on it moves when the plates take over.
            let dial = model.gate == .opening && model.unlockOpenedAt == nil ? model.doorDial : (typed: 0, turns: 0)
            VaultDoorStage(radius: radius, center: center, typed: dial.typed, turns: dial.turns, busy: false, errorAt: nil,
                           openedAt: model.gate == .opening ? model.unlockOpenedAt : nil,
                           closedAt: model.gate == .closing ? model.lockClosedAt : nil)
                .environment(\.gatePassing, true)
        }
    }

    private func plate(size: CGSize, top: Bool) -> some View {
        face(size: size)
            .mask(alignment: top ? .top : .bottom) { Rectangle().frame(height: size.height / 2) }
            .overlay(alignment: .top) {
                // The plates' edges: a dark seam with a thin highlight, so they read as heavy steel.
                VStack(spacing: 0) {
                    if !top { Rectangle().fill(.black.opacity(0.22)).frame(height: 2) }
                    Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
                    if top { Rectangle().fill(.black.opacity(0.22)).frame(height: 2) }
                }
                .offset(y: top ? size.height / 2 - 3 : size.height / 2)
            }
            // Depth at the parting edge from a cheap gradient (a full-window shadow over a material re-renders
            // offscreen every frame and stutters).
            .overlay(alignment: top ? .bottom : .top) {
                LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: top ? .bottom : .top, endPoint: top ? .top : .bottom)
                    .frame(height: 28)
                    .offset(y: top ? -size.height / 2 : size.height / 2)
                    .allowsHitTesting(false)
            }
    }
}
