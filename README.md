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
- Provider + model selection from `models.dev` cache
- Context window footer (`used/full` and `% left` when available)
- Slash command popup (Codex-style picker)
- `/model` popup picker
- `@` file popup picker
- `@path` file content injection into prompt context
- Clipboard image paste into `@path` references (`Ctrl-V` or `/paste-image`)
- Tool loop with discovery/edit/exec primitives:
  - `READ` (allowlisted shell read commands)
  - `LIST_DIR`, `READ_FILE`, `GREP_FILES`, `PROJECT_SEARCH`
  - `APPLY_PATCH`, `EXEC_COMMAND`, `WRITE_STDIN`, `WEB_SEARCH`, `VIEW_IMAGE`

## Requirements

- Zig `0.15.2` (or very close)
- Interactive terminal (TTY)
- At least one provider API key in environment variables

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
```

CLI helpers:

```bash
zolt -h
zolt --help
zolt --version
zolt -s <conversation-id>
zolt --session <conversation-id>
```

3. Install to `~/.local` (puts binary at `~/.local/bin/zolt`):

```bash
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

If `~/.local/bin` is in your `PATH`, you can then run:

```bash
zolt
```

4. Set a provider key (example):

```bash
export OPENAI_API_KEY=...
```

## API Key Setup

Zolt reads provider env vars from `models.dev` provider metadata when present, plus local fallbacks.
Common keys:

- `OPENAI_API_KEY`
- `OPENCODE_API_KEY`
- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `GOOGLE_GENERATIVE_AI_API_KEY` or `GEMINI_API_KEY`
- `ZENMUX_API_KEY`

Use `/provider <id>` to switch provider, then `/model` to pick models.

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
- `keybindings` (alias: `hotkeys`): optional key overrides for normal/insert mode

Example:

```jsonc
{
  // startup defaults
  "provider": "openai",
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
- `/models refresh` refreshes from `models.dev`

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
- `/commands` opens command palette
- `>` opens command palette
- `/model` opens model picker
- `@` opens file picker

### Slash Commands

- `/help`
- `/commands`
- `/provider [id]`
- `/model [id]`
- `/models [refresh]`
- `/files [refresh]`
- `/new [title]`
- `/list`
- `/sessions [id]` (no id opens conversation picker)
- `/title <text>`
- `/theme [codex|plain|forest]`
- `/ui [compact|comfy]`
- `/quit`
- `/q` (alias of `/quit`)
- `/paste-image`

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
