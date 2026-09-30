---
type: fork-extension-contract
canonical_subject: openai/symphony
canonical_revision: be10a1b79df723d6d7612b5651c8522704dafb2e
canonical_tree: 6e0ae271f586a5855082a52329d34355cad634fd
overlay_revision: da5fcf7b1d083b723ec08cae942563fc16b783d3
overlay_tree: f387c34005eb88b17cd717b9862ec14cb18e378d
status: proposed-evidence-gate
---

# Owner fork — AntiGravity worker parity contract and deletion budget

## Authority, scope, and source pins

This is an owner-fork contract, not a claim that official Symphony implements a generic worker
plugin or that AntiGravity is conformant. The canonical source was reopened at official commit
`be10a1b79df723d6d7612b5651c8522704dafb2e`, tree
`6e0ae271f586a5855082a52329d34355cad634fd`; the measured fork snapshot is
`da5fcf7b1d083b723ec08cae942563fc16b783d3`, tree
`f387c34005eb88b17cd717b9862ec14cb18e378d` (`0` behind, `13` ahead, 29 files,
`+5089/-146`).

Official ownership remains decisive: the Orchestrator owns polling, claims, retries and
reconciliation; `Workspace` owns the per-issue path; `AgentRunner` owns one worker lifetime; a
selected tracker adapter owns native tracker tools; status/log surfaces project state only. This
contract applies to a **local `agy` headless Harness adapter** only. It neither copies the Codex
app-server JSON-RPC protocol nor establishes remote worker-host support, a live canary, production
readiness, or a tracker bridge requirement.

| Evidence class | Pinned source reopened | What it establishes |
| --- | --- | --- |
| Official specification | `SPEC.md:635-849, 950-1168, 1179-1322, 1359-1457, 1634-1719, 1799-2199` | state-machine ownership; workspace/runner boundary; Codex-specific reference protocol; adapter tools; observability; recovery; required test profiles |
| Official implementation | `elixir/lib/symphony_elixir/{orchestrator,agent_runner,workspace,tracker}.ex`; `codex/app_server.ex` | the reference's single scheduler, host/workspace/session handling, tracker snapshot binding, and Codex transport behavior |
| Official tests | `core_test.exs`, `workspace_and_config_test.exs`, `app_server_test.exs`, `orchestrator_status_test.exs` | deterministic examples for reconciliation, retry, workspace safety, stream/input/tool handling, and observability |
| Fork facts only | fork `agent_backend.ex`; `pi/rpc.ex:160-181`; diff `be10a1b...da5fcf7` | existing closed Codex/Pi mapping, and the Pi receive loop that restarts its timeout after every protocol event |

## Non-negotiable selection rule

`codex` remains the default. Resolve the backend once when a new attempt is created and retain that
selection for all turns in that worker lifetime. A retry is a new attempt and may resolve the
then-current configured selection; it does not change the prior attempt. There is **no
mid-attempt switch** and **no silent fallback**: if `agy` is absent, cannot launch, or cannot meet
the adapter contract, the selected attempt fails with a classified error for the existing
orchestrator retry/reconciliation path. It must not run Codex instead.

The only permitted new selection is a closed mapping entry; configuration must never name an
arbitrary module, create an atom from workflow data, select a model catalog, or route per issue.
This preserves `SPEC.md:640-730` single-authority state while treating the harness protocol as an
execution-layer concern.

## Source-anchored parity matrix

Parity means the same observable lifecycle outcome at the official boundaries, not matching Codex
wire messages or event names. “Required evidence” means deterministic focused tests before any
optional, separately reported disposable live acceptance. No row authorizes a provider call in this
documentation change.

