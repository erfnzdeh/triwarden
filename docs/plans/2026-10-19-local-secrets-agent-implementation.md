# Local Secrets Agent Implementation Plan

> Use the executing-plans workflow to implement this plan task by task.

**Goal:** Ship a single-profile, single-field Bitwarden-backed launch flow with explicit native approval and no plaintext configuration.

**Architecture:** A new `SecretsAgent` Swift package target owns reference-only profiles, launch validation, restricted environments, and mutually authenticated one-request IPC. A native controller resolves the field from an unlocked account after approval. The bundled CLI validates the response and replaces itself using `execve`.

**Tech Stack:** Swift 6, SwiftUI/AppKit, LocalAuthentication, Security.framework, CryptoKit, Darwin Unix sockets.

## 1. Profile and launch policy

Files: `Packages/VaultCore/Sources/SecretsAgent/SecretsProfile.swift`, `LaunchPolicy.swift`, `Tests/SecretsAgentTests/SecretsAgentTests.swift`, package manifest.

Write failing tests for forbidden environment keys, same-name field ambiguity, revision changes, argument validation, reference-only serialization, executable replacement, and environment filtering. Run `swift test --filter SecretsAgentTests`. Implement canonical profiles and exact selectors, file fingerprinting, and restricted environment assembly; rerun the tests.

## 2. Authenticated transport

Files: `Packages/VaultCore/Sources/SecretsAgent/SecretsTransport.swift`, transport tests.

Test malformed/oversized frames, missing audit tokens, wrong counterpart authentication, one-shot connections, and disconnect handling. Implement socket audit-token/SecCode validation on both sides, bounded requests, and a liveness closure tied to the active connection. Unsigned peers fail closed. Re-run package tests.

## 3. Native profile and authorization

Files: `App/Sources/SecretsController.swift`, `SecretsSettings.swift`, `SettingsView.swift`, `AppModel.swift`.

Add one local profile editor using existing vault fields. Show saved launch parameters and one secret reference; never show the value. Add a native authorization card and LAContext authentication with deadline, disconnect, lock and profile-change cancellation. Resolve the value only at final delivery. Require online refresh; reject re-prompt items with guidance in this first slice. Add lifecycle checks for lock/logout and focused UI smoke coverage.

## 4. CLI exec path

Files: `CLI/main.swift`, `project.yml`, generated Xcode project.

Implement `tw run --profile NAME` with no command overrides. Load the profile, snapshot target identity, authenticate the App, request approval, verify nonce/revision and file identity again, construct the restricted environment, close IPC and exec. Preserve terminal semantics and exit codes. Never evaluate shell strings or print secrets. Test parser failures, failed launch, and a synthetic end-to-end canary flow in an isolated fixture.

## 5. Documentation and validation

Files: `docs/local-secrets.md`, `README.md`, `SECURITY.md`, design document.

Document setup, exact supported scope, migration, same-user environment visibility and path-exec race limitations. Run all package tests and a signed app build. Validate a denied request and a successful canary launch with isolated data, plus target-replacement and lock-race failures. Record any checks that require interactive device-owner authentication rather than claiming they were automated.

Implementation stays in `codex/local-secrets-agent`, based on fetched `origin/main` commit `2d2c236`. Existing untracked files in the original checkout are preserved.

## Progress

- Merged latest fetched main `653238d` into the feature branch after checkpointing the initial implementation.
- Core profile/launch policy, authenticated transport, native settings/approval, and CLI exec are implemented.
- Added a Data Protection Keychain pin for the natively reviewed profile revision to reject external JSON changes.
- Synthetic integration tests exercise real signed peer processes, sealed ad-hoc bundles, tampered bundle rejection, denied/disconnected requests, maximum escaped value delivery and real exec exit status/environment filtering.
- The full package regression suite, signed-app Keychain/profile diagnostic, and native cancellation tests against the real dev account pass. A user-assisted native canary also passed on 2026-10-21, including device-owner authentication, dummy-key delivery and real CLI exec. The Settings UI smoke passed earlier on 2026-10-20; a later rerun could not enable XCTest automation.
- Bounded activity history is deferred with richer profile management; it is not part of this core slice.

