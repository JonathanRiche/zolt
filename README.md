# Zolt

Zolt is a minimal Zig TUI chat client inspired by OpenCode and Codex.

## Status

This is **not ready for production use**.

Right now, Zolt is a test project to see how quickly a harness can be built in Zig for experimentation and testing.

It focuses on a fast single-pane workflow:
- stream responses in-terminal
- switch providers/models quickly
- keep multi-conversation history
- use picker-style UX for `/` commands, `/model`, and `@` file references
- render Markdown responses clearly in-chat (headings, lists, quotes, code fences, inline code)

## Why Zolt

Zolt is a barebones, hackable AI coding/chat TUI with a small codebase in Zig.
It is intentionally lightweight but keeps the UX patterns that matter for daily use.

## Current Feature Set

- Single-pane chat UI with vim-like modes (`normal` / `insert`)
- Streaming responses
- Markdown-aware chat rendering (headings, lists, block quotes, fenced code, inline code)
- Multiple saved conversations (persisted to disk)
- Codex-style conversation preview title from first prompt (for untitled/new chats)
- Manual `/compact` plus auto-compaction when context window is low
- Provider + model selection from `models.dev` cache
- Context window footer (`used/full` and `% left` when available)
- Slash command popup (Codex-style picker)
- `/model` popup picker
- `@` file popup picker
- `@path` file content injection into prompt context
- Clipboard image paste into `@path` references (`Ctrl-V` or `/paste-image`)
- Skill discovery/injection from Codex/OpenCode-style directories (`$skill-name`, `/skills`, `SKILL` tool)
- Tool loop with discovery/edit/exec primitives:
  - `READ` (allowlisted shell read commands)
  - `LIST_DIR`, `READ_FILE`, `GREP_FILES`, `PROJECT_SEARCH`
  - `APPLY_PATCH`, `EXEC_COMMAND`, `WRITE_STDIN`, `WEB_SEARCH` (DuckDuckGo default, Exa optional), `VIEW_IMAGE`, `SKILL`, `UPDATE_PLAN`, `REQUEST_USER_INPUT` (non-blocking inline)

## Requirements

- Zig `0.15.2` (or very close)
- Interactive terminal (TTY) for `zolt` chat mode
- Auth for at least one provider:
  - provider API key env var, or
  - OpenAI Codex/ChatGPT subscription auth via `CODEX_HOME/auth.json` (or `~/.codex/auth.json`)

## Quick Start

1. Build:

```bash
zig build
```

2. Run:

```bash
zig build run
```

Pass CLI flags through Zig with `--`:

```bash
zig build run -- -h
zig build run -- -s <conversation-id>
zig build run -- run "explain src/main.zig"
```

CLI helpers:

```bash
zolt -h
zolt --help
zolt --version
zolt models
zolt models opencode
zolt models --provider openai
zolt models --provider openai --search codex
zolt models --provider openai --select --search codex
zolt models --provider openai --set-default gpt-5.3-codex
zolt -s <conversation-id>
zolt --session <conversation-id>
zolt run "<prompt>"
zolt run --session <conversation-id> "<prompt>"
```

### Run Mode (Non-Interactive)

Use `zolt run` when another tool/script needs a one-shot answer on stdout (no TUI).

```bash
zolt run "<prompt>"
zolt run --session <conversation-id> "<prompt>"
zolt run --provider openai --model gpt-5-chat-latest "<prompt>"
zolt run --session <conversation-id> --provider openai --model gpt-5-chat-latest "<prompt>"
zolt run -s <conversation-id> "<prompt>"
zolt run --output text "<prompt>"
zolt run --output logs "<prompt>"
zolt run --output json "<prompt>"
zolt run --output json-stream "<prompt>"
```

Notes:
- `zolt run` uses the same model/provider selection as normal mode.
- Pass `--provider` and `--model` to force an explicit run-scoped selection.
- `--model` requires `--provider`.
- `--session` resumes that conversation context first, then appends your prompt.
- `--output` controls formatting:
  - `text`: final assistant response only (default)
  - `logs`: tool call/result log lines + final response
  - `json`: one JSON object with metadata, final response, stable token usage, and captured events
  - `json-stream` (`ndjson`/`jsonl` alias): newline-delimited JSON events while running
