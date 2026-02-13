//! Persistent application state: conversations, selected model/provider, and messages.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.state);

pub const Role = enum {
    user,
    assistant,
    system,
};

pub const Message = struct {
    role: Role,
    content: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }

    pub fn jsonStringify(self: *const Message, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(self.role);
        try jw.objectField("content");
        try jw.write(self.content);
        try jw.objectField("timestamp_ms");
        try jw.write(self.timestamp_ms);
        try jw.endObject();
    }
};

const BASELINE_TOKENS: i64 = 12_000;

pub const TokenUsage = struct {
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    total_tokens: i64 = 0,

    pub fn isZero(self: TokenUsage) bool {
        return self.total_tokens == 0 and
            self.input_tokens == 0 and
            self.cached_input_tokens == 0 and
            self.output_tokens == 0 and
            self.reasoning_output_tokens == 0;
    }

    pub fn cachedInput(self: TokenUsage) i64 {
        return @max(@as(i64, 0), self.cached_input_tokens);
    }

    pub fn nonCachedInput(self: TokenUsage) i64 {
        return @max(@as(i64, 0), self.input_tokens - self.cachedInput());
    }

    pub fn blendedTotal(self: TokenUsage) i64 {
        return @max(@as(i64, 0), self.nonCachedInput() + @max(@as(i64, 0), self.output_tokens));
    }

    pub fn tokensInContextWindow(self: TokenUsage) i64 {
        return self.total_tokens;
    }

    pub fn percentOfContextWindowRemaining(self: TokenUsage, context_window: i64) i64 {
        if (context_window <= BASELINE_TOKENS) return 0;

        const effective_window = context_window - BASELINE_TOKENS;
        const used = @max(@as(i64, 0), self.tokensInContextWindow() - BASELINE_TOKENS);
        const remaining = @max(@as(i64, 0), effective_window - used);
        const percent = (@as(f64, @floatFromInt(remaining)) / @as(f64, @floatFromInt(effective_window))) * 100.0;
        return @as(i64, @intFromFloat(@round(std.math.clamp(percent, 0.0, 100.0))));
    }

    pub fn addAssign(self: *TokenUsage, other: TokenUsage) void {
        self.input_tokens += other.input_tokens;
        self.cached_input_tokens += other.cached_input_tokens;
        self.output_tokens += other.output_tokens;
        self.reasoning_output_tokens += other.reasoning_output_tokens;
        self.total_tokens += other.total_tokens;
    }
};

pub const Conversation = struct {
    id: []u8,
    title: []u8,
    created_ms: i64,
    updated_ms: i64,
    total_token_usage: TokenUsage = .{},
    last_token_usage: TokenUsage = .{},
    model_context_window: ?i64 = null,
    messages: std.ArrayList(Message) = .empty,

    pub fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        for (self.messages.items) |*message| {
            message.deinit(allocator);
        }
        self.messages.deinit(allocator);
    }

    pub fn jsonStringify(self: *const Conversation, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("title");
        try jw.write(self.title);
        try jw.objectField("created_ms");
        try jw.write(self.created_ms);
        try jw.objectField("updated_ms");
        try jw.write(self.updated_ms);
        try jw.objectField("total_token_usage");
        try jw.write(self.total_token_usage);
        try jw.objectField("last_token_usage");
        try jw.write(self.last_token_usage);
        try jw.objectField("model_context_window");
        try jw.write(self.model_context_window);
        try jw.objectField("messages");
        try jw.write(self.messages.items);
        try jw.endObject();
    }
};

