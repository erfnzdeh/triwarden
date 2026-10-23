# Local API credentials

Triwarden can launch a saved development command with one credential from your Bitwarden or Vaultwarden vault. The key stays out of your shell startup file, launch arguments, project configuration and normal clipboard workflow.

This version supports **one saved tool with one credential**. Each launch needs an unlocked account and a successful online vault refresh. The first launch asks for approval and Touch ID or your Mac login password; you can choose one launch, 10 minutes, or until the vault locks. It does not use Bitwarden Secrets Manager.

## Save a key and provide it to a tool

1. In the vault, choose **New API Key** from the **+** or **File** menu. Give it a recognizable name, enter the service and paste the key issued by that provider. Confirm **Default environment variable**, for example `ANTHROPIC_API_KEY`, then save. Service suggestions update until you edit this name yourself; changing the service then keeps your custom name. The preset uses a standard Secure Note with hidden `api-key`, text `service`, and text `environment-variable` custom fields, so other Bitwarden/Vaultwarden clients can still manage it.
2. Open the saved key and choose **Provide to Tool…**. You can find these items under **All Items → API Keys**. No Settings page or manually created custom field is needed.
3. Give the tool a name you'll recognize, such as “Documentation assistant”. Choose an npm development project, Node.js/Python script, or another program, then select the project folder. Common interpreter paths are filled when available; select the executable if it cannot be found.
4. Check **Environment variable for this tool**. It starts with the saved key's default; older keys without this metadata use the service suggestion. Anthropic and OpenAI suggest their usual variable names; other services start with `API_KEY`. Match your tool's configuration. The form shows **selected key → variable → tool**. A tool-specific override leaves the key's vault default unchanged. This field takes a variable name, never the credential value. Invalid syntax and program-control names such as `PATH` or `NODE_OPTIONS` cannot be saved as defaults. Advanced options expose individual arguments without evaluating shell text.
5. Choose **Review**, inspect the complete executable, arguments, folder and key binding, then **Save Tool**. This version has one saved tool; replacing it is explicitly identified in the review. **Back** returns to editing without losing input.
6. **Tools & Projects** shows the saved tool and the command to launch it again. Install the bundled `tw` helper once using **Terminal Helper Setup…** (Settings → Developer → Install tw), then copy the launch command shown there. It contains only the generated shortcut name, not your key:

   ```sh
   tw run --profile tool-EXAMPLE
   ```

   Use the exact command displayed in your app. `profile` is the CLI's internal identifier; the app shows your chosen tool name.
7. Review the account, field, executable, every argument and working directory in the approval card. Select **Once**, **10 minutes**, or **Until lock** in the visible segmented control, confirm the matching button and authenticate with macOS. The default is once. The duration stays above the buttons while command details scroll. If the calling process cannot be verified, only once is available.

For subsequent use, run the saved command from your terminal. Update the key in the vault when it changes; you do not need to copy it into the tool's configuration. **Tools & Projects** lets you view the key, edit the launch setup, pause/resume it, or copy its command again. Paused settings remain paused when edited. A locked account or service error is shown as a condition to fix, not as “ready”.

**Trusted tools** in Tools & Projects lists active temporary approvals automatically after a successful launch with **10 minutes** or **Until lock**. Each row identifies the saved tool, its vault key and the terminal/launcher process, with a live remaining time or “Until Triwarden locks”. **Revoke** removes only that row's approval; **Revoke All** clears every temporary approval and cancels any pending delivery. Expired approvals disappear automatically. Once-only launches and merely saving a setup never add a trusted entry. The empty state explains how to grant temporary access; there is no permanent whitelist or manual trust-by-name setting.

Temporary access belongs to the same **calling process**, exact saved setting, credential and executable/directory identity. The calling process is the kernel-observed immediate parent of the signed bundled `tw`: its PID, start time and running code signature must match. Two processes with the same name cannot share approval, and a new terminal or newly created agent launcher may ask again. It is not a process-name or parent-app-name allowlist. Ten minutes has a fixed deadline that is not extended by reuse. Grants stay only in App memory and are cleared by lock, logout, tool save/pause, denial/cancellation, Revoke All or App exit. A changed credential or target invalidates the old grant on the next refreshed request. Once means exactly one launch; the SSH signing burst does not apply. Revoking or expiring access prevents new deliveries and cannot recall keys already supplied to running programs.