## Validation record

- `swift test --package-path Packages/VaultCore`: 152 tests passed across the four test targets (80 API, 28 crypto, 25 Secrets Agent, 19 SSH Agent). The secrets tests include seven real-process transport/exec fixtures. These are synthetic credentials, not a live Bitwarden account. The added regressions failed before the physical-path fix and passed afterward: executable/cwd identities retain `/private`, and `/tmp` supports actual exec with the expected exit code. Foundation strips that prefix in [its URL normalization](https://developer.apple.com/documentation/foundation/nsurl/resolvingsymlinksinpath); launch identity now uses Darwin `realpath` and preserves the existing `O_NOFOLLOW`/identity checks.
- `make build`: signed Debug app builds successfully.
- `codesign --verify --deep --strict build/Build/Products/Debug/Triwarden.app`: verifies the app and nested signatures.
- Bundled `tw run --profile dev -- /bin/echo …`: rejects the override without producing target output.
- `xcodebuild … -only-testing:TriwardenUITests/CISmokeTests/testSecretsSettingsUsesReferences`: passed on the active desktop on 2026-10-20. The test opens the explicit Settings menu action, verifies reference-selection controls, and checks that the page has no secret-entry control.
- `make selftest-secrets`: 18 checks passed again on 2026-10-21 using the signed Debug app and real Data Protection Keychain APIs. Covers native profile save/reload, protected revision updates, external-edit rejection, missing/unauthorized Keychain failures, disabled/demo saves, bundled CLI read/write denial, and rejection of malformed/unowned diagnostic scopes. Account storage is isolated before model construction; disposable files and the Keychain record are removed before exit.
- `make selftest-secrets-online`: eight checks passed again against the real disposable Vaultwarden dev server through a local loopback forward on 2026-10-21. The real bundled CLI reaches native approval after online refresh; denial, disconnection, profile save and account lock all prevent exec. Server-side item deletion and local-record cleanup are confirmed. Cleanup waits for asynchronous online session resume after an offline unlock.
- `make selftest-secrets-presentation`: reproduced an invisible card while Triwarden was inactive (`isVisible=true`, active Space, but occluded). A cooperative focus handoff to Finder made the regression repeatable. The check failed before setting `NSPanel.hidesOnDeactivate=false` and passed afterward with the app still inactive and the card unoccluded. This covers the current desktop, not fullscreen/every Spaces configuration. This matches [AppKit's documented panel default](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate).
- `make selftest-secrets-interactive`: passed on 2026-10-21 with user approval of the redesigned card and normal macOS device-owner authentication. The real bundled CLI received the dummy value, executed the canary and preserved exit status 37. The diagnostic exited 0 with zero failures; server item deletion and local file/Keychain cleanup were confirmed. No real API keys were requested or migrated, and Bitwarden cloud was not tested.
- Earlier attempts exposed panel occlusion, unavailable Keychain interaction (`-25308`), and the `/tmp` normalization bug above. The final run used an unlocked desktop and the fixes described here. Native diagnostic helpers inherit the App sandbox, so their cwd uses the disposable App Group directory; the real terminal `/tmp` scenario is covered independently by the process regression. A test-only cwd preflight catches fixture access errors before asking for authentication.
- The approval panel now reuses `FormHeader`, `FormCard`, `FormFooter`, `WindowBackdrop` and the app's capsule buttons, with resizable content, full argv wrapping, helper disclosure and pinned actions. Allow explicitly opts out of the shared footer's Return shortcut. Five synthetic light/dark/compact/long/busy previews were rendered and visually inspected; no live credential is included.

The worktree and feature branch are retained for review; no merge to main or publication is part of this delivery.