- `json` output always includes:
  - `usage.prompt_tokens` (`number|null`)
  - `usage.completion_tokens` (`number|null`)
  - `usage.total_tokens` (`number|null`)
- `json` output also includes `error`:
  - `null` on success
  - object on failure with `code`, `message`, `retryable`, `source`
- Existing top-level fields remain unchanged: `provider`, `model`, `session_id`, `prompt`, `response`, `events`.
- `usage` is normalized across providers (`input_tokens`/`output_tokens` map to `prompt_tokens`/`completion_tokens`).
- Tool loop is enabled in run mode (`READ`, `LIST_DIR`, `READ_FILE`, `GREP_FILES`, `PROJECT_SEARCH`, `APPLY_PATCH`, `EXEC_COMMAND`, `WRITE_STDIN`, `WEB_SEARCH`, `VIEW_IMAGE`, `SKILL`, `UPDATE_PLAN`, `REQUEST_USER_INPUT`).
- In `text` mode, stdout is only the final assistant response (tool call placeholders are not returned as final output).

3. Install to `~/.local` (puts binary at `~/.local/bin/zolt`):

```bash
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

To build with the experimental vaxis backend path enabled:

```bash
zig build install -Doptimize=ReleaseFast -Dvaxis=true --prefix "$HOME/.local"
```

If `~/.local/bin` is in your `PATH`, you can then run:

```bash
zolt
```

4. Set auth (examples):

```bash
export OPENAI_API_KEY=...
```

Or for OpenAI Codex subscription auth, run Codex login so this file exists:

- `$CODEX_HOME/auth.json` (if `CODEX_HOME` is set)
- fallback: `~/.codex/auth.json`

If you logged into OpenCode OAuth/Codex plugin, Zolt also reads:

- `$XDG_DATA_HOME/opencode/auth.json`
- fallback: `~/.local/share/opencode/auth.json`

## API Key Setup

Zolt reads provider env vars from `models.dev` provider metadata when present, plus local fallbacks.
Common keys:

- `OPENAI_API_KEY`
- `OPENCODE_API_KEY`
- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `GOOGLE_GENERATIVE_AI_API_KEY` or `GEMINI_API_KEY`
- `ZENMUX_API_KEY`
- `EXA_API_KEY` (only for `WEB_SEARCH` when `engine:"exa"` is requested)

Use `/provider <id> [auto|api_key|codex]` to switch provider/auth mode, then `/model` to pick models.

### OpenAI Codex Subscription Auth

For provider `openai`, Zolt also supports Codex/ChatGPT subscription auth without `OPENAI_API_KEY`:

- Reads token data from `CODEX_HOME/auth.json` or `~/.codex/auth.json`
- Reads OAuth token data from OpenCode auth file (`$XDG_DATA_HOME/opencode/auth.json` or `~/.local/share/opencode/auth.json`)
- Uses bearer `tokens.access_token`
- Sends `ChatGPT-Account-ID` when available
- Routes requests to `https://chatgpt.com/backend-api/codex` (`/responses`)
- If no subscription token exists, switching to OpenAI codex auth via `/provider` will trigger `codex login`.

If both subscription auth and `OPENAI_API_KEY` are present, API key auth is used first.

Optional auth preference override:

- `ZOLT_OPENAI_AUTH=auto` (default): API key first, then Codex auth fallback
- `ZOLT_OPENAI_AUTH=api_key`: API key only
- `ZOLT_OPENAI_AUTH=codex`: Codex auth first (fallback to API key)

## Config File (JSONC)

Zolt looks for an optional config file at:

- `$XDG_CONFIG_HOME/zolt/config.jsonc`
- fallback: `~/.config/zolt/config.jsonc`

Supported keys:

