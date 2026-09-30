Install Antigravity CLI, configure enterprise requirements, and establish secure authenticated sessions.

Antigravity CLI runs natively on macOS, Linux, and Windows. Use the platform-specific scripts below to install or upgrade the binary on your system.

Execute the native installer script to download and install the executable to `~/.local/bin/agy`:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

The installation script registers the `agy` binary to your local user directory:`C:\Users\<username>\AppData\Local\agy\bin` (where `<username>` represents your active Windows user profile).

**PowerShell**: Open PowerShell and execute the following installation script:

```powershell
irm https://antigravity.google/cli/install.ps1 | iex
```

**CMD**: Open a standard Command Prompt and execute:

```cmd
curl -fsSL https://antigravity.google/cli/install.cmd -o install.cmd && install.cmd && del install.cmd
```

When executing the installation scripts, you can append the following customization flags:

- `--skip-aliases`: Bypasses shell profile alias purging (prevents the script from purging or updating legacy `agy` or `antigravity` shell aliases).
- `--skip-path`: Bypasses shell profile `PATH` appending (prevents the script from modifying your shell profile’s dynamic environment variables).

Antigravity CLI uses secure credentials and token profiles to communicate with the shared agent harness.

When launching `agy` on your local machine, the CLI attempts to access your operating system’s native secure keyring (such as Apple Keychain, Linux Secret Service/dbus, or Windows Credential Manager). If a valid token profile is found, the CLI authenticates your session silently without opening a browser.

If no saved session is found:

1. The CLI automatically launches your local default web browser.
2. Sign in using your approved account credentials.

When running over SSH, the CLI detects the remote connection environment. Because it cannot launch a local web browser, the CLI initiates a manual URL loop:

1. Launch `agy` in your remote terminal session.
2. The CLI detects the SSH environment and prints a unique, secure authorization URL.
3. Copy this URL and paste it into a web browser on your local machine.
4. Sign in with your approved credentials and complete the authentication.
5. The browser displays a unique alphanumeric authorization code.
6. Copy this code, return to your remote SSH terminal, and paste it into the prompt.

Run Antigravity CLI with your own Gemini API key instead of a signed-in Google account. Model requests go directly to the Gemini API, and the CLI never establishes an account session. This suits headless and CI runs, where no browser is available to complete a sign-in. Create a key in [Google AI Studio](https://aistudio.google.com/app/api-keys).

To use a Gemini API key, you have to set a provider and an environment variable with the API key. Only setting a `GEMINI_API_KEY` environment variable on its own has no effect.

1. Set `modelProvider` to `gemini` in `~/.gemini/antigravity-cli/settings.json`:
	```json
	{
	    "modelProvider": "gemini"
	}
	```
2. Export your key as `GEMINI_API_KEY`:
	```bash
	export GEMINI_API_KEY="your-api-key"
	```
	This applies to the current shell only. Add the same line to your shell profile, such as `~/.zshrc` or `~/.bashrc`, to persist it across sessions.
3. Start the CLI:
	```bash
	agy
	```

The CLI skips the sign-in screen and opens the main interface directly. The header shows **Gemini API key** instead of your account email:

![Antigravity CLI authenticated with a Gemini API key, with "Gemini API key" shown in the header in place of an account email](/assets/image/docs/cli/install-gemini-api-key.png)

> **Note:** When you use the authentication with a `GEMINI_API_KEY`, `/logout` has no effect because there is no stored session to clear.

To send model requests to a different Gemini-compatible endpoint, set the `GOOGLE_GEMINI_BASE_URL` environment variable:

```bash
export GOOGLE_GEMINI_BASE_URL="https://your-endpoint.example.com"
```

If you want to revert back to using the default account based authentication:

1. Remove `modelProvider` from `~/.gemini/antigravity-cli/settings.json`.
2. Restart the CLI to sign in to your account.

> **Note:** The CLI cannot start if you unset the `GEMINI_API_KEY` environment variable, but still have the `modelProvider` set to `gemini`.

| Symptom | Cause | Resolution |
| --- | --- | --- |
| The CLI exits at startup reporting that `GEMINI_API_KEY` is not set | `modelProvider` is `gemini` but the key is missing from the environment | Export `GEMINI_API_KEY`, or remove `modelProvider` to use the default authentication |
| The CLI signs in normally and ignores the setting | `modelProvider` holds an unrecognized value | `gemini` is the only accepted value. Check the spelling and restart the CLI |
| A key set through `GOOGLE_API_KEY` or a `.env` file has no effect | The CLI reads the credential only from `GEMINI_API_KEY` in the environment, and does not load `.env` files | Export `GEMINI_API_KEY` in your shell or shell profile |
| Requests fail mid-session with a generic model error | The key is invalid, revoked, or lacks access to the requested model | Verify the key in Google AI Studio. The CLI checks only that the key is non-empty at startup, so an unusable key only surfaces on the first conversation |

Terminating your session clears active credentials and local cache directories.

To disconnect your account and purge saved authentication profiles from your operating system’s keyring, run the following command in the CLI prompt box:

```text
/logout
```

Once you complete installation and authentication, start interacting with your local agent:

- **[Tutorial](/docs/cli/tutorial)**: Create and run a basic Python project with an agent.
- **[Prompting & Interaction](/docs/cli/prompting)**: Explore multiline text editing, interrupt commands, and terminal media pasting.
- **[Permissions & Sandbox](/docs/cli/sandbox)**: Configure secure filesystem directories and command limits.
