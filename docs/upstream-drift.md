# Upstream drift 清單（fork `main` vs `openai/symphony`）

JARVIS-3794（S5）。母票 JARVIS-3789。本文件只記錄現況，不改任何行為。S2、S3 的 PR 必須引用本文件第 4 節（禁區）。

基準（2026-10-22 量測）：

| 項目 | 值 |
| --- | --- |
| fork `main` | `c303807`（origin = `sheep52031/symphony`） |
| `upstream/main` | `be10a1b`（2026-09-15，`ci: publish nightly binaries on main pushes`） |
| merge-base | `be10a1b`，與 `upstream/main` 相同，也就是 fork 已含 upstream 全部 commit |
| fork 領先 / 落後 | 領先 104 commits（merge commit 33 個，非 merge 71 個）／落後 0 |
| 總 diff | 92 files changed, +15190, −370（`git diff --stat upstream/main...main`） |

重現指令見第 5 節。

## 1. 三組清單與行數

分組規則：

- **A 後端新增**：`lib/symphony_elixir/{claude,deepseek,pi,antigravity}/`、`agent_backend.ex`，加上這些後端專屬的測試。全是新增檔案，沒有刪除，可獨立成 commit 群。
- **B 核心**：`orchestrator.ex`、`config.ex`、`config/schema.ex`、`agent_runner.ex`、`workspace.ex`、`linear/client.ex`（`router.ex` 在 fork 與 upstream 之間沒有任何差異，不在清單內）。
- **C 其他**：核心以外的 lib 小改動、測試、docs、CI、其他雜項。

行數是 `git diff --numstat` 的 insertions／deletions。四個 `.github/workflows/*.yml` 被改名到 `.github/workflow-archive/2026-09-26/`，git 以 rename 計算（0 行），所以 E 不含這 4 個檔案的 272 行。

| 組 | 子組 | 檔數 | +行 | −行 |
| --- | --- | ---: | ---: | ---: |
| A 後端新增 | A1 lib（後端模組與 `agent_backend.ex`） | 11 | 3544 | 0 |
| | A2 後端專屬測試 | 9 | 3526 | 0 |
| B 核心 | `orchestrator.ex`、`config.ex`、`config/schema.ex`、`agent_runner.ex`、`workspace.ex`、`linear/client.ex` | 6 | 1416 | 227 |
| C 其他 | C1 其他 lib（小改動，見 1.3） | 7 | 201 | 25 |
| | C2 其他測試與測試支援 | 20 | 1549 | 56 |
| | C3 docs 與 spike 證據（`docs/spikes/JARVIS-901-agy/` 18 檔） | 18 | 4115 | 0 |
| | C4 其他 docs（`SPEC.md`、`README.md`、`elixir/README.md`、`elixir/WORKFLOW.md`、`docs/*.md`、`docs/security-evidence/`） | 9 | 762 | 25 |
| | C5 CI 與雜項（`.codex/skills`、`.gitignore`、`.gitattributes`、`mix.exs`、`mix.lock`、`.github` 改名） | 12（另有 4 個改名） | 77 | 37 |
| **合計** | | **92** | **15190** | **370** |

核心與後端新增的比例：A 約 7,070 行（47%，其中測試約一半），B 約 1,643 行（11%）。回上游的風險集中在 B。

### 1.1 A 後端新增（逐檔）

| 檔案 | +行 | 來源 commit 群 |
| --- | ---: | --- |
| `agent_backend.ex` | 112 | `d80411f` centralize backend resolution；`c303807` 加 DeepSeek（1 行） |
| `pi/backend.ex` | 446 | `0a8f663`、`9e941b0`、`475463b`、`d11bbb7`、`39e24c1`、`c594fa5`、`63e7ff7`、`b58da99` |
| `pi/rpc.ex` | 594 | 同上（Pi 群） |
| `antigravity/{backend,launcher,transport}.ex` | 264 + 364 + 744 | `ac64103` 起，`a914803`…`337b151`、`48205b5`、`11cfbe6`、`ec18883`、`eb12829`、`29561d5`、`d1fb109` |
| `claude/{backend,stream,final_text}.ex` | 153 + 332 + 87 | `84dd8d7`、`46f606d`、`a543a81`、`88ec332`、`60990ad`、`603055f` |
| `deepseek/{backend,stream}.ex` | 160 + 288 | `c303807`（PR #38） |

