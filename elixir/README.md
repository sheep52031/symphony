# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches the selected execution backend inside the workspace (Codex app-server by default)
4. Sends the backend a workflow prompt
5. Keeps the selected agent working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

`agent.backend` defaults to `codex`. Set it to `pi` only when PiAgent is installed on the same
local worker. The Pi backend is local-worker-only and runs its command through non-interactive,
non-login `bash -c`; on Windows, run Symphony and Pi inside the same WSL2 environment. On macOS, prefer a
host-specific absolute Pi launcher when interactive shell PATH entries are not inherited. For Pi,
Symphony uses Pi's native RPC/session lifecycle only: it does not inject tracker tools, a loopback
bridge, or a host-side handoff into Pi. Configured tracker credential environment names are removed
from the Pi child, while tracker polling and lifecycle mutations remain owned by Symphony.

Set `agent.backend` to `antigravity` only on the accepted native Linux route. It is a local-only,
opt-in backend that speaks AntiGravity's native NDJSON protocol. It requires absolute paths for the
`agy` executable and one explicit profile root. Symphony launches it through a mandatory
Bubblewrap boundary: host root is read-only, the real user home and host `/run/user` are masked,
only the issue workspace and selected profile root are host-writable, the exact AGY executable is
projected read-only at a private path, `XDG_RUNTIME_DIR` is private, `.symphony` runtime metadata is
read-only to the child, and native `--sandbox` remains enabled. Missing containment, a non-`request-review` permission mode, identity drift, non-cumulative
usage, or permission/input denial fails visibly. Codex remains the default and rollback path; Pi
remains supported.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  backend: codex
  max_concurrent_agents: 10
  max_turns: 20
  # Optional canary controls; omit all three to preserve current scheduler behavior.
  allowed_issue_identifiers: ["JARVIS-917"]
  hold_after_normal_completion: true
  max_attempts_per_issue: 1
  stall_timeout_ms: 300000
pi:
  command: pi --mode rpc
  request_timeout_ms: 5000
  first_event_timeout_ms: 5000
  turn_timeout_ms: 3600000
  post_result_timeout_ms: 5000
antigravity:
  executable: $ANTIGRAVITY_EXECUTABLE
  profile_root: $ANTIGRAVITY_PROFILE_ROOT
  first_event_timeout_ms: 30000
  turn_timeout_ms: 3600000
  cancel_grace_ms: 1000
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `pi.command` defaults to `pi --mode rpc`. The command must resolve from non-interactive,
  non-login `bash -c`; shell startup files cannot reintroduce scrubbed tracker credentials.
  Symphony does not pass `--provider`, `--model`, or `--thinking`: Pi inherits the
  operator's active `PI_CODING_AGENT_DIR` (or Pi's normal user profile) and therefore uses the same
  saved default model as an operator-opened Pi terminal. Symphony records the effective model and
  thinking level returned by `get_state`, and keeps only the worker session in a workspace-owned
  `0700` `.symphony/pi-session` directory. Extensions, skills, themes, prompt templates, and
  context files are disabled. The selected Pi profile contains Pi's own authentication; use a dedicated WSL2 user/profile and
  do not store unrelated controller secrets in it.
- Pi SSH workers are rejected in this first slice rather than being silently treated as supported.
- Pi lifecycle deadlines are absolute, not reset by protocol chatter:
  - `pi.request_timeout_ms` bounds ordinary RPC requests and abort acknowledgement.
  - `pi.first_event_timeout_ms` bounds the first valid response or event after a request is sent.
  - `pi.turn_timeout_ms` bounds the entire provider turn through authoritative `agent_settled`.
  - `pi.post_result_timeout_ms` is one shared budget for assistant-text and usage reads after settlement.
  On timeout Symphony sends a bounded native abort. On hosts with `setsid`, session shutdown then
  terminates the dedicated Pi process group, including descendants; other hosts retain bounded
  direct-child shutdown. The Pi fields fall back to the compatible Codex read/turn defaults when omitted.
- `antigravity.executable` and `antigravity.profile_root` are required absolute paths when the
  AntiGravity backend is selected. The executable must be outside both writable roots. The profile
  root must be a dedicated directory: `/`, top-level or security-sensitive host trees (including
  `/bin`, `/etc`, and `/usr`), broad aggregate roots such as `/var`, the real user home or its
  ancestors, and roots overlapping the issue workspace are rejected. Specific descendants of the
  canonical home, private temporary roots, or dedicated roots such as `/var/lib/agy-profile`
  remain supported. Under the canonical home, `profile_root` uses exactly
  `~/.agy-profiles/<slot>`, while the issue workspace uses a non-hidden,
  non-credential/configuration path at least two components below home; each role rejects the
  other's home shape. Symphony does not
  rotate profiles or fall back to another backend.
  AntiGravity SSH workers are rejected.
