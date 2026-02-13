# Zolt

Zolt is a minimal Zig TUI chat client inspired by OpenCode and Codex.

It focuses on a fast single-pane workflow:
- stream responses in-terminal
- switch providers/models quickly
- keep multi-conversation history
- use picker-style UX for `/` commands, `/model`, and `@` file references

## Why Zolt

Zolt is a barebones, hackable AI coding/chat TUI with a small codebase in Zig.
It is intentionally lightweight but keeps the UX patterns that matter for daily use.

## Current Feature Set

- Single-pane chat UI with vim-like modes (`normal` / `insert`)
- Streaming responses
- Multiple saved conversations (persisted to disk)
- Provider + model selection from `models.dev` cache
- Context window footer (`used/full` and `% left` when available)
- Slash command popup (Codex-style picker)
- `/model` popup picker
- `@` file popup picker
- `@path` file content injection into prompt context
- Basic read-only tool loop (`READ`) for file inspection

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

3. Set a provider key (example):

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

## Models and Cache (`models.dev`)

Zolt pulls provider/model data from:

- `https://models.dev/api.json`

This cache includes model context window metadata used in the footer.

Commands:

- `/models` shows cache status
- `/models refresh` refreshes from `models.dev`

## Core Usage

### Modes and Basics

- `i` enter insert mode
- `esc` return to normal mode
- `enter` send
- `q` quit (normal mode)

### Picker UX

- `/` opens slash command picker
- `/model` opens model picker
- `@` opens file picker
- In pickers: `ctrl-n/ctrl-p` or `up/down` to move, `enter` or `tab` to accept, `esc` to close

### Slash Commands

- `/help`
- `/provider [id]`
- `/model [id]`
- `/models [refresh]`
- `/files [refresh]`
- `/new [title]`
- `/list`
- `/switch <id>`
- `/title <text>`
- `/theme [codex|plain|forest]`
- `/ui [compact|comfy]`
- `/quit`

### File Mentions

When you type `@path`, Zolt can:
- autocomplete via file picker
- inject referenced file contents into prompt context on send

Quoted paths are supported for spaces:
- `@"docs/My File.md"`
- `@'src/other file.zig'`

## Persistence and Paths

Default XDG paths:

- state: `~/.local/share/zig-ai/state.json`
- models cache: `~/.cache/zig-ai/models.json`

If XDG paths are unavailable/unwritable, Zolt falls back to:

- `.zig-ai/data/state.json`
- `.zig-ai/cache/models.json`

## Development

### Useful Commands

```bash
zig build test
zig build run
zig fmt src/*.zig build.zig
```

Notes:
- `zig build test` also runs formatting checks via `build.zig`.
- main binary name is currently `zig_ai` (project/product name is Zolt).

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
