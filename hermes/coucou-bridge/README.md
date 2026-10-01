# Hermes → Coucou bridge

Relays Hermes agent and subagent activity into the Coucou notch companion, and
answers Hermes approval prompts from the island.

Three moving parts:

| | |
|---|---|
| `hermes-coucou-hook.py` | shell hook: activity → Coucou's socket |
| `~/.hermes/plugins/coucou-approval/` | approval transport: Allow/Deny from the notch |
| `<path-to-this-repo>` | the Coucou fork (branch `hermes-agents`) |

The stock Coucou app will NOT show subagent pills — that needs the fork.

## How it works

Hermes shell hook (`hooks:` in `~/.hermes/config.yaml`)
  → `hermes-coucou-hook.py` (renames fields, maps event vocabulary)
  → Coucou's Unix socket `~/Library/Application Support/NotchBuddy/nb.sock`

Hermes and Claude Code emit nearly the same hook payload
(`{hook_event_name, tool_name, tool_input, session_id, cwd, extra}`), so the
bridge is mostly a vocabulary translation.

## Three things that are not obvious

1. **`term_program` must contain "vscode".** `HookServer.processEvent` hard-filters
   on `term_program`/`bundle_id` and silently drops everything else. Remove that
   line and the bridge becomes a no-op with no error anywhere.

2. **Pills are keyed by `child_session_id`, never `child_subagent_id`.**
   `subagent_start` carries both, but `subagent_stop` only carries the session id
   (`tools/delegate_tool_results.py`), so a pill opened under the subagent id
   could never be closed. Keying on the session id also makes a child's own tool
   calls land on its pill for free: they already carry
   `session_id == child_session_id`, so no bookkeeping is needed.

3. **The grid holds exactly 4 pills besides the focused one.**
   `others.prefix(4)` in `IslandViewContent.swift` (twice) and
   `IslandRootView.swift`. The fork evicts finished subagents before running
   ones when a fifth spawns; an evicted child's later steps fall back to the
   main pill rather than vanishing.

## Event mapping

| Hermes | Coucou | Notes |
|---|---|---|
| `on_session_start` | `SessionStart` | expands the island, "work" sound |
| `pre_tool_call` | `PreToolUse` | stamped with `subagent_id` to pick the pill |
| `subagent_start` | `SubagentStart` | creates a pill: goal as name, colour from the id |
| `subagent_stop` | `SubagentStop` | finished/error state, then removed after 4s |
| `on_session_end` | `Stop` / `StopFailure` / `SessionEnd` | chosen from `failed` / `interrupted` |
| `on_session_finalize` | `SessionEnd` | teardown |
| `agent_loop_stopped` | `StopFailure` | interrupted mid-run |
| `pre_approval_request` | `Notification` | observer only — the transport does the real asking |

`post_tool_call` is deliberately unregistered: it would double the process spawns
per tool call and only repeats the state `PreToolUse` already set.

## Approvals

Handled by the separate plugin, not by this hook. See
`~/.hermes/plugins/coucou-approval/__init__.py`. The short version: Hermes has a
first-class pluggable approval transport, and `pre_tool_call` is the wrong tool
for the job — a hook blocked on a click is NOT counted as human wait
(`agent/approval_human_wait.py`) and would time out tool batches.

`security.approval.transport_fallback: builtin` is load-bearing: the host turns
any transport failure into a denial, and only that fallback turns it back into
the ordinary terminal prompt.

## Rebuilding the fork

Your Xcode (16.2) is older than the project targets, so Swift 6 strict
concurrency rejects ~8 upstream call sites. Build in Swift 5 language mode — no
source changes needed:

```sh
cd <path-to-this-repo>/NotchBuddy
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug \
  -derivedDataPath ./build/dd -destination 'platform=macOS,arch=arm64' \
  SWIFT_VERSION=5 SWIFT_STRICT_CONCURRENCY=minimal OTHER_SWIFT_FLAGS="" build
pkill -f /Applications/Coucou.app
rm -rf /Applications/Coucou.app
ditto build/dd/Build/Products/Debug/Coucou.app /Applications/Coucou.app
codesign --force --deep --sign - /Applications/Coucou.app
open -a /Applications/Coucou.app
```

## Debugging

```sh
HERMES_COUCOU_DEBUG=1   # appends every raw payload to debug.jsonl
hermes hooks test subagent_start --payload-file some.json
tail -f ~/Library/Logs/NotchBuddy/nb.log
```

The log shows `PreToolUse <tool> → <pill id>`, which is how to check routing.
Upstream commit `1f6e0d0` stopped logging command text on purpose; the fork
kept that and added only the destination pill.

## Uninstall

Remove the `hooks:`, `security:` and `coucou-approval` blocks from
`~/.hermes/config.yaml` (backups exist as `config.yaml.bak-coucou-*` and
`config.yaml.bak-approval-*`), run `hermes hooks revoke`, and reinstall stock
Coucou from the upstream releases page.

---

## The notch chat talks to Hermes (not to Anthropic)

`ClaudeService.swift` in the fork no longer calls `api.anthropic.com`. It calls
the local Hermes gateway:

    http://127.0.0.1:8642/v1/chat/completions

That endpoint is OpenAI-compatible but it is NOT a model proxy
(`hermes proxy` is the model proxy): every request drives a real Hermes agent
turn with its toolsets, skills and subagents. A ~49k-token prompt and the
ability to answer questions about the local filesystem are how you can tell.

Enabled purely by `API_SERVER_KEY` in `~/.hermes/.env` — there is no
`config.yaml` toggle (`gateway/config_env.py::_api_server`). It binds
`127.0.0.1` only and refuses to start on a key under 16 characters, because
the endpoint dispatches terminal-capable agent work: a guessable key there is
remote code execution. Treat that key as a full-access credential; Coucou keeps
its copy in the Keychain under service `fr.louisraille.NotchBuddy`, account
`hermes-api-key`.

Other changes that came with it:
- Attached files are passed by PATH, not base64-inlined. Hermes runs on this
  machine and reads them with its own tools, so the old 200 KB text ceiling and
  the image/PDF encoding branches are gone.
- The request timeout went from 45s to 300s: an agent turn runs tools.
- Anthropic's `web_search_20250305` tool block was dropped — Hermes has its own.

The gateway must be running or the chat shows
"Hermes gateway not reachable". To keep it up across reboots:
`hermes gateway install`.
