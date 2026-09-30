# Sanitized local static capture

- Captured UTC date: `2026-09-19` (commands collected during one bounded static-inspection session)
- Scope: executable discovery plus help/version only. No prompt, model listing, settings/auth read,
  permission bypass, or provider inference request was made.
- Sanitization: local executable paths, usernames, and configuration locations are omitted.

## Host and tool versions

```text
Windows: Microsoft Windows NT 10.0.19045.0 (64-bit)
PowerShell: 5.1.19041.6456
Python: 3.12.10
Git: 2.55.0.windows.3
```

## Commands and results

```text
PS> Get-Command agy -All | Select-Object CommandType,Name
Application  agy.exe
exit=0

PS> cmd /c "agy --version"
1.1.26
exit=0

PS> cmd /c "agy agent --help"
Usage: agy agent [flags]

List available agents

Flags:
  -h      Show help
  --help  Show help
exit=0

PS> cmd /c "agy mcp --help"
Usage: agy mcp <subcommand> [flags] [args]

Available subcommands:
  add      Add or update an MCP server configuration
  remove   Remove an MCP server configuration
  list     List all configured MCP servers
  enable   Enable an MCP server
  disable  Disable an MCP server

Run "agy mcp <subcommand> --help" for flags.
exit=0

PS> wsl.exe -l -v
  NAME              STATE    VERSION
* Ubuntu-22.04      Running  2
  docker-desktop    Stopped  2
exit=0

PS> wsl.exe -d Ubuntu-22.04 -e sh -lc 'command -v agy; agy --version'
sh: 1: agy: not found
exit=127
```

The `*` identifies `Ubuntu-22.04` as the default distribution. It is the only distribution
checked for worker use. `docker-desktop` is not treated as a supported Symphony worker
distribution and was not probed for `agy`.

## Root help capture

```text
PS> cmd /c "agy --help"
Usage of agy:
  --add-dir                       Add a directory to the workspace (repeatable) (default [])
  --agent                         Agent for the current CLI session
  -c                              Short alias for --continue
  --continue                      Continue the most recent conversation
  --conversation                  Resume a previous conversation by ID
  --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting
  --disable-slash-commands        Disable slash command and skill expansion in print mode
  --effort                        Reasoning effort for the current CLI session (low|medium|high)
  -i                              Short alias for --prompt-interactive
  --input-format                  Input format for print mode (text, stream-json). stream-json reads one NDJSON message per line from stdin and runs a turn for each; it requires --output-format stream-json (default text)
  --json-schema                   Optional JSON schema string or path to a schema file to enforce structured output (for stream-json, only applicable to the final result)
  --log-file                      Override CLI log file path
  --mode                          Set the agent execution mode for this session (accept-edits, plan)
  --model                         Model for the current CLI session
  --new-project                   Create a new project for this session
  --output-format                 Output format for print mode (text, json, stream-json) (default text)
  -p                              Short alias for --print
  --print                         Run a single prompt non-interactively and print the response
  --print-timeout                 Timeout for print mode wait (default 5m0s)
  --project                       Project ID or project name for the current CLI session
  --prompt                        Alias for --print
  --prompt-interactive            Run an initial prompt interactively and continue the session
  --sandbox                       Run in a sandbox with terminal restrictions enabled

Available subcommands:
  agent           List available agents
  agents          List available agents
  changelog       Show changelog and release notes
  help            Show help for subcommands
  install         Configure environment paths and shell settings
  mcp             Manage MCP servers (add, remove, list, enable, disable)
  mic-serve       Serve this machine's microphone to a CLI on another host
  models          List available models
  plugin          Manage plugins (install, uninstall, list, enable, disable)
  plugins         Alias for plugin
  remote-control  Manage the remote-control background daemon (start, status, stop)
  update          Update CLI
exit=0
```