- AntiGravity requires `/usr/bin/bwrap`. It runs with `--unshare-all --share-net --unshare-user
  --disable-userns`, read-only `/`, private `/dev`, `/proc`, `/tmp`, and `/run/user`, and masks the
  canonical real user home with a private tmpfs unless a broader private tmpfs already contains it.
  Unrelated host-home contents, including host Git credentials, are unavailable. The selected profile
  is the sole intentional credential-bearing exception and the only dedicated explicit read-write
  host root besides the issue workspace. A single read-only bind projects the exact AGY executable
  to a fixed private `/tmp` path; its installation directory is not separately bound, and a source
  beneath the masked home remains hidden. The private mode-`0700` `XDG_RUNTIME_DIR` has no host
  session D-Bus address, and the native process also receives
  `--sandbox --mode accept-edits`; Symphony never adds `--add-dir`, `unsandboxed(...)`, or
  `--dangerously-skip-permissions`. Trusted host wrappers are addressed under `/usr/bin`; tracker
  credential names are removed before launch and the sandboxed child receives a small allowlisted
  environment. Symlinked runtime metadata directories are rejected, metadata is read-only to the
  child, and transient stderr/process-group files are removed during bounded shutdown.
- `antigravity.first_event_timeout_ms` and `antigravity.turn_timeout_ms` are absolute from prompt
  submission; protocol chatter cannot extend them. On timeout Symphony records local cancellation,
  sends bounded `SIGINT`/`SIGTERM`/`SIGKILL`, and verifies the process group is empty.
  `antigravity.cancel_grace_ms` bounds collection of a native terminal envelope after `SIGINT`.
  Native `denied_actions` and `WAITING` are surfaced as input-required errors rather than silently
  completed turns. Stdout frames are bounded and only reviewed protocol fields are forwarded to
  orchestration callbacks. A requested continuation identity may never become a fresh-session
  fallback.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `agent.stall_timeout_ms` is the provider-neutral watchdog used by the orchestrator. When omitted,
  it falls back to the legacy `codex.stall_timeout_ms`; `0` disables the watchdog. This is separate
  from each adapter's own request and turn deadlines.
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.backend` selects the execution adapter and defaults to `codex`. `pi` and `antigravity`
  are explicit, local-only opt-ins in this fork; configured SSH workers are rejected for both.
- Pi completion waits for the authoritative `agent_settled` event; `agent_end` with `willRetry: false`
  is not treated as final evidence. Pi returns lifecycle outcomes and neutral session/runtime evidence
  only; it does not receive a tracker bridge, host handoff path, or receipt store.
- `agent.max_turns` caps how many back-to-back backend turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.allowed_issue_identifiers` is an optional exact, case-sensitive issue-identifier allowlist.
  When omitted, all otherwise eligible issues remain eligible exactly as before. When present it must
  be a nonempty, unique list with no blank or whitespace-padded values; invalid configuration is
  rejected. Explicit `null` is rejected: omit the key to use the compatible default. The scheduler
  checks it at candidate selection, dispatch refresh, retry/slot reacquisition, continuation, and
  running reconciliation; revocation stops the live task through the existing bounded termination path.
- `agent.hold_after_normal_completion` defaults to `false`. When `true`, a normal AgentRunner exit
  keeps an active issue claimed as a `normal_completion_hold` instead of scheduling the one-second
  continuation retry. Explicit `null` is rejected. Input-required work remains `input_required`;
  holds are reported as `held` with a typed disposition and reason in the API/dashboard, not as errors.
- `agent.max_attempts_per_issue` is an optional positive total AgentRunner/session budget per claimed
  issue; omit it for unlimited compatible behavior. An attempt is reserved immediately before Symphony
  starts an AgentRunner, including a failed start, so the counter is conservative. Before initial
  dispatch and every continuation, failure, stall, retry-poll, refresh, and no-slot retry path,
  exhausted work becomes an `attempt_limit_hold` and no further backend attempt is started. Set `1`
  for at most one AgentRunner/backend session in one runtime. Explicit `null` and non-positive values
  are rejected.
- Failures and stalls continue to retry while budget remains; routing/label revocation, non-active
  states, and cancellation release claims. Human Review is non-terminal unless a workflow explicitly
  includes it in `tracker.terminal_states`; when explicitly terminal, its held workspace is cleaned up.
  Reducing neither setting releases holds; removing the normal-completion hold or removing/increasing
  the attempt budget releases only the affected holds while preserving their consumed attempt counters.
  Therefore disabling normal holds with a limit of `1` re-holds an active issue at the attempt limit,
  while raising `1` to `2` permits exactly one additional session. Holds and counters are in-memory: a
  fresh runtime resets both and requires fresh owner authorization before reuse. Roll back by removing the controls
  (or setting `hold_after_normal_completion: false`); no durable store is created.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if an agent can read that
  workspace. Use `$VAR` so Symphony can keep the token out of the child environment.

- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root`, `antigravity.executable`, and
  `antigravity.profile_root` resolve `$VAR` before path handling, while `codex.command` stays a shell
  command string and any `$VAR` expansion there happens in the launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### JARVIS-917 canary capability matrix

| Category | Behavior |
| --- | --- |
| Preserved | Omitted controls retain the Codex-default, Pi-supported scheduler and normal continuation retry. |
| Added | Exact admission, typed held dispositions, and opt-in per-issue AgentRunner/session budget. |
| Unchanged | Failure/stall retry below budget, input-required blocking, routing/state cleanup, and default Human Review behavior. |
| Out of scope | Tracker bridges, daemons, durable stores, new schedulers, credentials, quotas, dependency upgrades, and remote Pi. |
| Explicitly removed | None; no backend or existing scheduling path was removed. |

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  coding-agent child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
