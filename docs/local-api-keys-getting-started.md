# Use API keys with a local tool

This feature is for development tools and AI agents.
You can use Triwarden for passwords without enabling it.

## Open the guide

1. Open **Settings > Developer**.
2. Turn on **Show Secrets**.
3. Unlock the account you want to use.
4. Open **Secrets** and select **Walk me through it**.

The empty Secrets page also offers **Import from an .env file** and **Use a key already in the vault** if you prefer to start without the guide.
You can reopen the guide from the question-mark button, **Secrets options > Setup Guide…**, or **Start Setup Guide…** in **Settings > Developer**.
The Help topic **Secrets** also opens it.
You can close the guide at any time. It remembers the page, not a key value or an approval.

The guide opens the real forms. You can use a provider key or complete the practice below with a dummy key.

## 1. Save a key

Choose the path that matches your current setup:

- **My project has an .env file** shows a masked preview of one file. Select the keys and confirm the destination account. The file is only read.
- **I have an API key** saves an existing provider key to your vault.
- **My key is already in the vault** selects an API key from an unlocked account.

For practice, expand **Try it with a practice key** and select **Save a Practice Key…**.
The form contains a dummy value and the variable name `TRIWARDEN_TEST_KEY`.
Review and save this item. This test needs no provider account and makes no provider API call.

The value and its variable name have different roles.
For example, `OPENAI_API_KEY` is the name an application reads. The hidden API-key field contains the value.
Triwarden supplies the selected value under the variable name in the saved tool setup.
It cannot infer every program's required variable name.

The vault stores an ordinary Secure Note with custom fields. Other Bitwarden clients can read the item.

## 2. Choose the tool

Select **Set Up Tool…**. Choose a recipe and enter a recognizable tool name.
Recipes cover Claude Code, Codex CLI, Gemini CLI, Cursor CLI, Aider, OpenCode, npm, pnpm and Bun projects, Node.js and Python scripts, Python scripts with uv, and any other program.
Confirm the installed program, project folder, and every variable name.
Review the exact command and selected keys before you save.
You can select an existing saved tool instead.

For practice, expand **Practice with Python** and copy the script.
Save it as `check_key.py` in a test folder:

```python
import os
assert os.environ.get("TRIWARDEN_TEST_KEY") == "triwarden-preview-only"
print("Key available")
```

Choose **Python script** in the setup form. Select this file and its folder.
Keep `TRIWARDEN_TEST_KEY` as the variable name. Review and save.
The script checks the value without printing it.

For a real tool, use the variable name that its provider requires.
The Claude Code recipe uses an Anthropic API key. API use can charge that account instead of a subscription.
Confirm the intended provider account before you start it.

## 3. Connect Terminal

Select **Install Terminal Helper…**.
Move Triwarden to Applications before installation.
Select **Copy & Open Terminal**. Triwarden copies the install command and opens Terminal.
Paste the command with Command-V, press Return, and enter your Mac password.
macOS needs your password to add `tw` to `/usr/local/bin`, so this step runs in Terminal.
The setup window detects the new link and shows **tw is installed**.
If the guide still shows the old state, select **Check Again**.

The helper must link to this signed app.
Triwarden does not change `.zshrc` or `.bashrc`.
If Terminal finds another `tw`, use `command -v tw` to check its path.

## 4. Approve the first launch

1. Select the saved tool in the guide.
2. Copy the command under **Run this in Terminal**. Paste it into Terminal and run it.
3. Keep Triwarden open and the selected accounts unlocked.
4. Review the approval request. Check the tool, project folder, and keys.
5. Keep **Once** for this first test. Select **Allow Once** and confirm with Touch ID or your Mac password.
6. Check the program's output.

On a Mac with a notch, a tool with one key asks at the top of the screen by default.
Select **Details…** there to see the full approval window with the command and folder.
A tool with several keys always asks in the window.

The practice script must print **Key available**, without the key value.
Select **The tool started as expected** only after this check succeeds.
Copying a command or saving a setup does not confirm a successful launch.
The guide uses your confirmation for navigation. It does not verify the program or grant access.
Each launch refreshes the required vault accounts online. If sync fails, restore the connection before you try again.

If no card appears, check helper setup and keep Triwarden open.
If an account locks, unlock it.
If a key is missing, use **Edit Setup…** in Secrets to select it again.
If the provider rejects a real key, check the provider account and key.
Remove credentials from logs and screenshots before reporting a problem.

## 5. Use it again

Open Secrets, select the saved tool, and copy its launch command.
A ready tool also shows a short alias, such as `tw-documentation-assistant`.
Select **Copy Alias**, add the copied line to `~/.zshrc`, and open a new terminal. Then type the alias name.
You can also run `tw run` to choose a saved tool, or `tw tools list` to list exact commands.

Once remains the default approval.
For repeated launches, you can select **10 minutes** or **Until lock**.
Temporary access applies to the same saved command and authenticated launcher process.
A new terminal or launcher can require approval again.

While a tool has temporary access, a small status at the top of the screen shows the time left.
Point at it or click it to **End** an approval or **Open Access**.
Open **Access > Permissions** to review or end temporary access.
Lock, expiry, and revoke stop future delivery. They cannot recover keys that a program already received.
The receiving program can read, retain, or transmit keys. Other processes under your user account may inspect them.

For an `.env.triwarden` reference file, select **Save .env References…** in the guide or in the tool's menu in Secrets.
Triwarden does not add aliases to shell files.
Ordinary dotenv loaders cannot resolve Triwarden references. Use the exported file with `tw`.

If you imported a plaintext `.env`, the source still contains its original values.
After the tool works, delete each imported line with your editor and test again.
Delete the whole line, not just the value. An empty `KEY=` can override the key that Triwarden supplies.
Keep other settings that the project needs.

## Hide the developer interface

Turn off **Settings > Developer > Show Secrets**.
API Keys, Secrets, the setup guide, and related creation actions disappear from the main interface.
The vault retains the items as ordinary Secure Notes.
This preference hides controls. It does not delete tools or stop configured launches.
An open setup can finish normally. The page closes after its forms close, so a visibility change does not discard input.
Use Access to end temporary approvals, or pause a tool in Secrets before hiding the controls.
Active API-key approvals remain visible in Access so you can end them.

Existing tool users keep their navigation after upgrading until they choose to hide it.
New users start with these developer pages hidden.

For format limits and advanced commands, see the [Terminal guide](local-secrets-dx.md).
