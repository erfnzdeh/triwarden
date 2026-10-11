# SSH Approval UX Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show which app is asking the SSH agent to sign, let the person allow it once, for 10 minutes, or until the vault locks, and keep a local log of every request.

**Architecture:** Pure rules live in the `SSHAgent` package: parent-process walking, trust keys, in-memory grants, a one-at-a-time prompt queue, and the access log. `SSHAgentService` applies those rules, then asks `LAContext` only after an allow choice. A floating card, the menu bar, and a notification are three ways to reach that one choice. Grants die on lock. The log file stays in the App Group container.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPanel`, LocalAuthentication, UserNotifications, Security.framework, Swift Testing. Design: `docs/plans/2026-10-10-ssh-approval-ux-design.md`.

---

### Task 1: Resolve the asking app from a process chain

**Files:**
- Create: `Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift`
- Test: `Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import SSHAgent

@Test func walksToTheAppBundle() {
    let nodes = [
        ProcessNode(pid: 10, parent: 9, path: "/usr/bin/ssh"),
        ProcessNode(pid: 9, parent: 8, path: "/opt/homebrew/bin/git"),
        ProcessNode(pid: 8, parent: 1, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
    ]
    let byPID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0) })
    let who = SSHRequesterResolver.resolve(pid: 10, peerPath: "/usr/bin/ssh", peerName: "ssh") { byPID[$0] }
    #expect(who.displayName == "Cursor")
    #expect(who.via == "ssh")
    #expect(who.peerPath == "/usr/bin/ssh")
    #expect(who.appPath == "/Applications/Cursor.app")
    #expect(who.appPID == 8)
    #expect(who.trustKey == "path:/Applications/Cursor.app")
}

@Test func bareToolTrustsItsOwnPath() {
    let who = SSHRequesterResolver.resolve(pid: 4, peerPath: "/usr/bin/ssh", peerName: "ssh") { pid in
        pid == 4 ? ProcessNode(pid: 4, parent: 1, path: "/usr/bin/ssh") : nil
    }
    #expect(who.displayName == "ssh")
    #expect(who.appPath == nil)
    #expect(who.trustKey == "path:/usr/bin/ssh")
}

@Test func stopsAfterEightSteps() {
    let who = SSHRequesterResolver.resolve(pid: 20, peerPath: "/bin/zsh", peerName: "zsh") { pid in
        ProcessNode(pid: pid, parent: pid + 1, path: "/bin/zsh")
    }
    #expect(who.appPath == nil)
    #expect(who.trustKey == "path:/bin/zsh")
}
```

**Step 2: Run the test to verify it fails**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: FAIL, `SSHRequesterResolver` is undefined.

**Step 3: Write the implementation**

Add `Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift`:

```swift
import Foundation

public struct ProcessNode: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var path: String?
    public init(pid: Int32, parent: Int32, path: String?) {
        self.pid = pid
        self.parent = parent
        self.path = path
    }
}

public struct SSHRequester: Equatable, Sendable {
    public var displayName: String
    public var via: String
    public var peerPath: String?
    public var appPath: String?
    public var appPID: Int32?
    public var trustKey: String
    public init(displayName: String, via: String, peerPath: String?, appPath: String?, appPID: Int32?, trustKey: String) {
        self.displayName = displayName
        self.via = via
        self.peerPath = peerPath
        self.appPath = appPath
        self.appPID = appPID
        self.trustKey = trustKey
    }
}

