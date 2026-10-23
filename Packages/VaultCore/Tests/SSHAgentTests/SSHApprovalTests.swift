import Foundation
import Testing
@testable import SSHAgent

// Revoking an app's permanent permission must not leave its cached signing trust usable.
@Test func revokingCallerRemovesAllItsCachedKeysButKeepsOtherApps() {
    var store = SSHTrustStore()
    let now = Date.now
    store.grant(.init(trustKey: "terminal", keyID: "first", displayName: "Terminal", keyName: "First", until: nil))
    store.grant(.init(trustKey: "terminal", keyID: "second", displayName: "Terminal", keyName: "Second", until: now.addingTimeInterval(600)))
    store.grant(.init(trustKey: "editor", keyID: "first", displayName: "Editor", keyName: "First", until: nil))
    store.revoke(trustKey: "terminal")
    #expect(store.allows(trustKey: "terminal", keyID: "first", now: now) == nil)
    #expect(store.allows(trustKey: "terminal", keyID: "second", now: now) == nil)
    #expect(store.allows(trustKey: "editor", keyID: "first", now: now) != nil)
}

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

@Test func helperInsideCursorIsCursor() {
    let path = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
    let who = SSHRequesterResolver.resolve(pid: 5, peerPath: "/usr/bin/ssh", peerName: "ssh") { pid in
        pid == 5 ? ProcessNode(pid: 5, parent: 1, path: path) : nil
    }
    #expect(who.displayName == "Cursor")
    #expect(who.appPath == "/Applications/Cursor.app")
    #expect(who.via == "ssh")
}

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

@Test func theFrontPromptTimesOutWithoutReleasingTheQueue() async throws {
    let queue = SSHApprovalQueue()
    let first = SSHPrompt(id: UUID(), trustKey: "a", displayName: "Cursor", via: "git", path: nil, keyID: "1", keyName: "work")
    let second = SSHPrompt(id: UUID(), trustKey: "b", displayName: "Terminal", via: "ssh", path: nil, keyID: "1", keyName: "work")
    let one = Task { await queue.ask(first) }
    while await queue.snapshot().count < 1 { await Task.yield() }
    let two = Task { await queue.ask(second) }
    while await queue.snapshot().count < 2 { await Task.yield() }
    let deadline = try #require(await queue.snapshot().deadline)
    await queue.expire(now: deadline.advanced(by: .milliseconds(-1)))
    #expect(await queue.snapshot().current?.id == first.id)
    await queue.expire(now: deadline)
    #expect(await one.value == .timedOut)
    let waiting = await queue.snapshot()
    #expect(waiting.current?.displayName == "Terminal")
    #expect(waiting.count == 1)
    #expect(waiting.deadline == deadline.advanced(by: SSHApprovalQueue.timeout))
    await queue.resolveFront(.deny)
    #expect(await two.value == .deny)
}

@Test func aStalePanelCannotAnswerTheNextPrompt() async {
    let queue = SSHApprovalQueue()
    let first = SSHPrompt(id: UUID(), trustKey: "a", displayName: "Cursor", via: "git", path: nil, keyID: "1", keyName: "work")
    let second = SSHPrompt(id: UUID(), trustKey: "b", displayName: "Terminal", via: "ssh", path: nil, keyID: "1", keyName: "work")
    let one = Task { await queue.ask(first) }
    while await queue.snapshot().count < 1 { await Task.yield() }
    let two = Task { await queue.ask(second) }
    while await queue.snapshot().count < 2 { await Task.yield() }
    await queue.resolve(.deny, for: first.id)
    #expect(await one.value == .deny)
    await queue.resolve(.allow(.always), for: first.id)
    #expect(await queue.snapshot().current?.id == second.id)
    await queue.resolve(.deny, for: second.id)
    #expect(await two.value == .deny)
}

@Test func joiningSignaturesDoesNotRestartTheCountdown() async throws {
    let queue = SSHApprovalQueue()
    let prompt = SSHPrompt(id: UUID(), trustKey: "a", displayName: "Terminal", via: "ssh", path: nil, keyID: "1", keyName: "work")
    let answer = Task { await queue.ask(prompt) }
    while await queue.snapshot().count < 1 { await Task.yield() }
    let original = try #require(await queue.snapshot().deadline)
    await queue.noteJoined(prompt.id)
    #expect(await queue.snapshot().deadline == original)
    #expect(await queue.snapshot().current?.waitingCount == 2)
    await queue.denyAll()
    #expect(await answer.value == .deny)
    #expect(await queue.snapshot().deadline == nil)
}

@Test func anExpiredCardCannotAllowBeforeTheNextWatcherTick() async throws {
    let queue = SSHApprovalQueue()
    let prompt = SSHPrompt(id: UUID(), trustKey: "a", displayName: "Terminal", via: "ssh", path: nil, keyID: "1", keyName: "work")
    let answer = Task { await queue.ask(prompt) }
    while await queue.snapshot().count < 1 { await Task.yield() }
    let deadline = try #require(await queue.snapshot().deadline)
    await queue.resolve(.allow(.always), for: prompt.id, now: deadline)
    #expect(await answer.value == .timedOut)
}

@Test func aRepeatAskLeadsWithTrustUntilLock() {
    #expect(SSHApprovalEmphasis.leadsWithUntilLock(priorAsks: 0) == false)
    #expect(SSHApprovalEmphasis.leadsWithUntilLock(priorAsks: 2) == true)
}

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

@Test func allowlistMatchesTheTrustKeyNotTheDisplayName() throws {
    var list = SSHAllowlist()
    let key = "bundle:com.apple.dt.Xcode|team:APPLE"
    list.add(SSHAllowlistEntry(trustKey: key, displayName: "Xcode"))
    list.add(SSHAllowlistEntry(trustKey: key, displayName: "Xcode 26"))
    #expect(list.entries.count == 1)
    #expect(list.entries.first?.displayName == "Xcode 26")
    #expect(list.contains(key))
    #expect(list.contains("Xcode") == false)
    let url = FileManager.default.temporaryDirectory.appending(path: "ssh-allow-\(UUID().uuidString).json")
    try list.save(to: url)
    let loaded = SSHAllowlist.load(from: url)
    #expect(loaded.contains(key))
    var cleared = loaded
    cleared.remove(trustKey: key)
    #expect(cleared.entries.isEmpty)
}

@Test func aSilentAllowlistGrantIsNotAnotherAsk() {
    var log = SSHAccessLog()
    let start = Date(timeIntervalSince1970: 1_000)
    log.append(SSHAccessEvent(id: UUID(), date: start, appName: "Xcode", via: "ssh", path: nil,
                               keyName: "work", outcome: .allowlisted, trustKey: "k"))
    #expect(log.priorAsks(trustKey: "k", since: start) == 0)
}
