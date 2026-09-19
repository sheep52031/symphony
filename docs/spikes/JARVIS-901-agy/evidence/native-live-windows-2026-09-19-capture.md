# Sanitized native Windows `agy` command/envelope capture — 2026-09-19

The owner authorized this bounded rerun after refreshing account login. The commands ran directly against Windows `agy.exe 1.1.26` in one disposable directory. UUIDs and the disposable absolute path are replaced below; no credential, account identifier, settings file, or raw conversation ID is retained.

## Executable and host discovery

```text
$ agy --version
1.1.26

$ printf 'agy='; command -v agy.exe || printf 'NOT_FOUND\n'; printf 'elixir='; command -v elixir || printf 'NOT_FOUND\n'; printf 'mix='; command -v mix || printf 'NOT_FOUND\n'
agy=<WINDOWS_AGY_EXE>
elixir=NOT_FOUND
mix=NOT_FOUND

$ MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-22.04 -- bash -lc 'printf "agy="; command -v agy || printf "NOT_FOUND\n"; printf "elixir="; command -v elixir || printf "NOT_FOUND\n"; printf "mix="; command -v mix || printf "NOT_FOUND\n"'
agy=NOT_FOUND
elixir=NOT_FOUND
mix=NOT_FOUND
```

The wrapper labels each lookup; `<WINDOWS_AGY_EXE>` replaces the discovered host-absolute path. A `NOT_FOUND` line is emitted only when that `command -v` exits nonzero.

## Credential-variable presence check

```text
$ if [ -n "${GEMINI_API_KEY+x}" ]; then printf 'GEMINI_API_KEY=PRESENT\n'; else printf 'GEMINI_API_KEY=ABSENT\n'; fi
GEMINI_API_KEY=ABSENT
```

This is presence-only evidence; it does not inspect or print a value.

## Account/model catalog

```text
$ agy models
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)

[exit=0; stderr='Fetching available models...\n']
```

## Active model command (zero-token CLI command)

```json
$ agy --output-format json --print-timeout 30s --print /model
{"conversation_id":"","status":"SUCCESS","response":"gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"model","data":{"id":"gemini-3.8-flash-medium","label":"Gemini 3.8 Flash (Medium)","effort":"medium","is_default":false}}}
[exit=0; stderr='']
```

## Active permission command (zero-token CLI command)

```json
$ agy --output-format json --print-timeout 30s --print /permissions
{"conversation_id":"","status":"SUCCESS","response":"<REDACTED: category-level result contained broad command, unsandboxed, read/write, URL, and MCP allows>","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"permissions","data":{"permissions":"<REDACTED: shared/global effective policy contents>"}}}
[exit=0; stderr='']
```

Only the minimum permission categories needed for the HOLD decision are retained. Exact shared/global rules and scoped resources are intentionally omitted.

## MCP discovery

```text
$ agy mcp list
No MCP servers configured.
```

This was observed before the successful inference and resume checks below. It shows that those native checks did not depend on a configured MCP server; it does not prohibit a future adapter from using MCP.

## One-shot JSON inference

```json
$ agy --sandbox --mode plan --output-format json --print-timeout 60s --print "Respond with exactly CAPTURE_OK. Do not use tools. Do not create, edit, or delete files."
{"conversation_id":"<conversation-id>","status":"SUCCESS","response":"CAPTURE_OK\n","duration_seconds":1.8746121,"num_turns":1,"usage":{"input_tokens":16385,"output_tokens":91,"thinking_tokens":88,"cache_read_tokens":0,"total_tokens":16476}}
[exit=0; wall_seconds=4.906; stderr='']
```

## Two-turn stdin NDJSON session