- `provider` (alias: `default_provider_id`, `selected_provider_id`)
- `model` (alias: `default_model_id`, `selected_model_id`)
- `theme`: `codex` | `plain` | `forest`
- `ui` (alias: `ui_mode`): `compact` | `comfy`
- `compact_mode`: `true`/`false` (legacy alias for `ui`)
- `openai_auth` (alias: `openai_auth_mode`): `auto` | `api_key` | `codex`
- `auto_compact_percent_left` (alias: `auto_compact_trigger_percent_left`): integer `0..100` (default `15`)
- `keybindings` (alias: `hotkeys`): optional key overrides for normal/insert mode

Example:

```jsonc
{
  // startup defaults
  "provider": "openai",
  "openai_auth": "codex",
  "auto_compact_percent_left": 12,
  "model": "gpt-4.1",
  "theme": "codex",
  "ui": "compact",
  "keybindings": {
    "normal": {
      "quit": "x",
      "command_palette": "ctrl-o"
    },
    "insert": {
      "picker_next": "ctrl-j",
      "paste_image": "ctrl-y"
    }
  }
}
```

Accepted key values for `keybindings`:
- single character, like `"q"` or `"H"`
- control combos `"ctrl-a"` through `"ctrl-z"`
- named keys: `"esc"`, `"enter"`, `"tab"`, `"backspace"`, `"space"`, `"up"`, `"down"`, `"pgup"`, `"pgdn"`

## Models and Cache (`models.dev`)

Zolt pulls provider/model data from:

- `https://models.dev/api.json`

This cache includes model context window metadata used in the footer.

Commands:

- `/models` shows cache status
- `/models refresh` is recommended regularly to keep latest OpenAI models from `models.dev`
- CLI model listing:
  - `zolt models` shows provider IDs + model counts
  - `zolt models <provider-id>` prints exact model IDs (plus config snippet)
  - `zolt models --provider <id> --search <query>` filters models by id/name
  - `zolt models --provider <id> --select [--search <query>]` opens a numbered picker in terminal and saves defaults
  - `zolt models --provider <id> --set-default <model-id>` writes provider/model defaults to config without opening TUI

## Core Usage

### Keybindings

Global / stream-time:
- `Ctrl-Z` suspend Zolt (resume with shell `fg`)
- `Ctrl-C` quit Zolt immediately
- While streaming: `Esc Esc` interrupts generation
- `PgUp` / `PgDn` scroll chat history (works in both normal and insert modes)
- `Ctrl-P` opens command palette quick actions

Normal mode:
- `i` enter insert mode
- `a` enter insert mode and move cursor right by one
- `q` quit
- `j` scroll down chat history
- `k` scroll up chat history
- `h` move input cursor left
- `l` move input cursor right
- `x` delete character at cursor
- `H` / `L` shift conversation strip left/right
- `/` enter insert mode and start slash command input
- `Ctrl-P` open command palette

Insert mode:
- `Esc` return to normal mode (or close active picker)
- `Enter` send prompt (or accept active picker selection)
- `Tab` accept active picker selection
- `Backspace` delete character before cursor
- `Ctrl-V` paste image from clipboard into input as `@path`
- `Ctrl-P` open command palette
- `Ctrl-N` / `Ctrl-P` move picker selection down/up
- `Up` / `Down` arrows move picker selection up/down

Picker triggers:
- `/` opens slash command picker
- `/help` opens command palette
- `/commands` opens command palette
- `>` opens command palette
- `/model` opens model picker
- `@` opens file picker

### Slash Commands

- `/help` (same as `/commands`)
- `/commands`
- `/provider` (shows current provider and OpenAI auth mode options)
- `/provider [id] [auto|api_key|codex]` (OpenAI auth mode)
- `/model [id]`
- `/models [refresh]`
- `/files [refresh]`
- `/skills [name|refresh]` (list, inspect, or reload discovered skills)
- `/new [title]`
- `/sessions [id]` (no id opens conversation picker)
- `/compact` (compact current conversation now)
- `/compact auto [on|off]` (toggle auto-compaction near context limit)
- `/title <text>`
- `/theme [codex|plain|forest]`
- `/ui [compact|comfy]`
- `/ui backend [ansi|vaxis]` (vaxis requires building with `-Dvaxis=true`)
- `/quit`
- `/q` (alias of `/quit`)
- `/paste-image`

### Backend Fallback