後端測試（A2）：`test/claude/`（944 + fixture）、`test/deepseek/`（391 + fixture）、`antigravity_backend_test.exs`（890）、`pi_backend_test.exs`（492）、`pi_rpc_test.exs`（413）、`pi_concurrency_test.exs`（235）、`agent_backend_contract_test.exs`（144）。

### 1.2 B 核心（逐檔）

| 檔案 | +行 | −行 |
| --- | ---: | ---: |
| `orchestrator.ex` | 722 | 84 |
| `config/schema.ex` | 336 | 75 |
| `agent_runner.ex` | 156 | 45 |
| `config.ex` | 146 | 2 |
| `linear/client.ex` | 45 | 1 |
| `workspace.ex` | 11 | 20 |

### 1.3 C1 其他 lib（逐檔）

| 檔案 | +/− | 目的 | commit |
| --- | --- | --- | --- |
| `codex/app_server.ex` | +33/−2 | 實作 `AgentBackend` behaviour；擴充 host auth 環境變數清除清單 | `0a8f663`、`c594fa5`、`50ea9a9` |
| `process_session.ex` | +37/−0（新檔） | `setsid`／perl 的可攜行程群組前綴，後端共用 | `1c85fd1` |
| `status_dashboard.ex` | +18/−0 | 顯示 holds 計數與 `turn_completed` 的完整文字 | `52c4847`、`60990ad` |
| `tracker/issue.ex` | +9/−4 | `routable?/3` 加 `excluded_labels`（`/2` 仍保留） | `bacd603`、`33a6a9b` |
| `workflow.ex` | +1/−1 | 以 unicode 模式切行，CJK 文字不壞 | `1f63655` |
| `symphony_elixir_web/presenter.ex` | +52/−18 | 輸出 backend、holds、disposition | `52c4847`、`10a5df6`、`d55330b` |
| `symphony_elixir_web/live/dashboard_live.ex` | +51/−0 | held 的獨立顯示 | `10a5df6` |

## 2. 核心 hunk 表

「旗標狀態」欄的意思：

- **有旗標**：預設值等於 upstream 行為，設定後才改變行為。
- **預設無害**：沒有旗標，但設定省略時程式路徑的結果與 upstream 相同。
- **無旗標**：無條件改變行為，是回上游時要先處理的項目。

行號是 `c303807` 的 `orchestrator.ex` 行號，之後會漂移，請以函式名稱為準。

### 2.1 `orchestrator.ex`（+722/−84）

