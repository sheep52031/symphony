# JARVIS-901 — native `agy` headless feasibility spike

**Decision: native Linux feasibility GO for JARVIS-907, with mandatory outer OS containment;
production dispatch remains gated by JARVIS-906.** A retained Omarchy capture now proves native
NDJSON multi-turn, same-slot resume, cross-slot identity separation, permission soft denial,
cancellation/timeout cleanup, and selected-profile operation. A negative control also proves that
native `--sandbox` does not contain `write_to_file`; the accepted route therefore requires a
fail-closed Bubblewrap boundary. This removable spike changes no AgentBackend mapping, runner,
orchestrator, tracker, or production configuration.

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
| Authorized native Linux acceptance | The official Linux `agy` `1.2.7` completed retained two-turn NDJSON, same-slot context resume, cross-slot identity separation, permission denial, and bounded lifecycle checks. Native cwd and `--sandbox` alone failed an outside-write negative control; mandatory Bubblewrap mount isolation passed outside-write, symlink-escape, in-workspace-write, and hardened authenticated-inference checks. See [`native-live-linux-2026-09-21.md`](evidence/native-live-linux-2026-09-21.md). | A production Symphony dispatch, compatibility with later CLI versions, arbitrary remote hosts, or permission to omit the outer OS sandbox. |
| Official reference | The documented JSON/NDJSON envelopes, `init`/`step_update`/`result` event names, `conversation_id`, cumulative usage fields, terminal statuses, stdin multi-turn rules, stderr split, soft permission denial, and nonzero error behavior. | A guarantee beyond the exact observed build/profile. |
| Deterministic fixture evidence | This artifact's bounded parser/lifecycle policy handles partial bytes, LF framing with CRLF tolerance, malformed stdout, separate stderr, nonzero exit, a scripted two-result transcript, `WAITING`, no-progress chatter, first-token/turn deadlines, post-result exit grace, interrupt race, process loss, cwd containment, and host mismatch. | Native behavior not listed in the authorized observation. The child is explicitly fake and never invokes `agy` or a provider. |

No host-absolute path, exact shared/global permission rule, token, credential, account identifier,
auth material, settings-file content, raw envelope, or live prompt is committed.

## Reproducible Linux capture runner (offline by default)

[`capture_runner.py`](capture_runner.py) is a checked-in native-Linux provenance layer, not an
adapter. Its default `fake` mode runs only `fixtures/fake_agy.py`; it does not discover, launch, or
contact `agy`. It delegates framing, bounded queues/frames/evidence retention, and process-tree
cleanup to [`probe.py`](probe.py). Each bounded capture writes ignored exact raw stdin/stdout/stderr
bytes, a manifest with per-artifact SHA-256/size, and a redacted summary bound to that manifest. The summary records sanitized argv and version, timestamps, root PID/process group, every escalation signal,
process-group-empty outcome, return status, terminal statuses, hashed session identities, malformed
and stderr counts, workspace sentinel result, and whether `init.cwd` was exposed.

The shared probe starts a POSIX process group and closes stdin after the final accepted turn. If it does
not exit within the configured grace, it sends bounded `SIGINT`, `SIGTERM`, then `SIGKILL`, recording
the sequence and checking the owned group is gone. An unconditional absolute deadline follows the
final escalation; at that deadline readers are stopped and joined boundedly, a surviving group is
recorded as `process_group_empty=false` and `cleanup_failed=true`, and the run fails. It removes
known API-key/base-URL names from the child environment without reading their values. It does not
inspect profile, keyring, settings, or credential stores. A raw capture may contain provider output or prompts, so it is accepted only
outside the repository or below the root [`.agy-captures/`](../../../.gitignore) ignored subtree;
raw files have no import command and must never be force-added.

