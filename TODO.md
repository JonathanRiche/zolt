# Zolt Tooling TODO

Inspired by Codex default/builtin tools that we should evaluate for Zolt.

## Vaxis Low-Level Migration Plan (New)
- [x] extract terminal backend boundary (`src/terminal_backend.zig`) for raw mode + key mapping + pending input polling
- [x] add optional `libvaxis` dependency + `-Dvaxis=true` build option (wired in `build.zig`, gated import)
- [x] define backend interface in TUI (`ansi` vs `vaxis`) and route run loop through it
- [x] implement vaxis low-level event adapter:
  - [x] keyboard (normal/insert, arrows, pgup/pgdn, ctrl combos)
  - [x] resize handling
  - [x] suspend/resume behavior parity (`Ctrl-Z`, `fg`) (POSIX path)
- [x] implement vaxis frame renderer parity:
  - [x] header/status/footer
  - [x] chat viewport + scrolling
  - [x] model/command/file/skills pickers
  - [x] markdown line styling parity
- [x] keep non-interactive `zolt run` path independent of vaxis backend (headless path bypasses interactive backend loops)
- [x] add A/B toggle command (`/ui backend ansi|vaxis`) for runtime testing when vaxis is enabled
- [x] add regression tests for parsing/key behavior that should remain backend-agnostic
- [x] add perf/startup checks for Linux/macOS and document fallback behavior in README

## Core Tooling (Foundation)
- [x] `exec_command` + `write_stdin` (interactive shell sessions)
- [x] `apply_patch` (Codex-style patch editing)
- [x] `READ` (`rg`, `grep`, `ls`, `cat`, etc.) with allowlist

## File/Code Discovery (Foundation)
- [x] `grep_files` first-class tool (structured grep, not shell-only)
- [x] `read_file` first-class tool
- [x] `list_dir` first-class tool
- [x] richer project search (`search_tool_bm25` style)

## Planning and UX Control (High Priority)
- [x] `update_plan` equivalent
- [ ] `request_user_input` equivalent
  - [ ] define blocking vs non-blocking behavior
  - [ ] specify UI surface (modal, inline prompt, status bar, etc.)
- [x] auto-load `agents.md` at start of each new chat; lazily load skill names/descriptions so the LLM knows when to use a skill
- [x] OpenAI provider: allow user to choose between Codex/ChatGPT subscription vs API key option

## External Context (Next)
- [ ] `list_mcp_resources`
- [ ] `list_mcp_resource_templates`
- [ ] `read_mcp_resource`
- [ ] define MCP auth/permissions/scoping (per-workspace?)
- [ ] add tool permission model (read/exec/apply_patch/web_search/MCP scopes)
- [ ] gate tool execution with allow-once/always/deny prompt
- [ ] `/permissions` command to view/toggle tool permissions
- [ ] persist permission decisions per workspace/session
- [x] add `zolt run "<prompt>"` CLI mode (non-interactive single prompt)
- [x] `web_search` (optional mode)
- [x] `view_image` (local screenshots/assets)

## Runtime / Advanced (Later)
- [ ] `js_repl` + `js_repl_reset` (optional)
- [ ] multi-agent controls (`spawn_agent`, `send_input`, `resume_agent`, `wait`, `close_agent`)
  - [ ] internal API support
  - [ ] UI exposure (if needed)

## UX / Rendering (Later)
- [x] syntax highlighting for patch diff preview/code blocks (beyond +/- colors)
- [x] customizable keybindings/hotkeys (configurable shortcuts)
- [x] command palette / quick actions (e.g., “New chat”, “Toggle plan”, “Open logs”)
- [ ] status bar indicators (model/provider, token usage, tool mode)
- [ ] copy buttons for code blocks / tool outputs
- [ ] streaming UX tweaks (partial tool output display, spinner states)

## Repo / Product Polish
- [ ] add config file or env overrides for defaults (theme, UI density, provider, model)
- [ ] versioned config schema + migration strategy
- [ ] add README section for testing providers without keys / mock mode
- [ ] consider allocator choice for release builds (e.g., GPA vs DebugAllocator)
- [ ] add optional verbose logging or crash report log file path
- [ ] document state file schema/location for users who want to inspect/backup
- [ ] add deterministic test harness for tool invocations / golden outputs
- [x] document keybindings and customization in README