| Lifecycle concern | Official owner / invariant | Codex-specific reference detail | Minimal `agy` adapter obligation | Required evidence / test | Current limit or blocker |
| --- | --- | --- | --- | --- | --- |
| Issue selection, claim, and revalidation | `Orchestrator` alone owns candidate filtering, `claimed`, `running`, slots and ID refresh (`SPEC.md:640-730, 754-818`; `orchestrator.ex`; `workspace_and_config_test.exs` tests “provider-marked blocked issue…” and “dispatch revalidation…”). | None beyond workers reporting results; Codex does not choose issues. | Accept only the already selected normalized issue/attempt; return lifecycle outcome to the runner. Add **zero** `agy` branches to polling, claim, candidate sorting, or tracker refresh. | Existing Codex selection/revalidation regression plus an adapter contract test proving one selected attempt cannot create a second dispatch. | `agy` issue-selection capability is neither needed nor allowed; tracker bridge necessity is unproven. |
| Workspace and worker-host binding | `Workspace` and `AgentRunner` bind one worker lifetime to its issue workspace; paths stay root-contained (`SPEC.md:851-948, 1932-1993`; `workspace.ex`; `agent_runner.ex:22-199`). | `Codex.AppServer` validates cwd and uses its local/SSH launch path (`app_server.ex:150-240`). | Launch local `agy` with the already-created workspace as cwd; preserve that path for all turns and cleanup. Do not add host routing. | `workspace_and_config_test.exs` deterministic/reuse/symlink tests; a fake-`agy` cwd test; runner test that a session never changes workspace. | No remote worker-host parity is claimed. SSH launch, remote secret removal, and cross-host cleanup require later evidence. |
| Session, turn, and continuation | `AgentRunner` owns one session lifetime, checks the refreshed issue after a successful turn, and keeps continuation in the same workspace (`SPEC.md:640-674, 985-1037, 1932-1993`; `agent_runner.ex:74-156`). | Codex thread/turn IDs form `<thread_id>-<turn_id>` and continuation uses the same app-server thread. | Use only native `agy` headless session/resume semantics once verified; keep the selected process/session for continuation or return a classified inability to continue. Do not emulate Codex thread RPC. | Fake-native transcript tests: initial prompt once, continuation guidance only, max turns, refreshed inactive issue stops, session cleanup once. | `agy` session/resume flags and stable machine-readable completion signals are unverified; JARVIS-901 owns that spike. |
| Tools, permissions, and credential boundary | Tracker adapter owns provider-native tools; child gets results, not raw tracker credentials (`SPEC.md:1065-1141, 1179-1322`; `tracker.ex:48-74`). | Codex advertises `dynamicTools`, handles `item/tool/call`, and maps approval requests (`app_server.ex:307-883`). | Do not invent a generic tool protocol. If native `agy` can invoke host tools, bind one tracker snapshot and return native structured failures; otherwise document tools unsupported and fail/continue according to native behavior. | Tests for selected-snapshot stability, unsupported tool behavior, no tracker credential inherited, and no scheduler provider branch. | Native `agy` tool and permission protocol is not pinned. A loopback Pi bridge, Linear handoff path, or credential broker is not justified. |
| Approval and input-required | A run must not wait indefinitely for input; documented policy determines fail/surface/approved handling (`SPEC.md:1065-1141`). | Codex maps approval and MCP/user-input methods to explicit events/errors; official tests cover hard input blockers (`app_server_test.exs` tests “request-for-input…” through “option-based…”). | Translate native `agy` permission/input outcome to one neutral adapter update/result. A blocked outcome must be observable to the runner; do not auto-answer or silently continue without an explicit documented `agy` policy. | Scripted input/permission transcript tests and an orchestrator blocked-versus-retry regression. | Native noninteractive permission/input semantics are unknown; no Human Review automation follows from input blocking. |
| Startup, timeout, stall, and cancellation | Runner maps startup/turn failure; Orchestrator independently stops stale workers and reconciles cancellation (`SPEC.md:694-724, 819-840, 1142-1168, 1634-1688`; `orchestrator.ex:117-199, 594-723`; `orchestrator_status_test.exs` stall tests). | Codex read timeout, turn-silence timeout, and `codex.stall_timeout_ms` are Codex settings; app-server stream output resets its turn-silence timeout (`app_server.ex:368-477`; `app_server_test.exs:79-166`). | Define adapter-owned startup/turn completion deadline and a neutral heartbeat policy before integration; support prompt process stop/close. Send timestamps only for meaningful normalized progress, not every raw protocol line. | Fake `agy` tests for missing executable, startup failure, silence timeout, continuous chatter, cancellation, and cleanup; retain Codex timeout regressions. | Current Pi `Rpc.dispatch_message/2` recursively calls `receive_response/1` after every event, so continuous events reset the receive timeout (`pi/rpc.ex:160-181`). That defect is not evidence for `agy`; JARVIS-910 removes this runtime, and JARVIS-901 must prove a bounded `agy` policy. |
| Events, session identity, and usage | Orchestrator records normalized event time/session state and aggregates only defined cumulative usage (`SPEC.md:1039-1064, 1390-1448`; `orchestrator.ex:117-149, 1508-1814`). | Codex emits app-server PID, thread/turn IDs, token and rate-limit payload shapes. | Emit the minimum neutral update (`event`, UTC `timestamp`, optional opaque session ID and explicitly documented usage). Do not label unknown `agy` output as Codex usage or rate limits. | Contract tests for event ordering, session start, duplicate-safe cumulative usage when native totals exist, and omission when they do not. | `agy` event/usage schema is unverified; dashboards may show absent usage rather than fabricated values. |
| Retry and reconciliation | Only Orchestrator schedules continuation/backoff, refreshes opaque issue IDs, releases claims, and decides terminal/non-active cleanup (`SPEC.md:790-840, 1995-2046`; `orchestrator.ex:151-199, 805-1265`; `core_test.exs:1022-1240`). | Codex update timestamps feed the current stall calculation; protocol does not own retry. | Return normal/failure/input-required/cancelled outcome without a retry loop, receipt store, or tracker mutation. Preserve fixed backend selection through a lifetime only; each retry is a new attempt. | Existing normal/abnormal/retry-token tests plus adapter failure-result tests showing exactly one scheduler retry path. | No second scheduler, durable retry queue, receipt subsystem, or silent provider fallback is permitted. |
| Tracker handoff and Human Review | Tracker writes are provider-native agent-tool work; a successful run may end at workflow-defined `Human Review`, not necessarily Done (`SPEC.md:18-34, 1310-1322`). | Codex may invoke advertised tracker tools; it does not give the scheduler ticket-write logic. | At most expose native `agy` tool results to the selected tracker adapter after tool evidence exists. The adapter must not infer completion or change tracker state itself. | Tool-contract test with a fake selected adapter; later disposable tracker acceptance only if separately authorized. | No tracker bridge, Linear handoff module, or automatic Human Review transition is required or approved now. |
| Cleanup | Workspace owns hooks/removal; terminal reconciliation stops worker before cleanup, while non-active/unroutable stops without cleanup (`SPEC.md:841-948`; `workspace.ex`; `core_test.exs` tests “terminal issue state…” and “non-active issue state…”). | Codex session stop closes its port. | Stop the local `agy` process/session before existing workspace cleanup and never delete a workspace from the adapter. | Cancellation and terminal/non-terminal cleanup ordering tests; reuse/symlink safety regression. | No remote cleanup claim; no cancellation receipt policy is retained as an adapter requirement. |
| Status API, dashboard, and logs | Logs/status are projection only; snapshot failure cannot affect orchestration (`SPEC.md:1359-1457, 1669-1688`; `orchestrator.ex:1391-1499`; `orchestrator_status_test.exs`). | Current names and token parsing are Codex-shaped. | Supply neutral, bounded adapter event summaries and optional native session identifier; do not add a dashboard, API, receipt viewer, or control plane. | Snapshot/log regression with `agy` event and missing-usage cases; prove rendering does not alter worker outcome. | Current Pi-specific status/receipt fields are deletion scope, not a parity feature. |
| Removal | Official core remains independently usable; extension removal must not alter scheduler truth (`SPEC.md:41-69, 2167-2199`). | Codex remains the reference backend and default. | Remove one closed `antigravity` mapping entry, its adapter tree, adapter-owned config, and focused tests/docs; Codex regression must remain green. | Removal patch dry-run plus Codex core/quality checks. | No generic registry, model catalog, provider API, credential broker, or pre-abstraction may be retained for hypothetical adapters. |
| Upstream sync | Canonical source refresh precedes overlay re-evaluation (`canonical-refresh-protocol.md`; `SPEC.md:2049-2199`). | Codex protocol fields can change with the targeted app-server schema. | Reopen affected official anchors and native `agy` evidence; revalidate the adapter boundary without translating `agy` into Codex RPC. | Pin/tree refresh, focused contract tests, Codex regression, then separately reported optional live profile. | This document is stale if either source pin changes; no live canary is recorded for `agy`. |

