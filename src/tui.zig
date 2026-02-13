//! Minimal single-pane TUI with vim-style navigation and slash commands.

const std = @import("std");
const builtin = @import("builtin");

const models = @import("models.zig");
const patch_tool = @import("patch_tool.zig");
const provider_client = @import("provider_client.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const Conversation = @import("state.zig").Conversation;
const Role = @import("state.zig").Role;
const TokenUsage = @import("state.zig").TokenUsage;

const Mode = enum {
    normal,
    insert,
};

const Theme = enum {
    codex,
    plain,
    forest,
};

const TerminalMetrics = struct {
    width: usize,
    lines: usize,
};

const MODEL_PICKER_MAX_ROWS: usize = 8;
const FILE_PICKER_MAX_ROWS: usize = 8;
const COMMAND_PICKER_MAX_ROWS: usize = 8;
const TOOL_MAX_STEPS: usize = 4;
const READ_TOOL_MAX_OUTPUT_BYTES: usize = 24 * 1024;
const APPLY_PATCH_TOOL_MAX_PATCH_BYTES: usize = 256 * 1024;
const STREAM_INTERRUPT_ESC_WINDOW_MS: i64 = 1200;
const FILE_INJECT_MAX_FILES: usize = 8;
const FILE_INJECT_MAX_FILE_BYTES: usize = 64 * 1024;
const FILE_INJECT_HEADER = "[file-inject]";
const FILE_INDEX_MAX_OUTPUT_BYTES: usize = 32 * 1024 * 1024;
const TOOL_SYSTEM_PROMPT =
    "You can use two local tools.\n" ++
    "When you need to inspect files, reply with ONLY:\n" ++
    "<READ>\n" ++
    "<command>\n" ++
    "</READ>\n" ++
    "Allowed commands: rg, grep, ls, cat, find, head, tail, sed, wc, stat, pwd.\n" ++
    "When you need to edit files, reply with ONLY:\n" ++
    "<APPLY_PATCH>\n" ++
    "*** Begin Patch\n" ++
    "*** Update File: path/to/file\n" ++
    "@@\n" ++
    "-old text\n" ++
    "+new text\n" ++
    "*** End Patch\n" ++
    "</APPLY_PATCH>\n" ++
    "After a system message that starts with [read-result] or [apply-patch-result], continue the answer normally.";

const RawMode = struct {
    original_termios: std.posix.termios,

    pub fn enable() !RawMode {
        const stdin_handle = std.fs.File.stdin().handle;
        const original = try std.posix.tcgetattr(stdin_handle);

        var raw = original;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_handle, .NOW, raw);

        return .{ .original_termios = original };
    }

    pub fn disable(self: *const RawMode) void {
        const stdin_handle = std.fs.File.stdin().handle;
        std.posix.tcsetattr(stdin_handle, .NOW, self.original_termios) catch {};
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
) !void {
    var app: App = .{
        .allocator = allocator,
        .paths = paths,
        .app_state = app_state,
        .catalog = catalog,
        .notice = try allocator.dupe(u8, "Press i for insert mode. Type /help for commands."),
    };
    defer app.deinit();
    app.refreshFileIndex() catch {};
    app.ensureCurrentConversationVisibleInStrip();

    var raw_mode = try RawMode.enable();
    defer raw_mode.disable();

    try app.render();

    while (!app.should_exit) {
        var byte_buf: [1]u8 = undefined;
        const read_len = try std.posix.read(std.fs.File.stdin().handle, byte_buf[0..]);
        if (read_len == 0) break;

        if (byte_buf[0] == 26) {
            app.suspend_requested = true;
        }

        if (app.suspend_requested) {
            try suspendForJobControl(&raw_mode, &app);
            continue;
        }

        const mapped_key = if (byte_buf[0] == 27) try mapEscapeSequenceToKey() else null;
        if (mapped_key) |key| {
            try app.handleByte(key);
        } else {
            try app.handleByte(byte_buf[0]);
        }

        if (app.suspend_requested) {
            try suspendForJobControl(&raw_mode, &app);
            continue;
        }

        if (!app.should_exit) {
            try app.render();
        }
    }
}

fn suspendForJobControl(raw_mode: *RawMode, app: *App) !void {
    app.suspend_requested = false;
    app.stream_stop_for_suspend = false;

    raw_mode.disable();
    try std.posix.raise(std.posix.SIG.TSTP);
    raw_mode.* = try RawMode.enable();

    try app.setNotice("Resumed (fg)");
    if (!app.should_exit) {
        try app.render();
    }
}

fn mapEscapeSequenceToKey() !?u8 {
    if (!try stdinHasPendingByte(2)) return null;

    var second: [1]u8 = undefined;
    const second_read = try std.posix.read(std.fs.File.stdin().handle, second[0..]);
    if (second_read == 0) return null;
    if (second[0] != '[' and second[0] != 'O') return null;

    if (!try stdinHasPendingByte(2)) return null;

    var third: [1]u8 = undefined;
    const third_read = try std.posix.read(std.fs.File.stdin().handle, third[0..]);
    if (third_read == 0) return null;

    return switch (third[0]) {
        'A' => 16, // Up arrow -> Ctrl-P semantics
        'B' => 14, // Down arrow -> Ctrl-N semantics
        else => null,
    };
}

fn stdinHasPendingByte(timeout_ms: i32) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.fs.File.stdin().handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = try std.posix.poll(&poll_fds, timeout_ms);
    return ready_count > 0 and (poll_fds[0].revents & std.posix.POLL.IN) == std.posix.POLL.IN;
}

