# Start a saved tool from Terminal

## Set up a tool

1. Select an API key in your vault.
2. Select **Provide to Tool…**.
3. Choose a tool recipe.
4. Confirm the program path and project folder.
5. Confirm the variable name that the tool expects.
6. Review the selected keys and command.
7. Save the tool.

Recipes include Claude Code, npm projects, Node.js scripts, Python scripts, and other programs.
Triwarden looks for installed programs in fixed locations.
It does not run a detected program or evaluate shell startup files during discovery.
Use **Choose…** if it cannot find your program.
Script recipes require you to select the script.
Your custom tool name and variable name remain when you switch recipes.
The app replaces values that still match the previous recipe's suggestion.
Existing saved tools keep their exact paths, arguments, and bindings.

The Claude Code recipe suggests `ANTHROPIC_API_KEY`.
An API key can override Claude Code subscription authentication and incur API charges.
Confirm the account before use.
See [Anthropic's authentication explanation](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code).
The recipe does not verify provider credentials or establish compatibility with every client version.

## Install the helper

1. Open **Tools** in Triwarden.
2. Open the **Tools options** menu (…). Select **Terminal Helper Setup…**.
3. Check the install location and the helper path.
4. Select **Copy Install Command**.
5. Paste the command into Terminal and run it.

The install location is `/usr/local/bin/tw`.
The command creates a link to the helper in the current app.
It replaces an existing link at that location.
It refuses to replace a regular file or folder.
Move the app to its permanent location before you install the helper.

You can also open helper setup while you configure a tool or from **Settings > Developer**.
The setup window checks the app signature and the link destination.
It gives a repair instruction if the helper is missing, unsigned, or from another app.
These setup checks do not replace the signature checks for each launch.

If Terminal uses another `tw`, run `command -v tw` to find it.
Check your `PATH` order.
Triwarden does not change your shell startup files.

## Copy a launch

1. Select the saved tool in **Tools**.
2. Check the tool name, then select **Copy Launch**.
3. Paste the command into Terminal and run it.

The selected tool name identifies the launch. The copy confirmation shows that name.
The copied shell command uses its stable ID, for example:

```sh
tw run --profile tool-123
```

Open **Launch details** to see the exact shell command and the saved executable.
Duplicate display names do not change the selected ID.

## Choose a tool in Terminal

Run:

```sh
tw run
```

Select a number from the menu.
The menu shows tool names and full project folders.
It adds the stable ID when the name and folder are identical.
Blank input, `q`, or end of input cancels without a launch.
Paused tools cannot start from the menu.
Selection does not grant access. The normal launch and approval checks still apply.

Selection requires a terminal on standard input and standard error.
Scripts must use the exact command from `tw tools list`, such as `tw run --profile tool-123`.
Command overrides remain disabled.

## Repair a setup

Tools shows a setup action if the terminal helper needs attention.
A working helper adds no status row.
The check runs again when you return to Triwarden or close helper setup.
It does not prove that a key, provider account, or project script works.

- Select **Resume Tool** for a paused tool.
- Select **Unlock Account** for a locked account.
- Select **Add Account…** if the required account is absent from this Mac.
- Select **Select Key…** to replace a broken primary binding.
- Select **Edit Key Setup…** to repair an additional binding.

The main action repairs a missing key or account before it offers a launch command.
The review step shows the replacement key and the retained variable name before you save.

## Use a shell alias

Open the tool options menu (…) or **Launch details**.
Select **Copy Shell Alias** to copy a suggested alias:

```sh
alias tw-my-assistant='tw run --profile tool-123'
```

Paste this definition into your terminal.
Then start the tool with `tw-my-assistant`.
Change the alias name if another tool uses it.
The `tw-` prefix reduces conflicts with common commands.
Names without ASCII letters or digits use the tool ID as the suggested alias name.

The alias applies to the current shell session.
To keep it, add the definition to your shell startup file yourself.
Triwarden does not write the definition to that file.
The definition contains a tool ID, not a key value.
A tool name change does not change an existing alias.

## List saved tools

Run:

```sh
tw tools list
```

`tw tools` gives the same list.
Each entry shows its display name and exact launch command.
Paused tools have a `(paused)` label.
The list reads local reference metadata only.
It does not open a vault, connect to the app, request approval, or print key values.
It does not print binding fields, account details, saved arguments, or executable paths.
The list does not verify permission to launch a tool.
The normal launch checks still apply.

`tw list` remains the separate command for vault items.
It still requires vault access approval.

## Approval limits

Once remains the initial approval choice.
The user can select 10 minutes or Until lock.
This change adds no permanent API-key permission or API-key history.
Lock and revoke stop future delivery. They cannot recover keys that a program already received.

## Use an environment reference file

1. Select a saved tool in **Tools**.
2. Open its options menu (…) or **Launch details**.
3. Select **Save .env References…**.
4. Select **Save File…**. Check the destination in the file picker.
5. Keep the `.env.triwarden` suffix. Save the file in your project.
6. Select **Copy Launch**. Paste the command into Terminal.

The command has this form:

```sh
tw run --env-file '/path/to/project/.env.triwarden'
```

You can use a relative path from your terminal:

```sh
tw run --env-file .env.triwarden
```

The exported file contains vault references and no key values:

```dotenv
# triwarden-env: 1
# tool: tool-example
API_KEY=triwarden://vault/account-id/item-id/hidden/api-key
SECOND_KEY=triwarden://vault/account-id/other-item-id/password
```

The app creates these references. You do not need to type vault IDs.
Account IDs, item IDs, and field names use URL encoding where required.
The file contains vault identifiers. Review this metadata before you share the file.

The file selects an existing tool on this Mac. It does not create a tool on another Mac.
The tool header selects a saved tool. Changing that header can select another tool with matching bindings.
That selection still uses the selected tool's normal approval checks.
The file cannot define an executable, arguments, or a project folder.
The file location does not change the working folder.
Only one selector is accepted. Do not combine `--env-file` with `--profile` or a command override.

All references must match the saved tool's selected keys and variable names.
Triwarden rejects extra keys, missing keys, and changed references before it requests approval.
After you change key selections or variable names, save a new file from Tools.
A value rotation on the same vault item does not require a new file.

The normal launch checks still apply. Once remains the initial approval choice.
Temporary grants have the same scope as launches through `--profile`.
No new permission comes from the reference file or its location.
The target program receives the raw key values through its environment.

### Format and limits

- Use UTF-8. Keep the file at 256 KiB or less.
- Include one `# triwarden-env: 1` header and one `# tool: ID` header.
- Include all 1 to 16 bindings from the selected tool. Each variable name must be unique.
- Blank lines, separate comment lines, CRLF, and matching quotes around a reference are accepted.
- Literal values, shell expansion, shell commands, and comments after an assignment are rejected.
- The file must be a regular file. Links, pipes, and devices are rejected.
- Error messages identify the line or repair action. They do not print rejected values.

Use this file with `tw`. Ordinary dotenv loaders cannot resolve Triwarden references.
Do not rename it to `.env` or load it with `source`.
This feature does not import, scan, or change existing plaintext `.env` files.
It creates no plaintext key file, temporary key file, virtual mount, or shell startup entry.

### Check the file workflow with a dummy key

Use the Python dummy-key test in issue #93. Export its saved tool through **Save .env References…**.
Run the copied `tw run --env-file` command. Complete the normal approval in Triwarden.
The test script must confirm the dummy value without printing it.

Try these failure cases:

1. Replace one reference value with a dummy literal. Confirm that the launch fails without printing that literal.
2. Restore the exported file. Change one item ID. Confirm that the launch fails before an approval card appears.
3. Save a new file. Pause the tool. Confirm that the launch fails.
4. Resume the tool. Deny the launch in Triwarden. Confirm that the script does not start.

The automated tests use dummy values and isolated storage.
Signed IPC and exec tests use a test server. They do not verify real macOS authentication.
The file picker and a real Touch ID or Mac password launch still need a human acceptance test.
