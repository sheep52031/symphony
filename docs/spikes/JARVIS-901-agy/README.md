# JARVIS-901 — native `agy` headless feasibility spike

**Decision: native Windows functionality GO; Symphony integration HOLD on same-host placement and
permission hardening.** This removable spike changes no AgentBackend mapping, runner, orchestrator,
tracker, or production configuration.

## Scope and evidence classes

This spike read the owner-fork parity contract, official Symphony, and the official AntiGravity
headless reference. Immutable repository URLs are in [`evidence/sources.md`](evidence/sources.md).
The initial candidate captured static discovery/help and deterministic fake-process behavior only.
After the owner refreshed the AntiGravity login and authorized a bounded live check, the exact
Windows build was exercised directly in disposable no-tool workspaces; the sanitized results are in
[`native-live-windows-2026-09-19.md`](evidence/native-live-windows-2026-09-19.md).

| Class | What it establishes | What it does not establish |
| --- | --- | --- |
| Local static observation | A native Windows `agy.exe` is discoverable on `PATH`; `agy --version` printed **`1.1.26`**. Explicit discovery in the default `Ubuntu-22.04` WSL worker distribution reported `agy: not found`. | Other WSL distributions or a usable same-host WSL launcher. |
| Authorized native Windows observation | Account/keyring auth can list models and complete JSON inference; native stream JSON, two-turn stdin state, explicit conversation resume, cwd, usage, stderr separation, and bounded CTRL-BREAK exit were observed. | Linux auth/launch, least-privilege permissions, `--continue`, forced process-tree cleanup, or every native failure shape. |
| Official reference | The documented JSON/NDJSON envelopes, `init`/`step_update`/`result` event names, `conversation_id`, cumulative usage fields, terminal statuses, stdin multi-turn rules, stderr split, soft permission denial, and nonzero error behavior. | A guarantee beyond the exact observed build/profile. |
| Deterministic fixture evidence | This artifact's bounded parser/lifecycle policy handles partial bytes, LF framing with CRLF tolerance, malformed stdout, separate stderr, nonzero exit, a scripted two-result transcript, `WAITING`, no-progress chatter, first-token/turn deadlines, post-result exit grace, interrupt race, process loss, cwd containment, and host mismatch. | Native behavior not listed in the authorized observation. The child is explicitly fake and never invokes `agy` or a provider. |

No host-absolute path, exact shared/global permission rule, token, credential, account identifier,
auth material, or settings-file content is committed.

## Native protocol characterization

### Local discovery and host boundary

The discovered native executable is Windows-hosted `agy.exe`, version `1.1.26`; authorized live
inference now proves it is usable under the refreshed Windows account profile. The supported
Symphony path still requires BEAM, shell, workspace, and harness to share one host. The checked
default `Ubuntu-22.04` worker distribution lacks `agy`, and no Windows Elixir/Mix runtime was found.
A Windows executable must therefore **not** be presented as a WSL-native worker executable. The
probe's `require_same_host` test makes that integration failure explicit before launch.

A future adapter must resolve an executable in the selected local worker environment, fail
with a classified launch error when absent, and call it with the existing workspace as its
cwd. `require_contained_workspace` and the `cwd` fake process prove the intended pre-launch
containment check and observable child cwd; they do not prove native `agy` containment.
Remote/SSH workers have no evidence and remain unsupported.

### Documented headless contract (static only)

- `-p` is one-shot headless mode. `--output-format json` returns a terminal envelope; `--output-format stream-json` is NDJSON. The reference says response data belongs on stdout and diagnostics, auth, progress, and permission notices on stderr.
- Streaming output begins with `init`, has zero or more `step_update`s, then exactly one `result`. Documented result fields are `conversation_id`, `status`, `response`, `error` on failure, `duration_seconds`, `num_turns`, and usage totals (`input_tokens`, `output_tokens`, `thinking_tokens`, `cache_read_tokens`, `total_tokens`). Agent response deltas occur in `step_update.text_delta`; the reference describes usage/turns as cumulative in a stdin session.
- `--input-format stream-json --output-format stream-json` accepts one NDJSON `user` message per stdin line, holds one process/conversation for multiple turns, and yields one `result` per turn. Closing stdin ends a clean session after its active turn. `--continue` and `--conversation <id>` are documented cross-process resume mechanisms.
- Documented terminal statuses are `SUCCESS`, `ERROR`, `CANCELED`, `INTERRUPTED`, `INVALID`, `WAITING`, and `RUNNING`. The default `--print-timeout` is five minutes; it is a print-mode ceiling, not evidence of a first-token or per-turn silence policy.
- The documented default permission mode is request-review. In headless mode, unavailable approvals are described as soft-denied with a stderr notice; the reference does not supply a separately verified machine-readable permission-request event. `--dangerously-skip-permissions` was neither used nor considered acceptable.

The documented CLI exposes `agy mcp ...`, but that is configuration capability only. It
neither proves that a tracker MCP/loopback bridge is needed nor authorizes one.

## Deterministic probe