const App = struct {
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,

    mode: Mode = .normal,
    should_exit: bool = false,
    is_streaming: bool = false,

    input_buffer: std.ArrayList(u8) = .empty,
    input_cursor: usize = 0,
    scroll_lines: usize = 0,
    conv_strip_start: usize = 0,
    model_picker_open: bool = false,
    model_picker_index: usize = 0,
    model_picker_scroll: usize = 0,
    command_picker_open: bool = false,
    command_picker_index: usize = 0,
    command_picker_scroll: usize = 0,
    file_picker_open: bool = false,
    file_picker_index: usize = 0,
    file_picker_scroll: usize = 0,
    file_index: std.ArrayList([]u8) = .empty,
    compact_mode: bool = true,
    theme: Theme = .codex,
    stream_interrupt_esc_count: u8 = 0,
    stream_interrupt_last_esc_ms: i64 = 0,
    stream_interrupt_hint_shown: bool = false,
    stream_was_interrupted: bool = false,
    stream_stop_for_suspend: bool = false,
    stream_started_ms: i64 = 0,
    suspend_requested: bool = false,

    notice: []u8,

    pub fn deinit(self: *App) void {
        self.input_buffer.deinit(self.allocator);
        for (self.file_index.items) |path| self.allocator.free(path);
        self.file_index.deinit(self.allocator);
        self.allocator.free(self.notice);
    }

    fn handleByte(self: *App, key_byte: u8) !void {
        if (key_byte == 3) {
            self.should_exit = true;
            return;
        }

        switch (self.mode) {
            .normal => try self.handleNormalByte(key_byte),
            .insert => try self.handleInsertByte(key_byte),
        }
    }

    fn handleNormalByte(self: *App, key_byte: u8) !void {
        switch (key_byte) {
            'q' => self.should_exit = true,
            'i' => {
                self.mode = .insert;
                self.syncPickersFromInput();
            },
            'a' => {
                if (self.input_cursor < self.input_buffer.items.len) self.input_cursor += 1;
                self.mode = .insert;
                self.syncPickersFromInput();
            },
            'h' => {
                if (self.input_cursor > 0) self.input_cursor -= 1;
            },
            'l' => {
                if (self.input_cursor < self.input_buffer.items.len) self.input_cursor += 1;
            },
            'x' => {
                if (self.input_cursor < self.input_buffer.items.len) _ = self.input_buffer.orderedRemove(self.input_cursor);
            },
            'k' => {
                self.scroll_lines +|= 1;
            },
            'j' => {
                if (self.scroll_lines > 0) self.scroll_lines -= 1;
            },
            'H' => {
                self.shiftConversationStrip(-1);
            },
            'L' => {
                self.shiftConversationStrip(1);
            },
            '/' => {
                self.mode = .insert;
                if (self.input_buffer.items.len == 0) {
                    try self.input_buffer.append(self.allocator, '/');
                    self.input_cursor = 1;
                }
                self.syncPickersFromInput();
            },
            27 => self.mode = .normal,
            else => {},
        }
    }

    fn handleInsertByte(self: *App, key_byte: u8) !void {
        switch (key_byte) {
            27 => {
                if (self.model_picker_open) {
                    self.model_picker_open = false;
                    return;
                }
                if (self.command_picker_open) {
                    self.command_picker_open = false;
                    return;
                }
                if (self.file_picker_open) {
                    self.file_picker_open = false;
                    return;
                }
                self.mode = .normal;
            },
            127 => {
                if (self.input_cursor > 0) {
                    self.input_cursor -= 1;
                    _ = self.input_buffer.orderedRemove(self.input_cursor);
                }
                self.syncPickersFromInput();
            },
            '\r', '\n' => {
                if (self.model_picker_open) {
                    try self.acceptModelPickerSelection();
                    return;
                }
                if (self.command_picker_open) {
                    try self.acceptCommandPickerSelection();
                    return;
                }
                if (self.file_picker_open) {
                    try self.acceptFilePickerSelection();
                    return;
                }
                try self.submitInput();
            },
            '\t' => {
                if (self.model_picker_open) {
                    try self.acceptModelPickerSelection();
                    return;
                }
                if (self.command_picker_open) {
                    try self.acceptCommandPickerSelection();
                    return;
                }
                if (self.file_picker_open) {
                    try self.acceptFilePickerSelection();
                    return;
                }
            },
            14 => {
                if (self.model_picker_open) {
                    self.moveModelPickerSelection(1);
                } else if (self.command_picker_open) {
                    self.moveCommandPickerSelection(1);
                } else if (self.file_picker_open) {
                    self.moveFilePickerSelection(1);
                }
            },
            16 => {
                if (self.model_picker_open) {
                    self.moveModelPickerSelection(-1);
                } else if (self.command_picker_open) {
                    self.moveCommandPickerSelection(-1);
                } else if (self.file_picker_open) {
                    self.moveFilePickerSelection(-1);
                }
            },
            else => {
                if (key_byte >= 32 and key_byte <= 126) {
                    try self.input_buffer.insert(self.allocator, self.input_cursor, key_byte);
                    self.input_cursor += 1;
                    self.syncPickersFromInput();
                }
            },
        }
    }

    fn submitInput(self: *App) !void {
        const trimmed = std.mem.trim(u8, self.input_buffer.items, " \t\r\n");
        const line = try self.allocator.dupe(u8, trimmed);
        defer self.allocator.free(line);

        self.input_buffer.clearRetainingCapacity();
        self.input_cursor = 0;
        self.model_picker_open = false;
        self.command_picker_open = false;
        self.file_picker_open = false;

        if (line.len == 0) return;

        if (line[0] == '/') {
            self.model_picker_open = false;
            try self.handleCommand(line);
            return;
        }

        try self.handlePrompt(line);
    }

    fn handlePrompt(self: *App, prompt: []const u8) !void {
        const inject_result = try buildFileInjectionPayload(self.allocator, prompt);
        defer if (inject_result.payload) |payload| self.allocator.free(payload);

        try self.app_state.appendMessage(self.allocator, .user, prompt);
        if (inject_result.payload) |payload| {
            try self.app_state.appendMessage(self.allocator, .system, payload);
        }
        try self.app_state.appendMessage(self.allocator, .assistant, "");

        const provider_id = self.app_state.selected_provider_id;
        const model_id = self.app_state.selected_model_id;
        if (self.selectedModelContextWindow()) |window| {
            self.app_state.currentConversation().model_context_window = window;
        }

        const api_key = try self.resolveApiKey(provider_id);
        if (api_key == null) {
            try self.setLastAssistantMessage("[local] Missing API key for selected provider.");
            try self.setNoticeFmt("Set env var for provider {s} and retry. Example: {s}", .{
                provider_id,
                firstEnvVarForProvider(self, provider_id) orelse "<PROVIDER>_API_KEY",
            });
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            return;
        }
        defer self.allocator.free(api_key.?);

        self.is_streaming = true;
        self.stream_was_interrupted = false;
        self.stream_stop_for_suspend = false;
        self.stream_started_ms = std.time.milliTimestamp();
        self.resetStreamInterruptState();
        defer {
            self.is_streaming = false;
            self.stream_started_ms = 0;
            self.resetStreamInterruptState();
        }

        if (inject_result.referenced_count > 0) {
            try self.setNoticeFmt(
                "Injected {d}/{d} @file refs (skipped:{d})",
                .{
                    inject_result.included_count,
                    inject_result.referenced_count,
                    inject_result.skipped_count,
                },
            );
        }

        var step: usize = 0;
        while (step < TOOL_MAX_STEPS) : (step += 1) {
            const success = try self.streamAssistantOnce(provider_id, model_id, api_key.?);
            if (!success) break;

            const assistant_message = self.app_state.currentConversationConst().messages.items[self.app_state.currentConversationConst().messages.items.len - 1];
            const tool_call = parseAssistantToolCall(assistant_message.content) orelse break;
            switch (tool_call) {
                .read => |read_command| {
                    const read_command_owned = try self.allocator.dupe(u8, read_command);
                    defer self.allocator.free(read_command_owned);

                    const tool_note = try std.fmt.allocPrint(self.allocator, "[tool] READ {s}", .{read_command_owned});
                    defer self.allocator.free(tool_note);
                    try self.setLastAssistantMessage(tool_note);

                    const tool_result = try self.runReadToolCommand(read_command_owned);
                    defer self.allocator.free(tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNoticeFmt("Ran READ command: {s}", .{read_command_owned});
                },
                .apply_patch => |patch_text| {
                    const patch_text_owned = try self.allocator.dupe(u8, patch_text);
                    defer self.allocator.free(patch_text_owned);

                    try self.setLastAssistantMessage("[tool] APPLY_PATCH");

                    const tool_result = try self.runApplyPatchToolPatch(patch_text_owned);
                    defer self.allocator.free(tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran APPLY_PATCH tool");
                },
            }
            try self.render();
        }

        if (step == TOOL_MAX_STEPS) {
            const conversation = self.app_state.currentConversationConst();
            const last_message = conversation.messages.items[conversation.messages.items.len - 1];
            if (parseAssistantToolCall(last_message.content) != null) {
                try self.app_state.appendMessage(self.allocator, .system, "[tool-result]\nTool step limit reached. Continue without additional tool calls.");
            }
        }

        if (!self.stream_was_interrupted and provider_client.lastProviderErrorDetail() == null) {
            try self.setNoticeFmt("Completed response from {s}/{s}", .{ provider_id, model_id });
        }
        try self.app_state.saveToPath(self.allocator, self.paths.state_path);
    }

    fn streamAssistantOnce(self: *App, provider_id: []const u8, model_id: []const u8, api_key: []const u8) !bool {
        const provider_info = self.catalog.findProviderConst(provider_id);
        const request: provider_client.StreamRequest = .{
            .provider_id = provider_id,
            .model_id = model_id,
            .api_key = api_key,
            .base_url = if (provider_info) |info| info.api_base else null,
            .messages = try self.buildStreamMessages(true),
        };
        defer self.allocator.free(request.messages);

        try self.setNoticeFmt("Streaming from {s}/{s}...", .{ provider_id, model_id });
        try self.render();

        provider_client.streamChat(self.allocator, request, .{
            .on_token = onStreamToken,
            .on_usage = onStreamUsage,
            .context = self,
        }) catch |err| {
            if (err == error.StreamInterrupted) {
                self.stream_was_interrupted = true;
                if (self.stream_stop_for_suspend) {
                    try self.setNotice("Suspending... use fg to resume");
                } else {
                    try self.appendInterruptedMessage();
                    try self.setNotice("Streaming interrupted (Esc Esc)");
                }
                try self.app_state.saveToPath(self.allocator, self.paths.state_path);
                return false;
            }

            const provider_detail = provider_client.lastProviderErrorDetail();
            if (provider_detail) |detail| {
                try self.setNoticeFmt("Provider request failed: {s}", .{detail});
            } else {
                try self.setNoticeFmt("Provider request failed: {s}", .{@errorName(err)});
            }
            const conversation = self.app_state.currentConversationConst();
            const needs_paragraph_break = if (conversation.messages.items.len == 0) false else blk: {
                const last = conversation.messages.items[conversation.messages.items.len - 1];
                break :blk last.content.len > 0;
            };
            if (provider_detail) |detail| {
                const failure_line = try std.fmt.allocPrint(self.allocator, "[local] Request failed ({s}).", .{detail});
                defer self.allocator.free(failure_line);
                try self.appendToLastAssistantMessage(if (needs_paragraph_break) "\n\n" else "");
                try self.appendToLastAssistantMessage(failure_line);
            } else {
                try self.appendToLastAssistantMessage(if (needs_paragraph_break) "\n\n[local] Request failed." else "[local] Request failed.");
            }
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            return false;
        };
        return true;
    }

    fn appendInterruptedMessage(self: *App) !void {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len == 0) return;

        const last = conversation.messages.items[conversation.messages.items.len - 1];
        const needs_paragraph_break = last.role == .assistant and last.content.len > 0;
        if (needs_paragraph_break) {
            try self.appendToLastAssistantMessage("\n\n");
        }
        try self.appendToLastAssistantMessage("[local] Generation interrupted by user (Esc Esc).");
    }

    fn buildStreamMessages(self: *App, include_tool_prompt: bool) ![]provider_client.StreamMessage {
        const conversation = self.app_state.currentConversationConst();
        const conversation_len = conversation.messages.items.len;
        const skip_last_empty_assistant = conversation_len > 0 and
            conversation.messages.items[conversation_len - 1].role == .assistant and
            conversation.messages.items[conversation_len - 1].content.len == 0;

        const visible_count = if (skip_last_empty_assistant) conversation_len - 1 else conversation_len;
        const prompt_count: usize = if (include_tool_prompt) 1 else 0;
        const messages = try self.allocator.alloc(provider_client.StreamMessage, visible_count + prompt_count);

        var index: usize = 0;
        if (include_tool_prompt) {
            messages[index] = .{
                .role = .system,
                .content = TOOL_SYSTEM_PROMPT,
            };
            index += 1;
        }

        for (conversation.messages.items[0..visible_count]) |message| {
            messages[index] = .{
                .role = message.role,
                .content = message.content,
            };
            index += 1;
        }

        return messages;
    }

    fn runReadToolCommand(self: *App, command_text: []const u8) ![]u8 {
        var parsed_args = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(self.allocator, command_text);
        defer parsed_args.deinit();

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        while (parsed_args.next()) |token| {
            try argv.append(self.allocator, token);
            if (argv.items.len > 64) {
                return std.fmt.allocPrint(self.allocator, "[read-result]\ncommand: {s}\nerror: too many arguments", .{command_text});
            }
        }

        if (argv.items.len == 0) {
            return std.fmt.allocPrint(self.allocator, "[read-result]\ncommand: {s}\nerror: empty command", .{command_text});
        }

        if (!isAllowedReadCommand(argv.items[0])) {
            return std.fmt.allocPrint(
                self.allocator,
                "[read-result]\ncommand: {s}\nerror: command not allowed ({s})",
                .{ command_text, argv.items[0] },
            );
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = ".",
            .max_output_bytes = READ_TOOL_MAX_OUTPUT_BYTES,
        }) catch |err| {
            return std.fmt.allocPrint(
                self.allocator,
                "[read-result]\ncommand: {s}\nerror: {s}",
                .{ command_text, @errorName(err) },
            );
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        try output.writer.print("[read-result]\ncommand: {s}\nterm: ", .{command_text});
        switch (result.term) {
            .Exited => |code| try output.writer.print("exited:{d}\n", .{code}),
            .Signal => |sig| try output.writer.print("signal:{d}\n", .{sig}),
            .Stopped => |sig| try output.writer.print("stopped:{d}\n", .{sig}),
            .Unknown => |code| try output.writer.print("unknown:{d}\n", .{code}),
        }

        if (result.stdout.len > 0) {
            try output.writer.writeAll("stdout:\n");
            try output.writer.writeAll(result.stdout);
            if (result.stdout[result.stdout.len - 1] != '\n') try output.writer.writeByte('\n');
        }

        if (result.stderr.len > 0) {
            try output.writer.writeAll("stderr:\n");
            try output.writer.writeAll(result.stderr);
            if (result.stderr[result.stderr.len - 1] != '\n') try output.writer.writeByte('\n');
        }

        if (result.stdout.len == 0 and result.stderr.len == 0) {
            try output.writer.writeAll("stdout:\n(no output)\n");
        }

        return output.toOwnedSlice();
    }

    fn runApplyPatchToolPatch(self: *App, patch_text: []const u8) ![]u8 {
        const trimmed_patch = std.mem.trim(u8, patch_text, " \t\r\n");
        if (trimmed_patch.len == 0) {
            return self.allocator.dupe(u8, "[apply-patch-result]\nerror: empty patch payload");
        }

        if (trimmed_patch.len > APPLY_PATCH_TOOL_MAX_PATCH_BYTES) {
            return std.fmt.allocPrint(
                self.allocator,
                "[apply-patch-result]\nerror: patch too large ({d} bytes > {d})",
                .{ trimmed_patch.len, APPLY_PATCH_TOOL_MAX_PATCH_BYTES },
            );
        }

        if (!isValidApplyPatchPayload(trimmed_patch)) {
            return self.allocator.dupe(u8, "[apply-patch-result]\nerror: invalid patch payload; expected codex apply_patch format");
        }

        const stats = patch_tool.applyCodexPatch(self.allocator, trimmed_patch) catch |err| {
            const detail = switch (err) {
                error.FileNotFound => "target file not found",
                error.UpdateTargetMissing => "update target file not found (use *** Add File for new files)",
                error.DeleteTargetMissing => "delete target file not found",
                error.AddTargetExists => "add target already exists (use *** Update File instead)",
                error.PatchContextNotFound => "patch context not found in target file",
                error.MissingBeginPatch => "missing *** Begin Patch header",
                error.MissingEndPatch => "missing *** End Patch trailer",
                error.InvalidPatchHeader => "invalid patch operation header",
                error.InvalidPatchPath => "invalid or empty patch path",
                error.InvalidAddFileLine => "invalid add-file body line (expected leading +)",
                error.InvalidUpdateLine => "invalid update hunk line (expected ' ', '+', '-', or @@)",
                error.EmptyPatchOperations => "patch contains no operations",
                else => @errorName(err),
            };
            return std.fmt.allocPrint(
                self.allocator,
                "[apply-patch-result]\nerror: {s}",
                .{detail},
            );
        };

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        try output.writer.print(
            "[apply-patch-result]\nbytes: {d}\nops:{d} files_changed:{d} added:{d} updated:{d} deleted:{d} moved:{d}\nstatus: ok\n",
            .{
                trimmed_patch.len,
                stats.operations,
                stats.files_changed,
                stats.added,
                stats.updated,
                stats.deleted,
                stats.moved,
            },
        );

        return output.toOwnedSlice();
    }

    fn onStreamToken(context: ?*anyopaque, token: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        if (try self.pollStreamInterrupt()) {
            return error.StreamInterrupted;
        }
        if (token.len == 0) {
            try self.render();
            return;
        }
        try self.appendToLastAssistantMessage(token);
        try self.render();
    }

    fn onStreamUsage(context: ?*anyopaque, usage: TokenUsage) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        self.app_state.appendTokenUsage(usage, self.selectedModelContextWindow());
    }

    fn resetStreamInterruptState(self: *App) void {
        self.stream_interrupt_esc_count = 0;
        self.stream_interrupt_last_esc_ms = 0;
        self.stream_interrupt_hint_shown = false;
    }

    fn pollStreamInterrupt(self: *App) !bool {
        while (try stdinHasPendingByte(0)) {
            var byte_buf: [1]u8 = undefined;
            const read_len = try std.posix.read(std.fs.File.stdin().handle, byte_buf[0..]);
            if (read_len == 0) break;

            if (byte_buf[0] == 26) {
                self.stream_stop_for_suspend = true;
                self.suspend_requested = true;
                return true;
            }

            const now_ms = std.time.milliTimestamp();
            if (registerStreamInterruptByte(
                &self.stream_interrupt_esc_count,
                &self.stream_interrupt_last_esc_ms,
                byte_buf[0],
                now_ms,
            )) {
                return true;
            }

            if (self.stream_interrupt_esc_count == 1 and !self.stream_interrupt_hint_shown) {
                self.stream_interrupt_hint_shown = true;
                try self.setNotice("Press Esc again to stop stream");
            }
        }
        return false;
    }

    fn appendToLastAssistantMessage(self: *App, token: []const u8) !void {
        const conversation = self.app_state.currentConversation();
        if (conversation.messages.items.len == 0) return;

        const message = &conversation.messages.items[conversation.messages.items.len - 1];

        const old_len = message.content.len;
        message.content = try self.allocator.realloc(message.content, old_len + token.len);
        @memcpy(message.content[old_len..], token);
        message.timestamp_ms = std.time.milliTimestamp();
        conversation.updated_ms = message.timestamp_ms;
    }

    fn setLastAssistantMessage(self: *App, text: []const u8) !void {
        const conversation = self.app_state.currentConversation();
        if (conversation.messages.items.len == 0) return;

        const message = &conversation.messages.items[conversation.messages.items.len - 1];
        if (message.role != .assistant) return;

        const replacement = try self.allocator.dupe(u8, text);
        self.allocator.free(message.content);
        message.content = replacement;
        message.timestamp_ms = std.time.milliTimestamp();
        conversation.updated_ms = message.timestamp_ms;
    }

    fn handleCommand(self: *App, line: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, line[1..], " \t");
        const command = parts.next() orelse {
            try self.setNotice("Empty command. Try /help");
            return;
        };

        if (std.mem.eql(u8, command, "help")) {
            try self.setNotice("Commands: /help /provider [id] /model [id] /models [refresh] /files [refresh] /new [title] /list /switch <id> /title <text> /theme [codex|plain|forest] /ui [compact|comfy] /quit  input: use @path, pickers: Ctrl-N/P + Enter, assistant tools: <READ>rg --files</READ> and <APPLY_PATCH>*** Begin Patch ...");
            return;
        }

        if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "q")) {
            self.should_exit = true;
            return;
        }

        if (std.mem.eql(u8, command, "provider")) {
            const provider_id = parts.next();
            if (provider_id == null) {
                try self.setNoticeFmt("Current provider: {s}", .{self.app_state.selected_provider_id});
                return;
            }

            try self.app_state.setSelectedProvider(self.allocator, provider_id.?);
            if (!self.catalog.hasModel(provider_id.?, self.app_state.selected_model_id)) {
                if (self.catalog.findProviderConst(provider_id.?)) |provider| {
                    if (provider.models.items.len > 0) {
                        try self.app_state.setSelectedModel(self.allocator, provider.models.items[0].id);
                    }
                }
            }
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Provider set to {s}", .{provider_id.?});
            return;
        }

        if (std.mem.eql(u8, command, "model")) {
            const model_id = parts.next();
            if (model_id == null) {
                const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id);
                if (provider) |info| {
                    var line_writer: std.Io.Writer.Allocating = .init(self.allocator);
                    defer line_writer.deinit();
                    try line_writer.writer.print("Current model: {s}. Examples: ", .{self.app_state.selected_model_id});
                    const limit = @min(info.models.items.len, 4);
                    for (info.models.items[0..limit], 0..) |model, index| {
                        if (index > 0) try line_writer.writer.writeAll(", ");
                        try line_writer.writer.writeAll(model.id);
                    }
                    const notice = try line_writer.toOwnedSlice();
                    try self.setNoticeOwned(notice);
                } else {
                    try self.setNoticeFmt("Current model: {s}", .{self.app_state.selected_model_id});
                }
                return;
            }

            try self.app_state.setSelectedModel(self.allocator, model_id.?);
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);

            if (!self.catalog.hasModel(self.app_state.selected_provider_id, model_id.?)) {
                try self.setNoticeFmt("Model set to {s} (not found in cache for provider {s})", .{ model_id.?, self.app_state.selected_provider_id });
            } else {
                try self.setNoticeFmt("Model set to {s}", .{model_id.?});
            }
            return;
        }

        if (std.mem.eql(u8, command, "models")) {
            const action = parts.next();
            if (action != null and std.mem.eql(u8, action.?, "refresh")) {
                models.refreshToPath(self.allocator, self.paths.models_cache_path) catch |err| {
                    try self.setNoticeFmt("models refresh failed: {s}", .{@errorName(err)});
                    return;
                };

                const fresh_catalog = models.loadFromPath(self.allocator, self.paths.models_cache_path) catch |err| {
                    try self.setNoticeFmt("failed to reload models cache: {s}", .{@errorName(err)});
                    return;
                };

                self.catalog.deinit(self.allocator);
                self.catalog.* = fresh_catalog;

                try self.setNoticeFmt("models cache refreshed ({d} providers)", .{self.catalog.providers.items.len});
                return;
            }

            try self.setNoticeFmt("models cache has {d} providers. Use /model to inspect current provider.", .{self.catalog.providers.items.len});
            return;
        }

        if (std.mem.eql(u8, command, "files")) {
            const action = parts.next();
            if (action != null and std.mem.eql(u8, action.?, "refresh")) {
                self.refreshFileIndex() catch |err| {
                    try self.setNoticeFmt("file index refresh failed: {s}", .{@errorName(err)});
                    return;
                };
                try self.setNoticeFmt("file index refreshed ({d} files)", .{self.file_index.items.len});
                return;
            }

            try self.setNoticeFmt("file index has {d} files. Use /files refresh after file changes.", .{self.file_index.items.len});
            return;
        }

        if (std.mem.eql(u8, command, "new")) {
            const title = blk: {
                const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse break :blk "New conversation";
                const remainder = std.mem.trim(u8, line[first_space + 1 ..], " ");
                if (remainder.len == 0) break :blk "New conversation";
                break :blk remainder;
            };
            _ = try self.app_state.createConversation(self.allocator, title);
            self.scroll_lines = 0;
            self.ensureCurrentConversationVisibleInStrip();
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Created conversation: {s}", .{self.app_state.currentConversationConst().id});
            return;
        }

        if (std.mem.eql(u8, command, "list")) {
            var line_writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer line_writer.deinit();

            try line_writer.writer.writeAll("Conversations: ");
            const limit = @min(self.app_state.conversations.items.len, 6);
            for (self.app_state.conversations.items[0..limit], 0..) |conversation, index| {
                if (index > 0) try line_writer.writer.writeAll(" | ");
                const current_mark = if (index == self.app_state.current_index) "*" else "";
                try line_writer.writer.print("{s}{s}:{s}", .{ current_mark, conversation.id, conversation.title });
            }

            const notice = try line_writer.toOwnedSlice();
            try self.setNoticeOwned(notice);
            return;
        }

        if (std.mem.eql(u8, command, "switch")) {
            const conversation_id = parts.next() orelse {
                try self.setNotice("Usage: /switch <conversation-id>");
                return;
            };

            if (!self.app_state.switchConversation(conversation_id)) {
                try self.setNoticeFmt("Conversation not found: {s}", .{conversation_id});
                return;
            }

            self.scroll_lines = 0;
            self.ensureCurrentConversationVisibleInStrip();
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Switched to conversation: {s}", .{conversation_id});
            return;
        }

        if (std.mem.eql(u8, command, "title")) {
            const title_offset = std.mem.indexOf(u8, line, " ") orelse {
                try self.setNotice("Usage: /title <new title>");
                return;
            };
            const title = std.mem.trim(u8, line[title_offset + 1 ..], " ");
            if (title.len == 0) {
                try self.setNotice("Usage: /title <new title>");
                return;
            }

            try self.app_state.setConversationTitle(self.allocator, title);
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Conversation renamed to: {s}", .{title});
            return;
        }

        if (std.mem.eql(u8, command, "theme")) {
            const theme_name = parts.next();
            if (theme_name == null) {
                try self.setNoticeFmt("Current theme: {s}", .{@tagName(self.theme)});
                return;
            }

            if (std.mem.eql(u8, theme_name.?, "codex")) self.theme = .codex else if (std.mem.eql(u8, theme_name.?, "plain")) self.theme = .plain else if (std.mem.eql(u8, theme_name.?, "forest")) self.theme = .forest else {
                try self.setNotice("Unknown theme. Use: codex, plain, forest");
                return;
            }

            try self.setNoticeFmt("Theme set to {s}", .{theme_name.?});
            return;
        }

        if (std.mem.eql(u8, command, "ui")) {
            const mode_name = parts.next() orelse {
                try self.setNoticeFmt("UI mode: {s}", .{if (self.compact_mode) "compact" else "comfy"});
                return;
            };

            if (std.mem.eql(u8, mode_name, "compact")) {
                self.compact_mode = true;
                try self.setNotice("UI mode set to compact");
                return;
            }
            if (std.mem.eql(u8, mode_name, "comfy")) {
                self.compact_mode = false;
                try self.setNotice("UI mode set to comfy");
                return;
            }

            try self.setNotice("Usage: /ui [compact|comfy]");
            return;
        }

        try self.setNoticeFmt("Unknown command: /{s}", .{command});
    }

    fn resolveApiKey(self: *App, provider_id: []const u8) !?[]u8 {
        if (self.catalog.findProviderConst(provider_id)) |provider| {
            if (provider.env_vars.items.len > 0) {
                for (provider.env_vars.items) |env_var| {
                    const value = std.process.getEnvVarOwned(self.allocator, env_var) catch |err| switch (err) {
                        error.EnvironmentVariableNotFound => null,
                        else => return err,
                    };
                    if (value) |key| return key;
                }
            }
        }

        const fallback = fallbackEnvVars(provider_id);
        for (fallback) |env_var| {
            const value = std.process.getEnvVarOwned(self.allocator, env_var) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (value) |key| return key;
        }

        return null;
    }

    fn setNotice(self: *App, text: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, text);
        self.allocator.free(self.notice);
        self.notice = replacement;
    }

    fn setNoticeOwned(self: *App, owned_text: []u8) !void {
        self.allocator.free(self.notice);
        self.notice = owned_text;
    }

    fn setNoticeFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.setNoticeOwned(text);
    }

    fn render(self: *App) !void {
        var screen_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer screen_writer.deinit();

        const conversation = self.app_state.currentConversationConst();
        const palette = paletteForTheme(self.theme);

        const metrics = self.terminalMetrics();
        const width = metrics.width;
        const lines = metrics.lines;
        const content_width = if (width > 4) width - 4 else 56;
        const top_lines: usize = if (self.compact_mode) 3 else 4;
        const picker_lines = self.pickerLineCount(lines);
        const bottom_lines: usize = 3 + picker_lines;
        const viewport_height = @max(@as(usize, 4), lines - top_lines - bottom_lines);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        const now_ms = std.time.milliTimestamp();
        const last_index = if (conversation.messages.items.len == 0) @as(usize, 0) else conversation.messages.items.len - 1;
        for (conversation.messages.items, 0..) |message, index| {
            const loading_placeholder = if (self.is_streaming and
                index == last_index and
                message.role == .assistant and
                message.content.len == 0)
                try buildWorkingPlaceholder(self.allocator, content_width, self.stream_started_ms, now_ms)
            else
                null;
            defer if (loading_placeholder) |text| self.allocator.free(text);

            try appendMessageBlock(
                &body_writer.writer,
                message,
                content_width,
                palette,
                self.compact_mode,
                loading_placeholder,
            );
        }
        const body = try body_writer.toOwnedSlice();
        defer self.allocator.free(body);

        var body_lines: std.ArrayList([]const u8) = .empty;
        defer body_lines.deinit(self.allocator);
        var split_lines = std.mem.splitScalar(u8, body, '\n');
        while (split_lines.next()) |line| {
            try body_lines.append(self.allocator, line);
        }
        if (body_lines.items.len > 0 and body_lines.items[body_lines.items.len - 1].len == 0) {
            _ = body_lines.orderedRemove(body_lines.items.len - 1);
        }

        const total_body_lines = body_lines.items.len;
        const max_scroll = if (total_body_lines > viewport_height) total_body_lines - viewport_height else 0;
        if (self.scroll_lines > max_scroll) self.scroll_lines = max_scroll;

        const start_line = if (total_body_lines > viewport_height) total_body_lines - viewport_height - self.scroll_lines else 0;
        const end_line = @min(start_line + viewport_height, total_body_lines);

        try screen_writer.writer.writeAll("\x1b[2J\x1b[H");

        const mode_label = if (self.mode == .insert) "insert" else "normal";
        const stream_label = if (self.is_streaming) "streaming" else "idle";
        const short_conv_id = if (conversation.id.len > 10) conversation.id[0..10] else conversation.id;

        if (self.compact_mode) {
            const compact = try std.fmt.allocPrint(
                self.allocator,
                "Zolt  {s}/{s}  mode:{s}  conv:{s}  {s}",
                .{ self.app_state.selected_provider_id, self.app_state.selected_model_id, mode_label, short_conv_id, stream_label },
            );
            defer self.allocator.free(compact);
            const compact_line = try truncateLineAlloc(self.allocator, compact, width);
            defer self.allocator.free(compact_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.header, compact_line, palette.reset });

            const conversation_strip = try self.buildConversationStrip(width);
            defer self.allocator.free(conversation_strip);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, conversation_strip, palette.reset });
        } else {
            const title = try std.fmt.allocPrint(
                self.allocator,
                "Zolt  mode:{s}  conv:{s}",
                .{ mode_label, conversation.id },
            );
            defer self.allocator.free(title);
            const title_line = try truncateLineAlloc(self.allocator, title, width);
            defer self.allocator.free(title_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.header, title_line, palette.reset });

            const model_line = try std.fmt.allocPrint(
                self.allocator,
                "model: {s}/{s}  theme:{s}  ui:{s}  status:{s}",
                .{ self.app_state.selected_provider_id, self.app_state.selected_model_id, @tagName(self.theme), if (self.compact_mode) "compact" else "comfy", stream_label },
            );
            defer self.allocator.free(model_line);
            const model_trimmed = try truncateLineAlloc(self.allocator, model_line, width);
            defer self.allocator.free(model_trimmed);
            try screen_writer.writer.writeAll(model_trimmed);
            try screen_writer.writer.writeByte('\n');

            const note_text = try std.fmt.allocPrint(self.allocator, "note: {s}", .{self.notice});
            defer self.allocator.free(note_text);
            const note_line = try truncateLineAlloc(self.allocator, note_text, width);
            defer self.allocator.free(note_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, note_line, palette.reset });
        }

        try writeRule(&screen_writer.writer, width, palette, self.compact_mode);

        var rendered_lines: usize = 0;
        for (body_lines.items[start_line..end_line]) |line| {
            try screen_writer.writer.writeAll(line);
            try screen_writer.writer.writeByte('\n');
            rendered_lines += 1;
        }
        while (rendered_lines < viewport_height) : (rendered_lines += 1) {
            try screen_writer.writer.writeByte('\n');
        }

        try writeRule(&screen_writer.writer, width, palette, self.compact_mode);

        const key_hint = if (self.is_streaming)
            "esc esc stop"
        else if (self.model_picker_open)
            "ctrl-n/p or up/down, enter/tab select, esc close"
        else if (self.command_picker_open)
            "ctrl-n/p or up/down, enter/tab insert, esc close"
        else if (self.file_picker_open)
            "ctrl-n/p or up/down, enter/tab insert, esc close"
        else if (self.mode == .insert)
            "enter esc /"
        else
            "i j/k H/L / q";
        const context_summary = try self.contextUsageSummary(conversation);
        defer if (context_summary) |summary| self.allocator.free(summary);
        const status_text = if (context_summary) |summary|
            try std.fmt.allocPrint(
                self.allocator,
                "{s} | {s} | keys:{s} | scroll:{d}/{d}",
                .{ self.notice, summary, key_hint, self.scroll_lines, max_scroll },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{s} | keys:{s} | scroll:{d}/{d}",
                .{ self.notice, key_hint, self.scroll_lines, max_scroll },
            );
        defer self.allocator.free(status_text);
        const status_line = try truncateLineAlloc(self.allocator, status_text, width);
        defer self.allocator.free(status_line);
        try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, status_line, palette.reset });

        if (self.model_picker_open) {
            try self.renderModelPicker(&screen_writer.writer, width, lines, palette);
        } else if (self.command_picker_open) {
            try self.renderCommandPicker(&screen_writer.writer, width, lines, palette);
        } else if (self.file_picker_open) {
            try self.renderFilePicker(&screen_writer.writer, width, lines, palette);
        }

        const before_cursor = self.input_buffer.items[0..self.input_cursor];
        const after_cursor = self.input_buffer.items[self.input_cursor..];
        const input_view = try buildInputView(self.allocator, before_cursor, after_cursor, if (width > 10) width - 10 else 22);
        defer self.allocator.free(input_view.text);
        try screen_writer.writer.print("{s}[{s}]>{s} {s}", .{ palette.accent, if (self.mode == .insert) "INS" else "NOR", palette.reset, input_view.text });

        const cursor = computeInputCursorPlacement(
            width,
            lines,
            self.compact_mode,
            viewport_height,
            picker_lines,
            input_view.cursor_col,
        );
        try screen_writer.writer.print("\x1b[{d};{d}H", .{ cursor.row, cursor.col });

        const screen = try screen_writer.toOwnedSlice();
        defer self.allocator.free(screen);

        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        defer stdout_writer.interface.flush() catch {};

        try stdout_writer.interface.writeAll(screen);
    }

    fn buildConversationStrip(self: *App, width: usize) ![]u8 {
        var strip_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer strip_writer.deinit();

        const conversations = self.app_state.conversations.items;
        const total = conversations.len;
        if (total == 0) return self.allocator.dupe(u8, "convs: none");

        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;
        const start_index = @min(self.conv_strip_start, max_start);
        const max_items: usize = @min(total - start_index, window_size);
        const end_index = @min(start_index + max_items, total);

        try strip_writer.writer.print("convs({d}/{d}):", .{ self.app_state.current_index + 1, total });
        if (start_index > 0) try strip_writer.writer.writeAll(" ..");

        for (conversations[start_index..end_index], start_index..) |conv, index| {
            const marker = if (index == self.app_state.current_index) "*" else "";
            const short_id = conv.id[0..@min(conv.id.len, 6)];
            const title_limit: usize = 14;

            try strip_writer.writer.print(" {s}{s}:", .{ marker, short_id });
            if (conv.title.len <= title_limit) {
                try strip_writer.writer.writeAll(conv.title);
            } else {
                try strip_writer.writer.writeAll(conv.title[0 .. title_limit - 3]);
                try strip_writer.writer.writeAll("...");
            }

            if (index + 1 < end_index) try strip_writer.writer.writeAll(" |");
        }

        if (end_index < total) try strip_writer.writer.writeAll(" ..");

        const raw = try strip_writer.toOwnedSlice();
        defer self.allocator.free(raw);
        return truncateLineAlloc(self.allocator, raw, width);
    }

    fn shiftConversationStrip(self: *App, delta: i32) void {
        const total = self.app_state.conversations.items.len;
        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;

        if (delta < 0) {
            if (self.conv_strip_start > 0) self.conv_strip_start -= 1;
            return;
        }
        if (delta > 0) {
            if (self.conv_strip_start < max_start) self.conv_strip_start += 1;
        }
    }

    fn ensureCurrentConversationVisibleInStrip(self: *App) void {
        const total = self.app_state.conversations.items.len;
        if (total == 0) {
            self.conv_strip_start = 0;
            return;
        }

        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;
        const current = self.app_state.current_index;

        if (current < self.conv_strip_start) {
            self.conv_strip_start = current;
        } else if (current >= self.conv_strip_start + window_size) {
            self.conv_strip_start = current - window_size + 1;
        }

        if (self.conv_strip_start > max_start) self.conv_strip_start = max_start;
    }

    fn terminalMetrics(_: *App) TerminalMetrics {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd) {
            var winsize: std.posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };
            const rc = std.posix.system.ioctl(std.fs.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (std.posix.errno(rc) == .SUCCESS and winsize.col > 0 and winsize.row > 0) {
                return .{
                    .width = std.math.clamp(@as(usize, winsize.col), 64, 220),
                    .lines = std.math.clamp(@as(usize, winsize.row), 20, 120),
                };
            }
        }

        const env_width = std.process.parseEnvVarInt("COLUMNS", usize, 10) catch 120;
        const env_lines = std.process.parseEnvVarInt("LINES", usize, 10) catch 40;
        return .{
            .width = std.math.clamp(env_width, 64, 220),
            .lines = std.math.clamp(env_lines, 20, 120),
        };
    }

    fn parseModelPickerQuery(input: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, input, "/model")) return null;
        if (input.len == 6) return "";
        if (input.len > 6 and input[6] == ' ') return std.mem.trimLeft(u8, input[7..], " ");
        return null;
    }

    fn syncPickersFromInput(self: *App) void {
        self.syncModelPickerFromInput();
        if (self.model_picker_open) {
            self.command_picker_open = false;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        self.syncCommandPickerFromInput();
        if (self.command_picker_open) {
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        self.syncFilePickerFromInput();
    }

    fn syncModelPickerFromInput(self: *App) void {
        const query = parseModelPickerQuery(self.input_buffer.items);
        if (query == null) {
            self.model_picker_open = false;
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }

        if (!self.model_picker_open) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
        }
        self.model_picker_open = true;

        const total = self.modelPickerMatchCount(query.?);
        if (total == 0) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }
        if (self.model_picker_index >= total) self.model_picker_index = total - 1;
    }

    fn syncCommandPickerFromInput(self: *App) void {
        const query = parseCommandPickerQuery(self.input_buffer.items, self.input_cursor) orelse {
            self.command_picker_open = false;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        };

        if (!self.command_picker_open) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
        }
        self.command_picker_open = true;

        const total = self.commandPickerMatchCount(query);
        if (total == 0) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        }
        if (self.command_picker_index >= total) self.command_picker_index = total - 1;
    }

    fn syncFilePickerFromInput(self: *App) void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse {
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        };

        if (!self.file_picker_open) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
        }
        self.file_picker_open = true;

        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }
        if (self.file_picker_index >= total) self.file_picker_index = total - 1;
    }

    fn modelPickerMatchCount(self: *App, query: []const u8) usize {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return 0;
        var count: usize = 0;
        for (provider.models.items) |model| {
            if (modelMatchesQuery(model, query)) count += 1;
        }
        return count;
    }

    fn selectedModelContextWindow(self: *App) ?i64 {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return null;
        for (provider.models.items) |model| {
            if (std.mem.eql(u8, model.id, self.app_state.selected_model_id)) {
                return model.context_window;
            }
        }
        return null;
    }

    fn contextUsageSummary(self: *App, conversation: *const Conversation) !?[]u8 {
        const usage = conversation.last_token_usage;
        const window = conversation.model_context_window orelse self.selectedModelContextWindow();
        if (usage.isZero() and window == null) return null;

        const used = usage.tokensInContextWindow();
        const used_text = try formatTokenCount(self.allocator, used);
        defer self.allocator.free(used_text);

        if (window) |context_window| {
            const full_text = try formatTokenCount(self.allocator, context_window);
            defer self.allocator.free(full_text);
            const left_percent = usage.percentOfContextWindowRemaining(context_window);
            return @as(?[]u8, try std.fmt.allocPrint(self.allocator, "ctx:{s}/{s} {d}% left", .{ used_text, full_text, left_percent }));
        }

        return @as(?[]u8, try std.fmt.allocPrint(self.allocator, "ctx:{s} used", .{used_text}));
    }

    fn modelPickerNthMatch(self: *App, query: []const u8, target_index: usize) ?*const models.ModelInfo {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return null;
        var seen: usize = 0;
        for (provider.models.items) |*model| {
            if (!modelMatchesQuery(model.*, query)) continue;
            if (seen == target_index) return model;
            seen += 1;
        }
        return null;
    }

    fn moveModelPickerSelection(self: *App, delta: i32) void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        if (total == 0) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.model_picker_index > 0) self.model_picker_index -= 1;
        } else if (delta > 0) {
            if (self.model_picker_index + 1 < total) self.model_picker_index += 1;
        }
    }

    fn acceptModelPickerSelection(self: *App) !void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        if (total == 0) {
            try self.setNotice("No model matches the current filter");
            return;
        }

        if (self.model_picker_index >= total) self.model_picker_index = total - 1;
        const selected = self.modelPickerNthMatch(query, self.model_picker_index) orelse return;

        try self.app_state.setSelectedModel(self.allocator, selected.id);
        try self.app_state.saveToPath(self.allocator, self.paths.state_path);
        try self.setNoticeFmt("Model set to {s}", .{selected.id});

        self.input_buffer.clearRetainingCapacity();
        self.input_cursor = 0;
        self.model_picker_open = false;
        self.model_picker_index = 0;
        self.model_picker_scroll = 0;
    }

    fn modelPickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.model_picker_open) return 0;

        const query = parseModelPickerQuery(self.input_buffer.items) orelse return 0;
        const total = self.modelPickerMatchCount(query);
        const max_rows = self.modelPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn filePickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.file_picker_open) return 0;

        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return 0;
        const total = self.filePickerMatchCount(query);
        const max_rows = self.filePickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn commandPickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.command_picker_open) return 0;

        const query = parseCommandPickerQuery(self.input_buffer.items, self.input_cursor) orelse return 0;
        const total = self.commandPickerMatchCount(query);
        const max_rows = self.commandPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn pickerLineCount(self: *App, terminal_lines: usize) usize {
        if (self.model_picker_open) return self.modelPickerLineCount(terminal_lines);
        if (self.command_picker_open) return self.commandPickerLineCount(terminal_lines);
        if (self.file_picker_open) return self.filePickerLineCount(terminal_lines);
        return 0;
    }

    fn modelPickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(MODEL_PICKER_MAX_ROWS, budget);
    }

    fn filePickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(FILE_PICKER_MAX_ROWS, budget);
    }

    fn commandPickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(COMMAND_PICKER_MAX_ROWS, budget);
    }

    fn renderModelPicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        const max_rows = self.modelPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.model_picker_index >= total) self.model_picker_index = total - 1;
            if (self.model_picker_index < self.model_picker_scroll) {
                self.model_picker_scroll = self.model_picker_index;
            } else if (self.model_picker_index >= self.model_picker_scroll + shown_rows) {
                self.model_picker_scroll = self.model_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.model_picker_scroll > max_scroll) self.model_picker_scroll = max_scroll;
        } else {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "model picker ({d}) provider:{s} query:{s}",
            .{ total, self.app_state.selected_provider_id, if (query.len == 0) "*" else query },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.model_picker_scroll + shown_rows, total);
        var index = self.model_picker_scroll;
        while (index < end_index) : (index += 1) {
            const model = self.modelPickerNthMatch(query, index) orelse continue;
            const selected = index == self.model_picker_index;
            const marker = if (selected) ">" else " ";
            const row_color = if (selected) palette.accent else palette.dim;

            const row_text = if (std.mem.eql(u8, model.id, model.name))
                try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, model.id })
            else
                try std.fmt.allocPrint(self.allocator, "{s} {s} ({s})", .{ marker, model.id, model.name });
            defer self.allocator.free(row_text);

            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn filePickerMatchCount(self: *App, query: []const u8) usize {
        var count: usize = 0;
        for (self.file_index.items) |path| {
            if (filePathMatchesQuery(path, query)) count += 1;
        }
        return count;
    }

    fn commandPickerMatchCount(_: *App, query: []const u8) usize {
        var count: usize = 0;
        for (BUILTIN_COMMANDS) |entry| {
            if (commandMatchesQuery(entry, query)) count += 1;
        }
        return count;
    }

    fn filePickerNthMatch(self: *App, query: []const u8, target_index: usize) ?[]const u8 {
        var seen: usize = 0;
        for (self.file_index.items) |path| {
            if (!filePathMatchesQuery(path, query)) continue;
            if (seen == target_index) return path;
            seen += 1;
        }
        return null;
    }

    fn commandPickerNthMatch(_: *App, query: []const u8, target_index: usize) ?BuiltinCommandEntry {
        var seen: usize = 0;
        for (BUILTIN_COMMANDS) |entry| {
            if (!commandMatchesQuery(entry, query)) continue;
            if (seen == target_index) return entry;
            seen += 1;
        }
        return null;
    }

    fn moveFilePickerSelection(self: *App, delta: i32) void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.file_picker_index > 0) self.file_picker_index -= 1;
        } else if (delta > 0) {
            if (self.file_picker_index + 1 < total) self.file_picker_index += 1;
        }
    }

    fn moveCommandPickerSelection(self: *App, delta: i32) void {
        const query = parseCommandPickerQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.commandPickerMatchCount(query);
        if (total == 0) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.command_picker_index > 0) self.command_picker_index -= 1;
        } else if (delta > 0) {
            if (self.command_picker_index + 1 < total) self.command_picker_index += 1;
        }
    }

    fn acceptFilePickerSelection(self: *App) !void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            try self.setNotice("No file matches current @query");
            return;
        }

        if (self.file_picker_index >= total) self.file_picker_index = total - 1;
        const selected = self.filePickerNthMatch(query, self.file_picker_index) orelse return;

        try self.insertSelectedFilePathAtCursor(selected);
        self.file_picker_open = false;
        self.file_picker_index = 0;
        self.file_picker_scroll = 0;
        try self.setNoticeFmt("Inserted @{s}", .{selected});
    }

    fn acceptCommandPickerSelection(self: *App) !void {
        const query = parseCommandPickerQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.commandPickerMatchCount(query);
        if (total == 0) {
            try self.setNotice("No slash command matches current query");
            return;
        }

        if (self.command_picker_index >= total) self.command_picker_index = total - 1;
        const selected = self.commandPickerNthMatch(query, self.command_picker_index) orelse return;

        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, "/");
        try self.input_buffer.appendSlice(self.allocator, selected.name);
        if (selected.insert_trailing_space) {
            try self.input_buffer.append(self.allocator, ' ');
        }
        self.input_cursor = self.input_buffer.items.len;
        self.command_picker_open = false;
        self.command_picker_index = 0;
        self.command_picker_scroll = 0;

        try self.setNoticeFmt("Inserted /{s}", .{selected.name});
        self.syncPickersFromInput();
    }

    fn insertSelectedFilePathAtCursor(self: *App, path: []const u8) !void {
        const rewritten = try rewriteInputWithSelectedAtPath(self.allocator, self.input_buffer.items, self.input_cursor, path);
        defer self.allocator.free(rewritten.text);

        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, rewritten.text);
        self.input_cursor = rewritten.cursor;
    }

    fn renderFilePicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        const max_rows = self.filePickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.file_picker_index >= total) self.file_picker_index = total - 1;
            if (self.file_picker_index < self.file_picker_scroll) {
                self.file_picker_scroll = self.file_picker_index;
            } else if (self.file_picker_index >= self.file_picker_scroll + shown_rows) {
                self.file_picker_scroll = self.file_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.file_picker_scroll > max_scroll) self.file_picker_scroll = max_scroll;
        } else {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "file picker ({d}) query:{s}",
            .{ total, if (query.len == 0) "*" else query },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.file_picker_scroll + shown_rows, total);
        var index = self.file_picker_scroll;
        while (index < end_index) : (index += 1) {
            const selected_path = self.filePickerNthMatch(query, index) orelse continue;
            const selected = index == self.file_picker_index;
            const marker = if (selected) ">" else " ";
            const row_color = if (selected) palette.accent else palette.dim;

            const row_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, selected_path });
            defer self.allocator.free(row_text);
            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn renderCommandPicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = parseCommandPickerQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.commandPickerMatchCount(query);
        const max_rows = self.commandPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.command_picker_index >= total) self.command_picker_index = total - 1;
            if (self.command_picker_index < self.command_picker_scroll) {
                self.command_picker_scroll = self.command_picker_index;
            } else if (self.command_picker_index >= self.command_picker_scroll + shown_rows) {
                self.command_picker_scroll = self.command_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.command_picker_scroll > max_scroll) self.command_picker_scroll = max_scroll;
        } else {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "command picker ({d}) query:{s}",
            .{ total, if (query.len == 0) "*" else query },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.command_picker_scroll + shown_rows, total);
        var index = self.command_picker_scroll;
        while (index < end_index) : (index += 1) {
            const selected_entry = self.commandPickerNthMatch(query, index) orelse continue;
            const is_selected = index == self.command_picker_index;
            const marker = if (is_selected) ">" else " ";
            const row_color = if (is_selected) palette.accent else palette.dim;

            const row_text = try std.fmt.allocPrint(
                self.allocator,
                "{s} /{s}  {s}",
                .{ marker, selected_entry.name, selected_entry.description },
            );
            defer self.allocator.free(row_text);
            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn refreshFileIndex(self: *App) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rg", "--files" },
            .cwd = ".",
            .max_output_bytes = FILE_INDEX_MAX_OUTPUT_BYTES,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.FileIndexRefreshFailed,
            else => return error.FileIndexRefreshFailed,
        }

        for (self.file_index.items) |path| self.allocator.free(path);
        self.file_index.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            try self.file_index.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }
};