The generated `redacted-summary.json` deliberately excludes raw prompt/response text, absolute
paths, and raw conversation IDs. Identities use a deterministic truncated SHA-256 label solely to
check equality. Schema and redaction invariants reject owner paths and the fixture prompt strings;
the deterministic tests also assert summary output has neither the temporary workspace path nor
prompt text. The raw capture is bounded per stream (`1 MiB` default), and retained versus observed
bytes are explicit in the summary. Provenance binds `capture_runner.py`, `probe.py`, the fake
fixture when used, the committed safe wrapper bytes, the absolute `$REAL_HOME/.local/bin/agy`
target hash, and the clean git HEAD/tree before and after capture. Live children receive the fixed
trusted PATH `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`; operator PATH entries
are not used. The committed wrapper is executed directly; no external launcher is required or modified.
Its profile and keyring contents remain external, and it projects no unrelated operator `.ssh` or
`.gitconfig` configuration.

## Run the offline capture only

```bash
mkdir -p .agy-captures
run_dir="$(mktemp -d "$PWD/.agy-captures/offline-XXXXXX")"
chmod 700 "$run_dir"
PYTHONDONTWRITEBYTECODE=1 python3 docs/spikes/JARVIS-901-agy/capture_runner.py \
  --mode fake \
  --capture-dir "$run_dir"
```

### Future live command — requires fresh owner authorization

The accepted 2026-09-21 capture used this command shape. Any rerun still requires fresh owner
authorization, a new ignored directory, and owner-reviewed `prompts.ndjson`; prompt text is
intentionally not specified or checked in. The explicit authorization value is a guardrail, not a
credential and is required separately from `--mode live`:

```bash
mkdir -p .agy-captures
run_dir="$(mktemp -d "$PWD/.agy-captures/live-XXXXXX")"
chmod 700 "$run_dir"
# Owner creates "$run_dir/prompts.ndjson" as LF-delimited {"event":"user",...} envelopes.
PYTHONDONTWRITEBYTECODE=1 python3 docs/spikes/JARVIS-901-agy/capture_runner.py \
  --mode live \
  --live-authorization JARVIS-901-OWNER-AUTHORIZED \
  --profile acc1 \
  --prompts-file "$run_dir/prompts.ndjson" \
  --capture-dir "$run_dir"
```

Live mode invokes the committed reviewed safe wrapper directly with `--mode plan`, stream-json
input/output, and a 60-second CLI print timeout; it never adds the dangerous permission-bypass flag.
The wrapper source is committed at [`fixtures/agy-profile`](fixtures/agy-profile), and its exact
SHA-256 is pinned. Provenance also resolves and hashes its absolute `$REAL_HOME/.local/bin/agy`
target before launch. The wrapper's external `REAL_HOME` profile and keyring remain external and are
never copied or projected; in particular, no unrelated operator `.ssh` or `.gitconfig` is created.
It requires the same local Linux host: shared-SSH or remote launchers are unsupported because the
wrapper resolves that host's home, D-Bus, keyring, and absolute `agy` path rather than providing
remote transport. Live deadlines are explicit CLI options with bounded safe defaults, and are
deliberately not the fixture-scale offline values. It captures `agy --version` from the exact
underlying executable selected by the pinned wrapper before launch.
Before manually importing any result, the owner must inspect the ignored files locally, retain only a
reviewed redacted summary/report, and confirm that no prompt, raw envelope, path, auth material, or
opaque identity was copied. A runner result alone does not close any native gate: the actual observed
envelopes must meet the matrix below. Native `agy` does not document a machine-readable permission-
request event, a process-tree listing, profile/keyring isolation signal, or proof that
`--add-dir`/symlinks cannot escape; the runner labels only its own observable lifecycle and `init.cwd`.

The offline-equivalent parser/CLI check is the same command shape without live authorization and
never launches `agy`; it uses the same explicit directory precondition:

```bash
mkdir -p .agy-captures
run_dir="$(mktemp -d "$PWD/.agy-captures/offline-XXXXXX")"
chmod 700 "$run_dir"
PYTHONDONTWRITEBYTECODE=1 python3 docs/spikes/JARVIS-901-agy/capture_runner.py --mode fake \
  --capture-dir "$run_dir"
```

