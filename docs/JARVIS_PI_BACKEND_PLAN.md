# Jarvis thin Pi backend plan

Status: release candidate validated. The authorized JARVIS-877 single-ticket canary proved the
isolated Pi worker, host-mediated tracker bridge, durable completion/handoff receipts, Human Review
transition, and rollback to the Codex default on candidate `d11bbb780bc8ab1ed4a3aee222e6f709bf37e579`.

This fork stays close to `openai/symphony`. It adds a removable Pi execution path without replacing
Symphony's tracker, workspace, polling, retry, reconciliation, concurrency, lifecycle, or
observability responsibilities.

## Baseline and lineage

- Fork: `sheep52031/symphony`
- Upstream: `openai/symphony`
- Baseline: Official Symphony v0.0.3 peeled commit `1c0fb6c8e8ef9031a2c861e62af5f9e66cee39cb`,
  contained by the post-release nightly `be10a1b79df723d6d7612b5651c8522704dafb2e` (`main`)
- Working branch: `jarvis/symphony-pi-backends`
- Current branch: `jarvis/symphony-pi-backends` (the exact mutable HEAD is reported with delivery
  evidence rather than duplicated in this plan)
- Jarvis-specific tracker and prompt policy remains in the separate `jarvis-next` checkout. This
  fork's generic `elixir/WORKFLOW.md` must not acquire Jarvis-private project identifiers or
  credentials.
- WSL validation is available through `mise` with Elixir `1.19.5` / OTP `28`. The native Linux
  export of the branch passes `334 tests, 0 failures, 6 skipped`; `make all` also passes with
  format/spec checks, Credo (no issues), `100.00%` measured coverage, and Dialyzer (zero errors).
  The v0.0.3/nightly baseline passes `299 tests` with `6 skipped` but has one intermittent timing
  failure in `CoreTest`'s active-state continuation retry assertion. On the Windows-mounted
  checkout, generated shell fixtures inherit CRLF and fail with bad-interpreter statuses; that is
  a checkout artifact, not the supported-host result.

## Cross-device execution contract

Symphony is expected to be hosted by Windows through WSL2, while Jarvis infrastructure and future
PiAgent use also include macOS. The backend therefore follows these host rules:

- Windows runtime validation runs inside WSL2. The Symphony BEAM, `bash -lc`, workspace, Node
  runtime, and Pi process must be observed from the same WSL environment; invoking a Windows `pi.cmd`
  as if it were a native Linux process is not the acceptance path.
- `pi.command` is executed by non-interactive `bash -lc`, not by an interactive shell. A host-specific
  absolute launcher is preferred when shell profile PATH is not inherited. It must point at a Node
  runtime supported by the installed PiAgent package and keep its session directory under the host's
  Developer root.
- On the authorized M2 Air, PiAgent `@earendil-works/pi-coding-agent@0.85.1` is installed under
  `/Users/jason/Developer/Tools/pi-agent`; its launcher uses the Homebrew Node runtime explicitly.
  The existing older global Pi installation is left untouched.
- The Windows WSL2 smoke uses a separate exact-version PiAgent install under
  `/mnt/d/Developer/Tools/pi-agent-wsl` and an explicit Linux-Node launcher, avoiding dependence on
  Windows `pi.cmd` interop or an interactive shell profile.
- Pi remains local-worker-only in this slice. Cross-device access to the M2 Air is infrastructure
  validation, not a new Symphony remote worker transport; SSH workers remain an explicit error.

## Implemented first slice

- `SymphonyElixir.AgentBackend` resolves `codex` (default) and opt-in `pi` without changing the
  scheduler or tracker interfaces.
- `SymphonyElixir.Codex.AppServer` now implements the contract directly; its wire protocol and
  existing call sites remain unchanged.
- `SymphonyElixir.Pi.Rpc` provides strict stdout JSONL request correlation, partial-line buffering,
  CRLF tolerance, separate stderr capture, async event callbacks, unattended dialog cancellation,
  fire-and-forget UI observation without protocol responses, completion predicates, timeout, and
  graceful abort support.
- `SymphonyElixir.Pi.Backend` performs `get_state`, `set_session_name`, `prompt` through the
  authoritative `agent_settled` event, `get_last_assistant_text`, and `get_session_stats`, with
  Pi-native event and usage mapping. `agent_end` with `willRetry: false` is deliberately not a
  completion signal, so compaction/retry/queued continuation cannot race handoff. It is explicitly
  local-only; configured SSH workers are rejected rather than silently claimed as supported.
- The orchestrator snapshots the selected backend into each new running attempt and passes that
  value to `AgentRunner`; an in-flight attempt does not follow a later workflow reload. Running,
  blocked, and retry snapshots preserve backend and receipt identity when available.
