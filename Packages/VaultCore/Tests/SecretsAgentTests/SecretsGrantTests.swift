import Foundation
import Testing
@testable import SecretsAgent

struct SecretsGrantTests {
    func binding(pid: Int32 = 42, started: UInt64 = 1, code: UInt8 = 1,
                 revision: String = "reviewed", credential: String = "key-fingerprint",
                 helper: String = "/App/tw") throws -> SecretsGrantBinding {
        let profile = SecretsAgentTests().profile()
        let caller = SecretsCallerIdentity(pid: pid, uid: 501, startedSeconds: started, startedMicros: 0,
                                           codeHash: Data([code]), path: "/bin/zsh")
        return SecretsGrantBinding(caller: caller, helper: helper, revision: revision,
                                   credentialFingerprint: credential, launch: try .capture(profile))
    }

    @Test func onceDoesNotAuthorizeAnotherLaunch() throws {
        var grants = SecretsGrantStore()
        let scope = try binding(), now = ContinuousClock.now
        grants.grant(.once, for: scope, now: now)
        #expect(grants.allowed(scope, now: now) == nil)
    }

    @Test func tenMinutesHasExactNonSlidingDeadline() throws {
        var grants = SecretsGrantStore()
        let scope = try binding(), now = ContinuousClock.now
        grants.grant(.tenMinutes, for: scope, now: now)
        #expect(grants.allowed(scope, now: now.advanced(by: .seconds(599))) == .tenMinutes)
        #expect(grants.allowed(scope, now: now.advanced(by: .seconds(600))) == nil)
        #expect(grants.allowed(scope, now: now.advanced(by: .seconds(601))) == nil)
    }

    @Test func untilLockStillEndsOnReset() throws {
        var grants = SecretsGrantStore()
        let scope = try binding(), now = ContinuousClock.now
        grants.grant(.untilLock, for: scope, now: now)
        #expect(grants.allowed(scope, now: now.advanced(by: .seconds(86_400))) == .untilLock)
        grants.reset()
        #expect(grants.allowed(scope, now: now) == nil)
    }

    @Test func sameNameDoesNotAuthorizeDifferentProcessOrReusedPID() throws {
        var grants = SecretsGrantStore()
        let now = ContinuousClock.now
        grants.grant(.untilLock, for: try binding(), now: now)
        #expect(grants.allowed(try binding(pid: 43), now: now) == nil)
        #expect(grants.allowed(try binding(started: 2), now: now) == nil)
        #expect(grants.allowed(try binding(code: 2), now: now) == nil)
        #expect(grants.allowed(try binding(revision: "changed"), now: now) == nil)
        #expect(grants.allowed(try binding(credential: "rotated"), now: now) == nil)
        #expect(grants.allowed(try binding(helper: "/Other/tw"), now: now) == nil)
    }

    @Test func changedTargetDoesNotReuseGrant() throws {
        var grants = SecretsGrantStore()
        let now = ContinuousClock.now, scope = try binding()
        grants.grant(.untilLock, for: scope, now: now)
        var profile = SecretsAgentTests().profile()
        profile.executable = "/bin/echo"
        let other = SecretsGrantBinding(caller: scope.caller, helper: scope.helper, revision: scope.revision,
                                       credentialFingerprint: scope.credentialFingerprint, launch: try .capture(profile))
        #expect(grants.allowed(other, now: now) == nil)
    }

    @Test func storeIsBoundedAndExpiryDisappearsFromStatus() throws {
        var grants = SecretsGrantStore()
        let now = ContinuousClock.now
        for pid in 2..<42 { grants.grant(.tenMinutes, for: try binding(pid: Int32(pid)), now: now) }
        #expect(grants.activeCount(now: now) == 32)
        #expect(grants.activeCount(now: now.advanced(by: .seconds(600))) == 0)
    }

    @Test func missingKernelIdentityCannotCreateReusableCaller() {
        #expect(SecretsCallerIdentity.capture(auditToken: Data()) == nil)
        #expect(SecretsCallerIdentity.capture(auditToken: Data(repeating: 0, count: 32)) == nil)
    }

    @Test func observingRotationOrTargetChangeDiscardsOldGrants() throws {
        var grants = SecretsGrantStore()
        let scope = try binding()
        grants.grant(.untilLock, for: scope)
        grants.retain(revision: scope.revision, credentialFingerprint: "rotated", launch: scope.launch)
        #expect(grants.activeCount() == 0)
        #expect(grants.allowed(scope) == nil)
    }

    @Test func activeListShowsIndependentCallersAndMonotonicExpiry() throws {
        var grants = SecretsGrantStore()
        let now = ContinuousClock.now
        grants.grant(.tenMinutes, for: try binding(pid: 42), now: now)
        grants.grant(.untilLock, for: try binding(pid: 43), now: now)
        let active = grants.activeGrants(now: now)
        #expect(active.map(\.caller.pid) == [42, 43])
        #expect(active[0].duration == .tenMinutes)
        #expect(active[0].deadline == now.advanced(by: .seconds(600)))
        #expect(active[1].duration == .untilLock)
        #expect(active[1].deadline == nil)
        #expect(grants.activeGrants(now: now.advanced(by: .seconds(599))).map(\.id) == active.map(\.id))
        #expect(grants.activeGrants(now: now.advanced(by: .seconds(600))).map(\.caller.pid) == [43])
        grants.reset()
        #expect(grants.activeGrants(now: now).isEmpty)
    }

    @Test func revokeOneCallerLeavesOtherCallerAuthorized() throws {
        var grants = SecretsGrantStore()
        let first = try binding(pid: 42), second = try binding(pid: 43)
        grants.grant(.untilLock, for: first)
        grants.grant(.tenMinutes, for: second)
        let active = grants.activeGrants()
        grants.revoke(active[0].id)
        #expect(grants.allowed(first) == nil)
        #expect(grants.allowed(second) == .tenMinutes)
        #expect(grants.activeGrants().map(\.id) == [active[1].id])
        grants.revoke(active[0].id)
        #expect(grants.allowed(second) == .tenMinutes)
    }

    @Test func staleRowCannotRevokeReplacementGrant() throws {
        var grants = SecretsGrantStore()
        let scope = try binding()
        grants.grant(.tenMinutes, for: scope)
        let staleID = try #require(grants.activeGrants().first?.id)
        grants.grant(.untilLock, for: scope)
        grants.revoke(staleID)
        #expect(grants.allowed(scope) == .untilLock)
        #expect(grants.activeGrants().first?.id != staleID)
        grants.grant(.once, for: scope)
        #expect(grants.activeGrants().isEmpty)
    }
}