const Palette = struct {
    reset: []const u8,
    dim: []const u8,
    header: []const u8,
    accent: []const u8,
    user: []const u8,
    assistant: []const u8,
    system: []const u8,
};

const CursorPlacement = struct {
    row: usize,
    col: usize,
};

const InputView = struct {
    text: []u8,
    cursor_col: usize,
};

fn computeInputCursorPlacement(
    width: usize,
    lines: usize,
    compact_mode: bool,
    viewport_height: usize,
    picker_lines: usize,
    input_cursor_col: usize,
) CursorPlacement {
    const header_lines: usize = if (compact_mode) 2 else 3;
    const input_row_unclamped = header_lines + 1 + viewport_height + 1 + 1 + picker_lines + 1;
    const input_row = std.math.clamp(input_row_unclamped, @as(usize, 1), lines);

    // Prompt prefix is always "[INS]> " or "[NOR]> " (6 chars + trailing space).
    const prompt_visible_len: usize = 7;
    const input_col_unclamped = prompt_visible_len + input_cursor_col + 1;
    const input_col = std.math.clamp(input_col_unclamped, @as(usize, 1), width);

    return .{
        .row = input_row,
        .col = input_col,
    };
}

fn paletteForTheme(theme: Theme) Palette {
    return switch (theme) {
        .codex => .{
            .reset = "\x1b[0m",
            .dim = "\x1b[38;5;245m",
            .header = "\x1b[38;5;110m",
            .accent = "\x1b[38;5;117m",
            .user = "\x1b[38;5;215m",
            .assistant = "\x1b[38;5;114m",
            .system = "\x1b[38;5;146m",
        },
        .plain => .{
            .reset = "",
            .dim = "",
            .header = "",
            .accent = "",
            .user = "",
            .assistant = "",
            .system = "",
        },
        .forest => .{
            .reset = "\x1b[0m",
            .dim = "\x1b[38;5;245m",
            .header = "\x1b[38;5;71m",
            .accent = "\x1b[38;5;114m",
            .user = "\x1b[38;5;151m",
            .assistant = "\x1b[38;5;108m",
            .system = "\x1b[38;5;145m",
        },
    };
}

