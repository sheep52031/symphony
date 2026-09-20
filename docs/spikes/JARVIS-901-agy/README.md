# JARVIS-901 — native `agy` headless feasibility spike

**Decision: native Windows functionality GO; native Linux live report non-gating; JARVIS-901
Symphony integration HOLD.** The ephemeral Linux runner and raw envelopes were not retained, and
the reported session stopped at its second turn. Native NDJSON framing, cwd/workspace containment,
same-slot/cross-slot resume, permission hardening, and official cancellation remain open. This
removable spike changes no AgentBackend mapping, runner, orchestrator, tracker, or production
configuration.

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
| Authorized native Windows observation | Account/keyring auth can list models and complete JSON inference; native stream JSON, two-turn stdin state, explicit conversation resume, cwd, usage, stderr separation, and bounded CTRL-BREAK exit were observed. | Linux parity, least-privilege permissions, `--continue`, forced process-tree cleanup, or every native failure shape. |
| Authorized native Linux operator report | The official Linux `agy` `1.2.7` launcher and the supplied isolated profile launcher start. An ephemeral runner reported one `acc1` NDJSON result followed by a second-turn deadline, but neither runner nor raw envelopes were retained. The sanitized report is [`native-live-linux-2026-09-20.md`](evidence/native-live-linux-2026-09-20.md). | Auditable native NDJSON acceptance, canonical two-turn stdin completion, native cwd/workspace containment, same-slot resume, cross-slot fail-closed, official cancellation result, permission/input behavior, or fresh-session keyring/profile isolation. |
| Official reference | The documented JSON/NDJSON envelopes, `init`/`step_update`/`result` event names, `conversation_id`, cumulative usage fields, terminal statuses, stdin multi-turn rules, stderr split, soft permission denial, and nonzero error behavior. | A guarantee beyond the exact observed build/profile. |
| Deterministic fixture evidence | This artifact's bounded parser/lifecycle policy handles partial bytes, LF framing with CRLF tolerance, malformed stdout, separate stderr, nonzero exit, a scripted two-result transcript, `WAITING`, no-progress chatter, first-token/turn deadlines, post-result exit grace, interrupt race, process loss, cwd containment, and host mismatch. | Native behavior not listed in the authorized observation. The child is explicitly fake and never invokes `agy` or a provider. |

No host-absolute path, exact shared/global permission rule, token, credential, account identifier,
auth material, or settings-file content is committed.

## Native protocol characterization

### Local discovery and host boundary

The original native executable was Windows-hosted `agy.exe`, version `1.1.26`; it must not be
presented as a Linux worker executable. The supplied Linux launcher is now present at
`~/.local/bin/agy`, version `1.2.7`, with isolated slots invoked through
`~/.local/bin/agy-profile`. This establishes a native Linux executable for feasibility,
not a Symphony runtime: BEAM, shell, workspace, and harness must still share a supported host.
No Windows interop is Linux evidence. Remote/SSH workers have no evidence and remain unsupported.

A future adapter must resolve an executable in the selected local worker environment, fail with a
classified launch error when absent, and call it with the existing workspace as its cwd.
`require_contained_workspace` and the `cwd` fake process prove the intended pre-launch containment
check and observable child cwd; they do not prove native `agy` containment.

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

## Native live GO/HOLD matrix

