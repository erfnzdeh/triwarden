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

## Planned environment file support

A reference-only `.env` mode is planned for a separate design.
It is not available in this version.
Triwarden currently supplies variables from the saved tool settings.
It does not produce an environment file with actual key values.
