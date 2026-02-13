# Zolt Tooling TODO

Inspired by Codex default/builtin tools that we should evaluate for Zolt.

## Core Tooling
- [ ] `exec_command` + `write_stdin` (interactive shell sessions)
- [x] `apply_patch` (Codex-style patch editing)
- [x] `READ` (`rg`, `grep`, `ls`, `cat`, etc.) with allowlist

## File/Code Discovery
- [ ] `grep_files` first-class tool (structured grep, not shell-only)
- [ ] `read_file` first-class tool
- [ ] `list_dir` first-class tool
- [ ] richer project search (`search_tool_bm25` style)

## Planning and UX Control
- [ ] `update_plan` equivalent
- [ ] `request_user_input` equivalent

## External Context
- [ ] `list_mcp_resources`
- [ ] `list_mcp_resource_templates`
- [ ] `read_mcp_resource`
- [ ] `web_search` (optional mode)
- [ ] `view_image` (local screenshots/assets)

## Runtime / Advanced
- [ ] `js_repl` + `js_repl_reset` (optional)
- [ ] multi-agent controls (`spawn_agent`, `send_input`, `resume_agent`, `wait`, `close_agent`)
