# JARVIS-911 advisory and upstream inventory

## Scope and result

This inventory records **31 distinct advisory records** in scope for the historical
intake graph: 30 historical/fixed records and the one advisory active at the exact
baseline. A GitHub GHSA and its OSV `EEF-CVE-*` alias are one record and are shown in
the same row, not counted twice.

The historical intake pins are the versions in the `openai/symphony` `main` lock at
`be10a1b79df723d6d7612b5651c8522704dafb2e`:

| Package | Historical intake pin | Exact owner-fork baseline pin | Exact audited dependency-change head pin |
| --- | ---: | ---: | ---: |
| Bandit | `1.10.3` | `1.12.5` | `1.12.5` |
| Decimal | `2.3.0` | `3.1.1` | `3.1.1` |
| HPAX | `1.0.3` | `1.0.4` | `1.0.4` |
| Mint | `1.7.1` | `1.10.0` | `1.10.1` |
| Phoenix | `1.8.4` | `1.8.14` | `1.8.14` |
| Phoenix LiveView | `1.1.25` | `1.1.33` | `1.1.33` |
| Plug | `1.19.1` | `1.20.3` | `1.20.3` |
| Req | `0.5.17` | `0.7.4` | `0.7.4` |

The baseline is commit `9a84fd91e8051f7c9268ea98dea80b2327b620f7`, tree
`18db67c1aa0f9dd454aec7690287fb115486e6cc`. Its exact audit has one active finding:
Mint `1.10.0`, **MEDIUM**, `EEF-CVE-2026-82672` / `CVE-2026-82672` /
`GHSA-rj5m-69wp-cxq9`, fixed in `1.10.1`. The audited dependency-change head is
commit `59979b7b03b7f953709f2e01c404879b98cc6008`, tree
`2aa67bb98a606cedbfa2f31e58b9b2b75a874c77`; its exact audit is clean. The current
documentation head is commit `798386fae31597f9ca7952822de5c6bff625914b`, tree
`2caad71a3e94d942eceb0c64d01813242d427c11`. Both heads share the exact
`elixir/mix.lock` blob `344d6760961d826665f4466c4760fbfdd8df1201`; this follow-up
only changes documentation, so no audit rerun is needed.

## Historical fixed inventory

Every row below is explicit about the historical affected pin, fixed release, current
status, reachability, upstream comparison, action, and recheck condition. “Upstream
status” refers to the `openai/symphony` lock at the commit above; “current graph”
refers to the owner-fork audited dependency-change head.