`probe.py` is deliberately generic: it is a test-only byte reader, not an adapter or a claim
about native implementation. On Windows it starts the fake root suspended, assigns it to a
kill-on-close Job Object, then resumes it; on POSIX it starts a new session/process group. Thus a
root that exits after leaving inherited pipes cannot evade tree termination. Reader teardown has
bounded joins and never synchronously closes a pipe while its reader remains active. The minimum
lifecycle policy is inspectable:

1. The reader uses a bounded chunk queue; backpressure, rather than an unbounded queue, limits pending bytes.
2. Only LF terminates a stdout/stderr frame; a preceding CR is removed. Frames over the configured cap are discarded through their next LF, counted, and parsing resumes at the following frame.
3. Retained events, malformed stdout, and stderr lines are capped independently. Oldest retained evidence is dropped; dropped and truncated counts are recorded in `RunResult`.
4. A first-token deadline waits for nonempty `step_update.text_delta`; a turn deadline waits for a terminal `result`. Both are absolute from launch, so raw chatter cannot keep a worker alive.
5. A terminal result starts a bounded post-result exit grace. A process or inherited-pipe descendant that keeps the fixture open is stopped/reaped and classified `post-result-exit`; a cancellation path remains separately classified as `cancel-exit` only if it fails to exit after its terminal result.
6. Stderr remains diagnostics. A terminal error or `WAITING` result is retained even when the process exits nonzero or emits a permission notice. Exit without a terminal envelope is distinct process loss.

The fake-process scenarios exercise partial lines/CRLF/malformed JSON, stderr chatter,
nonzero error, a **scripted two-result transcript parser check** (not stdin interaction or
resume), permission/input waiting, chatter and stall deadlines, post-result hang, cancellation
race, process loss, high-volume bounded evidence, oversized-frame resynchronization, workspace
cwd, and cross-host rejection.

Run only the deterministic suite:

```bash
python -m unittest discover -s docs/spikes/JARVIS-901-agy/tests -p '*_test.py' -v
```

## Native live findings and remaining integration criteria

1. **Observed:** `1.1.26` JSON and NDJSON framing, event order, terminal success, usage, empty stderr on success, and nonzero terminal error on interrupt. **Remaining:** native malformed/unknown input, partial-byte delivery, and broader failure combinations.
2. **Observed:** one-process two-turn state, stable `conversation_id`, cumulative turns/usage, clean stdin close, and cross-process `--conversation` resume. **Remaining:** `--continue` and resume failure modes.
3. **Observed risk:** no dangerous bypass flag was used, but native `init` reported `permission_mode: always-proceed`, and `/permissions` showed broad command/unsandboxed/file/MCP allows. This observation does not close the merged owner contract's permission/input rows: no bypass or auto-answer, observable blocked/input outcomes, and no inherited raw tracker credential. This spike does not define a second permission policy.
4. **Observed:** account/keyring authentication, model catalog access, default `gemini-3.8-flash-medium` medium effort, and exact disposable Windows cwd. **Remaining:** native Linux auth, symlink and `--add-dir` containment, and default-agent behavior.
5. **Observed:** startup/turn completion and two CTRL-BREAK observations produced terminal error envelopes and bounded exits without forced kill. The audited capture returned `ERROR: interrupted`; an earlier exploratory run returned `ERROR: timeout waiting for response`. Raw status remains diagnostic; normalized cancellation must use adapter-owned local cancellation state. **Remaining:** forced terminate/kill tree cleanup, process loss, and an adapter-owned absolute first-token/turn policy.
6. **Blocked placement:** the checked `Ubuntu-22.04` worker still has no native `agy`. Use the official Linux installer and authenticate that host, or separately establish a supported Windows-host Symphony runtime; do not call Windows interop Linux parity.

## External integration prerequisites

- **Exact delivery gate:** JARVIS-910 precedes JARVIS-909; JARVIS-907 waits for JARVIS-909 completion plus JARVIS-901 GO. This spike does not bypass that sequence.
- **Same-host launcher:** install/authenticate the official Linux CLI in the supported WSL worker environment, or separately prove a Windows-host Symphony runtime. Direct Windows success is not permission to use cross-host interop.
- **Permissions:** close the merged owner contract's permission/input evidence rows for the selected host/profile. This spike records `always-proceed`; it does not redefine acceptance.
- **Tools/MCP/tracker:** these are not acceptance requirements and no bridge is required. `agy mcp list` reported no configured servers, while inference, same-process multi-turn, and explicit `--conversation` resume succeeded.

## Recommendation

- **Version test range:** `1.1.26` is the only observed version; no compatibility range is established. Any later version needs the deterministic suite and a bounded native acceptance.
- **Native functionality:** **GO on the observed Windows host/profile.** Authentication, model entitlement, inference, stream protocol, multi-turn state, resume, cwd, usage, and bounded interrupt all function.
- **Symphony adapter integration:** **HOLD, not abandoned.** Do not add the `antigravity` mapping until the same-host and canonical permission/input evidence gates close, JARVIS-909 completes, and this issue reaches GO.
- **Tracker bridge:** **No bridge.** Native inference succeeded with no MCP servers configured. Do not implement MCP, loopback, handoff, or credential plumbing from this spike.
