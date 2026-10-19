# Local API credentials

Triwarden can launch a saved development command with one credential from your Bitwarden or Vaultwarden vault. The key stays out of your shell startup file, launch arguments, project configuration and normal clipboard workflow.

This initial version supports **one local profile and one password or hidden custom field**. Each launch needs an unlocked account, a successful online vault refresh, an explicit approval, and Touch ID or your Mac login password. It does not use Bitwarden Secrets Manager.

## Set up

1. Save your API key in the vault using the normal item editor. A Secure Note with a hidden custom field such as `api-key` works; an existing login password also works.
2. Open **Settings → Secrets**. Select the account, item and exact field. Unlock the account in the main window if necessary.
3. Choose a profile name such as `agent-dev` and the variable expected by the tool, for example `ANTHROPIC_API_KEY`.
4. Select the executable and working directory using absolute paths. Add one row per argument. For example, select your `npm` executable and add `run` and `dev` as two arguments. Do not add shell quoting around argument values.
5. Enable the profile and click **Save Profile**.
6. Install the bundled `tw` command using **Settings → Developer → Install tw**, then run:

   ```sh
   tw run --profile agent-dev
   ```

7. Review the account, field, executable, every argument and working directory in the approval card. Choose **Allow This Launch…** and authenticate with macOS.

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

- Commands are saved in the native settings page. `tw run --profile NAME -- arbitrary-command` is intentionally rejected, regardless of whether the caller has a terminal. A TTY does not prove a request came from a human.
- Every launch asks again. One request can wait at a time. Denying, closing or timing out a request introduces a short cooldown to reduce repeated prompts.
- Requests expire after 60 seconds, including refresh time. Closing the terminal or disconnecting cancels the request.
- A missing, renamed, duplicated or no-longer-hidden custom field must be selected again in **Settings → Secrets**. There is no fuzzy fallback to another field.
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

See the [design](plans/2026-10-19-local-secrets-agent-design.md) and [implementation plan](plans/2026-10-19-local-secrets-agent-implementation.md).