pub const AppState = struct {
    conversations: std.ArrayList(Conversation) = .empty,
    current_index: usize = 0,
    selected_provider_id: []u8,
    selected_model_id: []u8,

    pub const DEFAULT_PROVIDER_ID = "opencode";
    pub const DEFAULT_MODEL_ID = "claude-opus-4-1";

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var app_state: AppState = .{
            .selected_provider_id = try allocator.dupe(u8, DEFAULT_PROVIDER_ID),
            .selected_model_id = try allocator.dupe(u8, DEFAULT_MODEL_ID),
        };
        errdefer app_state.deinit(allocator);

        _ = try app_state.createConversation(allocator, "Conversation 1");
        return app_state;
    }

    pub fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        for (self.conversations.items) |*conversation| {
            conversation.deinit(allocator);
        }
        self.conversations.deinit(allocator);
        allocator.free(self.selected_provider_id);
        allocator.free(self.selected_model_id);
    }

    pub fn currentConversation(self: *AppState) *Conversation {
        return &self.conversations.items[self.current_index];
    }

    pub fn currentConversationConst(self: *const AppState) *const Conversation {
        return &self.conversations.items[self.current_index];
    }

    pub fn createConversation(self: *AppState, allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
        const now_ms = std.time.milliTimestamp();

        const conversation: Conversation = .{
            .id = try generateConversationId(allocator),
            .title = try allocator.dupe(u8, title),
            .created_ms = now_ms,
            .updated_ms = now_ms,
        };
        errdefer allocator.free(conversation.id);
        errdefer allocator.free(conversation.title);

        try self.conversations.append(allocator, conversation);
        self.current_index = self.conversations.items.len - 1;

        return self.conversations.items[self.current_index].id;
    }

    pub fn setConversationTitle(self: *AppState, allocator: std.mem.Allocator, title: []const u8) !void {
        const conversation = self.currentConversation();
        const replacement = try allocator.dupe(u8, title);
        allocator.free(conversation.title);
        conversation.title = replacement;
        conversation.updated_ms = std.time.milliTimestamp();
    }

    pub fn appendMessage(self: *AppState, allocator: std.mem.Allocator, role: Role, content: []const u8) !void {
        const conversation = self.currentConversation();
        const message: Message = .{
            .role = role,
            .content = try allocator.dupe(u8, content),
            .timestamp_ms = std.time.milliTimestamp(),
        };
        try conversation.messages.append(allocator, message);
        conversation.updated_ms = message.timestamp_ms;
    }

    pub fn appendTokenUsage(self: *AppState, usage: TokenUsage, model_context_window: ?i64) void {
        const conversation = self.currentConversation();
        conversation.total_token_usage.addAssign(usage);
        conversation.last_token_usage = usage;
        if (model_context_window) |window| {
            conversation.model_context_window = window;
        }
        conversation.updated_ms = std.time.milliTimestamp();
    }

    pub fn switchConversation(self: *AppState, conversation_id: []const u8) bool {
        for (self.conversations.items, 0..) |conversation, index| {
            if (std.mem.eql(u8, conversation.id, conversation_id)) {
                self.current_index = index;
                return true;
            }
        }
        return false;
    }

    pub fn setSelectedProvider(self: *AppState, allocator: std.mem.Allocator, provider_id: []const u8) !void {
        const replacement = try allocator.dupe(u8, provider_id);
        allocator.free(self.selected_provider_id);
        self.selected_provider_id = replacement;
    }

    pub fn setSelectedModel(self: *AppState, allocator: std.mem.Allocator, model_id: []const u8) !void {
        const replacement = try allocator.dupe(u8, model_id);
        allocator.free(self.selected_model_id);
        self.selected_model_id = replacement;
    }

    pub fn jsonStringify(self: *const AppState, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(@as(u32, 1));
        try jw.objectField("current_conversation_id");
        try jw.write(self.currentConversationConst().id);
        try jw.objectField("selected_provider_id");
        try jw.write(self.selected_provider_id);
        try jw.objectField("selected_model_id");
        try jw.write(self.selected_model_id);
        try jw.objectField("conversations");
        try jw.write(self.conversations.items);
        try jw.endObject();
    }

    pub fn saveToPath(self: *const AppState, allocator: std.mem.Allocator, state_path: []const u8) !void {
        if (std.fs.path.dirname(state_path)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }

        var payload_writer: std.Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();

        var json_writer: std.json.Stringify = .{
            .writer = &payload_writer.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try json_writer.write(self);

        const payload = try payload_writer.toOwnedSlice();
        defer allocator.free(payload);

        var file = try createFileForPath(state_path, .{ .truncate = true });
        defer file.close();

        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        defer file_writer.interface.flush() catch {};

        try file_writer.interface.writeAll(payload);
    }

    pub fn loadFromPath(allocator: std.mem.Allocator, state_path: []const u8) !AppState {
        var file = try openFileForPath(state_path, .{});
        defer file.close();

        var read_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(&read_buffer);

        var content_writer: std.Io.Writer.Allocating = .init(allocator);
        defer content_writer.deinit();

        _ = try file_reader.interface.streamRemaining(&content_writer.writer);
        const content = try content_writer.toOwnedSlice();
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(PersistedState, allocator, content, .{});
        defer parsed.deinit();

        return AppState.fromPersistedState(allocator, parsed.value);
    }

    pub fn loadOrCreate(allocator: std.mem.Allocator, state_path: []const u8) !AppState {
        return AppState.loadFromPath(allocator, state_path) catch |err| switch (err) {
            error.FileNotFound => {
                var app_state = try AppState.init(allocator);
                errdefer app_state.deinit(allocator);
                try app_state.saveToPath(allocator, state_path);
                return app_state;
            },
            else => return err,
        };
    }

    fn fromPersistedState(allocator: std.mem.Allocator, persisted_state: PersistedState) !AppState {
        if (persisted_state.conversations.len == 0) {
            return AppState.init(allocator);
        }

        var app_state: AppState = .{
            .selected_provider_id = try allocator.dupe(u8, persisted_state.selected_provider_id),
            .selected_model_id = try allocator.dupe(u8, persisted_state.selected_model_id),
        };
        errdefer app_state.deinit(allocator);

        for (persisted_state.conversations) |persisted_conversation| {
            var conversation: Conversation = .{
                .id = try allocator.dupe(u8, persisted_conversation.id),
                .title = try allocator.dupe(u8, persisted_conversation.title),
                .created_ms = persisted_conversation.created_ms,
                .updated_ms = persisted_conversation.updated_ms,
                .total_token_usage = persisted_conversation.total_token_usage orelse .{},
                .last_token_usage = persisted_conversation.last_token_usage orelse .{},
                .model_context_window = persisted_conversation.model_context_window,
            };
            errdefer conversation.deinit(allocator);

            for (persisted_conversation.messages) |persisted_message| {
                const message: Message = .{
                    .role = persisted_message.role,
                    .content = try allocator.dupe(u8, persisted_message.content),
                    .timestamp_ms = persisted_message.timestamp_ms,
                };
                try conversation.messages.append(allocator, message);
            }

            try app_state.conversations.append(allocator, conversation);
        }

        for (app_state.conversations.items, 0..) |conversation, index| {
            if (std.mem.eql(u8, conversation.id, persisted_state.current_conversation_id)) {
                app_state.current_index = index;
                return app_state;
            }
        }

        app_state.current_index = 0;
        return app_state;
    }

    fn generateConversationId(allocator: std.mem.Allocator) ![]u8 {
        var bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        const hex_chars = "0123456789abcdef";
        var id = try allocator.alloc(u8, bytes.len * 2);
        for (bytes, 0..) |byte, index| {
            id[index * 2] = hex_chars[(byte >> 4) & 0x0f];
            id[(index * 2) + 1] = hex_chars[byte & 0x0f];
        }
        return id;
    }

    fn createFileForPath(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.createFileAbsolute(path, flags);
        }
        return std.fs.cwd().createFile(path, flags);
    }

    fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.openFileAbsolute(path, flags);
        }
        return std.fs.cwd().openFile(path, flags);
    }
};