fn writeRule(writer: *std.Io.Writer, width: usize, palette: Palette, compact_mode: bool) !void {
    const rule_width: usize = if (compact_mode and width > 88) 88 else width;
    try writer.writeAll(palette.dim);
    try writer.splatByteAll('-', rule_width);
    try writer.writeAll(palette.reset);
    try writer.writeByte('\n');
}

fn roleColor(role: Role, palette: Palette) []const u8 {
    return switch (role) {
        .user => palette.user,
        .assistant => palette.assistant,
        .system => palette.system,
    };
}

fn appendMessageBlock(
    writer: *std.Io.Writer,
    message: anytype,
    width: usize,
    palette: Palette,
    compact_mode: bool,
    content_override: ?[]const u8,
) !void {
    _ = compact_mode;

    const marker, const continuation, const color = switch (message.role) {
        .user => .{ "› ", "  ", palette.user },
        .assistant => .{ "• ", "  ", palette.assistant },
        .system => .{ "○ ", "  ", palette.system },
    };

    const rendered_content = content_override orelse messageDisplayContent(message);
    _ = try writeWrappedPrefixed(
        writer,
        rendered_content,
        width,
        marker,
        continuation,
        color,
        palette.reset,
    );
    try writer.writeByte('\n');
}

fn messageDisplayContent(message: anytype) []const u8 {
    if (message.content.len == 0) return "...";

    if (message.role == .system and std.mem.startsWith(u8, message.content, FILE_INJECT_HEADER)) {
        const line_end = std.mem.indexOfScalar(u8, message.content, '\n') orelse message.content.len;
        return message.content[0..line_end];
    }

    return message.content;
}