- Default builds (without `-Dvaxis=true`) run ANSI backend only.
- In ANSI-only builds, `/ui backend vaxis` is rejected with a clear notice.
- In `-Dvaxis=true` builds, backend switching is available with:
  - `/ui backend ansi`
  - `/ui backend vaxis`

### Startup/Perf Checks

Quick manual checks for startup latency:

Linux:

```bash
time -p zolt --help
time -p zolt --version
```

macOS:

```bash
time zolt --help
time zolt --version
```

Compare ANSI vs vaxis-enabled builds:

```bash
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
time -p zolt --help

zig build install -Doptimize=ReleaseFast -Dvaxis=true --prefix "$HOME/.local"
time -p zolt --help
```

### Skills

Zolt discovers `SKILL.md` files using Codex/OpenCode-compatible roots.

Global roots:
- `$XDG_CONFIG_HOME/opencode/skill/*/SKILL.md` (fallback: `~/.config/opencode/skill/*/SKILL.md`)
- `$XDG_CONFIG_HOME/opencode/skills/*/SKILL.md` (fallback: `~/.config/opencode/skills/*/SKILL.md`)
- `$XDG_CONFIG_HOME/zolt/skill/*/SKILL.md` (fallback: `~/.config/zolt/skill/*/SKILL.md`)
- `$XDG_CONFIG_HOME/zolt/skills/*/SKILL.md` (fallback: `~/.config/zolt/skills/*/SKILL.md`)
- `~/.agents/skills/*/SKILL.md`
- `~/.claude/skills/*/SKILL.md`
- `~/.zolt/skill/*/SKILL.md` and `~/.zolt/skills/*/SKILL.md` (legacy/local convenience)
- `$CODEX_HOME/skills/*/SKILL.md` (fallback: `~/.codex/skills/*/SKILL.md`)

Project roots (searched from repo root -> cwd, so deeper paths override):
- `.opencode/skill/*/SKILL.md`
- `.opencode/skills/*/SKILL.md`
- `.agents/skills/*/SKILL.md`
- `.claude/skills/*/SKILL.md`
- `.codex/skills/*/SKILL.md`

Yes: skills in the directory where Zolt is currently running are included (if they are under one of the project roots above).

Usage:
- Mention `$skill-name` in your prompt to inject that skill’s full `SKILL.md` content.
- Use `/skills` to list cached skills.
- Use `/skills <name>` to inspect a specific skill entry.
- Use `/skills refresh` after adding/changing skill files.

### File Mentions

When you type `@path`, Zolt can:
- autocomplete via file picker
- inject referenced file contents into prompt context on send

For referenced image files, Zolt injects image metadata (path/mime/size/dimensions) instead of raw binary bytes.

Quoted paths are supported for spaces:
- `@"docs/My File.md"`
- `@'src/other file.zig'`

## Persistence and Paths

Default XDG paths:

- state: `~/.local/share/zig-ai/workspaces/<scope>.json`
- models cache: `~/.cache/zig-ai/models.json`

Note: the storage directory name is currently `zig-ai` (legacy) even though the binary/app name is `zolt`.

`<scope>` is derived from your git root when available (or current directory otherwise),
so conversations are automatically scoped per project/workspace.

If XDG paths are unavailable/unwritable, Zolt falls back to:

- `<workspace-root>/.zig-ai/data/workspaces/<scope>.json`
- `<workspace-root>/.zig-ai/cache/models.json`

## Development

### Useful Commands

```bash
zig build test
zig build run
zig fmt src/*.zig build.zig
```

Notes:
- `zig build test` also runs formatting checks via `build.zig`.
- main binary name is `zolt`.

### Project Layout

- `src/main.zig` app entry
- `src/tui.zig` TUI and interaction logic
- `src/provider_client.zig` provider streaming clients
- `src/models.zig` models.dev cache + catalog parsing
- `src/state.zig` persisted conversations and token usage
- `src/paths.zig` XDG/fallback path handling

## Inspiration

Zolt is directly inspired by OpenCode and Codex interaction patterns, especially:
- streaming-first terminal flow
- picker-based model/command/file selection
- concise, keyboard-centric interaction
