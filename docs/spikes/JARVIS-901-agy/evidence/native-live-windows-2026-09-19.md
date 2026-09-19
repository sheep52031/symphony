# Authorized native Windows `agy` live evidence — 2026-09-19

## Scope and safety

The owner reported a fresh AntiGravity sign-in and authorized a bounded native functionality
check before any Symphony integration. These runs used the installed Windows executable directly,
not Symphony, a tracker, a product issue, WSL interop, or a permission-bypass flag. Prompts and
workspaces were disposable. No credential, token, settings file, or account identifier was read or
recorded.

Observed executable: `agy.exe 1.1.26` on Windows. `GEMINI_API_KEY` was absent from the invoking
environment, so successful model listing and inference establish usable account/keyring
authentication rather than an environment API-key path.

## Results

The auditable, sanitized commands and native envelopes are committed in
[`native-live-windows-2026-09-19-capture.md`](native-live-windows-2026-09-19-capture.md), SHA-256
`7081aa73a0147d10f100e62f8864beb3c097d7412c19ae9f45b13edd837bfa1c` (the repository-normalized LF bytes).

| Check | Result | Bounded evidence |
| --- | --- | --- |
| Account/model access | **PASS** | `agy models` returned the authorized catalog. `/model` reported `gemini-3.8-flash-medium` with medium effort. |
| One-shot JSON inference | **PASS** | Plan+sandbox run exited `0`; terminal status `SUCCESS`; response exactly `CAPTURE_OK`; one turn; parseable usage; empty stderr. |
| Cwd/no-side-effect smoke | **PASS, containment untested** | Native `init.cwd` matched the disposable Windows directory. The pre-created sentinel remained unchanged and no child file was added. Symlink, `--add-dir`, and attempted workspace escape remain untested. |
| stdin NDJSON multi-turn | **PASS** | One `init`, two terminal `result` events, one stable conversation ID, statuses `SUCCESS/SUCCESS`, responses `CAPTURE_ALPHA/CAPTURE_ALPHA`, and cumulative turn counters `1/2`; process exited `0`; stderr empty. |
| Cross-process resume | **PASS** | `--conversation <sanitized-id>` recovered the same conversation, returned `CAPTURE_ALPHA`, preserved the conversation ID, and reported turn `3`; exit `0`; stderr empty. |
| Interrupt/exit bound | **PASS with normalization unresolved** | The audited Windows `CTRL_BREAK_EVENT` run produced terminal `ERROR: interrupted`, exit `1`, within 4.406 seconds and required no forced kill. An earlier exploratory run returned `ERROR: timeout waiting for response`. Raw envelopes remain diagnostic; a future adapter must track locally initiated cancellation and normalize its lifecycle result under the owner contract before Orchestrator retry/reconciliation. |
| MCP dependency | **PASS: none configured** | `agy mcp list` reported no MCP servers. Native inference, same-process multi-turn, and explicit `--conversation` resume succeeded without a tracker bridge. |
| Runtime placement | **BLOCKED** | `Ubuntu-22.04` still reports no `agy`; the checked Windows environment reports no `elixir` or `mix`. The official CLI supports native Linux installation, but no installation or Linux authentication was performed. |

The one-shot result included usage totals. The two-turn streaming results retained cumulative
`num_turns` and usage values. Raw conversation IDs were used only during disposable checks and are
replaced in the committed capture.

## Permission observation

No run used `--dangerously-skip-permissions`. However, the native `init` envelope reported
`permission_mode: "always-proceed"`. The zero-token `/permissions` command also reported broad
shared/global allows including command, unsandboxed command, file read/write, URL, and MCP classes,
with only destructive command patterns requiring or receiving stricter treatment.

This proves authentication and protocol functionality, but it does not close the authoritative
permission/input rows in the merged owner contract linked from [`sources.md`](sources.md). That
contract—not this spike—requires no permission bypass or auto-answer, an observable blocked/input
outcome, and no inherited raw tracker credential. The current `always-proceed` profile has not
demonstrated those cases, so the permission gate remains open. Absence of the dangerous CLI flag
alone is not least-privilege evidence.

## Host conclusion

The earlier NO-GO did **not** show a provider or login failure; it meant native authenticated
behavior had not yet been run and the checked WSL worker host had no launcher. This live evidence
now establishes **native Windows functionality GO** for version `1.1.26`: account access,
one-shot inference, machine-readable streaming, multi-turn state, explicit resume, cwd reporting,
usage, and bounded interrupt behavior all work.

Symphony integration remains **HOLD**, not abandoned, until one same-host route is accepted and
validated:

1. install the official native Linux `agy` in the supported WSL worker environment and authenticate
   that Linux profile; or
2. separately establish a supported Windows-host Symphony runtime instead of presenting Windows
   interop as Linux support.

No AntiGravity backend mapping or Symphony runtime change is authorized by this evidence alone.
