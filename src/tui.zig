//! Minimal single-pane TUI with vim-style navigation and slash commands.

const std = @import("std");
const builtin = @import("builtin");

const models = @import("models.zig");
const provider_client = @import("provider_client.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const Conversation = @import("state.zig").Conversation;
const Role = @import("state.zig").Role;

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
    app.ensureCurrentConversationVisibleInStrip();

    var raw_mode = try RawMode.enable();
    defer raw_mode.disable();

    try app.render();

    while (!app.should_exit) {
        var byte_buf: [1]u8 = undefined;
        const read_len = try std.posix.read(std.fs.File.stdin().handle, byte_buf[0..]);
        if (read_len == 0) break;

        try app.handleByte(byte_buf[0]);

        if (!app.should_exit) {
            try app.render();
        }
    }
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
    compact_mode: bool = true,
    theme: Theme = .codex,

    notice: []u8,

    pub fn deinit(self: *App) void {
        self.input_buffer.deinit(self.allocator);
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
            'i' => self.mode = .insert,
            'a' => {
                if (self.input_cursor < self.input_buffer.items.len) self.input_cursor += 1;
                self.mode = .insert;
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
            },
            27 => self.mode = .normal,
            else => {},
        }
    }

    fn handleInsertByte(self: *App, key_byte: u8) !void {
        switch (key_byte) {
            27 => self.mode = .normal,
            127 => {
                if (self.input_cursor > 0) {
                    self.input_cursor -= 1;
                    _ = self.input_buffer.orderedRemove(self.input_cursor);
                }
            },
            '\r', '\n' => {
                try self.submitInput();
            },
            else => {
                if (key_byte >= 32 and key_byte <= 126) {
                    try self.input_buffer.insert(self.allocator, self.input_cursor, key_byte);
                    self.input_cursor += 1;
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

        if (line.len == 0) return;

        if (line[0] == '/') {
            try self.handleCommand(line);
            return;
        }

        try self.handlePrompt(line);
    }

    fn handlePrompt(self: *App, prompt: []const u8) !void {
        try self.app_state.appendMessage(self.allocator, .user, prompt);
        try self.app_state.appendMessage(self.allocator, .assistant, "");

        const provider_id = self.app_state.selected_provider_id;
        const model_id = self.app_state.selected_model_id;

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
        defer self.is_streaming = false;

        const provider_info = self.catalog.findProviderConst(provider_id);
        const request: provider_client.StreamRequest = .{
            .provider_id = provider_id,
            .model_id = model_id,
            .api_key = api_key.?,
            .base_url = if (provider_info) |info| info.api_base else null,
            .messages = try self.buildStreamMessages(),
        };
        defer self.allocator.free(request.messages);

        try self.setNoticeFmt("Streaming from {s}/{s}...", .{ provider_id, model_id });
        try self.render();

        provider_client.streamChat(self.allocator, request, .{
            .on_token = onStreamToken,
            .context = self,
        }) catch |err| {
            try self.setNoticeFmt("Provider request failed: {s}", .{@errorName(err)});
            const conversation = self.app_state.currentConversationConst();
            const needs_paragraph_break = if (conversation.messages.items.len == 0) false else blk: {
                const last = conversation.messages.items[conversation.messages.items.len - 1];
                break :blk last.content.len > 0;
            };
            try self.appendToLastAssistantMessage(if (needs_paragraph_break) "\n\n[local] Request failed." else "[local] Request failed.");
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            return;
        };

        try self.setNoticeFmt("Completed response from {s}/{s}", .{ provider_id, model_id });
        try self.app_state.saveToPath(self.allocator, self.paths.state_path);
    }

    fn buildStreamMessages(self: *App) ![]provider_client.StreamMessage {
        const conversation = self.app_state.currentConversationConst();
        const messages = try self.allocator.alloc(provider_client.StreamMessage, conversation.messages.items.len);

        for (conversation.messages.items, 0..) |message, index| {
            messages[index] = .{
                .role = message.role,
                .content = message.content,
            };
        }

        return messages;
    }

    fn onStreamToken(context: ?*anyopaque, token: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        try self.appendToLastAssistantMessage(token);
        try self.render();
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
            try self.setNotice("Commands: /help /provider [id] /model [id] /models [refresh] /new [title] /list /switch <id> /title <text> /theme [codex|plain|forest] /ui [compact|comfy] /quit  keys: H/L scroll conv tabs");
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
        const bottom_lines: usize = 3;
        const viewport_height = @max(@as(usize, 4), lines - top_lines - bottom_lines);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        for (conversation.messages.items) |message| {
            try appendMessageBlock(&body_writer.writer, message, content_width, palette, self.compact_mode);
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
                "zig-ai  {s}/{s}  mode:{s}  conv:{s}  {s}",
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
                "zig-ai  mode:{s}  conv:{s}",
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

        const key_hint = if (self.mode == .insert) "enter esc /" else "i j/k H/L / q";
        const status_text = try std.fmt.allocPrint(
            self.allocator,
            "{s} | keys:{s} | scroll:{d}/{d}",
            .{ self.notice, key_hint, self.scroll_lines, max_scroll },
        );
        defer self.allocator.free(status_text);
        const status_line = try truncateLineAlloc(self.allocator, status_text, width);
        defer self.allocator.free(status_line);
        try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, status_line, palette.reset });

        const before_cursor = self.input_buffer.items[0..self.input_cursor];
        const after_cursor = self.input_buffer.items[self.input_cursor..];
        const input_view = try buildInputView(self.allocator, before_cursor, after_cursor, if (width > 10) width - 10 else 22);
        defer self.allocator.free(input_view);
        try screen_writer.writer.print("{s}[{s}]>{s} {s}\n", .{ palette.accent, if (self.mode == .insert) "INS" else "NOR", palette.reset, input_view });

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

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    if (indent == 0) return;
    try writer.splatByteAll(' ', indent);
}

fn writeWrapped(writer: *std.Io.Writer, text: []const u8, width: usize, indent: usize) !usize {
    var line_count: usize = 0;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        if (paragraph.len == 0) {
            try writeIndent(writer, indent);
            try writer.writeByte('\n');
            line_count += 1;
            continue;
        }

        var start: usize = 0;
        while (start < paragraph.len) {
            const max_end = @min(start + width, paragraph.len);
            var end = max_end;
            if (max_end < paragraph.len) {
                var cursor = max_end;
                while (cursor > start and paragraph[cursor - 1] != ' ') : (cursor -= 1) {}
                if (cursor > start) {
                    end = cursor - 1;
                }
            }

            if (end <= start) end = max_end;

            try writeIndent(writer, indent);
            try writer.writeAll(std.mem.trimRight(u8, paragraph[start..end], " "));
            try writer.writeByte('\n');
            line_count += 1;

            start = end;
            while (start < paragraph.len and paragraph[start] == ' ') : (start += 1) {}
        }
    }
    return line_count;
}

fn roleLabel(role: Role) []const u8 {
    return switch (role) {
        .user => "u",
        .assistant => "a",
        .system => "s",
    };
}

fn roleColor(role: Role, palette: Palette) []const u8 {
    return switch (role) {
        .user => palette.user,
        .assistant => palette.assistant,
        .system => palette.system,
    };
}

fn appendMessageBlock(writer: *std.Io.Writer, message: anytype, width: usize, palette: Palette, compact_mode: bool) !void {
    const color = roleColor(message.role, palette);
    try writer.print("{s}{s}>{s}\n", .{ color, roleLabel(message.role), palette.reset });
    _ = try writeWrapped(writer, if (message.content.len == 0) "..." else message.content, width, if (compact_mode) 1 else 2);
    if (!compact_mode) try writer.writeByte('\n');
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

fn buildInputView(allocator: std.mem.Allocator, before: []const u8, after: []const u8, max_width: usize) ![]u8 {
    var full_writer: std.Io.Writer.Allocating = .init(allocator);
    defer full_writer.deinit();
    try full_writer.writer.writeAll(before);
    try full_writer.writer.writeByte('|');
    try full_writer.writer.writeAll(after);
    const full = try full_writer.toOwnedSlice();
    defer allocator.free(full);

    if (full.len <= max_width) return allocator.dupe(u8, full);
    if (max_width <= 3) return allocator.dupe(u8, full[full.len - max_width ..]);

    const tail_len = max_width - 3;
    var out = try allocator.alloc(u8, max_width);
    out[0] = '.';
    out[1] = '.';
    out[2] = '.';
    @memcpy(out[3..], full[full.len - tail_len ..]);
    return out;
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