## Native protocol characterization

### Local discovery and host boundary

The original native executable was Windows-hosted `agy.exe`, version `1.1.26`; it must not be
presented as a Linux worker executable. The supplied Linux executable is present at
`~/.local/bin/agy`, version `1.2.7`, with isolated slots selected by the committed safe wrapper.
This establishes a native Linux executable for feasibility, not a Symphony runtime: BEAM, shell,
workspace, and harness must still share a supported host.
No Windows interop is Linux evidence. Remote/SSH workers have no evidence and remain unsupported.

A future adapter must resolve the executable and selected profile root in the local worker
environment, fail with a classified launch error when either is absent, and launch through the
accepted Bubblewrap policy with the existing workspace as its only issue-data write root.
`require_contained_workspace` and the `cwd` fake process prove only a pre-launch path check and
observable child cwd. The 2026-09-21 negative control proves that cwd plus native `--sandbox` is not
native file-tool containment.

### Documented headless contract (static only)

- `-p` is one-shot headless mode. `--output-format json` returns a terminal envelope; `--output-format stream-json` is NDJSON. The reference says response data belongs on stdout and diagnostics, auth, progress, and permission notices on stderr.
- Streaming output must begin with exactly one valid `init` carrying its own nonempty
  `conversation_id`; no step/result may precede it, duplicate init is rejected, and every later
  identity must match. It then has zero or more `step_update`s, followed by exactly one `result` per
  submitted turn. Documented result fields are `conversation_id`, `status`, `response`, `error` on
  failure, `duration_seconds`, `num_turns`, and usage totals (`input_tokens`, `output_tokens`,
  `thinking_tokens`, `cache_read_tokens`, `total_tokens`). Agent response deltas occur in
  `step_update.text_delta`; the reference describes usage/turns as cumulative in a stdin session.
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
6. Cleanup escalation has an unconditional absolute deadline. At the deadline, reader stop/join is bounded and a group that still exists is explicit failure rather than an opportunity to loop again.
7. Stderr remains diagnostics. A terminal error or `WAITING` result is retained even when the process exits nonzero or emits a permission notice. Exit without a terminal envelope is distinct process loss.

The fake-process scenarios exercise partial lines/CRLF/malformed JSON, stderr chatter,
nonzero error, an actual stdin-driven two-turn same-session identity check, a scripted two-result
transcript parser check, permission/input waiting, chatter and stall deadlines, post-result hang,
cancellation race, bounded `SIGINT`/`SIGTERM`/`SIGKILL` escalation, group-never-empty kill
failure with an absolute deadline, inherited-pipe process-tree cleanup, process loss, high-volume
bounded evidence, oversized-frame resynchronization, workspace cwd, and cross-host rejection. It
also rejects adversarial pre-init step/result events, identity-less or duplicate init, and later
identity mismatch. These are fixture properties, not claims about the native CLI.

Run only the deterministic suite:

```bash
python -m unittest discover -s docs/spikes/JARVIS-901-agy/tests -p '*_test.py' -v
```

## Native live GO/HOLD matrix

