# Environment reference files: design and implementation plan

**Goal:** Start a saved tool from a project file that contains vault references and no key values.

**Architecture:** The reference file selects an existing saved tool. Its bindings must match that tool exactly. The app remains the authority for keys, the launch command, approval, and temporary grants.

**Stack:** Swift, Foundation, SecretsAgent, SwiftUI, and the signed `tw` helper.

## Product decisions

Use `.env.triwarden` as the default name. Ordinary dotenv loaders must not load these reference strings as key values.
The app exports the file through a file picker. It shows the destination before writing.
After saving, it shows a command that the user can copy.
Add the export action to tool options and Launch details. Add no permanent status row to Tools.

Keep the current approval choices and Once as the default.
Do not add arbitrary commands, a proxy, offline delivery, or permanent API-key grants.
Do not change shell startup files. Do not import plaintext `.env` files in this slice.

## File format

```dotenv
# triwarden-env: 1
# tool: tool-example
API_KEY=triwarden://vault/account-id/item-id/hidden/api-key
```

The version and tool headers are required. The tool ID selects a saved local tool.
Each assignment contains a variable name and an exact vault reference.
A password reference ends with `/password`. A hidden-field reference ends with `/hidden/<encoded-field-name>`.
Encode account IDs, item IDs, and field names as URL path components.
Allow comments, blank lines, CRLF, and matching quotes around references.
Reject literal values, duplicate variables, expansion, commands, unsupported versions, and malformed references.
Do not evaluate any shell text. Do not include rejected input in errors.

Require the complete binding set. Do not allow file edits to add bindings to the selected tool or define a command.
The tool header can select another existing tool with matching bindings. Its normal approval checks still apply.
After a key selection or variable change, the user must export the file again.
A value rotation on the same vault item does not require a new file.
The file works with this Mac's saved tool. It does not create a tool on another Mac.

## Security boundary

Read a bounded UTF-8 snapshot from a regular file. Reject final-component symlinks, devices, pipes, and files over 256 KiB.
Check all references against the saved tool before IPC. No binding subset or additional literal variable is accepted.
Then use the existing profile revision, caller checks, signed helper checks, online refresh, approval, and exec path.
The filename and comments add no permission. The file does not contain program arguments.
The existing saved working folder remains in effect. The file's location does not change that folder.

A file edit after parsing cannot change the parsed launch. App-side revision checks still apply.
The target receives raw keys. Lock and revoke cannot recover keys that the target already received.
The file contains vault identifiers. It is metadata, not an encrypted portable vault.

## Implementation steps

1. Add `EnvReferenceFileTests.swift` in `Packages/VaultCore/Tests/SecretsAgentTests/`.
   Test export, parsing, exact binding checks, unsafe syntax, value-free errors, size limits, and bounded file reads.
   Run the tests before implementation. Confirm that the missing API causes failure.
2. Add `EnvReferenceFile.swift` in `Packages/VaultCore/Sources/SecretsAgent/`.
   Add the bounded parser, generator, reference checks, and shell command formatter.
   Add a strict run-source parser beside `RunArguments` in `SecretsProfile.swift`.
   Run the new tests and the complete package tests.
3. Add `run --env-file FILE` in `CLI/main.swift`.
   Parse and check the file before the existing saved-tool launch path. Add no separate delivery path.
   Extend the isolated signed CLI checks in `App/Sources/ToolsBrowserSelfTest.swift`.
4. Add `EnvReferenceExport.swift` in `App/Sources/`.
   Use the app's controls, file picker, and thin scroller. Show variables, purpose, and the copyable launch command.
   Add the entry points in `ToolLaunchesPane.swift`. Add synthetic light and dark previews in `Snapshot.swift`.
5. Build the signed app. Run the package suite, native checks, and strict signature check.
   Inspect the new preview images. Do not describe these checks as real macOS authentication acceptance.
6. Update `docs/local-secrets-dx.md` and preview issue #93 with exact commands and limits.
   Keep unrelated local document edits intact. Commit only this slice. Keep the existing preview branch and open no new PR.

## Verification record

The signed Debug app build passed. Strict signature verification passed.
The package suite passed. It reported 80 API tests, 28 crypto tests, 78 SecretsAgent tests, and 23 SSH tests.
Tests that require online development servers were skipped.
The new tests first failed because the parser API and fixture mode did not exist.
The new tests then passed with the implementation.

All 57 isolated native checks passed. They include the real signed CLI selecting a tool from a reference file.
The CLI rejects literal values, changed references, and paused tools before delivery.
Two-key fixture tests passed through signed IPC and exec. They preserved the expected exit code without printing keys.
A stale-reference fixture failed before execution.

Synthetic light and dark previews cover export, the saved-file command, and Launch details.
The file picker and real macOS authentication still need a human acceptance test.
The fixture server simulates approval. It does not prove Touch ID behavior.