| # | 區段（函式） | 目的 | 旗標狀態 | 能否改成旗標或獨立模組 | commit |
| --- | --- | --- | --- | --- | --- |
| O1 | `handle_agent_down(:normal …)`（212） | 正常完成後可改為 hold 而不是排 continuation retry；`block_issue_from_entry` 多了 `reason`、`disposition` 參數 | 有旗標：`agent.hold_after_normal_completion`（預設 `false`） | 已是旗標；`block_issue_from_entry` 的簽名變更是共用基礎，S3 要加的閘門就接在這個 `cond` | `0953040`、`52c4847` |
| O2 | `attempts` 狀態欄位、`reserve_issue_attempt`、`attempt_budget_exhausted?`、`schedule_issue_retry` 前置檢查、`block_issue_from_retry(:attempt_limit_hold)`（961、1433、1460） | 每個 issue 的嘗試預算（`max_attempts_per_issue`） | 預設無害：`agent.max_attempts_per_issue` 為 `nil` 時不限制；但 `attempts` 計數器本身無條件遞增 | 可拆成 `Orchestrator.AttemptBudget`（純函式 + 狀態 map）；計數器可改成只在設定限制時才記 | `52c4847`、`10a5df6` |
| O3 | `terminate_running_issue/4`（710）、`cancellation_reason` 參數 | 讓 stall 的 terminate 保留 attempts，其餘清掉；所有呼叫點都被改成 4 個參數 | 無旗標（內部簽名變更，行為隨 O2） | 若 O2 拆出，這裡可改回 3 個參數 | `cbd69cb`、`52c4847` |
| O4 | `reconcile_stalled_running_issues`、`restart_stalled_issue`（746）改用 `Config.agent_stall_timeout_ms()`，stall retry 帶 backend/host/session metadata | stall 逾時可依後端設定（`agent.stall_timeout_ms`，缺省回退 `codex.stall_timeout_ms`） | 預設無害：缺省時等於 upstream 的 `codex.stall_timeout_ms` | 只剩一行 timeout 來源與 metadata 欄位；metadata 欄位隨 O7 | `c594fa5`、`c303807` |
| O5 | `allowed_issue_identifiers`：`issue_identifier_allowed?` 出現在 reconcile、blocked reconcile、`candidate_issue?`、`spawn_issue_on_worker_host` | 只允許名單內的 issue 識別碼被派工或續跑（圍欄） | 有旗標：`agent.allowed_issue_identifiers`（`nil` = 全允許） | 4 處檢查可收斂成一個 `Orchestrator.Admission` 述詞 | `0953040`、`52c4847` |
| O6 | `writer_conflict?`、`same_nonblank_value?`（1125），掛在 `should_dispatch_issue?` | 同 workspace key 或同 branch name 的 issue 不得同時執行（避免兩個 writer 寫同一目錄） | **無旗標**：無條件 | 可獨立成述詞並加旗標（建議 `agent.writer_conflict_guard`，預設開）；語意是安全性，適合直接當 upstream PR | `d55330b` |
| O7 | issue_backends 路由：`resolve_attempt_backend`、`hold_changed_bound_attempt`、`bound_backend_metadata`、`dispatch_issue` 多 `bound_backend` 參數、`do_dispatch_issue`、`spawn_*` 三層、`handle_active_retry`→`dispatch_active_retry`→`dispatch_active_retry_on_current_host`（1258、1628） | 每個 issue 綁定後端；續跑與重試時若路由或 worker host 變了就 fail-closed hold | 有旗標：`agent.issue_backends`、`agent.issue_backend_routing_enabled`；但 `Config.issue_backend_binding/1` 在每次派工都會跑（預設走 `agent.backend = "codex"`） | `Orchestrator.BackendRouting` 模組可吸收；`dispatch_issue` 的簽名變更仍留在核心 | `d55330b`、`cbd69cb`、`30fb1c6` |
| O8 | `select_worker_host/3`、`issue_worker_slots_available?`、`worker_slots_available?/3`、`worker_hosts_for_backend`（1787） | worker host 選擇改成依後端相容性過濾；刪掉 upstream 的「preferred host 可用就沿用，否則最少負載」邏輯 | **無旗標**：改變了 SSH worker 的選擇語意 | 這是最難還原的一塊：要先加旗標保留 upstream 路徑，或把 upstream 邏輯當成 `:new_attempt` 的 fallback | `cbd69cb`、`30fb1c6` |
| O9 | `running_backend_route_current?`、`revoke_running_backend_route`、`reconcile` 新增 `!issue_identifier_allowed?` 與 `!running_backend_route_current?` 分支（525、660） | 執行中若路由或識別碼被撤銷就停掉 attempt | 預設無害：沒設定 issue_backends 時 `running_backend_route_current?` 為真 | 隨 O7 的 `BackendRouting` 模組 | `d55330b`、`cbd69cb` |
| O10 | `hold_unknown_startup_backend_routes`、`startup_backend_hold_pending?`、`backend_route_unknown_after_restart`（325） | 控制器重啟後無法確認 attempt 綁定的 In Progress issue，一律 hold | 有旗標：只有 `issue_backend_routing_enabled` 或 `issue_backends` 非空時才啟用 | 隨 O7 | `d55330b`、`52c4847` |
| O11 | `block_issue_from_retry` 四個 disposition 子句、`release_config_revoked_holds`、`hold_released_by_config?`（961–1072、2215） | 各種 hold 的 blocked entry 與設定變更時自動釋放 | 隨各自旗標；四個子句幾乎是複製貼上 | 可合併成一個帶 disposition 參數的函式，縮約 80 行 | `0953040`、`52c4847`、`10a5df6`、`d55330b` |
| O12 | `issue_routable?` 改傳 `excluded_labels` | 標籤排除清單 | 有旗標：`tracker.excluded_labels`（預設 `[]`） | 已是旗標；可單獨成 PR | `bacd603` |
| O13 | running／retry／blocked 的 snapshot 欄位（`backend`、`model`、`thinking_level`、`session_file`、`backend_command`、`stderr_path`、`last_assistant_text`）、`assistant_text_for_update`、`backend_for_update`、`direct_token_usage_from_payload`（1946–2130） | 多後端可觀測性：Pi、Claude、DeepSeek 的更新帶這些欄位 | 預設無害：只有後端更新帶這些鍵時才寫入 | 純轉換函式，可搬到 `Orchestrator.RuntimeUpdate` 模組，核心只剩呼叫 | `475463b`、`9e941b0`、`60990ad` |
| O14 | 七個 `*_for_test` 公開函式（約 445–510） | 測試入口 | 預設無害（`@doc false`） | 可搬到 `Orchestrator.TestSupport` | `0953040`、`52c4847`、`d55330b`、`cbd69cb` |
| O15 | 輪詢派工流程（`reconcile_*` 之後的 `with`）：移除 `true <- available_slots(state) > 0`，改成先跑 `hold_unknown_startup_backend_routes` 再判斷名額 | 讓啟動 hold 在沒有名額時也會執行 | 預設無害（O10 未啟用時等價） | 隨 O10 | `d55330b` |