- Pi turn completion, typed failure, timeout/abort, and orchestrator cancellation write bounded
  JSON receipts. Pi receipts include the native session, effective model and thinking level,
  backend PID, final/last assistant text, stats, and a bounded stderr tail. Reconciliation now
  copies an existing attempt receipt into host-owned stable storage (or persists an `interrupted`
  partial receipt there) before cancellation and workspace cleanup, so every returned prior-receipt
  link remains resolvable after the workspace is removed.
- `SymphonyElixir.Pi.TrackerBridge` gives each Pi session a random bearer capability to a dedicated
  `127.0.0.1` listener, binds one adapter/settings/tool-spec snapshot and normalized issue, and
  executes adapter tools inside Symphony. The generated mode-`0600` Pi extension deletes bridge
  bootstrap values from `process.env` immediately after registration.
- Pi launch is an explicit supported isolation boundary: Symphony sets workspace-owned `0700`
  `PI_CODING_AGENT_DIR`/`PI_CODING_AGENT_SESSION_DIR`, appends `--session-dir` and Pi's
  `--no-extensions`, `--no-skills`, `--no-themes`, `--no-prompt-templates`, `--no-context-files`,
  and `--no-approve` controls, scrubs credential-like inherited environment names, and explicitly
  appends only the generated tracker bridge extension. The proof test rejects ambient credentials,
  verifies all flags, and verifies the effective directories.
- `symphony_handoff` stages only a non-active, non-terminal target state name. For Linear,
  Symphony resolves the target inside the bound issue's team, constructs the mutation host-side,
  and requires the response to confirm the exact state. Pi completion is settled and written first;
  the mutation is committed second; a separate `handoff_completed` or `handoff_failed` receipt is
  written last. Detectable direct Linear `stateId` mutations are denied.
- Linear may resolve `tracker.provider.api_key_command` host-side without shell parsing. The
  included PowerShell helper reads one Bitwarden custom field; helper-auth environment names are
  explicitly removed from coding-agent children. A locked vault fails closed.
- Deterministic bridge/backend/RPC/secret/cancellation tests do not call an LLM or mutate Linear;
  the full native suite and quality gate above cover them. The dependency lock was refreshed within
  the declared constraints to patched Bandit/Plug/Phoenix/Req/Mint/LiveView/Decimal releases.
- A real no-prompt Pi smoke through `SymphonyElixir.Pi.Rpc` successfully completed `get_state` in
  WSL2 using PiAgent `0.85.1` and the explicit Linux launcher; no LLM prompt was sent.
- The first authorized live Pi ticket (JARVIS-868) produced one workspace/branch/PR and stopped at
  Human Review. It also proved two blockers: Pi could discover a Windows User-scope Linear token via
  PowerShell, and reconciliation cancelled the final turn before a per-ticket completion receipt
  existed. The loopback bridge, deferred handoff, and interrupted receipt are direct remediations;
  JARVIS-868 is failure evidence for those old paths, not acceptance evidence for the remediations.
- The second authorized live canary, JARVIS-877, ran candidate `d11bbb7` with one Pi worker and one
  workspace. PiAgent `0.85.1` used `openai-codex` / `gpt-5.6-luna` / `high`, committed the bounded
  evidence change at `68bb5e6926ca61c293c20b126848110373c17afb`, opened
  `sheep52031/symphony#2`, and staged `Human Review` through `symphony_handoff`. Symphony persisted
  the settled completion receipt before the host-side Linear mutation and then persisted the
  separate `handoff_completed` receipt. Stable copies and a manifest remain under
  `workspaces-pi-canary/.symphony/completion-receipts/JARVIS-877/`.
- JARVIS-877's LLM-callable shell reported `LINEAR_API_KEY` and `BW_SESSION` absent. Pi loaded only
  the generated tracker extension plus an isolated workspace-owned agent/session directory; the
  extension removes its actual bridge URL, capability, and tool-spec bootstrap variables before
  agent tools run, as covered by deterministic bridge tests. A separate negative-auth probe removed
  ambient credential-like variables, failed closed without an isolated provider credential, and
  still reached authoritative `agent_settled`. The post-canary empty-selector launch restored
  `agent.backend: codex`, started no LLM worker, and left the product issue unchanged.

## PR readiness

The release gate is satisfied for the bounded, opt-in, local-only Pi backend. Candidate `d11bbb7`
passed the authorized JARVIS-877 tracker/security/lifecycle canary, durable receipt read-back,
Human Review handoff, negative credential probe, and Codex-default rollback. The branch also passed
fresh native-Linux `make all` and GitHub `make-all`. Pi remains disabled unless a workflow explicitly
selects `agent.backend: pi`; SSH Pi workers remain unsupported, and Codex remains the default and
rollback path.

## Fixed boundaries

### Keep upstream behavior