An environment variable name is not a unique key identifier. Different projects may all expect `API_KEY` while using different vault items. Triwarden uses the explicitly saved tool binding to select the item and variable; it does not infer access from a process name or intercept arbitrary programs asking for environment variables. Start a tool with its saved `tw run` command to receive the approved key. Changing a key's default variable later does not rewrite an already saved tool binding; edit that tool setup and review its actual name separately.

The approval window uses the same forms and buttons as the rest of Triwarden. Resize it or scroll to inspect long commands; each argument is shown separately without truncation. Expand **Requesting helper** to inspect its full path. The actions stay at the bottom, and Return does not approve a launch. Escape or **Deny** cancels it.

## Existing or advanced bindings

Existing profiles remain readable and keep their CLI names and protected revisions. **Settings → Secrets → Advanced Launch Settings…** retains the reference-only editor for a login password or another uniquely named hidden field, and for manual command configuration. It never accepts a raw credential value. Ordinary API-key setup starts in the vault and Tools & Projects.

The CLI replaces itself with the saved program. Interactive input, Ctrl-C and the program's exit code behave as they do in an ordinary terminal launch. The Secrets profile has its own enable switch and authorization; the general “Answer the tw command” setting and its cached approvals do not grant `tw run` access.

Use the `tw` inside the same app bundle as the running Triwarden. A symlink to it is supported. Copied, unsigned, modified or mismatched helpers fail signature validation. The transport accepts correctly sealed ad-hoc counterpart signatures; signed official builds additionally require matching Team IDs. Source builds also need valid Data Protection Keychain entitlements to save the profile confirmation. Ad-hoc signing alone does not grant that access.

## What is passed to the program

Only the selected credential and a small set of basic user, terminal, locale and temporary-directory settings are inherited. `PATH` is set to:

```text
/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Other exported API keys, proxy configuration and runtime-control variables are omitted. Bindings such as `PATH`, `DYLD_*`, `NODE_OPTIONS`, `PYTHONPATH` and `BASH_ENV` are rejected. If a tool needs additional configuration variables, this initial version may not fit it yet.

The key is delivered through authenticated local IPC, briefly held by `tw`, then placed in the launched program's environment. It is not written to a temporary `.env` file or printed by `tw run`. The invoking shell does not receive the variable.

**The receiving program can read, save, print or send the key.** Its descendants inherit it, and other processes running as the same macOS user may be able to inspect process environments. This is not a sandbox. Triwarden does not capture or sanitize arbitrary program output.

Locking Triwarden cancels pending approvals and stops new deliveries. Delivery commits when the approved response is written to the local socket; bytes already sent cannot be recalled. A process that already received a key keeps it until it exits or changes its environment. Revoke a key at its provider if you need to invalidate it.

## Approval and troubleshooting

- Commands are saved through guided tool setup or Advanced Launch Settings. `tw run --profile NAME -- arbitrary-command` is intentionally rejected, regardless of whether the caller has a terminal. A TTY does not prove a request came from a human.
- A launch asks again unless the same calling process has a current temporary approval for exactly this key and command. One request can wait at a time. Denying, closing or timing out a request clears temporary access and introduces a short cooldown to reduce repeated prompts.
- Requests expire after 60 seconds, including refresh time. The footer's countdown ring shows the actual seconds remaining and turns orange for the last five seconds. It continues during macOS authentication and uses the same monotonic deadline as authorization. Closing the terminal or disconnecting cancels the request.
- For an API-key preset, repair an empty key or duplicate field in its vault editor before opening **Provide to Tool…** again. The warning points to **Additional fields**, where duplicates remain editable. For a legacy binding, select the exact field again under **Settings → Secrets → Advanced Launch Settings…**. There is no fuzzy fallback to another field.
- Trashed, archived, unsupported and inaccessible items cannot be used. Items requiring an additional master-password re-prompt are unsupported by `tw run` in this release; their protection is not bypassed.
- If the vault cannot refresh online, nothing starts. There is no silent cache fallback in this version.
- If the executable or working directory changes during approval, the CLI refuses to launch. Run the command again after checking the change.
- Updating a key in the vault takes effect on the next successfully refreshed launch. Restart existing programs to give them the new value.
- The App pins the profile revision in its Data Protection Keychain group. Editing the JSON file outside Triwarden invalidates that confirmation; review and save the complete profile in the native UI before launching. A missing/unavailable Keychain pin fails closed.
- Changing a profile cancels an outstanding approval. Other Bitwarden clients can continue to manage the underlying standard vault item.

Executable checks compare canonical path, file identity, permissions, timestamps and content digest immediately before execution. macOS public APIs still require path-based exec, so there is a final replacement race. Interpreters, scripts, dependencies, plugins and project code are not verified by the executable check. Approve only commands and projects you intend to trust.

## Move away from `.zshrc`

Save the key to the vault and verify the new launch workflow first. Then remove its literal assignment/export from `~/.zshrc` and other plaintext configuration. Start a fresh terminal or explicitly clear old exported variables: editing the file does not clear already-running shells.

An alias containing only `tw run --profile agent-dev` is fine. Do not replace a literal key with an automatic `tw get` export in `.zshrc`: that would load it into every interactive shell again.

There is no automatic `.zshrc` importer in this release. If a key previously reached Git, a conversation, or a log, replace it at the provider; moving it into the vault does not invalidate the old value.

## Scope and next steps

The current feature covers local environment injection. Multiple profiles/fields, safe file import, richer repair flows, tested editor integrations, and bounded local activity history are later work. An already-running editor cannot acquire a new environment merely because another process ran `tw`.

A future service-specific proxy can keep original provider keys out of supported tools. It requires endpoint compatibility testing and scoped local session credentials; it is not implemented by this launch feature. SSH private keys continue to use the existing SSH agent.

## Developer validation

Run `swift test --package-path Packages/VaultCore` for the launch policy and synthetic signed-process transport/exec tests. Run `make selftest-secrets` for actual Keychain and native profile checks in a signed Debug build. The diagnostic uses an empty, disposable account namespace and a UUID-scoped Keychain record, checks that the bundled CLI cannot read or overwrite the App's record, and removes its test data before exit. It does not open a real vault or request device-owner authentication.

For native tests against the documented disposable Vaultwarden dev account, first forward the dev server to a loopback port in a separate terminal:

```sh
ssh -N -L 127.0.0.1:28880:127.0.0.1:18880 m1pro
```

Then run `make selftest-secrets-online`. It logs into the seeded `usagi@chiikawarden.test` dev account with the documented dev password, creates one uniquely named dummy credential, and exercises the real bundled CLI and native controller. Denial, CLI disconnection, profile changes and account locking must prevent exec. The test checks server-side item cleanup after online refresh, removes its local records, and restores the login preferences it changed. Each cancellation retains the normal cooldown.

Run `make selftest-secrets-interactive` for the successful launch. Its isolated UI fixture preselects **Trust Until Lock**; normal app launches still default to once. Review the `canary` approval card, confirm its matching button and complete the normal Touch ID/Mac-password step yourself within 60 seconds. You may change the duration. The child checks only the dummy value, writes a disposable success marker and exits with status 37; no provider API is called. After a timed choice the diagnostic checks a repeated launch without another prompt, revokes the grant, then denies a new request and checks that no command starts. Once requires a new prompt instead. Both commands are Debug-only and use a separate account namespace, profile/socket directory and Keychain service. They accept only a loopback dev server; `TRIWARDEN_SECRETS_TEST_PORT` can change its port. Stop the forward when finished. If multiple development copies share the bundle ID, UI automation can select another copy: do not operate that copy or count its main window as the diagnostic card.

Run `make selftest-secrets-presentation` on an unlocked GUI desktop to check that the card remains onscreen without taking the foreground app or opening ordinary windows. It uses the same isolated dev-account flow, attempts a focus handoff to Finder, records the actual foreground app (activation is cooperative), checks active-Space/occlusion and the nonactivating/fullscreen-auxiliary window configuration, then denies and cleans up. This does not exercise actual fullscreen or every Spaces arrangement. The card stays visible while another app is in front; denial, timeout, disconnect and account locking still close it. A screenshot of the window by itself does not prove it is actually visible on the desktop.

For a manual guided-setup HTTP exercise, `scripts/local-secrets-journey.py` is a stdlib Python client and loopback-only fake-key API for the existing usagi **Anthropic API Key — Demo (fake)** example. Its launcher refuses a different item ID, variable or script. It never uses a provider API. Start the fixture from the checkout:

```sh
/usr/bin/python3 scripts/local-secrets-journey.py server
```

In the key's **Provide to Tool** form, select **Python script**, this script's absolute path, the checkout as project folder and `ANTHROPIC_API_KEY`. Review and save; do not replace another saved tool without reviewing that replacement. From another terminal, run:

```sh
/usr/bin/python3 scripts/local-secrets-journey.py launch --expect allow --repeat 2
```

Choose a temporary scope and authenticate on the first request. The second CLI has the same signed Python launcher, so it can reuse that scope. Separate invocations of the launcher create different calling processes and should ask again. `--expect deny` requires the actual denial error and zero child/API activity; `--expect blocked` checks zero activity for paused/locked cases. JSONL receipts under `build/local-secrets-journey/` contain counts, booleans and timings, never credentials. The child verifies the cwd, confirms unrelated-key/runtime-control sentinels are absent and authenticates an actual HTTP request using its delivered variable. The CLI is invoked from this checkout's signed bundle, without changing global helper installation. Stop the fixture server when finished. This tests a development client, not a provider SDK, a third-party AI CLI, or a paid API call.

If no card appears, check that the Mac running Triwarden is unlocked and that a local or remote desktop session is available. Diagnostic runs report a Keychain status code if profile confirmation cannot be written; `-25308` means interaction was not allowed. No profile confirmation or credential delivery is bypassed when Keychain is unavailable.

The signed Debug binary's `--selftest-secrets-preview` mode renders synthetic light, dark, compact, long-command, authentication-in-progress and last-five-seconds layouts. It opens no vault, Keychain or socket and never authenticates. Use `TRIWARDEN_SNAPSHOT_STDOUT=1` with the existing snapshot stream to export these images without accessing the App container directly.

`--selftest-api-key-preview` renders the vault preset, key detail, first-use tool page, setup, review and saved-tool page in light and dark appearances. It constructs an isolated synthetic model, disables live profile configuration and does not log in or deliver a credential. The focused native UI tests in `CISmokeTests` cover the vault entry, key-to-tool entry and advanced reference editor using `--demo`.

Before release, verify the complete native flow with a disposable vault item:

1. In a test account, create a Secure Note with a hidden field named `api-key` and the dummy value `triwarden-test-only`.
2. Save an enabled profile named `canary`, binding that field to `TRIWARDEN_TEST_KEY`. Select `/bin/sh` with working directory `/tmp` and two separate arguments: `-c`, then the following literal command:

   ```sh
   test "${TRIWARDEN_TEST_KEY:-}" = triwarden-test-only && printf '%s\n' 'credential received'
   ```

   This explicitly selected shell is only a test target. The command checks the dummy value without printing it or making an API request.
3. Run `tw run --profile canary`, review the saved launch, allow it and complete Touch ID/Mac-password authentication. Expect `credential received` and exit status zero.
4. Repeat and deny the request. After each cooldown, also check locking the account and closing the invoking terminal while approval is pending. None should launch the target or leave an approval available to a later request.
5. Disconnect the network and confirm refresh failure prevents launch. Restore connectivity, rename the field in the vault, refresh, and confirm launch fails until the exact field is selected and saved again.
6. Disable the profile and save, then delete the disposable vault item when finished. Automated checks do not replace this real-account and authentication pass.

See the [design](plans/2026-10-19-local-secrets-agent-design.md) and [implementation plan](plans/2026-10-19-local-secrets-agent-implementation.md).