### 2.2 `config/schema.ex`（+336/−75）與 `config.ex`（+146/−2）

| # | 區段 | 目的 | 旗標狀態 | 能否改成旗標或獨立模組 | commit |
| --- | --- | --- | --- | --- | --- |
| C-1 | `Tracker` embed 新增 `excluded_labels`、`reply_wake_states`、`agent_comment_marker` | 標籤排除；Human Review 等狀態在有人回覆後才喚醒 | 有旗標：`excluded_labels` 預設 `[]`、`reply_wake_states` 預設 `[]` | 已是旗標 | `bacd603`、`9e11f17` |
| C-2 | `Agent` embed 新增 `backend`、`issue_backends`、`issue_backend_routing_enabled`、`accepted_antigravity_issue_identifiers`、`allowed_issue_identifiers`、`hold_after_normal_completion`、`max_attempts_per_issue`、`stall_timeout_ms` 與對應 validators | 後端選擇、路由、圍欄、hold、預算、stall | 預設值等於 upstream 行為 | `validate_antigravity_routes` 與 `accepted_antigravity_issue_identifiers` 是 AntiGravity 專屬，應隨 A 組搬到 `antigravity/` 的 changeset | `0953040`、`52c4847`、`d55330b`、`d80411f`、`c594fa5` |
| C-3 | 新 embed `Pi`、`Antigravity` | 後端設定 | 僅在選用該後端時讀 | 已是附加；可與 A 組同一個 commit 群 | `0a8f663`、`ac64103`、`11cfbe6`、`ec18883` |
| C-4 | `parse/1`、`finalize_settings/1` 重構：`finalize_settings` 回傳 `{:ok, _}`、新增 `finalize_tracker_credentials/2`、`validate_safety_settings_not_nil/1` | 禁止把安全設定寫成 `null`；為了加入 antigravity 路徑解析而改寫 | **無旗標**：改了回傳形狀與 `agent.*` 三個欄位的 `null` 處理 | `validate_safety_settings_not_nil` 可獨立；`finalize_settings` 的重構是純機械改動，回上游時單獨一個 commit | `475463b`、`52c4847` |
| C-5 | `codex` embed 的 command 驗證從 `command != "" and trim == ""` 改為 `trim == ""` | 空字串也拒絕 | **無旗標**（細微行為變更） | 一行，可單獨還原或上游化 | `475463b` |
| C-6 | `config.ex`：`issue_identifier_allowed?`、`issue_backend*`、`worker_hosts_for_backend`、`worker_host_binding_current?`、`default_worker_host`、`hold_after_normal_completion?`、`max_attempts_per_issue`、`agent_stall_timeout_ms`；`validate!` 先驗證後端設定 | 上面所有旗標的存取層與驗證 | 隨各旗標 | 可搬到 `Config.Backends`／`Config.Holds` 子模組，`config.ex` 只保留委派 | `0953040`、`52c4847`、`d55330b`、`cbd69cb`、`ac64103`、`c594fa5` |

### 2.3 `agent_runner.ex`（+156/−45）、`workspace.ex`（+11/−20）、`linear/client.ex`（+45/−1）

