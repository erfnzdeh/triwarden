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
