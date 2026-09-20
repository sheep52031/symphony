# JARVIS-911 advisory and upstream inventory

## Scope and result

Baseline: owner-fork `main` `9a84fd91e8051f7c9268ea98dea80b2327b620f7`
(tree `18db67c1aa0f9dd454aec7690287fb115486e6cc`).

The full resolved Hex graph was checked with `mix hex.audit`. At baseline it reported
one affected package: Mint `1.10.0`, advisory `EEF-CVE-2026-82672` / `CVE-2026-82672`
/ `GHSA-rj5m-69wp-cxq9`, **MEDIUM**, fixed in `1.10.1`. After the lock-only upgrade,
`mix hex.audit` reports `No retired or security advisory packages found`; therefore
there are no remaining lower-severity advisories in the resolved graph.

The current `openai/symphony` `main` examined for this change is
`be10a1b79df723d6d7612b5651c8522704dafb2e`. Its `elixir/mix.exs` declaration set
matches the owner fork, but its lock pins predate the owner-fork security updates
(for example Mint `1.7.1`, Bandit `1.10.3`, Decimal `2.3.0`, HPAX `1.0.3`, Phoenix
`1.8.4`, Plug `1.19.1`, and Req `0.5.17`). It has not adopted Mint `1.10.1`.

## Intake package inventory

| Package | Current pinned version | Advisory / severity / fixed version | Upstream status | Reachability | Chosen action | Recheck condition |
| --- | --- | --- | --- | --- | --- | --- |
| Bandit | `1.12.5` | `GHSA-9q9q-324x-93r2` (**HIGH**, `1.11.1`); related WebSocket/HTTP/2 advisories fixed by `1.12.5` | Upstream lock is `1.10.3`; owner pin already contains the fixes | Inbound HTTP/WebSocket server | Retain current owner pin | Re-audit when Bandit is changed or an advisory affects `>= 1.12.5` |
| Decimal | `3.1.1` | `GHSA-rhv4-8758-jx7v` (**MEDIUM**, `3.0.0`) | Upstream lock is `2.3.0`; owner pin already contains the fix | Used transitively by Ecto/Solid; no new exposure from this change | Retain current owner pin | Re-audit when Decimal/Ecto/Solid constraints change |
| HPAX | `1.0.4` | `EEF-CVE-2026-58226` (**HIGH**, `1.0.4`) | Upstream lock is `1.0.3`; owner pin already contains the fix | Bandit HTTP/2 request parsing | Retain current owner pin | Re-audit when Bandit/HPAX is changed |
| Mint | `1.10.1` | `EEF-CVE-2026-82672` / `CVE-2026-82672` / `GHSA-rj5m-69wp-cxq9` (**MEDIUM**, `1.10.1`) | Upstream lock is `1.7.1`; no Symphony upstream lock fix exists | Req/Finch outbound HTTP; affected parsing is reachable from a malicious upstream response on pooled HTTP/1 connections | **Upgrade lock only** from `1.10.0` to `1.10.1` | Re-audit on every dependency update and when upstream adopts a newer compatible Mint pin |
| Phoenix | `1.8.14` | `GHSA-6983-jfq8-485w` (**HIGH**, `1.8.9`); `GHSA-628h-q48j-jr6q` (**HIGH**, `1.8.6`) | Upstream lock is `1.8.4`; owner pin already contains the fixes | Dashboard/HTTP endpoint | Retain current owner pin | Re-audit when Phoenix is changed |
| Phoenix LiveView | `1.1.33` | `EEF-CVE-2026-64941` (**MEDIUM**, `1.1.33`) | Upstream lock is `1.1.25`; owner pin already contains the fix | Interactive dashboard links; requires attacker-controlled navigation input | Retain current owner pin | Re-audit when LiveView is changed or the dashboard adds user-controlled links |
| Plug | `1.20.3` | `GHSA-468c-vq7p-gh64` (**HIGH**, `1.19.2`); multipart/cookie fixes through `1.20.3` | Upstream lock is `1.19.1`; owner pin already contains the fixes | Inbound request/query/multipart parsing | Retain current owner pin | Re-audit when Plug/Bandit/Phoenix is changed |
| Req | `0.7.4` | `GHSA-655f-mp8p-96gv` (**HIGH**, `0.6.1`); `GHSA-px9f-whj3-246m` (**MEDIUM**, `0.6.0`) | Upstream lock is `0.5.17`; owner pin already contains the fixes | Outbound requests to configured tracker/provider APIs | Retain current owner pin | Re-audit when Req/Finch is changed or new outbound endpoints are added |

## Source evidence

- Hex resolver/audit: `mise exec -- mix deps.get` and `mise exec -- mix hex.audit`.
  Baseline audit named Mint `1.10.0` and its advisory; post-upgrade audit was clean.
- Hex package releases: <https://hex.pm/packages/mint> (Mint `1.10.1` is the fixed
  released version), plus the corresponding Hex package pages for the intake packages.
- GitHub Security Advisories: <https://github.com/advisories/GHSA-9q9q-324x-93r2>,
  <https://github.com/advisories/GHSA-rhv4-8758-jx7v>,
  <https://github.com/advisories/GHSA-6983-jfq8-485w>,
  <https://github.com/advisories/GHSA-628h-q48j-jr6q>,
  <https://github.com/advisories/GHSA-468c-vq7p-gh64>,
  <https://github.com/advisories/GHSA-655f-mp8p-96gv>, and
  <https://github.com/advisories/GHSA-px9f-whj3-246m>.
- OSV records: <https://osv.dev/vulnerability/EEF-CVE-2026-82672> and
  <https://osv.dev/vulnerability/EEF-CVE-2026-58226>.
- Upstream comparison: `openai/symphony` `main`
  `be10a1b79df723d6d7612b5651c8522704dafb2e`,
  `elixir/mix.exs` and `elixir/mix.lock`.

No declaration changed because Finch's existing `~> 1.8` Mint constraint already
permits `1.10.1`. The sole fork-only change is necessary because upstream Symphony
has not yet updated its lockfile, while the fixed package release is compatible.