public enum SSHRequesterResolver {
    /// The first `.app` bundle walking from `pid` toward its parents, at most eight steps.
    /// Pid 0 and 1 stop the walk. A display name is the bundle's file name, or the peer name.
    public static func resolve(pid: Int32, peerPath: String?, peerName: String, lookup: (Int32) -> ProcessNode?) -> SSHRequester {
        var current = pid
        var appPath: String?
        var appPID: Int32?
        for _ in 0..<8 where current > 1 {
            guard let node = lookup(current) else { break }
            if let path = node.path, let bundle = bundlePath(in: path) {
                appPath = bundle
                appPID = node.pid
                break
            }
            current = node.parent
        }
        let trustKey = appPath.map { "path:\($0)" } ?? peerPath.map { "path:\($0)" } ?? "name:\(peerName)"
        let displayName = appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? peerName
        return SSHRequester(displayName: displayName, via: peerName, peerPath: peerPath, appPath: appPath, appPID: appPID, trustKey: trustKey)
    }

    static func bundlePath(in path: String) -> String? {
        var built = ""
        for component in path.split(separator: "/") where !component.isEmpty {
            built += "/\(component)"
            if component.hasSuffix(".app") { return built }
        }
        return nil
    }
}
```

**Step 4: Run the test to verify it passes**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift
git commit -m "$(cat <<'EOF'
Identify the app behind an SSH agent request.

EOF
)"
```

---

### Task 2: Trust keys and grants

**Files:**
- Modify: `Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift`
- Modify: `Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift`

**Step 1: Write the failing test**

```swift
@Test func signedAppOutranksAPath() {
    let key = SSHTrustKey.make(bundleID: "com.todesktop.230313mzl4w4u92", teamID: "2DC432GLL2",
                               appPath: "/Applications/Cursor.app", peerPath: "/usr/bin/ssh", peerName: "ssh")
    #expect(key == "bundle:com.todesktop.230313mzl4w4u92:2DC432GLL2")
}

@Test func missingTeamIDKeepsTheAppPath() {
    let key = SSHTrustKey.make(bundleID: "com.example.Fake", teamID: nil,
                               appPath: "/tmp/Fake.app", peerPath: "/usr/bin/ssh", peerName: "ssh")
    #expect(key == "path:/tmp/Fake.app")
}

@Test func grantsExpireAndLockClearsThem() {
    var store = SSHTrustStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    store.grant(SSHTrust(trustKey: "path:/Applications/Cursor.app", keyID: "k", displayName: "Cursor", keyName: "work", until: now.addingTimeInterval(15)))
    store.grant(SSHTrust(trustKey: "path:/Applications/Terminal.app", keyID: "k", displayName: "Terminal", keyName: "work", until: nil))
    #expect(store.allows(trustKey: "path:/Applications/Cursor.app", keyID: "k", now: now.addingTimeInterval(10)) != nil)
    store.expire(now: now.addingTimeInterval(16))
    #expect(store.allows(trustKey: "path:/Applications/Cursor.app", keyID: "k", now: now.addingTimeInterval(16)) == nil)
    #expect(store.untilLock.map(\.displayName) == ["Terminal"])
    store.reset()
    #expect(store.untilLock.isEmpty)
}
```

**Step 2: Run the test to verify it fails**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: FAIL, `SSHTrustKey` and `SSHTrustStore` are undefined.

**Step 3: Write the implementation**

Append to `SSHApproval.swift`:

```swift
public enum SSHTrustKey {
    /// A signed bundle beats a path. An unsigned bundle keeps its own path so a copied app cannot inherit a grant.
    public static func make(bundleID: String?, teamID: String?, appPath: String?, peerPath: String?, peerName: String) -> String {
        if let bundleID, let teamID, !bundleID.isEmpty, !teamID.isEmpty {
            return "bundle:\(bundleID):\(teamID)"
        }
        if let appPath { return "path:\(appPath)" }
        if let peerPath { return "path:\(peerPath)" }
        return "name:\(peerName)"
    }
}

public struct SSHTrust: Equatable, Sendable, Identifiable {
    public var id: String { "\(trustKey)|\(keyID)" }
    public var trustKey: String
    public var keyID: String
    public var displayName: String
    public var keyName: String
    /// Nil lasts until `reset` (the vault locking).
    public var until: Date?
    public init(trustKey: String, keyID: String, displayName: String, keyName: String, until: Date?) {
        self.trustKey = trustKey
        self.keyID = keyID
        self.displayName = displayName
        self.keyName = keyName
        self.until = until
    }
}

public struct SSHTrustStore {
    public private(set) var entries: [SSHTrust] = []
    public init() {}

    public func allows(trustKey: String, keyID: String, now: Date) -> SSHTrust? {
        entries.first { $0.trustKey == trustKey && $0.keyID == keyID && ($0.until.map { $0 > now } ?? true) }
    }

    public var untilLock: [SSHTrust] { entries.filter { $0.until == nil } }

    public mutating func grant(_ trust: SSHTrust) {
        entries.removeAll { $0.id == trust.id }
        entries.append(trust)
    }

    public mutating func revoke(id: String) { entries.removeAll { $0.id == id } }

    public mutating func expire(now: Date) {
        entries.removeAll { $0.until.map { $0 <= now } ?? false }
    }

    public mutating func reset() { entries.removeAll() }
}
```

**Step 4: Run the test to verify it passes**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift
git commit -m "$(cat <<'EOF'
Remember SSH signature grants until they expire or the vault locks.

EOF
)"
```

---

### Task 3: One card at a time, with a timeout

**Files:**
- Modify: `Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift`
- Modify: `Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift`

**Step 1: Write the failing test**

```swift
@Test func theFrontPromptTimesOutWithoutReleasingTheQueue() async {
    let queue = SSHApprovalQueue()
    let first = SSHPrompt(id: UUID(), trustKey: "a", displayName: "Cursor", via: "git", path: nil, keyID: "1", keyName: "work")
    let second = SSHPrompt(id: UUID(), trustKey: "b", displayName: "Terminal", via: "ssh", path: nil, keyID: "1", keyName: "work")
    async let one = queue.ask(first)
    async let two = queue.ask(second)
    await queue.expire(now: Date().addingTimeInterval(61))
    #expect(await one == .timedOut)
    let waiting = await queue.snapshot()
    #expect(waiting.current?.displayName == "Terminal")
    #expect(waiting.count == 1)
    await queue.resolveFront(.deny)
    #expect(await two == .deny)
}
```

**Step 2: Run the test to verify it fails**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: FAIL, `SSHApprovalQueue` is undefined.

**Step 3: Write the implementation**

Append to `SSHApproval.swift`:

```swift
public enum SSHChoice: Equatable, Sendable {
    case deny
    case allow(SSHGrant)
    case timedOut
}

public enum SSHGrant: String, Equatable, Sendable {
    case once
    case tenMinutes
    case untilLock
}

public struct SSHPrompt: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var trustKey: String
    public var displayName: String
    public var via: String
    public var path: String?
    public var keyID: String
    public var keyName: String
    public init(id: UUID, trustKey: String, displayName: String, via: String, path: String?, keyID: String, keyName: String) {
        self.id = id
        self.trustKey = trustKey
        self.displayName = displayName
        self.via = via
        self.path = path
        self.keyID = keyID
        self.keyName = keyName
    }
}

