# API keys from the user's perspective

The user approved moving from a Settings/Profile-first workflow to **save a key → provide it to a tool/project → review authorization → use it again**. User experience is the first requirement.

Add an API Key preset to the normal vault creation/editing flow. It remains a standard Secure Note with a uniquely named hidden `api-key` field and optional ordinary service/environment metadata, compatible with other Bitwarden/Vaultwarden clients. Show API Keys among vault item filters. The editor should ask for a name, service and key instead of asking users to invent hidden custom fields.

Add a contextual “Provide to Tool…” action and a “Tools & Projects” page. Guided setup starts with an already selected key, offers common Node/Python/npm launch recipes and an explicit custom-program option, and reviews the exact command, directory and credential reference before saving. Technical arguments and environment names remain inspectable; nothing evaluates shell text. The completion state gives the next terminal command and CLI installation guidance. Tool names are user-facing names; internal profile identifiers are generated and remain available for CLI compatibility.

Keep the existing one-setting/one-key security core, mutually authenticated IPC, Keychain revision confirmation, restricted environment and per-launch approval. Clearly label the single-setting limit; replacing an existing setting requires explicit review. Settings becomes a link to the main feature and a place for integration setup. Existing advanced profile editing remains available during transition and recovery.

Validation: package tests for backward-compatible profile titles/serialization, signed app build, synthetic first-use/editor/setup/review/completion previews, isolated diagnostic checks, and focused UI tests where desktop automation permits. No real provider key or account is needed for design validation. Do not report a walkthrough as actual user research.

## Implementation and verification — 22 October 2026

Implemented the vault preset, API Keys navigation, contextual Provide to Tool action, guided setup/review, and Tools & Projects page. The setup generates the CLI identifier and keeps the recognizable tool name separate. Existing names and revisions without a display name retain their encoding. Editing a paused setting preserves its paused state; replacing the single saved setting is called out during review. The legacy reference editor remains available under Advanced Launch Settings.

The shared vault editor still performs encrypted creation/update. Additional fields keep stable identities: typing a reserved name into an extra row cannot hide that row. Duplicate names disable saving with a repair instruction. This fixes a recovery issue identified during a partial independent review; the complete independent review was unavailable when the reviewer hit its service usage limit.

Verification completed on this worktree:

- All 157 VaultCore tests passed: 80 API, 28 crypto, 27 Secrets, and 22 SSH tests. New cases cover Unicode tool titles, changed authorization revisions, and unchanged legacy serialization.
- Signed Debug app build and strict, deep code-signature verification passed.
- All 29 isolated native compatibility checks passed, including encrypted standard Secure Note round-trip, hidden key handling, duplicate-field recovery and archive/trash filtering.
- All 18 isolated native Secrets/Keychain checks passed. These checks use disposable records and do not replace device-owner authentication.
- Three native UI tests passed: vault API-key creation/cancel, saved key to guided tool setup with the provider's variable default/cancel, and the reference-only advanced Settings editor. An initial header assertion was corrected to identify the form by its accessible fields; the shared header combines title and subtitle.
- Twelve synthetic light/dark previews cover creation, key detail, first-use empty state, new setup, command review and the saved-tool page. These render the shared app backdrop. The synthetic saved-tool state accurately asks for account unlock; previews do not create a live account session or bypass validation.

This is implementation verification and a design walkthrough, not user research. The newly guided save path has not yet been exercised against a real vault with a human completing Touch ID/Mac-password authentication. Prior core-flow authentication acceptance remains separate evidence. No real provider key or provider API was used. Multiple saved tools/keys, automatic import and provider proxies remain outside this increment.
