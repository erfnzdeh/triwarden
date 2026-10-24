#!/usr/bin/env swift
import Foundation
import Darwin

// Exercise the production AppKit event handler and SwiftUI row without moving the desktop pointer.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let viewSource = try String(contentsOf: root.appendingPathComponent("App/Sources/VaultView.swift"), encoding: .utf8)
guard let start = viewSource.range(of: "private struct SwipeDismissRow<"),
      let end = viewSource.range(of: "private struct InboxRow:", range: start.lowerBound..<viewSource.endIndex) else {
    fatalError("Notification swipe components were not found")
}
let components = String(viewSource[start.lowerBound..<end.lowerBound])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("triwarden-swipe-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let fixture = directory.appendingPathComponent("main.swift")
let tests = #"""
final class ScrollFixture: NSEvent {
    let target: NSWindow?
    let dx: CGFloat
    let dy: CGFloat
    let eventPhase: NSEvent.Phase
    init(window: NSWindow?, dx: CGFloat, dy: CGFloat = 0, phase: NSEvent.Phase = []) {
        target = window; self.dx = dx; self.dy = dy; eventPhase = phase
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { target?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { NSPoint(x: 100, y: 25) }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { eventPhase }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 50), styleMask: .borderless, backing: .buffered, defer: false)
private let surface = SwipeScrollSurface.Surface(frame: NSRect(x: 0, y: 0, width: 364, height: 50))
window.contentView = surface
var delta: CGFloat = 0
var ended = 0
surface.onDelta = { delta += $0 }
surface.onEnded = { ended += 1 }
func pump(_ seconds: TimeInterval = 0.03) {
    let deadline = Date.now.addingTimeInterval(seconds)
    repeat {
        if let event = app.nextEvent(matching: .any, until: Date.now.addingTimeInterval(0.005), inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.005))
    } while Date.now < deadline
}
func send(_ event: NSEvent) { _ = surface.handle(event); pump() }
func check(_ name: String, expectedDelta: CGFloat, expectedEnded: Int) {
    precondition(delta == expectedDelta && ended == expectedEnded, "\(name): delta=\(delta), ended=\(ended)")
    print("PASS: \(name)")
    delta = 0; ended = 0
}
send(ScrollFixture(window: window, dx: -160))
pump(0.3)
check("wheel swipe without phases settles", expectedDelta: -160, expectedEnded: 1)
send(ScrollFixture(window: window, dx: -20, phase: .began))
send(ScrollFixture(window: window, dx: -140, phase: .changed))
send(ScrollFixture(window: nil, dx: 0, phase: .ended))
pump(0.3)
check("zero-delta end without window settles exactly once", expectedDelta: -160, expectedEnded: 1)
send(ScrollFixture(window: window, dx: -160, phase: .changed))
pump(0.3)
check("trackpad stream missing its end settles", expectedDelta: -160, expectedEnded: 1)
send(ScrollFixture(window: window, dx: 0, dy: -160, phase: .changed))
pump(0.3)
check("vertical scrolling leaves rows alone", expectedDelta: 0, expectedEnded: 0)
surface.stop()
print("All notification swipe event checks passed")


@Observable
private final class RowFixtureModel { var dismissed = false }
private struct RowFixtureView: View {
    let model: RowFixtureModel
    var body: some View {
        if !model.dismissed {
            SwipeDismissRow { model.dismissed = true } content: {
                Text("Notification").frame(maxWidth: .infinity, minHeight: 50)
            }
        } else {
            Text("Nothing waiting.")
        }
    }
}
private func findSurface(_ view: NSView) -> SwipeScrollSurface.Surface? {
    if let surface = view as? SwipeScrollSurface.Surface { return surface }
    return view.subviews.lazy.compactMap { findSurface($0) }.first
}
private let rowModel = RowFixtureModel()
private let host = NSHostingView(rootView: RowFixtureView(model: rowModel))
host.frame = NSRect(x: 0, y: 0, width: 364, height: 50)
window.contentView = host
host.layoutSubtreeIfNeeded()
pump(0.3)
private let rowSurface = findSurface(host)!
_ = rowSurface.handle(ScrollFixture(window: window, dx: -160, phase: .changed))
pump(0.6)
precondition(rowModel.dismissed, "Full left swipe must call dismiss")
host.layoutSubtreeIfNeeded()
let transitionDeadline = Date.now.addingTimeInterval(2)
while findSurface(host) != nil, Date.now < transitionDeadline { pump(0.05) }
precondition(findSurface(host) == nil, "The dismissed notification must leave the rendered view")
print("PASS: full left swipe removes the real SwiftUI row even without an end event")

"""#
try ("import AppKit\nimport SwiftUI\nimport Observation\n" + components + tests).write(to: fixture, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", fixture.path]
try process.run()
process.waitUntilExit()
let status = process.terminationStatus
try FileManager.default.removeItem(at: directory)
exit(status)