public actor SSHApprovalQueue {
    public let timeout: TimeInterval = 60
    private struct Waiting {
        var prompt: SSHPrompt
        var shownAt: Date?
        var resume: CheckedContinuation<SSHChoice, Never>
    }
    private var order: [UUID] = []
    private var waiting: [UUID: Waiting] = [:]

    public init() {}

    public func snapshot() -> (current: SSHPrompt?, count: Int) {
        (order.first.flatMap { waiting[$0]?.prompt }, order.count)
    }

    public func ask(_ prompt: SSHPrompt) async -> SSHChoice {
        await withCheckedContinuation { continuation in
            waiting[prompt.id] = Waiting(prompt: prompt, shownAt: order.isEmpty ? .now : nil, resume: continuation)
            order.append(prompt.id)
        }
    }

    public func resolveFront(_ choice: SSHChoice) {
        guard let id = order.first, let item = waiting.removeValue(forKey: id) else { return }
        order.removeFirst()
        item.resume.resume(returning: choice)
        revealFront()
    }

    public func expire(now: Date) {
        guard let id = order.first, let shown = waiting[id]?.shownAt, now.timeIntervalSince(shown) >= timeout else { return }
        resolveFront(.timedOut)
    }

    private func revealFront() {
        guard let id = order.first, var item = waiting[id] else { return }
        item.shownAt = item.shownAt ?? .now
        waiting[id] = item
    }
}
```

**Step 4: Run the test to verify it passes**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: PASS. The second prompt becomes current only after the first times out, and its own 60 seconds start then.

**Step 5: Commit**

```bash
git add Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift
git commit -m "$(cat <<'EOF'
Queue SSH approval prompts and time out the one on screen.

EOF
)"
```

---

### Task 4: Local access log

**Files:**
- Modify: `Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift`
- Modify: `Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift`

**Step 1: Write the failing test**

```swift
@Test func logKeepsTheNewestTwoHundred() throws {
    var log = SSHAccessLog()
    for n in 0..<205 {
        log.append(SSHAccessEvent(id: UUID(), date: Date(timeIntervalSince1970: TimeInterval(n)),
                                   appName: "Cursor", via: "git", path: "/usr/bin/git", keyName: "work",
                                   outcome: .reusedTrust))
    }
    #expect(log.events.count == 200)
    #expect(log.events.first?.date == Date(timeIntervalSince1970: 204))
    let url = FileManager.default.temporaryDirectory.appending(path: "ssh-log-\(UUID().uuidString).json")
    try log.save(to: url)
    let loaded = SSHAccessLog.load(from: url)
    #expect(loaded.events.count == 200)
    #expect(loaded.events.first?.outcome == .reusedTrust)
}
```

**Step 2: Run the test to verify it fails**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: FAIL, `SSHAccessLog` is undefined.

**Step 3: Write the implementation**

Append to `SSHApproval.swift`:

```swift
public enum SSHAccessOutcome: String, Codable, Equatable, Sendable {
    case allowedOnce
    case allowedForTenMinutes
    case allowedUntilLock
    case denied
    case timedOut
    case locked
    case reusedTrust
}

public struct SSHAccessEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appName: String
    public var via: String
    public var path: String?
    public var keyName: String
    public var outcome: SSHAccessOutcome
    public init(id: UUID, date: Date, appName: String, via: String, path: String?, keyName: String, outcome: SSHAccessOutcome) {
        self.id = id
        self.date = date
        self.appName = appName
        self.via = via
        self.path = path
        self.keyName = keyName
        self.outcome = outcome
    }
}

public struct SSHAccessLog: Codable, Equatable, Sendable {
    public static let capacity = 200
    public private(set) var events: [SSHAccessEvent] = []
    public init() {}

    public mutating func append(_ event: SSHAccessEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }

    public mutating func clear() { events.removeAll() }