| # | 區段 | 目的 | 旗標狀態 | 能否改成旗標或獨立模組 | commit |
| --- | --- | --- | --- | --- | --- |
| R-1 | `run/3` 加 `issue_identifier_allowed?` 守門；`run_allowed_issue` | 圍欄在 runner 端再檢查一次 | 有旗標：隨 O5 | 隨 O5 | `0953040` |
| R-2 | `AppServer.*` 直接呼叫改為 `backend.start_session/run_turn/stop_session`，並以 `AgentBackend.validate_*` 驗證回傳；`do_run_codex_turns` 改為 `do_run_agent_turns` 並把 8 個位置參數收成一個 context map | 多後端分派 | 預設無害：`agent.backend` 預設 `"codex"` 走 `Codex.AppServer`（它已實作 behaviour） | 不能完全旗標化；這是 fork 與 upstream 最大的結構差異，上游化時要先上 `AgentBackend` behaviour 本身（A 組）再合這段 | `0a8f663`、`d80411f`、`475463b`、`c594fa5` |
| R-3 | `selected_backend_name`、`requested_backend_name`、`selected_worker_host/2`（回傳 `{:ok, host}`） | 後端與 worker host 綁定檢查 | 隨 O7／O8；`selected_worker_host` 刪掉 upstream 的 preferred/first-host 邏輯 | 同 O8 | `cbd69cb`、`30fb1c6` |
| R-4 | `agent_message_handler` 檢查 update 是否符合後端契約，違反時 `throw` | 後端契約強制 | 無旗標（但只對非 codex 後端有實質作用） | 隨 R-2 | `475463b` |
| R-5 | `continue_with_issue?` 多檢查 `issue_identifier_allowed?`、`excluded_labels` | 續跑時再驗 | 隨旗標 | 隨 O5、O12 | `0953040`、`bacd603` |
| W-1 | `workspace.ex` `remove_issue_workspaces/2`：原本「有 SSH hosts 就只清遠端、沒有才清本機」，改成「一律清本機，再清所有遠端」 | 後端綁定恢復時，本機 workspace 也要清 | **無旗標**：改變清理語意（本機一律清） | 4 行等價改動，可單獨上游化並附測試 | `30fb1c6` |
| L-1 | `linear/client.ex`：GraphQL 加 `comments(first: 5)`；`dispatchable` 加 `awaiting_owner_reply?` | `tracker.reply_wake_states` 內的狀態（例如 Human Review）只在最新留言不是 agent 簽名時才派工 | 有旗標：`tracker.reply_wake_states` 預設 `[]`；但 GraphQL 多拉 5 則留言是無條件的 | 查詢欄位可條件化；其餘是 Linear 專屬，不影響其他 tracker 介面 | `9e11f17` |

### 2.4 upstream 最近 30 commits 是否已實作 fork 的功能

`git log --oneline -30 upstream/main` 的範圍是 `68a18a7`…`be10a1b`（2026-09-15 以前）。fork 的 merge-base 就是 `be10a1b`，所以這 30 個 commit 已全在 fork 裡。檢查結果：

- upstream 的 `lib/` 內搜尋 `max_attempts`、`hold_after`、`backend`、`issue_backends`、`excluded_labels`、`agent_comment_marker`、`allowed_issue`，全部 0 筆。
- 唯一重疊是 `stall_timeout_ms`：upstream 只有 `codex.stall_timeout_ms`（預設 300000），fork 保留它，另加 `agent.stall_timeout_ms` 覆寫（O4、C-2）。fork 沒有刪除或改名 upstream 欄位，也沒有行為衝突。
- upstream 的這幾項與 fork 的改動在同一區域，但各自獨立：`476b2b0 Couple workers to orchestrator runtime`、`0517275 Keep retry dispatch fresh without leaking claims`、`cbd2158 Retry failed workspace setup`、`7cf29df Make terminal workspace cleanup safe`、`54b456b Require opt-in labels for dispatch (#88)`、`7af5a76 Add generic tracker interface (#102)`。fork 的 `excluded_labels`（O12）建立在 `#88` 的 `required_labels` 之上。

結論：**沒有可以直接刪除的 fork 改動**，也沒有可以「改回 upstream 寫法」而不損失 fork 功能的地方。能回收的只有兩類：

1. 與功能無關的重複（O11 四個 `block_issue_from_retry` 子句、O14 測試入口）。
2. 純機械重構（C-4 `finalize_settings`、R-2 的 context map），回上游時要當成獨立 commit，和功能 commit 分開。

注意：upstream 之後若移動（`git fetch upstream` 顯示有新 commit），本節必須重跑；`orchestrator.ex`、`config/schema.ex`、`agent_runner.ex`、`workspace.ex` 是 fork 與 upstream 都會動的檔案，衝突會集中在這四個檔。

## 3. 回上游順序

原則：先上不改既有行為的，再上帶旗標的，最後才處理無旗標且改了語意的。每一步獨立成 PR，PR 之間沒有循環依賴。