```text
$ agy --sandbox --mode plan --input-format stream-json --output-format stream-json --print-timeout 60s < input.ndjson
INPUT:
{"event":"user","message":{"content":"Reply with exactly CAPTURE_ALPHA. Do not use tools or modify files."}}
{"event":"user","message":{"content":"What exact token did I request in the previous turn? Reply with only that token. Do not use tools or modify files."}}
OUTPUT:
{"event":"init","conversation_id":"<conversation-id>","init":{"cwd":"<disposable-workspace>","tools":["ask_custom_permission","ask_permission","ask_question","browser_click_element","browser_drag_pixel_to_pixel","browser_get_dom","browser_get_network_request","browser_input","browser_list_network_requests","browser_mouse_down","browser_mouse_up","browser_move_mouse","browser_press_key","browser_refresh_page","browser_resize_window","browser_scroll","browser_scroll_dom","browser_select_option","browser_subagent","call_mcp_tool","capture_browser_console_logs","capture_browser_screenshot","click_browser_pixel","command_status","define_subagent","delete_knowledge","execute_browser_javascript","find_by_name","finish","generate_image","grep_search","invoke_subagent","list_browser_pages","list_dir","list_permissions","list_resources","manage_inbox","manage_subagents","manage_task","multi_replace_file_content","notebook_edit","notebook_execution","open_browser_url","read_browser_page","read_resource","read_url_content","replace_file_content","run_command","schedule","search_web","sed_file","send_command_input","send_message","view_file","wait","wait_5_seconds","write_to_file"],"permission_mode":"always-proceed"}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"CAPTURE_ALPHA"}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":1.5516888,"usage":{"input_tokens":16385,"output_tokens":61,"thinking_tokens":58,"cache_read_tokens":0,"total_tokens":16446}}}
{"event":"result","result":{"conversation_id":"<conversation-id>","status":"SUCCESS","response":"CAPTURE_ALPHA\n","duration_seconds":1.6633925,"num_turns":1,"usage":{"input_tokens":16385,"output_tokens":61,"thinking_tokens":58,"cache_read_tokens":0,"total_tokens":16446}}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":2,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"CAPTURE_ALPHA\n","duration_seconds":2.010443,"usage":{"input_tokens":5118,"output_tokens":87,"thinking_tokens":84,"cache_read_tokens":12214,"total_tokens":5205}}}
{"event":"result","result":{"conversation_id":"<conversation-id>","status":"SUCCESS","response":"CAPTURE_ALPHA\n","duration_seconds":3.9182347,"num_turns":2,"usage":{"input_tokens":21503,"output_tokens":148,"thinking_tokens":142,"cache_read_tokens":12214,"total_tokens":21651}}}
[exit=0; wall_seconds=8.016; stderr='']
```

## Explicit cross-process resume

```json
$ agy --sandbox --mode plan --conversation <conversation-id> --output-format json --print-timeout 60s --print <context-recall-prompt>
{"conversation_id":"<conversation-id>","status":"SUCCESS","response":"CAPTURE_ALPHA\n","duration_seconds":8.1582148,"num_turns":3,"usage":{"input_tokens":23659,"output_tokens":205,"thinking_tokens":196,"cache_read_tokens":28496,"total_tokens":23864}}
[exit=0; wall_seconds=4.328; stderr='']
```

## Operator interrupt observation

```text
$ agy --sandbox --mode plan --output-format stream-json --print-timeout 60s --print <long-no-tool-prompt>
# Windows CTRL_BREAK_EVENT sent after first stdout event
{"event":"init","conversation_id":"<conversation-id>","init":{"cwd":"<disposable-workspace>","tools":["ask_custom_permission","ask_permission","ask_question","browser_click_element","browser_drag_pixel_to_pixel","browser_get_dom","browser_get_network_request","browser_input","browser_list_network_requests","browser_mouse_down","browser_mouse_up","browser_move_mouse","browser_press_key","browser_refresh_page","browser_resize_window","browser_scroll","browser_scroll_dom","browser_select_option","browser_subagent","call_mcp_tool","capture_browser_console_logs","capture_browser_screenshot","click_browser_pixel","command_status","define_subagent","delete_knowledge","execute_browser_javascript","find_by_name","finish","generate_image","grep_search","invoke_subagent","list_browser_pages","list_dir","list_permissions","list_resources","manage_inbox","manage_subagents","manage_task","multi_replace_file_content","notebook_edit","notebook_execution","open_browser_url","read_browser_page","read_resource","read_url_content","replace_file_content","run_command","schedule","search_web","sed_file","send_command_input","send_message","view_file","wait","wait_5_seconds","write_to_file"],"permission_mode":"always-proceed","expanded_commands":[{"name":"plan","type":"system"}]}}
{"event":"step_update","step_update":{"conversation_id":"<conversation-id>","step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"result","result":{"conversation_id":"<conversation-id>","status":"ERROR","response":"","error":"interrupted","duration_seconds":0,"num_turns":1,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}
[exit=1; wall_seconds=4.406; forced_kill=False; stderr='error: interrupted\n']
```

The raw native interrupt envelope is diagnostic evidence only. A future adapter must track whether it initiated cancellation and normalize the lifecycle outcome under the owner contract; retry/reconciliation remains an Orchestrator decision.

## Disposable directory read-back

```text
sentinel=sentinel-before
files=['sentinel.txt']
```

Only the pre-created sentinel existed in the native working directory; capture content was held by the parent process and written to the repository only after sanitization. This is a cwd/no-side-effect smoke check, not a symlink, `--add-dir`, or filesystem-containment test.
