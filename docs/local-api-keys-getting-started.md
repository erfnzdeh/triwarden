# Use API keys with a local tool

This feature is for development tools and AI agents.
You can use Triwarden for passwords without enabling it.

## Open the guide

1. Open **Settings > Developer**.
2. Turn on **Show API key tools**.
3. Unlock the account you want to use.
4. Open **Tools** and select **Start Setup Guide…**.

You can reopen the guide from the question-mark button or **Tools options > Setup Guide…**.
The Help topic **API keys and tools** also opens it.
You can close the guide at any time. It remembers the page, not a key value or an approval.

The guide opens the real forms. You can use a provider key or complete the practice below with a dummy key.

## 1. Save a key

Choose the path that matches your current setup:

- **Save a Key…** saves an existing provider key to your vault.
- **Import .env File…** shows a masked preview of one file. Select the values and confirm the destination account.
- **Choose Saved Key…** selects an API key from an unlocked account.

For practice, expand **Try with a dummy key** and select **Save a Practice Key…**.
The form contains a dummy value and the variable name `TRIWARDEN_TEST_KEY`.
Review and save this item. This test needs no provider account and makes no provider API call.

The value and its variable name have different roles.
For example, `OPENAI_API_KEY` is the name an application reads. The hidden API-key field contains the value.
Triwarden supplies the selected value under the variable name in the saved tool setup.
It cannot infer every program's required variable name.

The vault stores an ordinary Secure Note with custom fields. Other Bitwarden clients can read the item.

## 2. Choose the tool

Select **Set Up Tool…**. Choose a recipe and enter a recognizable tool name.
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

Select **Open Terminal Helper Setup…**.
Move Triwarden to its permanent location before installation.
Check the install destination, `/usr/local/bin/tw`, and the helper path.
Copy the install command. Paste it into Terminal and run it.
Return to the guide and select **Check Again**.

The helper must link to this signed app.
Triwarden does not change `.zshrc` or `.bashrc`.
If Terminal finds another `tw`, use `command -v tw` to check its path.

## 4. Approve the first launch

1. Select the saved tool in the guide.
2. Select **Copy Launch**. Paste the command into Terminal and run it.
3. Keep Triwarden open and the selected accounts unlocked.
4. Review the approval card. Check the tool, project folder, command, and keys.
5. Keep **Allow Once** for this first test. Allow the launch and complete macOS authentication.
6. Check the program's output.

The practice script must print **Key available**, without the key value.
Select **I ran the launch and the tool started as expected.** only after this check succeeds.
Copying a command or saving a setup does not confirm a successful launch.
The guide uses your confirmation for navigation. It does not verify the program or grant access.

If no card appears, check helper setup and keep Triwarden open.
If an account locks, unlock it.
If a key is missing, use **Edit Setup…** in Tools to select it again.
If the provider rejects a real key, check the provider account and key.
Remove credentials from logs and screenshots before reporting a problem.

## 5. Use it again

Open Tools, select the saved tool, and copy its launch.
You can also run `tw run` to choose a saved tool, or `tw tools list` to list exact commands.

Once remains the default approval.
For repeated launches, you can select **10 minutes** or **Until lock**.
Temporary access applies to the same saved command and authenticated launcher process.
A new terminal or launcher can require approval again.

Open **Access > Permissions** to review or revoke temporary access.
Lock, expiry, and revoke stop future delivery. They cannot recover keys that a program already received.
The receiving program can read, retain, or transmit keys. Other processes under your user account may inspect them.

Expand **More launch options** for a shell alias or an `.env.triwarden` reference file.
Triwarden does not add aliases to shell files.
Ordinary dotenv loaders cannot resolve Triwarden references. Use the exported file with `tw`.

If you imported a plaintext `.env`, the source still contains its original values.
After the tool works, remove the imported assignments with your editor and test again.
Remove whole assignments. Empty assignments can replace supplied keys in some dotenv loaders.
Keep other settings that the project needs.

## Hide the developer interface

Turn off **Settings > Developer > Show API key tools**.
API Keys, Tools, the setup guide, and related creation actions disappear from the main interface.
The vault retains the items as ordinary Secure Notes.
This preference hides controls. It does not delete tools or stop configured launches.
An open setup can finish normally. The page closes after its forms close, so a visibility change does not discard input.
Use Access to revoke temporary approvals, or pause a tool in Tools before hiding the controls.
Active API-key approvals remain visible in Access so you can revoke them.

Existing tool users keep their navigation after upgrading until they choose to hide it.
New users start with these developer pages hidden.

For format limits and advanced commands, see the [Terminal guide](local-secrets-dx.md).