1. **第 0 步：保留來源。** 保留 `upstream` remote 與 `NOTICE`、`LICENSE`；不要 rebase、不要 squash fork 歷史。回上游時用 `git cherry-pick` 或對 `upstream/main` 開新分支重做，讓 fork 歷史原樣留著。
2. **第 1 步：獨立的小修正（不碰核心）。** `1f63655` workflow unicode 切行、`1c85fd1` 的 `process_session.ex`（先拆掉與測試穩定化混在一起的部分）、`50ea9a9` 的 host auth 環境變數清除。
3. **第 2 步：`AgentBackend` behaviour 與 `Codex.AppServer` 實作它（A1 的 `agent_backend.ex` + C1 的 `codex/app_server.ex` + R-2 的 `agent_runner.ex`）。** 這是所有後端的前提；`agent.backend` 預設 `"codex"`，行為不變。這一步會動 `agent_runner.ex`，是第一個和 upstream 可能衝突的核心 PR。
4. **第 3 步：後端模組（A1／A2 各後端）。** 每個後端一個 PR：`pi/`、`claude/`、`deepseek/`、`antigravity/`。後端各自附 schema embed（C-3），所以要先確認 `Config.Schema` 的 embed 可以獨立加入，不必依賴 `finalize_settings` 重構（C-4）。這一步不改 `orchestrator.ex`，只增加 `AgentBackend.supported_names/0` 的內容。
5. **第 4 步：已帶旗標、預設無害的核心功能。** 順序：`tracker.excluded_labels`（O12、C-1）→ `agent.stall_timeout_ms`（O4）→ `tracker.reply_wake_states`（L-1，先把 GraphQL 的留言欄位條件化）→ `agent.allowed_issue_identifiers`（O5、R-1、R-5）→ `agent.hold_after_normal_completion`（O1）→ `agent.max_attempts_per_issue`（O2、O3，先改成「只有設定限制才記數」）。每一個都要附單元測試，且預設設定下的既有測試不得變動。
6. **第 5 步：先加旗標再上的無旗標項目。**
   - O6 `writer_conflict?`：加旗標 `agent.writer_conflict_guard`（預設開），單獨 PR。
   - W-1 `workspace.ex`：改動小，附測試單獨 PR；若 upstream 不接受，改成只在綁定後端時才清本機。
   - C-5 空字串 command 驗證：單獨 PR。
   - C-4 `validate_safety_settings_not_nil`：單獨 PR；`finalize_settings` 重構留到最後。
7. **第 6 步：issue_backends 路由與 worker host 綁定（O7–O10、R-3）。** 這是 fork 對 `orchestrator.ex` 最大、最難回上游的一塊（約 400 行，加上 `select_worker_host` 的語意改變 O8）。上游化前先做：把 O8 改成「`agent.issue_backend_routing_enabled` 為假時沿用 upstream 的 preferred-host 選擇」，再把 O7–O10、O11 搬進 `Orchestrator.BackendRouting` 模組，核心只留呼叫點。
8. **第 7 步：觀測欄位（O13、C1 的 status_dashboard／presenter／dashboard_live）。** 在第 3 步後端合併之後；O13 搬到 `Orchestrator.RuntimeUpdate` 再上。
9. **不上游：** C3 的 `docs/spikes/JARVIS-901-agy/`（證據與 spike）、`docs/security-evidence/`、`.github/workflow-archive/`、fork 的 release 版本號（`mix.exs` 0.0.9）、`.codex/skills` 改動、`docs/JARVIS-*`。這些留在 fork。

每一步的驗收：`mix test` 在預設設定下，與 `upstream/main` 的測試結果相同；fork 的 `make all` 通過。

## 4. 禁區（S2、S3、S6 必須遵守）

目標：新的 patch 不能擴大第 2 節那張表的 diff，否則第 3 節的順序會被堵死。

### 4.1 全域規則

1. `orchestrator.ex`、`config/schema.ex`、`config.ex`、`agent_runner.ex`、`workspace.ex`、`linear/client.ex` 的既有區段（第 2 節表格列出的函式）**不得再修改**，除非下面 4.2 或 4.3 明確允許。
2. 新功能一律是：新模組 + 預設關閉的 config 旗標。旗標預設值必須等於「沒有這個功能」的行為，預設設定下既有測試不得變動。
3. 不要新增 `_for_test` 公開函式到 `orchestrator.ex`（O14 已有七個）；測試直接測新模組，或用 fixture。
4. 不要改 `block_issue_from_entry`、`block_issue_from_retry`、`terminate_running_issue`、`schedule_issue_retry` 的簽名（O1–O3、O11）。
5. 不要碰 A 組（後端模組）與 `agent_backend.ex`。新增後端或後端行為不屬於 S2／S3。
6. 不要碰 `.github/workflow-archive/`、`docs/spikes/`、`mix.exs` 版本號。
7. 每個 PR 的 `git diff --stat upstream/main...HEAD -- elixir/lib` 在核心六檔的增量必須寫進 PR body；超出下面允許範圍的 PR 不合併。