    public static func load(from url: URL) -> SSHAccessLog {
        guard let data = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(SSHAccessLog.self, from: data) else {
            return SSHAccessLog()
        }
        return log
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
```

**Step 4: Run the test to verify it passes**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Packages/VaultCore/Sources/SSHAgent/SSHApproval.swift Packages/VaultCore/Tests/SSHAgentTests/SSHApprovalTests.swift
git commit -m "$(cat <<'EOF'
Keep the newest SSH access requests in a local log.

EOF
)"
```

---

### Task 5: Drive the agent with the rules

**Files:**
- Modify: `App/Sources/SSHAgentService.swift`
- Modify: `App/Sources/Snapshot.swift` only if the hook's call shape would change. It must not: `approveOverride(identity.name, peer.processName)` stays, so the assertion `asked == ["ssh-keygen→Selftest SSH"]` stays true.

**Step 1: Add a live process lookup beside the service**

Create `App/Sources/SSHProcess.swift`:

```swift
import Darwin
import Foundation
import SSHAgent

enum SSHProcess {
    static func node(_ pid: pid_t) -> ProcessNode? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard size == Int32(MemoryLayout.size(ofValue: info)) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = n > 0 ? String(cString: buffer) : nil
        return ProcessNode(pid: info.pbsi_pid, parent: info.pbsi_ppid, path: path)
    }
}
```

If `proc_bsdshortinfo` or `PROC_PIDT_SHORTBSDINFO` fails to compile, declare the C struct and the constant `13` locally. Do not change the resolver tests to match a broken lookup.

**Step 2: Read a signature only for the app pid**

In the same file, add a function that returns `(bundleID, teamID)` via `SecCodeCopyGuestWithAttributes` (`kSecGuestAttributePid`) and `SecCodeCopySigningInformation`. Use `kSecCodeInfoIdentifier` and `kSecCodeInfoTeamIdentifier`. Any failure returns `(nil, nil)`. Call it with `requester.appPID`, then replace `requester.trustKey` with `SSHTrustKey.make(...)`. Prefer `NSRunningApplication(processIdentifier:)?.localizedName` for `displayName` when it is non-empty.

**Step 3: Replace the grant map in `SSHAgentService`**

Remove `approvedUntil` and the read of `Pref.sshApprovalSeconds`. Hold:

- `var trust = SSHTrustStore()`
- `var accessLog = SSHAccessLog.load(from: logURL)`
- `let prompts = SSHApprovalQueue()`
- `private var inflight: [String: Task<SSHChoice, Never>] = [:]`

`logURL` is the App Group container plus `ssh-access-log.json`, next to `agent.sock`. After `save`, set the file protection to `completeUntilFirstUserAuthentication`.

`reset()` clears `trust` and `parsed`. It leaves `accessLog` on disk.

**Step 4: Write `approve`**

Keep this branch first, with the same arguments the self-test uses, and return before any log file write, queue, or `LAContext`:

```swift
if let approveOverride {
    let allowed = approveOverride(identity.name, peer.processName)
    recent.insert((.now, identity.name, peer.processName, allowed), at: 0)
    if recent.count > 8 { recent.removeLast() }
    return allowed
}
```

Otherwise:

1. Build the requester (Task 1 + Step 2). If the vault is locked, append `.locked` and return false.
2. `trust.expire(now: .now)`. If `trust.allows` hits, append `.reusedTrust` and return true.
3. Join `inflight[requester.trustKey + "|" + identity.id]` when one exists, so a burst shares one choice and one Touch ID. Cursor often starts several `ssh` processes together; those must not each call `LAContext`. Otherwise store a `Task` that asks `prompts.ask` and, on `.allow`, runs `LAContext` with reason `allow “\(displayName)” to sign with the SSH key “\(identity.name)”` and cancel title `Deny`. Store a grant only after that returns true: 15 seconds for `.once`, 600 seconds for `.tenMinutes`, nil for `.untilLock`. The prompt records `waitingCount` for how many callers joined before the person answers.
4. Every caller, including the ones that joined the task, appends one event for the resulting outcome. A failed Touch ID is `.denied`. Publish the newest events through the existing `recent` tuples so the menu bar keeps compiling (`program` is `requester.displayName`).
5. Call `model?.noteActivity()` only when a signature is allowed.

Map outcomes: `.once` → `.allowedOnce`, `.tenMinutes` → `.allowedForTenMinutes`, `.untilLock` → `.allowedUntilLock`.

**Step 5: Build**

Run: `make build`
Expected: the app builds. `Snapshot.swift` is unchanged.

**Step 6: Commit**

```bash
git add App/Sources/SSHAgentService.swift App/Sources/SSHProcess.swift
git commit -m "$(cat <<'EOF'
Approve SSH signatures through grants instead of a fixed timer.

EOF
)"
```

---

### Task 6: Approval card

**Files:**
- Create: `App/Sources/SSHApprovalCard.swift`
- Modify: `App/Sources/SSHAgentService.swift`

**Step 1: Publish the prompt that is waiting**

On `SSHAgentService`, add `private(set) var pending: SSHPrompt?` and `private(set) var pendingCount = 0`. Refresh them from `prompts.snapshot()` when a request starts, when the front changes, and when a timeout or choice resolves one. A one-second task calls `prompts.expire(now: .now)` while `pendingCount > 0`.

`func choose(_ choice: SSHChoice)` calls `prompts.resolveFront`. The menu bar and the card both call it.

**Step 2: Build the card**

`SSHApprovalCard` is a SwiftUI view, about 380 points wide, using the menu-bar panel's card, type, and `.buttonStyle(.appPrimarySmall)`. It shows:

- the app icon from `NSWorkspace.shared.icon(forFile:)` when `appPath` is known, otherwise `terminal`
- `Text("\(name) wants to sign")` with the display name verbatim
- `via \(tool) · \(key name)`
- the path in 11-point monospaced secondary text, middle-truncated
- `This signs one SSH operation. The private key stays in your vault.`
- `macOS will ask for Touch ID or your Mac login password. That password stays with macOS.`
- Deny, Allow Once, Allow for 10 Minutes, Trust Until Lock
- when `waitingCount > 1`, a line `^[\(count) signatures in this request](inflect: true)`

The first ask from an app in this unlock leads with Allow Once as the primary button. If `accessLog` already contains that `trustKey` since the vault was unlocked, Trust Until Lock is the primary button and the card adds `This app has asked to sign before.` Allow Once stays on the card. Add a pure helper and a test:

```swift
enum SSHApprovalEmphasis {
    /// The first ask in an unlock leads with a short grant. A repeat ask leads with trust until lock.
    public static func leadsWithUntilLock(priorAsks: Int) -> Bool { priorAsks > 0 }
}
```

Those four buttons call `choose` with `.deny`, `.allow(.once)`, `.allow(.tenMinutes)`, and `.allow(.untilLock)`.

**Step 3: Host it in a panel**

When `pending` becomes non-nil, order an `NSPanel` forward (`.floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `hidesOnDeactivate = false`). Remember `NSWorkspace.shared.frontmostApplication`, activate Triwarden, and make the panel key so Touch ID attaches here. When `pending` becomes nil, close the panel and activate the remembered app. Closing the panel with its close button sets `pending` presentation away but does not call `choose`; the request stays in the queue until the menu bar, the card, or the 60-second timeout answers it. Reopening happens from the menu bar row.

**Step 4: Build**

Run: `make build`
Expected: the app builds.

**Step 5: Commit**

```bash
git add App/Sources/SSHApprovalCard.swift App/Sources/SSHAgentService.swift
git commit -m "$(cat <<'EOF'
Ask for an SSH signature in a card that names the app.

EOF
)"
```

---

### Task 7: Menu bar

**Files:**
- Modify: `App/Sources/MenuBarExtraView.swift`
- Modify: `App/Sources/TriwardenApp.swift`

**Step 1: Mark the glyph**

Give `MenuBarGlyph.image` a `pending` flag. When it is true, fill a 3-point circle at the top trailing of the 18-point template. Leave the image a template. In `TriwardenApp`, pass `model.sshAgent.pendingCount > 0`.

**Step 2: Replace the SSH row while a request is waiting**

In `SSHRow`, when `agent.pending` is set, show that app, the key name, and the same four actions as the card, calling `agent.choose`. The existing status line remains the view for an idle agent, using the latest log entry's app name. `pendingCount > 1` adds a secondary line `^[\(count - 1) more waiting](inflect: true)`. Choosing an action on the row answers the front prompt.

**Step 3: Build**

Run: `make build`
Expected: the app builds.

**Step 4: Commit**

```bash
git add App/Sources/MenuBarExtraView.swift App/Sources/TriwardenApp.swift
git commit -m "$(cat <<'EOF'
Surface a waiting SSH signature on the menu bar.

EOF
)"
```

---

### Task 8: Notification that only opens the card

**Files:**
- Create: `App/Sources/SSHApprovalNotifier.swift`
- Modify: `App/Sources/TriwardenApp.swift`
- Modify: `App/Sources/SettingsView.swift` (the SSH agent toggle)

**Step 1: Ask for permission when the agent is turned on**

In the existing `onChange(of: enabled)` for `Use Triwarden as SSH agent`, when `on` is true, call `UNUserNotificationCenter.current().requestAuthorization(options: [.alert])`. Ignore the result. A denial leaves the card and the menu bar working.

**Step 2: Post only while the card is still waiting**

`SSHApprovalNotifier` schedules a local notification two seconds after a prompt becomes current. Title: `\(displayName) wants to sign`. Body: the key name. Category `ssh-approval` has no actions. `userInfo` carries the prompt id. If the prompt is gone before two seconds, or a newer prompt is current, remove the pending request. On resolve, remove the delivered notification with that id.

Set the app delegate (or a small `UNUserNotificationCenterDelegate` owned by the app) so a tap activates Triwarden and orders the approval panel forward. The tap does not call `choose`.

**Step 3: Build**

Run: `make build`
Expected: the app builds.

**Step 4: Commit**

```bash
git add App/Sources/SSHApprovalNotifier.swift App/Sources/TriwardenApp.swift App/Sources/SettingsView.swift
git commit -m "$(cat <<'EOF'
Ping when an SSH signature request is still waiting.

EOF
)"
```

---

### Task 9: Settings for trust and the log

**Files:**
- Modify: `App/Sources/SettingsView.swift`
- Modify: `App/Sources/Preferences.swift`

**Step 1: Remove the global timer**

Delete the `Ask before signing` picker and `@AppStorage(Pref.sshApprovalSeconds)`. Leave the `Pref.sshApprovalSeconds` constant in place so an old default is simply unread. Update the section footer to: `SSH key items from unlocked accounts are offered to ssh and git. Each signature asks you, then asks macOS for Touch ID or your Mac login password. Keys never leave the app.`

**Step 2: List grants that last until lock**

Add a section `Trusted until the vault locks`. Empty copy: `Trust an app from the prompt when it asks to sign. Trust lasts until the vault locks.` Each row shows the display name, the key name, and Remove, calling `trust.revoke(id:)` on the service. Expose `untilLock` and `revokeTrust(id:)` on `SSHAgentService`.

**Step 3: List the log**

Replace `Recent SSH requests` with `SSH access`. Rows read `accessLog.events`: app name, `via` tool, key name, a short outcome label, and the date. A `Clear Log` button calls `accessLog.clear()` and deletes the file. Expose `sshAccessLog` and `clearSSHAccessLog()` on the service.

Outcome labels: `Allowed once`, `Allowed for 10 minutes`, `Trusted until lock`, `Denied`, `Timed out`, `Vault locked`, `Used an existing grant`.

**Step 4: Build**

Run: `make build`
Expected: the app builds.

**Step 5: Commit**

```bash
git add App/Sources/SettingsView.swift App/Sources/SSHAgentService.swift
git commit -m "$(cat <<'EOF'
Show SSH grants and the access log in Settings.