fn buildWorkingPlaceholder(
    allocator: std.mem.Allocator,
    width: usize,
    started_ms: i64,
    now_ms: i64,
) ![]u8 {
    const elapsed_ms = @max(@as(i64, 0), now_ms - started_ms);
    const elapsed_s = @divFloor(elapsed_ms, 1000);

    const max_bar = @max(@as(usize, 12), @min(@as(usize, 28), width / 3));
    const segment_len = @max(@as(usize, 4), @min(@as(usize, 8), max_bar / 4));
    const travel = if (max_bar > segment_len) max_bar - segment_len else 1;
    const period_i64: i64 = @as(i64, @intCast(travel)) * 2;
    const frame = @divFloor(elapsed_ms, 70);
    const phase = @as(usize, @intCast(@mod(frame, period_i64)));
    const forward = phase <= travel;
    const offset = if (forward) phase else @as(usize, @intCast(period_i64 - @as(i64, @intCast(phase))));

    var bar_buf: [32]u8 = undefined;
    std.debug.assert(max_bar <= bar_buf.len);
    for (0..max_bar) |index| {
        bar_buf[index] = '-';
    }

    var seg_index: usize = 0;
    while (seg_index < segment_len and offset + seg_index < max_bar) : (seg_index += 1) {
        bar_buf[offset + seg_index] = '=';
    }

    if (forward) {
        const head = offset + segment_len - 1;
        if (head < max_bar) bar_buf[head] = '>';
    } else {
        if (offset < max_bar) bar_buf[offset] = '<';
    }

    return std.fmt.allocPrint(
        allocator,
        "Working {d}s [{s}]  Esc Esc to interrupt",
        .{ elapsed_s, bar_buf[0..max_bar] },
    );
}