### 4.2 S3（閘門 patch）允許動的位置

只允許修改 `orchestrator.ex` 的 **正常完成分支一處**：`handle_agent_down(:normal, state, issue_id, running_entry, session_id)`（目前在 212 行附近）的 `cond`。

- 新增一個 `cond` 子句，放在 `input_required_blocker?/1` 之後、`Config.hold_after_normal_completion?()` 之前（或之後，由 S3 設計，但只能是這個 `cond` 內），以 `Config.verify_gate_enabled?()` 之類的存取器守住，旗標是 **`agent.verify_gate_enabled`**（預設 `false`）。
- 旗標為 `false` 時，這個函式的結果必須與 `c303807` 逐位元相同。
- 閘門本身的邏輯（讀驗證結果、決定是否放行）放在新模組，例如 `SymphonyElixir.VerifyGate`；`orchestrator.ex` 只留一個呼叫與一個 `cond` 子句。
- 閘門失敗時要用現成的 `block_issue_from_entry(state, issue_id, running_entry, reason, disposition)`，沿用既有 hold 機制，不新增 `block_issue_from_retry` 子句。若確實需要新的 disposition，要同時在 `hold_released_by_config?` 加一個子句（O11）並在 PR 裡說明為什麼不能用 `:normal_completion_hold`。
- `agent.verify_gate_enabled` 的 schema 欄位加在 `config/schema.ex` 的 `Agent` embed 的 field 清單、`cast` 清單各一行，加在 `config.ex` 一個 `verify_gate_enabled?/0` 存取器。這三處是除 `orchestrator.ex` 以外唯一允許動的位置，每處不超過 3 行。

S3 不得：修改 `AgentRunner`、`Workspace.run_after_run_hook/3`（S1 的 after_run 驗證是純 config，`after_run` hook 的錯誤目前被吞掉，S3 不能用改 `workspace.ex` 的方式讓它回報；要讀結果請走新模組）。

### 4.3 S2（派工 lint）允許動的位置

- 新模組 `lib/symphony_elixir/dispatch_lint.ex`（及其測試 `test/symphony_elixir/dispatch_lint_test.exs`）。
- 新增 config 旗標 `agent.dispatch_lint_enabled`（預設 `false`，名稱可由 S2 調整，但必須在 `agent` 下且預設關閉）：`config/schema.ex` `Agent` embed 的 field 與 cast 清單各一行、`config.ex` 一個存取器。
- 呼叫點：只能是 `orchestrator.ex` 的 `candidate_issue?`／`should_dispatch_issue?`（第 1107 行附近）已有的述詞鏈**加一個 `and`**，或 `choose_issues` 內加一個 filter。二選一，且僅一處；旗標關閉時必須與現況逐位元相同。
- 若 lint 要在 `agent_runner.ex` 再驗一次，**不允許**；lint 的單一入口在 orchestrator 的派工前。

S2 不得：動 `linear/client.ex`（`awaiting_owner_reply?` 之外的查詢欄位也不行）、動 `Tracker.Issue`、動 `select_worker_host` 與 backend routing（O7–O10）。

### 4.4 禁區區段一覽

| 檔案 | 區段 | S2 | S3 | S6 |
| --- | --- | --- | --- | --- |
| `orchestrator.ex` | `handle_agent_down(:normal …)` 的 `cond` | 禁止 | **允許，一個子句** | **允許，改寫該子句一處**（見 4.5） |
| `orchestrator.ex` | `should_dispatch_issue?`／`choose_issues` | **允許，一處** | 禁止 | **允許，換掉最後一項**（見 4.5） |
| `orchestrator.ex` | O2、O3、O6–O15 其餘所有區段 | 禁止 | 禁止 | 禁止 |
| `config/schema.ex` | `Agent` embed 的 field／cast 清單 | **允許，一個旗標** | **允許，一個旗標** | **允許，三個旗標** |
| `config/schema.ex` | 其餘（validators、`finalize_settings`、`Pi`／`Antigravity` embed） | 禁止 | 禁止 | 禁止 |
| `config.ex` | 新增存取器 | **允許，一個** | **允許，一個** | **允許，三個** |
| `config.ex` | 其餘 | 禁止 | 禁止 | 禁止 |
| `agent_runner.ex`、`workspace.ex`、`linear/client.ex`、`tracker/issue.ex` | 全部 | 禁止 | 禁止 | 禁止 |
| A 組（所有後端與 `agent_backend.ex`） | 全部 | 禁止 | 禁止 | 禁止 |
| 新模組（`dispatch_lint.ex`、`verify_gate.ex`、`state_extras.ex`、`verify_gate_rework.ex` 等） | 新增 | **允許** | **允許** | **允許** |
| `presenter.ex`、`dashboard_live.ex`（C1，不在 4.1 核心清單） | 見 4.5 | — | — | **允許，最小行數** |