EOF
)"
```

---

### Task 10: Security note and translations

**Files:**
- Modify: `SECURITY.md`
- Modify: `App/Resources/Localizable.xcstrings`

**Step 1: Replace the SSH agent bullet in `SECURITY.md`**

Use this paragraph:

```markdown
- **SSH agent** (off by default) listens on a `0600` socket in the App Group container. It only lists and
  signs; it never adds, removes or exports keys. A signature request names the app that owns the connecting
  process (bundle id and Team ID when the signature is readable, otherwise the executable path). The person
  allows it once, for 10 minutes, or until the vault locks; macOS then asks for Touch ID or the Mac login
  password, which Triwarden never receives. Grants live in memory and are cleared on lock. Allowing once
  also covers the same app and key for 15 seconds. Every request is appended to `ssh-access-log.json` in the
  App Group container (newest 200; app, tool, path, key name, outcome; no key material and no signed payload).
  Keys are only available while their account is unlocked.
```

**Step 2: Add the new strings**

Add every new user-facing string to `App/Resources/Localizable.xcstrings` with `en` as the source and translations for `zh-Hans`, `zh-Hant`, `zh-HK`, and `ja`. Include at least:

| Source | zh-Hans | zh-Hant / zh-HK | ja |
| --- | --- | --- | --- |
| `%@ wants to sign` | `%@ 想要簽名` | `%@ 想要簽名` | `%@ が署名しようとしています` |
| `This signs one SSH operation. The private key stays in your vault.` | `這次只做一次 SSH 簽名。私鑰留在保險庫裡。` | `這次只做一次 SSH 簽名。私鑰留在保險庫裡。` | `SSH の署名を 1 回行います。秘密鍵は保管庫に残ります。` |
| `macOS will ask for Touch ID or your Mac login password. That password stays with macOS.` | `macOS 接著會要求 Touch ID 或這台 Mac 的登入密碼。這組密碼只留在 macOS。` | `macOS 接著會要求 Touch ID 或這部 Mac 的登入密碼。這組密碼只留在 macOS。` | `続いて macOS が Touch ID またはこの Mac のログインパスワードを求めます。そのパスワードは macOS だけが扱います。` |
| `Allow Once` | `只允許這次` | `只允許這次` | `今回だけ許可` |
| `Allow for 10 Minutes` | `允許 10 分鐘` | `允許 10 分鐘` | `10 分間許可` |
| `Trust Until Lock` | `直到上鎖前信任` | `直到上鎖前信任` | `ロックまで信頼` |
| `Trusted until the vault locks` | `直到保險庫上鎖前信任` | `直到保險庫上鎖前信任` | `保管庫をロックするまで信頼` |
| `SSH access` | `SSH 存取紀錄` | `SSH 存取紀錄` | `SSH の利用記録` |
| `Clear Log` | `清空紀錄` | `清空紀錄` | `記録を消去` |
| `Used an existing grant` | `沿用剛才的允許` | `沿用剛才的允許` | `既存の許可を使用` |

zh-HK uses 這部 Mac where zh-Hant uses 這台 Mac. Match the vocabulary already in the catalog when a string is adjacent to an existing one.

**Step 3: Commit**

```bash
git add SECURITY.md App/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
Describe SSH approval grants and record them for people who read the log.

EOF
)"
```

---

### Task 11: Verify

**Step 1: Unit tests**

Run: `cd Packages/VaultCore && swift test --filter SSHApprovalTests`
Expected: PASS.

**Step 2: App build**

Run: `make build`
Expected: build succeeds.

**Step 3: Manual check**

Turn the SSH agent on. From Terminal and from another app, run a command that signs with a vault SSH key. Confirm:

- the card names that app, not Triwarden, and names the key
- several overlapping `ssh` processes from Cursor produce one card and one system dialog, and the card shows how many signatures are in the burst
- a later ask from Cursor in the same unlock leads with Trust Until Lock
- Deny makes the command fail
- Allow Once leads to the system Touch ID or Mac password dialog, then a second sign within 15 seconds does not ask
- Trust Until Lock appears in Settings and disappears after locking the vault
- the menu-bar glyph shows its corner mark while the card is waiting, and the SSH row can answer it
- a notification appears only if the request is still waiting, and tapping it does not approve
- Settings → SSH access lists the app, the tool, the key, and the outcome, and Clear Log empties it
