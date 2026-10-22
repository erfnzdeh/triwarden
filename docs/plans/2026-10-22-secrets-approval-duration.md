# API-key approval duration

The user requested SSH-style approval choices and selected **Allow Once / Allow for 10 Minutes / Trust Until Lock**. The default remains once. The native panel keeps its existing countdown, explicit action and normal macOS authentication.

Repeated development restarts should reuse an explicit temporary approval. A grant authorizes a saved launch, not an arbitrary command or every process with the same name. It remains in memory and is bound to the verified bundled helper, the kernel-observed immediate calling process (PID, start time and valid running code signature), the entire saved profile revision, actual executable/directory identity, and a keyed fingerprint of the current vault credential. Parent names and client-supplied caller claims confer no authority. An uninspectable caller falls back to once. This deliberately does not carry across different terminal processes or newly created agent launchers.

Each request still authenticates its helper with its audit token, refreshes the vault online and validates its nonce, current configuration, caller and target before delivery. Ten minutes uses a fixed monotonic deadline; repeated use never extends it. Until-lock access ends on account lock, logout, configuration save/pause, explicit revocation or App exit. Changed key/target/caller must ask again. Failed authentication or delivery creates no grant; denial/cancellation clears existing grants. A grant never retains the credential value.

The panel shows the calling process and explains the chosen scope. Tools & Projects shows temporary authorization and a Revoke Access action. Once means exactly one launch, without SSH's 15-second signing burst. Neither timed choice recalls a key already delivered to a program or verifies project scripts/dependencies. Permanent Always Allow is outside this increment.

## Implementation plan

**Goal:** reduce repeated development approval prompts while keeping grants narrow and revocable.

**Architecture:** pure SecretsAgent grant state plus native caller verification; SecretsController owns in-memory authorization and normal macOS authentication. SwiftUI presents the choices and revocation. No server schema, raw key file, permanent trust or CLI command override is added.

**Tech stack:** Swift, Swift Testing, Darwin process information, Security code verification, CryptoKit, SwiftUI/AppKit.

1. Add failing grant tests for once, ten-minute exact expiry/non-sliding reuse, until-lock reset, caller/profile/credential/target mismatch and bounded storage. Add live caller-verification coverage using signed fixture processes. Run focused SecretsAgent tests before implementation.
2. Implement caller snapshot from the already authenticated CLI audit token. Read child/parent kernel identity around Security inspection; recheck the child token and parent identity before use. Fail closed to once when a stable signed caller cannot be established. Implement the pure bounded grant store.
3. Integrate scoped grants after online refresh. Verify actual launch identity independently, fingerprint the credential with an ephemeral HMAC key, check caller again at delivery, and store a grant only after successful native authentication and committed response. Split prompt cleanup from authorization reset so ordinary successful completion does not revoke its grant.
4. Add native authorization picker/caller description, updated scope copy, temporary-access status and Revoke Access. Extend synthetic previews for timed/until-lock choices; update existing descriptions that incorrectly promise per-launch prompts.
5. Run focused/full package checks, signed build/strict signature verification, native diagnostics and visual checks. Exercise the guided fake-key Python HTTP flow with a persistent launcher: first launch authenticates, second identical launch reuses the selected scope; denial/revocation/lock stop future deliveries. Record exact results and remaining provider/client coverage in docs.

## Existing journey evidence (before duration changes)

On 22 October the normal signed app saved the existing usagi fake API-key example through Provide to Tool using the Python recipe, script `scripts/local-secrets-journey.py`, project root as cwd, and `ANTHROPIC_API_KEY`. Python successfully authenticated HTTP requests to a loopback-only fixture API, including after quitting/reopening the app. The user confirmed approving and authenticating the first two launches. The post-restart launch independently exited 0 and recorded one start, request and successful response, with unrelated key/runtime-control sentinels absent and the launcher's supplied environment unchanged.

Pausing the saved tool and locking the dev account each prevented Python exec and HTTP requests. Several runs labeled deny were actually allowed; their expectation checks failed and are retained as such, not reported as successful denial tests. A later attempt had no running app, and after the tool session reset a launched client found the fixture server stopped; neither proves denial. The ordinary-client Deny path still needs a controlled rerun. No real provider key, paid request, Bitwarden cloud, provider SDK or third-party AI CLI was tested. The global terminal-helper installation was not changed; the matching bundled CLI was used.