const PersistedMessage = struct {
    role: Role,
    content: []const u8,
    timestamp_ms: i64,
};

const PersistedConversation = struct {
    id: []const u8,
    title: []const u8,
    created_ms: i64,
    updated_ms: i64,
    total_token_usage: ?TokenUsage = null,
    last_token_usage: ?TokenUsage = null,
    model_context_window: ?i64 = null,
    messages: []PersistedMessage,
};

const PersistedState = struct {
    version: u32,
    current_conversation_id: []const u8,
    selected_provider_id: []const u8,
    selected_model_id: []const u8,
    conversations: []PersistedConversation,
};

test "state save and load keeps conversations and messages" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator);
    defer state.deinit(allocator);

    try state.setSelectedProvider(allocator, "openai");
    try state.setSelectedModel(allocator, "gpt-4.1");
    try state.appendMessage(allocator, .user, "hello");
    try state.appendMessage(allocator, .assistant, "world");

    _ = try state.createConversation(allocator, "Second conversation");
    try state.appendMessage(allocator, .user, "second");

    const second_id = try allocator.dupe(u8, state.currentConversationConst().id);
    defer allocator.free(second_id);

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const state_path = try std.fs.path.join(allocator, &.{ abs_dir, "state.json" });
    defer allocator.free(state_path);

    try state.saveToPath(allocator, state_path);

    var loaded = try AppState.loadFromPath(allocator, state_path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.conversations.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.selected_provider_id, "openai"));
    try std.testing.expect(std.mem.eql(u8, loaded.selected_model_id, "gpt-4.1"));
    try std.testing.expect(std.mem.eql(u8, loaded.currentConversationConst().id, second_id));
    try std.testing.expectEqual(@as(usize, 1), loaded.currentConversationConst().messages.items.len);
    try std.testing.expect(std.mem.eql(u8, loaded.currentConversationConst().messages.items[0].content, "second"));
}

test "switchConversation returns false for unknown id" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator);
    defer state.deinit(allocator);

    try std.testing.expect(!state.switchConversation("does-not-exist"));
}

comptime {
    _ = builtin;
    _ = log;
}