fn writeWrappedPrefixed(
    writer: *std.Io.Writer,
    text: []const u8,
    width: usize,
    first_prefix: []const u8,
    next_prefix: []const u8,
    prefix_color: []const u8,
    reset: []const u8,
) !usize {
    var line_count: usize = 0;
    var first_line = true;

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        const para = std.mem.trimRight(u8, paragraph, " ");
        if (para.len == 0) {
            const prefix = if (first_line) first_prefix else next_prefix;
            try writer.print("{s}{s}{s}\n", .{ prefix_color, prefix, reset });
            first_line = false;
            line_count += 1;
            continue;
        }

        var start: usize = 0;
        while (start < para.len) {
            const prefix = if (first_line) first_prefix else next_prefix;
            const prefix_len = prefix.len;
            const wrap_width = @max(@as(usize, 1), width -| prefix_len);
            const max_end = @min(start + wrap_width, para.len);

            var end = max_end;
            if (max_end < para.len) {
                var cursor = max_end;
                while (cursor > start and para[cursor - 1] != ' ') : (cursor -= 1) {}
                if (cursor > start) end = cursor - 1;
            }
            if (end <= start) end = max_end;

            try writer.print("{s}{s}{s}", .{ prefix_color, prefix, reset });
            try writer.writeAll(std.mem.trimRight(u8, para[start..end], " "));
            try writer.writeByte('\n');

            line_count += 1;
            first_line = false;
            start = end;
            while (start < para.len and para[start] == ' ') : (start += 1) {}
        }
    }

    return line_count;
}