| Contract row | Native-Linux evidence | Status | Remaining gate |
| --- | --- | --- | --- |
| Executable placement and process-level catalog invocation | Official Linux `agy` is executable at the approved launcher path and reported `1.2.7`; a fresh-D-Bus `acc3 models` invocation exited `0`, with diagnostics and catalog output deliberately unread. | **PARTIAL GO** | The exit code does not prove authentication or catalog correctness. A supported same-host Symphony runtime and profile/keyring restart isolation are still unproven. |
| JSON/NDJSON framing | An ephemeral runner reported one `acc1` NDJSON `init` + `SUCCESS` result, but neither the runner nor raw envelopes were retained. | **HOLD — operator report only** | Produce a sanitized, reproducible runner and machine-auditable summary before counting native framing as acceptance evidence. |
| Multi-turn identity and cumulative counters | The same operator report says prompt 2 was submitted after turn 1 and produced no terminal result within a 70-second absolute deadline. | **HOLD** | Reproduce with a retained sanitized runner; prove one init/two results, stable identity, clean close, cumulative counters, and a bounded failure policy. |
| Native cwd/workspace containment | The Linux report names a disposable cwd and sentinel, but does not retain `init.cwd`, sentinel verification, symlink behavior, or `--add-dir` boundary evidence. | **HOLD** | Prove the native child observes the exact contained workspace, cannot escape through symlinks or extra directories, and leaves the sentinel/workspace unchanged unless explicitly authorized. |
| Same-slot cross-process resume | Planned explicit `acc1 --conversation` check was not submitted. | **HOLD** | Re-authorize/run only after the stream failure is understood. |
| Cross-slot resume fail-closed | Planned explicit `acc2 --conversation` check was not submitted. | **HOLD** | Prove that an `acc1` conversation cannot be recovered by another isolated slot. |
| Cancellation/process cleanup | The ephemeral runner reported process-group termination and a zero-process leak check, but the runner/transcript were not retained. | **HOLD — operator report only** | Reproduce with a retained sanitized runner; prove native terminal cancellation, descendant-tree cleanup, and neutral adapter mapping. |
| Scoped permission/input-required | No permission-seeking prompt or bypass flag was used. | **HOLD** | Observe a real scoped soft-denial/input-required outcome without auto-answer or raw credential inheritance. |
| Fresh-session profile isolation | Fresh D-Bus catalog invocation exited `0`, but diagnostics and catalog contents were intentionally not inspected. | **HOLD** | Prove clean D-Bus/keyring restart/refresh behavior and cross-slot isolation. |
| Vendor authorization and production dispatch | No production dispatch or authorization change was attempted. | **HOLD** | Owner/vendor authorization remains external to this spike. |

The full sanitized live record, exact two-prompt count, and cleanup result are in
[`native-live-linux-2026-09-20.md`](evidence/native-live-linux-2026-09-20.md). The deadline
requires a HOLD rather than inference about why the second turn did not settle.

## External integration prerequisites and gate ownership

- **Completed baseline:** JARVIS-910 and JARVIS-909 are complete. They provide the accepted Codex+Pi baseline and provider-neutral bounded lifecycle; they do not make AntiGravity worker-ready.
- **JARVIS-901 feasibility gate:** auditable native Linux NDJSON/multi-turn, same-slot resume, cross-slot fail-closed, cwd/workspace containment, cancellation/process cleanup, permission/input behavior, profile/keyring isolation, and external vendor authorization must reach GO before JARVIS-907 starts.
- **JARVIS-907 implementation gate:** after JARVIS-901 GO, implement only the removable `agy` adapter and its deterministic contract tests. Do not defer an unresolved native-feasibility row into adapter implementation.
- **JARVIS-906 integrated acceptance:** after JARVIS-907 completes, revalidate the exact integrated candidate through one disposable Symphony worker canary, including same-host workspace binding, session continuation, cancellation/cleanup, usage/status visibility, Codex+Pi regression, adapter removal, and upstream-sync rehearsal. JARVIS-906 does not waive or replace JARVIS-901's native feasibility gate.
- **Same-host launcher:** the official Linux CLI is installed, but the unretained first-turn operator report is not acceptance proof. A supported Linux-host Symphony runtime and canonical session behavior still need auditable evidence. Direct Windows success is not permission to use cross-host interop.
- **Permissions:** close the merged owner contract's permission/input evidence rows for the selected host/profile. The earlier Windows capture records `always-proceed`; it does not redefine acceptance and this Linux follow-up did not exercise permissions.
- **Tools/MCP/tracker:** these are not acceptance requirements and no bridge is required. The earlier Windows capture reported no configured MCP servers while its inference, same-process multi-turn, and explicit `--conversation` resume succeeded; the incomplete Linux report makes no equivalent claim.

## Recommendation

- **Version test range:** `1.1.26` (Windows) and `1.2.7` (Linux) are individually observed; neither establishes a compatibility range. Any later version needs the deterministic suite and a bounded native acceptance.
- **Native functionality:** **GO on the observed Windows host/profile.** **Linux HOLD for acceptance:** executable/version discovery is reproducible and a `models` command exited `0`, but that exit does not prove auth/catalog correctness. The first-turn result and second-turn deadline are retained only as a non-gating operator report.
- **Symphony adapter integration:** **HOLD, not abandoned.** Do not add the `antigravity` mapping until auditable same-host NDJSON/multi-turn/resume, native cwd/workspace containment, cancellation/process cleanup, permission/input, profile isolation, and vendor-authorization gates close and JARVIS-901 reaches GO. Then JARVIS-907 may implement the adapter; JARVIS-906 must separately revalidate the integrated candidate and rollback/removal path.
- **Tracker bridge:** **No bridge.** This spike does not justify MCP, loopback, handoff, account rotation, or credential plumbing.