| Contract row | Native-Linux evidence | Status | Required downstream invariant |
| --- | --- | --- | --- |
| Executable placement and authentication | Native `agy 1.2.7` completed provider turns from two explicit profile slots on the same Omarchy host as Symphony. | **GO** | Local host only; no SSH/Windows interop claim. |
| JSON/NDJSON framing | Retained capture observed one valid init, two results, no malformed/dropped frames, stable identity, cumulative usage, and clean exit. | **GO** | Preserve exact native envelopes behind the adapter boundary. |
| Multi-turn and same-slot resume | Two stdin turns completed; a new same-slot process preserved identity and exactly recalled first-turn context. | **GO** | Reject missing or changed continuation identity. |
| Cross-slot resume | A second slot did not recover the source identity and silently created a new successful conversation. | **GO with policy** | Requested continuation plus returned identity mismatch is a hard adapter error, never a fresh-session fallback. |
| Cwd and filesystem containment | Cwd matched, but native `--sandbox` still allowed an outside-workspace file write. Bubblewrap read-only-root tests blocked outside and symlink writes while preserving exact workspace writes. | **GO only with outer sandbox** | Bubblewrap is mandatory and fail-closed; native `--sandbox` remains defense in depth. |
| Cancellation/process cleanup | Native SIGINT produced a terminal interrupt-class `ERROR`; timeout and interrupt runs emptied their process groups. Deterministic tests cover escalation and descendant cases. | **GO with normalization** | A locally initiated cancel owns cancellation classification; unsolicited `ERROR` remains provider failure. |
| Scoped permission/input-required | `request-review` returned a structured denied action and stderr notice without the shell side effect. | **GO** | Never auto-answer and never use the dangerous bypass flag. |
| Fresh-session profile isolation | Two selected profile roots completed independently and cross-slot continuation did not recover source identity. | **GO** | Bind only one explicit writable profile root per attempt; no account rotation. |
| Owner authorization and production dispatch | The owner authorized the bounded development checks. No production issue was dispatched. | **GO for JARVIS-907; production HOLD** | JARVIS-906 owns the exact-issue integrated canary and final dispatch decision. |

The superseding record is
[`native-live-linux-2026-09-21.md`](evidence/native-live-linux-2026-09-21.md), with the reviewed
aggregate in
[`native-live-linux-2026-09-21-summary.json`](evidence/native-live-linux-2026-09-21-summary.json).
The earlier 2026-09-20 report remains historical non-gating evidence.

## External integration prerequisites and gate ownership

- **Completed baseline:** JARVIS-910 and JARVIS-909 provide the accepted Codex+Pi baseline and provider-neutral bounded lifecycle.
- **JARVIS-901 feasibility gate:** **GO on the observed Omarchy host for JARVIS-907.** The mandatory Bubblewrap requirement is a resolved launcher design constraint, not an optional implementation follow-up.
- **JARVIS-907 implementation gate:** implement only the removable `agy` mapping/module tree, exact native protocol adapter, mandatory mount sandbox, and deterministic/shared contract tests. Identity mismatch, unavailable containment, permission denial, and local cancellation must be explicit neutral outcomes.
- **JARVIS-906 integrated acceptance:** after JARVIS-907 completes, run one disposable exact-issue Symphony canary, recheck same-host workspace binding, continuation, cancellation/cleanup, usage/status visibility, Codex+Pi regression, adapter removal, and upstream-sync rehearsal.
- **Same-host launcher:** Linux evidence is accepted only for the tested local route. Direct Windows success is not permission to add cross-host interop.
- **Permissions:** native `request-review` soft denial is visible. Runtime policy may grant bounded commands inside the sandbox, but the adapter must never auto-answer prompts, add `unsandboxed(...)`, or use `--dangerously-skip-permissions`.
- **Tools/MCP/tracker:** no bridge is required. The adapter owns no tracker lifecycle and receives no raw Linear credential.

## Recommendation

- **Version test range:** `1.1.26` (Windows) and `1.2.7` (Linux) are individually observed; neither establishes a compatibility range. Any later version needs deterministic regression and bounded native acceptance.
- **Native functionality:** **GO on the observed Linux host/profile route when launched through the accepted outer containment policy.** Native cwd and native `--sandbox` alone are explicitly NO-GO.
- **Symphony adapter integration:** **GO for JARVIS-907.** Codex stays default/rollback, Pi stays supported, and AntiGravity remains opt-in. JARVIS-906 separately owns integrated canary and rollback/removal acceptance.
- **Tracker bridge:** **No bridge.** This spike does not justify MCP, loopback, handoff, account rotation, credential plumbing, or a second controller.
