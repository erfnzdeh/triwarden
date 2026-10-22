# API Key Variable Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the saved key → environment variable → tool relationship visible during API-key creation and tool setup.

**Architecture:** Keep a standard Secure Note with hidden `api-key`, text `service`, and text `environment-variable` fields. The vault stores a default variable name; each saved tool retains its own explicitly reviewed name. Existing key items without this metadata derive the same service suggestion as before. Editing the default never rewrites an existing tool binding or grants access to another program.

**Tech Stack:** SwiftUI, shared Bitwarden custom fields, SecretsAgent launch validation, native XCTest and isolated app diagnostics.

The user identified that the current creation form hides how a key becomes an environment variable. Continue the agreed user journey with an explicit default at creation, editable confirmation during tool setup, and a visible mapping in review. Prefer this over requiring a globally unique variable name (several projects can use `API_KEY`) or guessing from program names (no reliable identity or intent).

### 1. Demonstrate the missing field

Modify `UITests/CISmokeTests.swift` to require `apiKeyVariable` on the normal vault creation form, initially `API_KEY`. Run the focused native test before implementation and confirm it fails because the field is absent.

### 2. Implement the default and repair behavior

Modify `App/Sources/APIKeyTemplate.swift` and `App/Sources/EditItemSheet.swift`:

- Include a standard text `environment-variable` field in the preset and capture its stable ID alongside the other primary fields.
- Suggest `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `API_KEY` while the new field is untouched. Once the user edits it, preserve it across service changes. Preserve every existing saved name when editing or cloning.
- Fill older items without this metadata from their service when opening the editor. Keep duplicate/wrong-kind metadata editable under Additional fields; reject duplicates with a repair message.
- Validate syntax and the existing launch policy before saving, with an inline actionable error.

### 3. Expose the complete binding

Modify `App/Sources/VaultView.swift` and `App/Sources/ToolLaunchSetup.swift` to label the default in key detail and explicitly show the selected key, actual variable name, and tool name during setup/review. A tool-specific override is local to that saved launch; it does not change the vault default. Add brief launch instructions that tools receive a key only when launched through Triwarden.

### 4. Verify and deliver

- Extend `App/Sources/CompatibilitySelfTest.swift` for encrypted metadata round-trip, old-item fallback and stable duplicate repair.
- Add a focused native UI test for provider suggestions, preservation of custom names, invalid-name feedback and cancel/discard.
- Build the signed app, run the native checks/UI tests, and inspect light/dark previews of the changed screens.
- Update `docs/local-secrets.md`. Reopen the signed app and use the usagi fake-key example to verify a saved default survives a vault round-trip and pre-fills tool setup without saving a tool grant.
- Commit the verified change in the existing worktree.

Commands: `xcodebuild -project Triwarden.xcodeproj -scheme Triwarden -configuration Debug -derivedDataPath build -allowProvisioningUpdates test -only-testing:TriwardenUITests/CISmokeTests/testAPIKeyCreationStartsInTheVault`; run the built binary with `--selftest-compatibility` for isolated native checks. Expect the first UI run to fail, then the final focused tests and native checks to pass. No provider request or Touch ID bypass is involved.
