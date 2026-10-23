# Multiple tools and keys Implementation Plan

**Goal:** Manage multiple saved tools and explicitly bind each tool to the API keys it needs, keeping Triwarden a credential manager and authorized launcher.

**Architecture:** Keep ordinary Bitwarden/Vaultwarden vault fields and the signed `tw run` transport. Store a bounded, reference-only catalog in the existing private file and protect the complete catalog revision with the existing Keychain record. Read legacy single-tool files and preserve their revision. Extend each tool with optional additional key bindings; omitted additions preserve old encoding. Resolve every requested key before one atomic response; fail the whole launch if any binding is unavailable. Do not add an API proxy, network interception, arbitrary environment exports or permanent API-key trust.

**Tech Stack:** Swift, SwiftUI, CryptoKit, Data Protection Keychain, existing SecretsAgent package.

## Product and security decisions

- Each saved tool has a stable CLI name. New vault → Provide to Tool starts a new setup; Edit on a saved tool explicitly selects that tool. Existing tools are never silently replaced.
- Setup lists every selected vault key and its exact variable, with Add Key / Remove actions. Review and authorization show all bindings and accounts without exposing values. Each variable must be unique and pass the existing runtime-control restrictions.
- A tool can use up to 16 bindings from unlocked accounts. Up to 64 tools are supported. Resolved values are bounded to a combined 32 KiB; missing fields, locked accounts, failed refresh or oversized delivery prevent all exec.
- Catalog saves invalidate temporary approvals conservatively. Runtime grants include the tool name; refreshing one tool must not evict unrelated tools' approvals. Lock/logout/revoke-all continue to cancel pending work globally. No raw-key fallback is used for unsupported modes.
- The UI must support choosing, editing, pausing/resuming and removing individual tools, and viewing all active approvals with the correct tool/key labels. Removing a setup never deletes the vault keys.
- A local proxy is outside the current product scope. Environment delivery does not provide SSH private-key isolation: the target receives the raw keys. Keep that statement in approval and documentation.

## Task 1: Catalog and multi-key domain model

Modify `Packages/VaultCore/Sources/SecretsAgent/SecretsProfile.swift`, `LaunchPolicy.swift`, `SecretsTransport.swift`, `SecretsGrants.swift`; add tests in `Packages/VaultCore/Tests/SecretsAgentTests/SecretsCatalogTests.swift`.

1. Write failing tests for legacy migration, named lookup, independent saves/removal, duplicate/corrupt catalog rejection, complete revision pinning, unique/forbidden variables, unchanged legacy encoding, and complete-response validation.
2. Implement bounded catalog load/upsert/remove and exact named CLI lookup. Keep single-tool `load()` only when unambiguous for existing diagnostic fixtures.
3. Add reference-only additional bindings, bounded multi-value environment construction and exact response-key validation. Preserve old single-value fixture support only for single-binding requests.
4. Bind temporary grant retention and presentation snapshots to the exact tool name; test isolation and key-change invalidation.
5. Run `swift test --filter SecretsAgentTests`; inspect every failure.

## Task 2: Native controller and CLI

Modify `App/Sources/SecretsController.swift`, `App/Sources/SecretsApprovalView.swift`, `CLI/main.swift` and signed native diagnostics.

1. Load and pin the complete catalog. Every request verifies its exact named setting and the protected catalog before refresh and immediately before delivery.
2. Refresh all selected accounts with cancellation; validate every field and reprompt policy. Recheck complete value fingerprints after approval and deliver all values in one frame. A failed binding produces no partial launch.
3. Display all requested key/account/variable mappings and update permission explanations to plural where appropriate.
4. CLI reads the exact name, validates the complete response, rechecks the named profile and exec identity, and injects only approved bindings.

## Task 3: User journey

Modify `App/Sources/APIKeyTemplate.swift`, `ToolLaunchSetup.swift`, `ToolLaunchesPane.swift`, `SecretsSettings.swift`, and `Snapshot.swift`.

1. Separate new setup from explicit edit with a reference carrying the saved tool name. Preserve enabled state and optimistic revision conflict checks for the selected tool.
2. Add selected-key rows, native key pickers and exact per-key variables, removal, complete review and clear repair guidance.
3. Render independent saved tools, launch commands, pause/resume/remove actions and correctly associated trust rows. Keep global Revoke All.
4. Preserve extra bindings in the advanced recovery editor; never silently discard additional keys. Keep vault credentials out of Settings.
5. Render light/dark and narrow multi-tool/multi-key/empty/long-name scenarios; inspect visually.

## Task 4: Verification and documentation

Run focused and complete package tests, signed `make build`, strict deep signature verification, and isolated native self-tests where available. Extend the real signed CLI fixture to assert two dummy variables arrive together and missing bindings do not exec, without granting or bypassing device authentication. Record which checks ran and which still need user-assisted acceptance. Update `docs/local-secrets.md` and `SECURITY.md`; do not advertise a proxy or untested provider client.