| Package | Advisory ID(s) | Severity | Affected / historical pin | Fixed version | Current status | Reachability in Symphony | Upstream status | Action | Recheck condition | Direct citation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bandit | `GHSA-9q9q-324x-93r2` / `EEF-CVE-2026-39803` / `CVE-2026-39803` | HIGH | `1.10.3` (`>=1.4.0,<1.11.1`) | `1.11.1` | Fixed; current `1.12.5` | Inbound HTTP/1 chunked request bodies | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-9q9q-324x-93r2) |
| Bandit | `GHSA-rf5q-vwxw-gmrf` / `EEF-CVE-2026-39806` / `CVE-2026-39806` | HIGH | `1.10.3` (`>=1.6.0,<1.11.1`) | `1.11.1` | Fixed; current `1.12.5` | Inbound HTTP/1 chunked trailers | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-rf5q-vwxw-gmrf) |
| Bandit | `GHSA-pf94-94m9-536p` / `EEF-CVE-2026-42786` / `CVE-2026-42786` | HIGH | `1.10.3` (`>=0.5.0,<1.11.0`) | `1.11.0` | Fixed; current `1.12.5` | Inbound WebSocket continuation-frame reassembly | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-pf94-94m9-536p) |
| Bandit | `GHSA-frh3-6pv6-rc8j` / `EEF-CVE-2026-39804` / `CVE-2026-39804` | HIGH | `1.10.3` (`>=0.5.8,<1.11.0`) | `1.11.0` | Fixed; current `1.12.5` | Inbound WebSocket per-message deflate | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-frh3-6pv6-rc8j) |
| Bandit | `GHSA-375f-4r2h-f99j` / `EEF-CVE-2026-39807` / `CVE-2026-39807` | MEDIUM | `1.10.3` (`>=1.0.0,<1.11.0`) | `1.11.0` | Fixed; current `1.12.5` | Inbound HTTP/1 URI scheme and transport handling | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-375f-4r2h-f99j) |
| Bandit | `GHSA-c67r-gc9j-2qf7` / `EEF-CVE-2026-39805` / `CVE-2026-39805` | MEDIUM | `1.10.3` (`<1.11.0`) | `1.11.0` | Fixed; current `1.12.5` | Inbound HTTP/1 duplicate `Content-Length` parsing | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-c67r-gc9j-2qf7) |
| Bandit | `GHSA-q6v9-r226-v65f` / `EEF-CVE-2026-42788` / `CVE-2026-42788` | MEDIUM | `1.10.3` (`>=0.3.5,<1.11.0`) | `1.11.0` | Fixed; current `1.12.5` | Inbound HTTP/2 frame-size and body buffering | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [GitHub Advisory](https://github.com/advisories/GHSA-q6v9-r226-v65f) |
| Bandit | `EEF-CVE-2026-74836` / `GHSA-xj8g-532w-jv94` | HIGH | `1.10.3` (`>=0.3.4,<1.12.5`) | `1.12.5` | Fixed; current `1.12.5` | Inbound HTTP/2 flow-control stream processes | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-74836) |
| Bandit | `EEF-CVE-2026-75484` / `GHSA-x3gh-xhj4-3vq8` | MEDIUM | `1.10.3` (`>=1.4.0,<1.12.5`) | `1.12.5` | Fixed; current `1.12.5` | Inbound HTTP/2 header-value validation | Upstream `1.10.3` remains affected | Retain `1.12.5`; no runtime change | Re-audit on Bandit change or new advisory | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-75484) |
| Decimal | `GHSA-rhv4-8758-jx7v` / `EEF-CVE-2026-32686` / `CVE-2026-32686` | MEDIUM (GitHub; MODERATE in OSV) | `2.3.0` (`>=0.1.0,<3.0.0`) | `3.0.0` | Fixed; current `3.1.1` | Transitive Ecto/Solid decimal parsing; no new input path | Upstream `2.3.0` remains affected | Retain `3.1.1`; no runtime change | Re-audit when Decimal, Ecto, or Solid changes | [GitHub Advisory](https://github.com/advisories/GHSA-rhv4-8758-jx7v) |
| HPAX | `EEF-CVE-2026-58226` / `GHSA-jj2p-32j7-whj2` | HIGH | `1.0.3` (`>=0.1.1,<1.0.4`) | `1.0.4` | Fixed; current `1.0.4` | Bandit HTTP/2 HPACK integer decoding | Upstream `1.0.3` remains affected | Retain `1.0.4`; no runtime change | Re-audit when HPAX or Bandit changes | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-58226) |
| Mint | `GHSA-2pg6-44cx-c49v` / `EEF-CVE-2026-48861` / `CVE-2026-48861` | LOW | `1.7.1` (`>=0.1.0,<1.9.0`) | `1.9.0` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 request encoding only if method/target is attacker-controlled | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-48861) |
| Mint | `GHSA-g586-ccqf-7x4r` / `EEF-CVE-2026-48862` / `CVE-2026-48862` | HIGH | `1.7.1` (`>=0.2.0,<1.9.0`) | `1.9.0` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/2 PUSH_PROMISE parsing via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [GitHub Advisory](https://github.com/advisories/GHSA-g586-ccqf-7x4r) |
| Mint | `GHSA-mjqx-c6f6-7rc2` / `EEF-CVE-2026-49753` / `CVE-2026-49753` | MEDIUM | `1.7.1` (`>=0.1.0,<1.9.0`) | `1.9.0` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 response Content-Length parsing via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-49753) |
| Mint | `GHSA-2p26-p43x-fhp8` / `EEF-CVE-2026-49754` / `CVE-2026-49754` | HIGH | `1.7.1` (`<1.9.0`) | `1.9.0` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/2 CONTINUATION/HEADERS parsing via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [GitHub Advisory](https://github.com/advisories/GHSA-2p26-p43x-fhp8) |
| Mint | `GHSA-c59h-fq4p-r36r` / `EEF-CVE-2026-56810` / `CVE-2026-56810` | HIGH | `1.7.1` (`>=0.5.0,<1.9.1`) | `1.9.1` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 chunked response buffering via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-56810) |
| Mint | `GHSA-qrfr-wh4c-3qhw` / `EEF-CVE-2026-58229` / `CVE-2026-58229` | HIGH | `1.7.1` (`>=0.1.0,<1.9.2`) | `1.9.2` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 response-header and chunked-trailer buffering via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-58229) |
| Mint | `GHSA-8pf6-g464-h6h9` / `EEF-CVE-2026-59246` / `CVE-2026-59246` | MEDIUM | `1.7.1` (`>=0.1.0,<1.9.2`) | `1.9.2` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/2 zero-length CONTINUATION parsing via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-59246) |
| Mint | `GHSA-x3x7-96vm-6h2w` / `EEF-CVE-2026-59249` / `CVE-2026-59249` | MEDIUM | `1.7.1` (`>=0.1.0,<1.9.3`) | `1.9.3` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 chunk-size parsing via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-59249) |
| Mint | `GHSA-g83f-2j6r-q6m4` / `EEF-CVE-2026-82728` / `CVE-2026-82728` | HIGH | `1.7.1` (`>=0.1.0,<1.10.0`) | `1.10.0` | Fixed before baseline; baseline `1.10.0` and head `1.10.1` are fixed | Outbound Mint HTTP/1 status-line and chunk-extension buffering via Finch/Req | Upstream `1.7.1` remains affected | Retain the current fixed pins | Re-audit on Mint/Finch/Req change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-82728) |
| Phoenix | `GHSA-6983-jfq8-485w` / `EEF-CVE-2026-56811` / `CVE-2026-56811` | HIGH | `1.8.4` (`>=1.8.0-rc.0,<1.8.9`) | `1.8.9` | Fixed; current `1.8.14` | Dashboard Phoenix transports if LongPoll/WebSocket is exposed | Upstream `1.8.4` remains affected | Retain `1.8.14`; no runtime change | Re-audit when Phoenix or transport exposure changes | [GitHub Advisory](https://github.com/advisories/GHSA-6983-jfq8-485w) |
| Phoenix | `GHSA-628h-q48j-jr6q` / `EEF-CVE-2026-32689` / `CVE-2026-32689` | HIGH | `1.8.4` (`>=1.8.0,<1.8.6`) | `1.8.6` | Fixed; current `1.8.14` | Dashboard LongPoll NDJSON handling | Upstream `1.8.4` remains affected | Retain `1.8.14`; no runtime change | Re-audit when Phoenix or transport exposure changes | [GitHub Advisory](https://github.com/advisories/GHSA-628h-q48j-jr6q) |
| Phoenix | `GHSA-63mc-hw7g-86rr` / `EEF-CVE-2026-56812` / `CVE-2026-56812` | MEDIUM | `1.8.4` (`>=1.8.0-rc.0,<1.8.9`) | `1.8.9` | Fixed; current `1.8.14` | Phoenix JavaScript presence-key handling; Symphony does not use presence state | Upstream `1.8.4` remains affected | Retain `1.8.14`; no runtime change | Re-audit when Phoenix or dashboard client behavior changes | [GitHub Advisory](https://github.com/advisories/GHSA-63mc-hw7g-86rr) |
| Phoenix LiveView | `EEF-CVE-2026-64941` / `GHSA-36m4-rm57-3prf` | LOW | `1.1.25` (`>=1.1.0-rc.0,<1.1.33`) | `1.1.33` | Fixed; current `1.1.33` | Dashboard links; requires attacker-controlled navigation target | Upstream `1.1.25` remains affected | Retain `1.1.33`; no runtime change | Re-audit when LiveView or user-controlled links change | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-64941) |
| Plug | `GHSA-468c-vq7p-gh64` / `EEF-CVE-2026-8468` / `CVE-2026-8468` | HIGH | `1.19.1` (`>=1.19.0,<1.19.2`) | `1.19.2` | Fixed; current `1.20.3` | Inbound multipart header parsing | Upstream `1.19.1` remains affected | Retain `1.20.3`; no runtime change | Re-audit when Plug, Bandit, or Phoenix changes | [GitHub Advisory](https://github.com/advisories/GHSA-468c-vq7p-gh64) |
| Plug | `EEF-CVE-2026-54892` / `GHSA-j43x-5hjq-rgxf` | HIGH | `1.19.1` (`>=1.19.0,<1.19.3`) | `1.19.3` | Fixed; current `1.20.3` | Inbound nested query and URL-encoded body parsing | Upstream `1.19.1` remains affected | Retain `1.20.3`; no runtime change | Re-audit when Plug, Bandit, or Phoenix changes | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-54892) |
| Plug | `EEF-CVE-2026-56813` / `GHSA-wpmj-jh88-rpgm` | LOW | `1.19.1` (`>=1.19.0,<1.19.5`) | `1.19.5` | Fixed; current `1.20.3` | Cookie encoding only if attacker controls cookie attributes | Upstream `1.19.1` remains affected | Retain `1.20.3`; no runtime change | Re-audit when Plug or cookie handling changes | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-56813) |
| Plug | `EEF-CVE-2026-56814` / `GHSA-95qv-c9g9-rm63` | MEDIUM | `1.19.1` (`>=1.19.0,<1.19.5`) | `1.19.5` | Fixed; current `1.20.3` | Inbound multipart part headers and temporary files | Upstream `1.19.1` remains affected | Retain `1.20.3`; no runtime change | Re-audit when Plug, Bandit, or Phoenix changes | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-56814) |
| Req | `GHSA-655f-mp8p-96gv` / `EEF-CVE-2026-49755` / `CVE-2026-49755` | HIGH | `0.5.17` (`>=0.1.0,<0.6.1`) | `0.6.1` | Fixed; current `0.7.4` | Outbound response decoding from configured tracker/provider URLs | Upstream `0.5.17` remains affected | Retain `0.7.4`; no runtime change | Re-audit when Req/Finch or outbound endpoints change | [GitHub Advisory](https://github.com/advisories/GHSA-655f-mp8p-96gv) |
| Req | `GHSA-px9f-whj3-246m` / `EEF-CVE-2026-49756` / `CVE-2026-49756` | MEDIUM (GitHub; MODERATE in OSV) | `0.5.17` (`>=0.5.3,<0.6.0`) | `0.6.0` | Fixed; current `0.7.4` | Outbound multipart encoding only if part metadata is attacker-controlled | Upstream `0.5.17` remains affected | Retain `0.7.4`; no runtime change | Re-audit when Req/Finch or multipart use changes | [GitHub Advisory](https://github.com/advisories/GHSA-px9f-whj3-246m) |

## Sole baseline-active finding

| Package | Advisory ID(s) | Severity | Affected / baseline pin | Fixed version | Current status | Reachability in Symphony | Upstream status | Action | Recheck condition | Direct citation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mint | `EEF-CVE-2026-82672` / `CVE-2026-82672` / `GHSA-rj5m-69wp-cxq9` | MEDIUM | `1.10.0` (`>=0.1.0,<1.10.1`) | `1.10.1` | **Baseline-active; fixed at audited dependency-change head `1.10.1`** | Req/Finch outbound HTTP; a malicious upstream response can reach pooled HTTP/1 parsing | Upstream `1.7.1` remains affected; no upstream lock fix | **Lock-only upgrade `1.10.0` → `1.10.1`**; no declaration or runtime change | Re-run `mix hex.audit` for every dependency update and when upstream adopts a newer Mint pin | [OSV](https://osv.dev/vulnerability/EEF-CVE-2026-82672) |

## Durable exact audit evidence

The command was run in native WSL from the exact detached baseline worktree and exact
audited dependency-change head worktree. The checked-in files contain the source
commit/tree, UTC timestamp,
exit status, tool versions, and unmodified command output. Paths are deliberately
redacted inside the evidence files.

- Baseline `9a84fd91` (expected finding, exit `1`):
  [`docs/security-evidence/JARVIS-911-baseline-9a84fd91-hex-audit.txt`](security-evidence/JARVIS-911-baseline-9a84fd91-hex-audit.txt)
- Audited dependency-change head `59979b7` (clean, exit `0`):
  [`docs/security-evidence/JARVIS-911-audited-dependency-change-head-59979b7-hex-audit.txt`](security-evidence/JARVIS-911-audited-dependency-change-head-59979b7-hex-audit.txt)

Evidence SHA-256 values are recorded here after the files are finalized:

- `JARVIS-911-baseline-9a84fd91-hex-audit.txt`: `24f64bb37fedb0c628e2efe91fc22fb1f1c346b8dbf2f2e1d28992c076256126`
- `JARVIS-911-audited-dependency-change-head-59979b7-hex-audit.txt`: `8fd95a05dfeaf585650548f0a2757be04118bb008e69e1f63add283f79922e69`

## Primary metadata and citations

The advisory rows were independently checked against the primary GitHub Advisory API
for GHSA records, OSV records for `EEF-CVE-*` records, and Hex package metadata. OSV
package/version queries used ecosystem `Hex` and the historical intake pins above;
OSV aliases are shown alongside their GHSA record where both identify the same issue.
Hex release pages used to verify the package pins and fixed releases:

- [Bandit](https://hex.pm/packages/bandit), [Decimal](https://hex.pm/packages/decimal),
  [HPAX](https://hex.pm/packages/hpax), [Mint](https://hex.pm/packages/mint)
- [Phoenix](https://hex.pm/packages/phoenix),
  [Phoenix LiveView](https://hex.pm/packages/phoenix_live_view),
  [Plug](https://hex.pm/packages/plug), [Req](https://hex.pm/packages/req)

The upstream comparison is limited to the lock/declaration metadata at
`openai/symphony` `main` commit `be10a1b79df723d6d7612b5651c8522704dafb2e`.
No runtime source, dependency declaration, scheduler/backend/tracker/workspace/provider
behavior, or live runtime was changed. The only dependency change is the existing
`elixir/mix.lock` Mint `1.10.0` → `1.10.1` entry.