S1（`after_run` 驗證腳本，純 config）不動 `lib/`，不受本節約束；若 S1 需要改 `workspace.ex` 的 hook 行為，要先在母票上提出。

### 4.5 S6 允許動的位置

S6（JARVIS-3796）把 S1–S5 已存在的零件接上線：STOP 檔、嘗試欄位、閘門失敗轉 Rework。三項都是旗標，預設 `false`，旗標關閉時行為與 `a78e2e6` 相同。

| 檔案 | 呼叫點 | 預算 |
| --- | --- | --- |
| `orchestrator.ex` | `should_dispatch_issue?` 述詞鏈：把最後一項 `DispatchLint.dispatch_allowed?(issue)` 換成 `DispatchGate.allowed?(issue)`（新模組，先問 STOP 檔再問 lint）。述詞鏈不多一個 `and`，因為 credo 的複雜度上限是 9，加一個 `and` 會超過 | +1／−1 |
| `orchestrator.ex` | `handle_agent_down(:normal …)` 的 S3 子句：把 `VerifyGate.hold_reason(…)` 換成 `VerifyGateRework.hold(…)`，回傳 `{reason, disposition}`，不新增子句 | +3／−2（兩處合計 +4／−3，預算上限 +6／−3） |
| `config/schema.ex` | `Agent` embed 加 `stop_file_enabled`、`attempt_fields_enabled`、`verify_gate_rework_enabled` 三個 field 與 cast 各一行 | +6 |
| `config.ex` | 三個存取器（各含 `@spec`） | +9 |
| `presenter.ex`（C1） | `state_payload` 一個 `Map.merge`；`retry_entry_payload`、`blocked_entry_payload` 各接一個 `StateExtras.put_attempt_fields/2`，邏輯全在 `StateExtras` | +4／−1 |
| `dashboard_live.ex`（C1） | `stopped` 時顯示一個橫幅區塊 | +7 |

新模組：`dispatch_gate.ex`（STOP 檔加 lint 的單一入口）、`state_extras.ex`（`stopped` 與嘗試欄位的投影）、`verify_gate_rework.ex`（失敗時留言、轉 Rework／Human Review 與計次）。`stop_file.ex` 加 `dispatch_blocked?/0`。

規則：

- 旗標為 `false` 時 `/api/v1/state` 的 JSON 與現況逐位元相同（新鍵不出現），S3 的 `:normal_completion_hold` 行為不變。
- 不新增 disposition：達到 `agent.max_attempts_per_issue` 時用既有的 `:attempt_limit_hold`，它的 `hold_released_by_config?` 子句已存在（預算不再用盡就釋放），所以不需要新子句。
- 不改 `block_issue_from_entry`、`block_issue_from_retry`、`terminate_running_issue`、`schedule_issue_retry` 的簽名，也不新增 `_for_test` 函式。
- 任何一步失敗（非 Linear tracker、留言失敗、轉狀態失敗）都退回 S3 的 hold，不會讓失敗的 run 悄悄通過。

## 5. 重現指令

```bash
git fetch upstream && git diff --stat upstream/main...main
```

產生本文件第 1 節三組行數的指令（`--numstat` 加 `--no-renames` 會把 4 個 workflow 改名算成新增與刪除各 272 行，與 `--stat` 的 rename 結果差 272）：

```bash
git diff --numstat upstream/main...main
```

核心檔案逐 hunk 與 commit 來源：

```bash
git diff upstream/main...main -- elixir/lib/symphony_elixir/orchestrator.ex
git log --format='%h %s' upstream/main..main -- elixir/lib/symphony_elixir/orchestrator.ex
```

核對 fork 是否仍領先 104、落後 0：

```bash
git rev-list --left-right --count upstream/main...main
```

本文件的數字是在 `main = c303807`、`upstream/main = be10a1b` 時量測。任何一邊移動後，請重跑上面的指令並更新第 1 節。