- Linear/provider adapter and native tracker tools
- per-issue workspace isolation and hooks
- polling, claims, retry/backoff, reconciliation, terminal cleanup
- Codex App Server as the default execution path
- existing Codex tests and runtime configuration

### Add only the execution seam

Introduce a small `AgentBackend` contract implemented by:

- `Codex.AppServer` adapter: wraps the current behavior with no protocol change
- `Pi.Rpc` adapter: owns Pi-native JSONL process/session/turn behavior

A backend owns its process, native session state, event parsing, timeout/abort behavior, credential
boundary, and typed failures. The common contract must not pretend Pi, Codex, Claude, or another
Harness share a wire protocol.

The first configuration selector is `agent.backend`, defaulting to `codex`; `pi` is opt-in only.
A running attempt never changes backend mid-run.

## Delivery sequence

### 0. Baseline evidence

- Keep this branch based on the exact synced upstream main commit.
- Capture current Codex test and build status before backend changes.
- Do not replace the installed Jarvis runtime or start a live Linear dispatch.

### 1. Pi RPC feasibility spike — implemented locally

Implement the smallest isolated Pi RPC client/test seam as an independently testable lower layer; it
must not make the scheduler or tracker speak the Pi protocol:

- spawn a configured command in the issue workspace
- send LF-terminated JSON commands with request IDs
- buffer partial lines and accept CRLF while treating only LF as the delimiter
- parse stdout protocol only and keep stderr as diagnostics
- correlate responses while forwarding asynchronous events
- classify `agent_start`, `agent_end`, `agent_settled`, `turn_*`, tool events, and failures
- auto-cancel unattended dialog UI requests; record fire-and-forget UI events
- exercise `get_state`, `set_session_name`, `prompt`, `abort`, and a bounded completion path
- prove timeout, graceful abort, and forced process termination behavior

The spike must use a fake Pi process for deterministic tests and one no-prompt real Pi smoke when
available. It must not make an LLM call, mutate Linear, install extensions, or write to shared user
sessions.

### 2. Backend integration — security/lifecycle rework completed

The resolver, `agent.backend: codex|pi` validation, `AgentRunner` session/turn selection,
Pi-to-existing-update mapping, durable receipts, session-scoped host tracker bridge, deferred
handoff, host secret command, and snapshot proof fields are present. Deterministic lifecycle,
cancellation, receipt, isolation, secret-command, bridge, and Codex-regression coverage passes on a
supported LF-native WSL/Linux checkout. The exact candidate has supported-host GitHub CI and an
owner-approved Bitwarden Secrets Manager launcher supplies only the control-plane Linear secret.

### 3. Single-ticket acceptance — second canary passed

JARVIS-877 supplied the required live evidence with one explicitly authorized Linear issue and one
worker only:

- exact issue/workspace/branch/PR identity and no duplicate runtime or workspace
- no auto-merge; the worker stopped at Human Review
- Codex baseline regression remained green
- Pi worker evidence includes event stream, session identity, effective model/thinking level, final
  text, stats, bounded stderr, and deterministic timeout/abort coverage
- tracker operations traversed the loopback bridge; ambient Bitwarden/Linear credentials were absent
  from Pi and shell descendants, and the negative-auth probe failed closed
- completion receipt persistence preceded provider handoff; handoff has a separate durable receipt,
  and cancellation evidence links a non-null prior receipt
- rollback restored `agent.backend: codex` with an empty selector and no product mutation

## Non-goals

- no second scheduler, queue, control plane, tracker replica, or retry/reviewer controller
- no provider model registry or credential broker
- no automatic DeepSeek backend; DSH remains explicit single-ticket takeover only
- no Eureka code or MemoryBank/Cognee code in this repository
- no Pi-specific PR/merge/dashboard automation copied from `tmustier/pi-symphony`
- no automatic merge, release, or live runtime replacement in the feasibility phase

## Acceptance gates

1. The branch can be rebased/synced from upstream without a broad conflict surface.
2. `agent.backend` omitted means current Codex behavior, with existing tests unchanged.
3. Pi RPC framing, event handling, UI policy, timeout, and abort behavior have deterministic tests.
4. A single Pi worker can execute one isolated issue only after explicit runtime authorization.
5. Every attempt records backend identity and a readable proof summary.
6. Rollback disables Pi selection without deleting its evidence or changing tracker state.
7. No claim of production readiness is made before live acceptance evidence exists.

## Evidence references

- [OpenAI Symphony](https://github.com/openai/symphony)
- [Pi RPC documentation](https://pi.dev/docs/latest/rpc)
- [Pi package directory](https://pi.dev/packages)
- [Pi Symphony reference](https://github.com/tmustier/pi-symphony)
- [Jarvis planning issue JARVIS-862](https://linear.app/luvinai/issue/JARVIS-862/規劃以薄-backend-branch-將-piagent-接入-elixir-symphony)