## Closed change budget for a future `agy` adapter

After JARVIS-910 reaches the deletion baseline below, a single future adapter change may contain
only:

1. one explicit `"antigravity" -> adapter module` entry in the existing closed mapping;
2. one `antigravity/` adapter module tree containing native `agy` launch/session/event handling;
3. the smallest `agent.backend` selection/config/schema fields needed to default to `codex` and
   select `antigravity` for a new attempt;
4. focused adapter/runner tests, this contract's evidence update, and adapter configuration docs.

It must contain **zero provider-specific branches in `Orchestrator`**, zero tracker lifecycle or
receipt/control-plane code, zero unrelated dependency upgrades, and no generic registry/factory,
router, provider API, model catalog, credential broker, or fallback abstraction. The adapter owns
native protocol and adapter-local config; the existing runner/orchestrator ownership does not move.
A proposed file outside this closed list needs a separate owner decision.

## JARVIS-910 strict deletion budget

JARVIS-910 is a cleanup workstream after JARVIS-908. It may run in parallel with the isolated
JARVIS-901 `agy` feasibility spike; neither workstream authorizes adapter integration. It must
remove the current Pi-specific expansion from the pinned 29-file / `+5089/-146` fork delta, not
rebrand it for AntiGravity. The only permitted retained runtime seam is a small closed backend
resolver and runner/config selection that defaults to Codex, has no provider branch in
Orchestrator, and is independently removable. It is justified only as an owner-fork
execution-layer seam; official source remains Codex-specific.