fn formatTokenCount(allocator: std.mem.Allocator, raw_count: i64) ![]u8 {
    const count = @max(@as(i64, 0), raw_count);
    if (count >= 1_000_000) {
        const scaled = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        const rounded = @round(scaled);
        if (@abs(scaled - rounded) < 0.05) {
            return std.fmt.allocPrint(allocator, "{d}M", .{@as(i64, @intFromFloat(rounded))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1}M", .{scaled});
    }
    if (count >= 1_000) {
        const scaled = @as(f64, @floatFromInt(count)) / 1_000.0;
        const rounded = @round(scaled);
        if (@abs(scaled - rounded) < 0.05) {
            return std.fmt.allocPrint(allocator, "{d}k", .{@as(i64, @intFromFloat(rounded))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1}k", .{scaled});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

fn truncateLineAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (text.len <= max_width) return allocator.dupe(u8, text);
    if (max_width <= 3) return allocator.dupe(u8, text[0..max_width]);

    const out_len = max_width;
    var out = try allocator.alloc(u8, out_len);
    @memcpy(out[0 .. out_len - 3], text[0 .. out_len - 3]);
    out[out_len - 3] = '.';
    out[out_len - 2] = '.';
    out[out_len - 1] = '.';
    return out;
}

fn buildInputView(allocator: std.mem.Allocator, before: []const u8, after: []const u8, max_width: usize) !InputView {
    var full_writer: std.Io.Writer.Allocating = .init(allocator);
    defer full_writer.deinit();
    try full_writer.writer.writeAll(before);
    try full_writer.writer.writeByte('|');
    try full_writer.writer.writeAll(after);
    const full = try full_writer.toOwnedSlice();
    defer allocator.free(full);

    const marker_view = blk: {
        if (full.len <= max_width) break :blk try allocator.dupe(u8, full);
        if (max_width <= 3) break :blk try allocator.dupe(u8, full[full.len - max_width ..]);

        const tail_len = max_width - 3;
        var out = try allocator.alloc(u8, max_width);
        out[0] = '.';
        out[1] = '.';
        out[2] = '.';
        @memcpy(out[3..], full[full.len - tail_len ..]);
        break :blk out;
    };
    defer allocator.free(marker_view);

    const marker_index = std.mem.indexOfScalar(u8, marker_view, '|') orelse marker_view.len;
    const has_marker = marker_index < marker_view.len;
    const out_len = marker_view.len - (if (has_marker) @as(usize, 1) else @as(usize, 0));
    var out = try allocator.alloc(u8, out_len);

    if (has_marker) {
        @memcpy(out[0..marker_index], marker_view[0..marker_index]);
        @memcpy(out[marker_index..], marker_view[marker_index + 1 ..]);
    } else {
        @memcpy(out, marker_view);
    }

    return .{
        .text = out,
        .cursor_col = @min(marker_index, out_len),
    };
}

const BuiltinCommandEntry = struct {
    name: []const u8,
    description: []const u8,
    insert_trailing_space: bool = true,
};

const BUILTIN_COMMANDS = [_]BuiltinCommandEntry{
    .{ .name = "help", .description = "show command help", .insert_trailing_space = false },
    .{ .name = "provider", .description = "set/show provider id" },
    .{ .name = "model", .description = "pick or set model id" },
    .{ .name = "models", .description = "list models cache / refresh" },
    .{ .name = "files", .description = "show file index / refresh" },
    .{ .name = "new", .description = "create conversation" },
    .{ .name = "list", .description = "list conversations", .insert_trailing_space = false },
    .{ .name = "switch", .description = "switch conversation id" },
    .{ .name = "title", .description = "rename conversation" },
    .{ .name = "theme", .description = "set theme (codex/plain/forest)" },
    .{ .name = "ui", .description = "set ui mode (compact/comfy)" },
    .{ .name = "quit", .description = "exit app", .insert_trailing_space = false },
    .{ .name = "q", .description = "exit app", .insert_trailing_space = false },
};

fn parseCommandPickerQuery(input: []const u8, cursor: usize) ?[]const u8 {
    if (input.len == 0 or input[0] != '/') return null;

    const first_space = std.mem.indexOfAny(u8, input, " \t\r\n");
    if (first_space) |space_index| {
        if (cursor > space_index) return null;
        return input[1..space_index];
    }

    return input[1..];
}

fn commandMatchesQuery(entry: BuiltinCommandEntry, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(entry.name, query) or containsAsciiIgnoreCase(entry.description, query);
}

fn registerStreamInterruptByte(
    esc_count: *u8,
    last_esc_ms: *i64,
    key_byte: u8,
    now_ms: i64,
) bool {
    if (key_byte != 27) {
        esc_count.* = 0;
        last_esc_ms.* = 0;
        return false;
    }

    if (esc_count.* == 0 or (now_ms - last_esc_ms.*) > STREAM_INTERRUPT_ESC_WINDOW_MS) {
        esc_count.* = 1;
        last_esc_ms.* = now_ms;
        return false;
    }

    esc_count.* = 0;
    last_esc_ms.* = 0;
    return true;
}

const AssistantToolCall = union(enum) {
    read: []const u8,
    apply_patch: []const u8,
};

fn parseAssistantToolCall(text: []const u8) ?AssistantToolCall {
    if (parseReadToolCommand(text)) |command| {
        return .{ .read = command };
    }
    if (parseApplyPatchToolPayload(text)) |patch_text| {
        return .{ .apply_patch = patch_text };
    }
    return null;
}

fn parseReadToolCommand(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<READ>")) {
        const rest = trimmed["<READ>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</READ>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "READ:")) {
        return std.mem.trimLeft(u8, trimmed["READ:".len..], " \t");
    }

    if (std.mem.startsWith(u8, trimmed, "READ ")) {
        return std.mem.trimLeft(u8, trimmed["READ".len..], " \t");
    }

    if (std.mem.startsWith(u8, trimmed, "```read")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseApplyPatchToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<APPLY_PATCH>")) {
        const rest = trimmed["<APPLY_PATCH>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</APPLY_PATCH>") orelse return null;
        const payload = std.mem.trim(u8, rest[0..close_index], " \t\r\n");
        if (payload.len == 0) return null;
        return payload;
    }

    if (std.mem.startsWith(u8, trimmed, "```apply_patch")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        const payload = std.mem.trim(u8, body[0..close_index], " \t\r\n");
        if (payload.len == 0) return null;
        return payload;
    }

    return extractCodexPatchPayload(trimmed);
}

fn extractCodexPatchPayload(text: []const u8) ?[]const u8 {
    const begin_index = std.mem.indexOf(u8, text, "*** Begin Patch") orelse return null;
    const rest = text[begin_index..];
    const end_index = std.mem.indexOf(u8, rest, "*** End Patch") orelse return null;
    const end = begin_index + end_index + "*** End Patch".len;
    return std.mem.trim(u8, text[begin_index..end], " \t\r\n");
}

fn isValidApplyPatchPayload(patch_text: []const u8) bool {
    if (!std.mem.startsWith(u8, patch_text, "*** Begin Patch")) return false;
    return std.mem.indexOf(u8, patch_text, "*** End Patch") != null;
}

const AtTokenRange = struct {
    start: usize,
    end: usize,
    query: []const u8,
};

const RewriteResult = struct {
    text: []u8,
    cursor: usize,
};

fn currentAtTokenRange(input: []const u8, cursor: usize) ?AtTokenRange {
    const safe_cursor = @min(cursor, input.len);
    const before = input[0..safe_cursor];
    const after = input[safe_cursor..];

    const start = blk: {
        var i = before.len;
        while (i > 0) : (i -= 1) {
            if (std.ascii.isWhitespace(before[i - 1])) break;
        }
        break :blk i;
    };

    const end = blk: {
        var i: usize = 0;
        while (i < after.len and !std.ascii.isWhitespace(after[i])) : (i += 1) {}
        break :blk safe_cursor + i;
    };

    if (start >= end) return null;
    const token = input[start..end];
    if (token[0] != '@') return null;

    var query = token[1..];
    if (query.len > 0 and (query[0] == '"' or query[0] == '\'')) {
        query = query[1..];
    }

    return .{
        .start = start,
        .end = end,
        .query = query,
    };
}

fn currentAtTokenQuery(input: []const u8, cursor: usize) ?[]const u8 {
    const token = currentAtTokenRange(input, cursor) orelse return null;
    return token.query;
}

fn filePathMatchesQuery(path: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(path, query);
}

fn rewriteInputWithSelectedAtPath(
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize,
    path: []const u8,
) !RewriteResult {
    const token = currentAtTokenRange(input, cursor) orelse return error.MissingAtToken;

    const quoted = blk: {
        if (!containsWhitespace(path)) break :blk false;
        if (std.mem.indexOfScalar(u8, path, '"') == null) break :blk true;
        break :blk false;
    };
    const inserted_token = if (quoted)
        try std.fmt.allocPrint(allocator, "@\"{s}\"", .{path})
    else
        try std.fmt.allocPrint(allocator, "@{s}", .{path});
    defer allocator.free(inserted_token);

    const suffix = std.mem.trimLeft(u8, input[token.end..], " \t");
    const new_len = token.start + inserted_token.len + 1 + suffix.len;
    var out = try allocator.alloc(u8, new_len);

    @memcpy(out[0..token.start], input[0..token.start]);
    @memcpy(out[token.start .. token.start + inserted_token.len], inserted_token);
    out[token.start + inserted_token.len] = ' ';
    @memcpy(out[token.start + inserted_token.len + 1 ..], suffix);

    return .{
        .text = out,
        .cursor = token.start + inserted_token.len + 1,
    };
}

fn containsWhitespace(text: []const u8) bool {
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

const FileInjectResult = struct {
    payload: ?[]u8 = null,
    referenced_count: usize = 0,
    included_count: usize = 0,
    skipped_count: usize = 0,
};

fn buildFileInjectionPayload(allocator: std.mem.Allocator, prompt: []const u8) !FileInjectResult {
    var references = try collectAtFileReferences(allocator, prompt);
    defer {
        for (references.items) |entry| allocator.free(entry);
        references.deinit(allocator);
    }

    if (references.items.len == 0) return .{};

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    var included_count: usize = 0;
    var skipped_count: usize = 0;

    for (references.items, 0..) |reference, index| {
        if (included_count >= FILE_INJECT_MAX_FILES) {
            skipped_count += references.items.len - index;
            break;
        }

        const path = trimMatchingOuterQuotes(reference);
        if (path.len == 0) {
            skipped_count += 1;
            continue;
        }

        const file_content = readFileForInjection(allocator, path) catch {
            skipped_count += 1;
            continue;
        };
        defer allocator.free(file_content);

        if (looksBinary(file_content)) {
            skipped_count += 1;
            continue;
        }

        included_count += 1;
        try body_writer.writer.print("<file path=\"{s}\">\n", .{path});
        try body_writer.writer.writeAll(file_content);
        if (file_content.len == 0 or file_content[file_content.len - 1] != '\n') {
            try body_writer.writer.writeByte('\n');
        }
        try body_writer.writer.writeAll("</file>\n");
    }

    if (included_count == 0) {
        return .{
            .referenced_count = references.items.len,
            .included_count = 0,
            .skipped_count = skipped_count,
        };
    }

    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    try payload_writer.writer.print(
        "{s} included:{d} referenced:{d} skipped:{d}\n",
        .{ FILE_INJECT_HEADER, included_count, references.items.len, skipped_count },
    );
    try payload_writer.writer.writeAll(
        "The user referenced these files with @path. Treat this as project context.\n",
    );
    try payload_writer.writer.writeAll(body);

    return .{
        .payload = try payload_writer.toOwnedSlice(),
        .referenced_count = references.items.len,
        .included_count = included_count,
        .skipped_count = skipped_count,
    };
}

fn collectAtFileReferences(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]u8) {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    var dedupe: std.StringHashMapUnmanaged(void) = .empty;
    defer dedupe.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '@') continue;
        if (index > 0 and !std.ascii.isWhitespace(text[index - 1])) continue;

        var normalized: []const u8 = undefined;
        if (index + 1 < text.len and (text[index + 1] == '"' or text[index + 1] == '\'')) {
            const quote = text[index + 1];
            var end = index + 2;
            while (end < text.len and text[end] != quote) : (end += 1) {}
            if (end >= text.len) continue;

            normalized = text[index + 2 .. end];
            index = end;
        } else {
            var end = index + 1;
            while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
            if (end <= index + 1) continue;

            const token = text[index + 1 .. end];
            normalized = trimMatchingOuterQuotes(token);
            index = end - 1;
        }

        if (normalized.len == 0) continue;

        if (dedupe.contains(normalized)) continue;
        try dedupe.put(allocator, normalized, {});
        try refs.append(allocator, try allocator.dupe(u8, normalized));
    }

    return refs;
}

fn trimMatchingOuterQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '"' and text[text.len - 1] == '"') or
            (text[0] == '\'' and text[text.len - 1] == '\''))
        {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

fn readFileForInjection(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, FILE_INJECT_MAX_FILE_BYTES);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, FILE_INJECT_MAX_FILE_BYTES);
}

