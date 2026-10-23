# Start a saved tool from Terminal

## Install the helper

1. Open **Tools** in Triwarden.
2. Select **Terminal Helper Setup…**.
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
2. Select **Copy Launch for [tool name]**.
3. Paste the command into Terminal and run it.

The action identifies the tool by its display name.
The copied shell command uses its stable ID, for example:

```sh
tw run --profile tool-123
```

Open **Advanced** to see the exact shell command and the saved executable.
Duplicate display names do not change the selected ID.

## Use a shell alias

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