| Current drift category | JARVIS-910 deletion requirement | Permitted remainder | Acceptance boundary |
| --- | --- | --- | --- |
| Pi runtime and protocol | Delete `elixir/lib/symphony_elixir/pi/{backend,rpc,tracker_bridge,tracker_bridge_extension,tracker_bridge_plug}.ex` and Pi-only launch/protocol behavior. | No Pi module or compatibility shim. | Repository search has no `SymphonyElixir.Pi`, Pi RPC, or Pi backend config/test reference. |
| Orchestrator/control plane | Delete Pi backend metadata branches, Pi event/receipt fields, cancellation/interrupted receipt persistence, Pi-only blocked/retry/status projection, and any Pi-specific timeout wording from `orchestrator.ex`. | Neutral worker result/update handling only if needed by the closed resolver; scheduler stays protocol-agnostic. | `orchestrator.ex` has zero `:pi`, `Pi.`, `agy`, provider protocol, receipt, or tracker-handoff branches. |
| Tracker bridge and Human Review policy | Delete loopback bridge, bridge plug/extension, `linear/handoff.ex`, and their integrations/tests. | Existing official selected tracker adapter and workflow prompt/tool boundary only. | No new tracker write API, bridge listener, or Human Review automation. |
| Secrets and host helpers | Delete `secret_command.ex`, Bitwarden resolver scripts, secret-command schema/config, and tests. | Official adapter-declared secret-environment removal only; no broker. | No command-based secret resolver or host-specific credential path remains. |
| Receipts/evidence store | Delete cancellation/attempt receipt code, paths, status fields, docs, and tests introduced for Pi. | Normal structured logs and official snapshot fields only. | No durable receipt subsystem, receipt directory, or recovery truth is introduced. |
| Configuration and docs | Remove Pi-only fields from `config.ex`, `config/schema.ex`, `WORKFLOW.md`, `elixir/README.md`, `SPEC.md`, and `docs/JARVIS_PI_BACKEND_PLAN.md`; restore official text where this fork changed canonical prose. | Minimal closed `agent.backend` default/allowlist documentation only, if the neutral seam remains. | Codex is the documented default; no Pi profile/default model or arbitrary backend module selection. |
| Tests and support | Delete Pi, bridge, handoff, secret, and receipt suites/support fixtures; remove Pi assertions from mixed core/status tests. | Focused closed-resolver/runner contract test plus unmodified Codex regressions. | No coverage ignore, fixture, or test name retains Pi behavior. |
| Dependency and lockfile drift | Separate all `mix.exs`/`mix.lock` changes from the adapter cleanup; remove Pi-caused lock drift unless an independently reviewed security update explicitly retains it. | No dependency change in an `agy` adapter or JARVIS-910 cleanup commit. | Lockfile diff is empty for this cleanup, or a separate approved dependency commit documents every retained entry. |

The budget names removal scope, not a mandate to delete official files or rewrite history. JARVIS-910
must report the resulting diff against `be10a1b79df723d6d7612b5651c8522704dafb2e`, enumerate every
retained non-upstream line, and prove Codex behavior before the baseline is accepted.

## Gate sequence and unresolved evidence

1. **JARVIS-908 (this document):** accept this scoped contract and deletion budget; no runtime
   change and no provider call.
2. **JARVIS-910 and JARVIS-901 may proceed in parallel:** JARVIS-910 meets the deletion budget and
   establishes the Codex-default neutral baseline. JARVIS-901 inspects pinned native `agy` headless
   CLI behavior locally with fixtures, then decides whether the rows above can be implemented. It
   must prove executable discovery/fail-closed behavior, cwd/session/continuation,
   completion/error/input semantics, bounded timeout behavior, event/usage availability, and
   process cancellation before proposing an adapter.
3. **JARVIS-907 adapter integration waits for both JARVIS-910 and JARVIS-901:** only then may a
   candidate use the closed change budget and focused deterministic adapter tests.
4. Only after those deterministic gates: run a separately authorized, disposable live acceptance
   profile and report it as such.

Unresolved limits are intentional: no validated `agy` protocol/version pin, no native tool or
permission mapping, no remote-host behavior, no live canary, no production-readiness claim, and no
evidence that a tracker bridge or receipt store is necessary. These limits block implementation
claims; they do not expand the adapter budget.
