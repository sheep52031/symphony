# JARVIS-901 — native `agy` headless feasibility spike

**Decision: NO-GO for adapter implementation.** This is a removable, documentation-local probe;
it changes no AgentBackend mapping, runner, orchestrator, tracker, or production configuration.

## Scope and evidence classes

This spike read the [JARVIS-908 parity contract](evidence/sources.md), official
Symphony, and the official AntiGravity headless reference. Immutable repository URLs are in
[`evidence/sources.md`](evidence/sources.md); sanitized local command/help/version captures, the
reviewed JARVIS-908 contract, and the full content-pinned official reference are committed under
[`evidence/`](evidence/). It ran
local executable discovery and `--version`/`--help` only. It did **not** submit a prompt, list
models, inspect auth/config contents, use a permission bypass, or make a provider/network
inference call.

| Class | What it establishes | What it does not establish |
| --- | --- | --- |
| Local static observation | A native Windows `agy.exe` is discoverable on `PATH`; `agy --version` printed **`1.1.26`**. Explicit discovery in the default `Ubuntu-22.04` WSL worker distribution reported `agy: not found`. | Other WSL distributions, authentication, profiles, models, native stream output, or a usable WSL launcher. |
| Local help observation | `-p`/`--print`, `--output-format text|json|stream-json`, `--input-format text|stream-json`, `--continue`, `--conversation`, `--print-timeout`, `--model`, `--agent`, and `mcp` management are exposed. Help says `stream-json` input requires `stream-json` output and reads NDJSON prompts from stdin. | That the installed build accepts or emits the documented protocol under its active profile. |
| Official reference | The documented JSON/NDJSON envelopes, `init`/`step_update`/`result` event names, `conversation_id`, cumulative usage fields, terminal statuses, stdin multi-turn rules, stderr split, soft permission denial, and nonzero error behavior. | A version-specific guarantee for the installed binary or any host/profile. |
| Deterministic fixture evidence | This artifact's bounded parser/lifecycle policy handles partial bytes, LF framing with CRLF tolerance, malformed stdout, separate stderr, nonzero exit, a scripted two-result transcript, `WAITING`, no-progress chatter, first-token/turn deadlines, post-result exit grace, interrupt race, process loss, cwd containment, and host mismatch. | Native `agy` behavior or interactive stdin/resume behavior. The child is explicitly fake and never invokes `agy` or a provider. |

No host-absolute path, configuration contents, token, credential, or auth material is recorded here.

## Native protocol characterization

### Local discovery and host boundary

The only discovered native executable is Windows-hosted `agy.exe`, version `1.1.26`.
The supported Symphony worker path in JARVIS-908 is a local worker whose BEAM, shell,
workspace, and harness share one host. The checked default `Ubuntu-22.04` worker distribution
currently lacks `agy`; other WSL distributions were not evaluated. A Windows executable must
therefore **not** be launched as the WSL worker executable.
The probe's `require_same_host` test makes that failure explicit before launch.

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

## Native live acceptance criteria (separately authorized)

1. The actual `1.1.26` `json` and `stream-json` stdout/stderr framing, partial-line behavior, event order/schema, unknown/malformed input behavior, terminal envelope/exit-code combinations, and usage field semantics remain unobserved.
2. stdin multi-turn state, `conversation_id` stability, `--continue`, `--conversation`, and post-stdin-close behavior remain unobserved. The two-result fixture has `stdin=DEVNULL`; it is only a transcript parser check and supplies none of that evidence.
3. The native permission/input-required outcome remains unobserved: whether it is only stderr soft-denial, `WAITING`, another result shape, or process behavior. No auto-answer or bypass is allowed.
4. Native cwd reporting/enforcement, symlink behavior, `--add-dir` scope, model/profile/default-agent selection, and authentication behavior remain unobserved. No model assumption is permitted.
5. Actual startup/first-token/turn timing, SIGINT result/exit behavior, terminate/kill cleanup, and process-loss recovery remain unobserved. The fixture proves required policy, not native signal handling.
6. A native launcher is absent from the checked default `Ubuntu-22.04` worker distribution. A Windows executable must not be treated as a WSL worker executable; another distribution needs its own explicit discovery, and Windows-host acceptance is separate if it later becomes supported.

## External integration prerequisites (not native live criteria)

- **JARVIS-910:** its deletion baseline remains an independent JARVIS-907 integration prerequisite. This spike does not assert it is complete.
- **Tools/MCP/tracker:** these are not acceptance requirements and no bridge is required. They become a separately scoped question only if a real future adapter proves a native dependency. Do not implement MCP, loopback, handoff, or credential plumbing from this spike.

## Recommendation

- **Version test range:** `1.1.26` is the only observed version; no compatibility range is established. If a later integration needs a guard, `>=1.1.26, <1.2.0` is only an unverified test-selection range, not evidence that any unobserved `1.1.x` version is compatible. Each version requires the deterministic suite and an authorized disposable native acceptance.
- **Adapter go/no-go:** **NO-GO.** Do not begin JARVIS-907 adapter code or add an
  `antigravity` mapping until the six native criteria above are closed by authorized same-host
  acceptance and JARVIS-910 has met its separate deletion gate. Live acceptance is prerequisite
  evidence, not permission to change runtime in this ticket.
- **Tracker bridge:** **No bridge.** `agy mcp` help is not proof of an unavoidable bridge, and no
  native tracker-tool requirement was observed. Do not implement or configure MCP, loopback,
  handoff, or credential plumbing in response to this spike.