fn looksBinary(content: []const u8) bool {
    if (std.mem.indexOfScalar(u8, content, 0) != null) return true;
    if (content.len == 0) return false;

    const sample_len = @min(content.len, 1024);
    var control_count: usize = 0;
    for (content[0..sample_len]) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) control_count += 1;
    }
    return control_count * 10 > sample_len;
}

fn isAllowedReadCommand(command: []const u8) bool {
    if (command.len == 0) return false;
    if (std.mem.indexOfScalar(u8, command, '/')) |_| return false;

    const allowlist = [_][]const u8{
        "rg",
        "grep",
        "ls",
        "cat",
        "find",
        "head",
        "tail",
        "sed",
        "wc",
        "stat",
        "pwd",
    };

    for (allowlist) |allowed| {
        if (std.mem.eql(u8, command, allowed)) return true;
    }
    return false;
}

fn modelMatchesQuery(model: models.ModelInfo, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(model.id, query) or containsAsciiIgnoreCase(model.name, query);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn fallbackEnvVars(provider_id: []const u8) []const []const u8 {
    if (std.mem.eql(u8, provider_id, "opencode")) return &.{"OPENCODE_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openai")) return &.{"OPENAI_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openrouter")) return &.{"OPENROUTER_API_KEY"};
    if (std.mem.eql(u8, provider_id, "anthropic")) return &.{"ANTHROPIC_API_KEY"};
    if (std.mem.eql(u8, provider_id, "google")) return &.{ "GOOGLE_GENERATIVE_AI_API_KEY", "GEMINI_API_KEY" };
    if (std.mem.eql(u8, provider_id, "zenmux")) return &.{"ZENMUX_API_KEY"};
    return &.{};
}

fn firstEnvVarForProvider(app: *App, provider_id: []const u8) ?[]const u8 {
    if (app.catalog.findProviderConst(provider_id)) |provider| {
        if (provider.env_vars.items.len > 0) return provider.env_vars.items[0];
    }

    const fallback = fallbackEnvVars(provider_id);
    if (fallback.len > 0) return fallback[0];
    return null;
}

test "parseReadToolCommand extracts command formats" {
    try std.testing.expectEqualStrings("rg --files src", parseReadToolCommand("<READ>\nrg --files src\n</READ>").?);
    try std.testing.expectEqualStrings("ls -la", parseReadToolCommand("READ: ls -la").?);
    try std.testing.expectEqualStrings("cat src/main.zig", parseReadToolCommand("READ cat src/main.zig").?);
    try std.testing.expectEqualStrings("grep -n foo src/tui.zig", parseReadToolCommand("```read\ngrep -n foo src/tui.zig\n```").?);
    try std.testing.expect(parseReadToolCommand("normal assistant text") == null);
}

test "parseApplyPatchToolPayload extracts codex patch formats" {
    const xml_payload =
        "<APPLY_PATCH>\n" ++
        "*** Begin Patch\n" ++
        "*** Update File: src/main.zig\n" ++
        "@@\n" ++
        "-old\n" ++
        "+new\n" ++
        "*** End Patch\n" ++
        "</APPLY_PATCH>";
    try std.testing.expectEqualStrings(
        "*** Begin Patch\n*** Update File: src/main.zig\n@@\n-old\n+new\n*** End Patch",
        parseApplyPatchToolPayload(xml_payload).?,
    );

    const fence_payload =
        "```apply_patch\n" ++
        "*** Begin Patch\n" ++
        "*** Add File: notes.txt\n" ++
        "+hello\n" ++
        "*** End Patch\n" ++
        "```";
    try std.testing.expectEqualStrings(
        "*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch",
        parseApplyPatchToolPayload(fence_payload).?,
    );

    try std.testing.expect(parseApplyPatchToolPayload("normal assistant text") == null);
}

test "parseAssistantToolCall detects read and apply_patch" {
    const read_tool = parseAssistantToolCall("<READ>ls</READ>").?;
    switch (read_tool) {
        .read => |command| try std.testing.expectEqualStrings("ls", command),
        else => return error.TestUnexpectedResult,
    }

    const patch_call = parseAssistantToolCall(
        "*** Begin Patch\n*** Update File: src/tui.zig\n@@\n-old\n+new\n*** End Patch",
    ).?;
    switch (patch_call) {
        .apply_patch => |payload| try std.testing.expect(isValidApplyPatchPayload(payload)),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCommandPickerQuery handles slash token editing only" {
    try std.testing.expectEqualStrings("mo", parseCommandPickerQuery("/mo", 3).?);
    try std.testing.expectEqualStrings("", parseCommandPickerQuery("/", 1).?);
    try std.testing.expectEqualStrings("model", parseCommandPickerQuery("/model test", 6).?);
    try std.testing.expect(parseCommandPickerQuery("/model test", 8) == null);
    try std.testing.expect(parseCommandPickerQuery("hello", 2) == null);
}

test "commandMatchesQuery matches name and description" {
    const entry: BuiltinCommandEntry = .{
        .name = "provider",
        .description = "set/show provider id",
    };
    try std.testing.expect(commandMatchesQuery(entry, "prov"));
    try std.testing.expect(commandMatchesQuery(entry, "show"));
    try std.testing.expect(!commandMatchesQuery(entry, "xyz"));
}

test "registerStreamInterruptByte requires double esc within window" {
    var esc_count: u8 = 0;
    var last_esc_ms: i64 = 0;

    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1000));
    try std.testing.expectEqual(@as(u8, 1), esc_count);

    try std.testing.expect(registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1500));
    try std.testing.expectEqual(@as(u8, 0), esc_count);
}

test "registerStreamInterruptByte resets on non-esc and timeout" {
    var esc_count: u8 = 0;
    var last_esc_ms: i64 = 0;

    _ = registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1000);
    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 'a', 1001));
    try std.testing.expectEqual(@as(u8, 0), esc_count);

    _ = registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 2000);
    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 4005));
    try std.testing.expectEqual(@as(u8, 1), esc_count);
}

test "isAllowedReadCommand allowlist and slash rejection" {
    try std.testing.expect(isAllowedReadCommand("rg"));
    try std.testing.expect(isAllowedReadCommand("ls"));
    try std.testing.expect(!isAllowedReadCommand("bash"));
    try std.testing.expect(!isAllowedReadCommand("/usr/bin/rg"));
}

test "collectAtFileReferences parses unique @path tokens" {
    const allocator = std.testing.allocator;
    const text = "review @src/main.zig and @src/tui.zig then @src/main.zig again";

    var refs = try collectAtFileReferences(allocator, text);
    defer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("src/main.zig", refs.items[0]);
    try std.testing.expectEqualStrings("src/tui.zig", refs.items[1]);
}

test "collectAtFileReferences parses quoted @path with spaces" {
    const allocator = std.testing.allocator;
    const text = "review @\"docs/My File.md\" then @'src/other file.zig'";

    var refs = try collectAtFileReferences(allocator, text);
    defer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("docs/My File.md", refs.items[0]);
    try std.testing.expectEqualStrings("src/other file.zig", refs.items[1]);
}

test "currentAtTokenRange detects @token under cursor" {
    const text = "review @src/main.zig now";
    const token = currentAtTokenRange(text, 11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("src/main.zig", token.query);
    try std.testing.expectEqual(@as(usize, 7), token.start);
    try std.testing.expectEqual(@as(usize, 20), token.end);
}

test "rewriteInputWithSelectedAtPath inserts selected file token" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteInputWithSelectedAtPath(allocator, "review @sr now", 9, "src/main.zig");
    defer allocator.free(rewritten.text);

    try std.testing.expectEqualStrings("review @src/main.zig now", rewritten.text);
    try std.testing.expectEqual(@as(usize, 21), rewritten.cursor);
}

test "rewriteInputWithSelectedAtPath quotes path with spaces" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteInputWithSelectedAtPath(allocator, "check @do", 8, "docs/My File.md");
    defer allocator.free(rewritten.text);

    try std.testing.expectEqualStrings("check @\"docs/My File.md\" ", rewritten.text);
}

test "computeInputCursorPlacement anchors cursor to input marker" {
    const placement = computeInputCursorPlacement(
        120,
        40,
        true,
        30,
        0,
        3,
    );

    try std.testing.expectEqual(@as(usize, 36), placement.row);
    try std.testing.expectEqual(@as(usize, 11), placement.col);
}

test "buildInputView hides inline marker and preserves cursor column" {
    const allocator = std.testing.allocator;
    const view = try buildInputView(allocator, "hello", " world", 64);
    defer allocator.free(view.text);

    try std.testing.expectEqualStrings("hello world", view.text);
    try std.testing.expectEqual(@as(usize, 5), view.cursor_col);
}

test "buildFileInjectionPayload includes readable files and reports counts" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const file_path = try std.fs.path.join(allocator, &.{ abs_dir, "inject.txt" });
    defer allocator.free(file_path);

    var file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();
    var write_buf: [256]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.writeAll("hello inject\n");
    try file_writer.interface.flush();

    const prompt = try std.fmt.allocPrint(allocator, "check @{s} and @missing.txt", .{file_path});
    defer allocator.free(prompt);

    const result = try buildFileInjectionPayload(allocator, prompt);
    defer if (result.payload) |payload| allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 2), result.referenced_count);
    try std.testing.expectEqual(@as(usize, 1), result.included_count);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_count);
    try std.testing.expect(result.payload != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "<file path=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "hello inject") != null);
}

test "formatTokenCount trims trailing .0 for compact context display" {
    const allocator = std.testing.allocator;

    const a = try formatTokenCount(allocator, 105_000);
    defer allocator.free(a);
    try std.testing.expectEqualStrings("105k", a);

    const b = try formatTokenCount(allocator, 225_000);
    defer allocator.free(b);
    try std.testing.expectEqualStrings("225k", b);

    const c = try formatTokenCount(allocator, 123_456);
    defer allocator.free(c);
    try std.testing.expectEqualStrings("123.5k", c);
}

test "buildWorkingPlaceholder includes timer and interrupt hint" {
    const allocator = std.testing.allocator;

    const placeholder = try buildWorkingPlaceholder(allocator, 120, 1_000, 6_500);
    defer allocator.free(placeholder);

    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Working 5s") != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Esc Esc to interrupt") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, placeholder, '[') != null);
    try std.testing.expect(
        std.mem.indexOfScalar(u8, placeholder, '>') != null or
            std.mem.indexOfScalar(u8, placeholder, '<') != null,
    );
}
