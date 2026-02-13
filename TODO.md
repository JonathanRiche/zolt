# Zolt Tooling TODO

Inspired by Codex default/builtin tools that we should evaluate for Zolt.

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
- [ ] `update_plan` equivalent
- [ ] `request_user_input` equivalent

## External Context (Next)
- [ ] `list_mcp_resources`
- [ ] `list_mcp_resource_templates`
- [ ] `read_mcp_resource`
- [x] `web_search` (optional mode)
- [ ] `view_image` (local screenshots/assets)

## Runtime / Advanced (Later)
- [ ] `js_repl` + `js_repl_reset` (optional)
- [ ] multi-agent controls (`spawn_agent`, `send_input`, `resume_agent`, `wait`, `close_agent`)

## UX / Rendering (Later)
- [ ] syntax highlighting for patch diff preview/code blocks (beyond +/- colors)

## Repo / Product Polish
- [ ] add config file or env overrides for defaults (theme, UI density, provider, model)
- [ ] add README section for testing providers without keys / mock mode
- [ ] consider allocator choice for release builds (e.g., GPA vs DebugAllocator)
- [ ] add optional verbose logging or crash report log file path
- [ ] document state file schema/location for users who want to inspect/backup
