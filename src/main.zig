//! zolt: a minimal terminal AI chat client.

const std = @import("std");
const builtin = @import("builtin");

const app_config = @import("config.zig");
const models = @import("models.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const Conversation = @import("state.zig").Conversation;
const Role = @import("state.zig").Role;
const TokenUsage = @import("state.zig").TokenUsage;
const provider_client = @import("provider_client.zig");
const tui = @import("tui.zig");
const APP_VERSION = "0.1.0-dev";

const CliRunOptions = struct {
    session_id: ?[]const u8 = null,
};

const CliRunTaskOptions = struct {
    session_id: ?[]const u8 = null,
    prompt_parts: []const []const u8,
};

const CliAction = union(enum) {
    run_tui: CliRunOptions,
    run_task: CliRunTaskOptions,
    show_help,
    show_version,
    invalid: []const u8,
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli_action = parseCliAction(args[1..]);
    switch (cli_action) {
        .run_tui, .run_task => {},
        .show_help => {
            try writeHelpToStdout();
            return;
        },
        .show_version => {
            try writeVersionToStdout();
            return;
        },
        .invalid => |arg| {
            try writeInvalidArgToStderr(arg);
            return;
        },
    }

    var paths = try Paths.init(allocator);

    paths.ensureDirs() catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {
            std.log.warn("cannot use XDG dirs ({s}), falling back to workspace-local .zig-ai", .{@errorName(err)});
            paths.deinit(allocator);
            paths = try Paths.initWorkspaceFallback(allocator);
            try paths.ensureDirs();
        },
        else => return err,
    };
    probePathsWritable(allocator, &paths) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {
            std.log.warn("XDG path is not writable ({s}), using workspace-local .zig-ai", .{@errorName(err)});
            paths.deinit(allocator);
            paths = try Paths.initWorkspaceFallback(allocator);
            try paths.ensureDirs();
            try probePathsWritable(allocator, &paths);
        },
        else => return err,
    };
    defer paths.deinit(allocator);

    var config = app_config.loadOptionalFromPath(allocator, paths.config_path) catch |err| blk: {
        std.log.warn("failed to load config ({s}): {s}", .{ paths.config_path, @errorName(err) });
        break :blk null;
    };
    defer if (config) |*cfg| cfg.deinit(allocator);

    var app_state = try AppState.loadOrCreate(allocator, paths.state_path);
    defer app_state.deinit(allocator);

    var startup_options: tui.StartupOptions = .{};
    if (config) |cfg| {
        if (cfg.provider_id) |provider_id| {
            try app_state.setSelectedProvider(allocator, provider_id);
        }
        if (cfg.model_id) |model_id| {
            try app_state.setSelectedModel(allocator, model_id);
        }
        if (cfg.theme) |theme| {
            startup_options.theme = switch (theme) {
                .codex => .codex,
                .plain => .plain,
                .forest => .forest,
            };
        }
        if (cfg.ui_mode) |ui_mode| {
            startup_options.compact_mode = switch (ui_mode) {
                .compact => true,
                .comfy => false,
            };
        }
        if (cfg.keybindings) |bindings| {
            startup_options.keybindings = bindings;
        }
    }

    var catalog = blk: {
        const loaded = models.loadOrRefresh(allocator, paths.models_cache_path) catch |err| {
            std.log.warn("failed to load models cache: {s}", .{@errorName(err)});
            break :blk models.Catalog{};
        };

        std.log.info(
            "loaded {d} providers from models cache ({s})",
            .{ loaded.catalog.providers.items.len, if (loaded.loaded_from_cache) "cached" else "refreshed" },
        );
        break :blk loaded.catalog;
    };
    defer catalog.deinit(allocator);

    switch (cli_action) {
        .run_tui => |run_options| {
            if (run_options.session_id) |session_id| {
                if (!app_state.switchConversation(session_id)) {
                    try writeSessionNotFoundToStderr(session_id);
                    return;
                }
            } else {
                try selectStartupConversationWithoutSession(allocator, &app_state);
            }

            tui.run(allocator, &paths, &app_state, &catalog, startup_options) catch |err| switch (err) {
                error.NotATerminal => {
                    var output_buffer: [1024]u8 = undefined;
                    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
                    defer stderr_writer.interface.flush() catch {};
                    try stderr_writer.interface.writeAll("zolt requires a TTY. Run it directly in a terminal.\n");
                    return;
                },
                else => return err,
            };
            try app_state.saveToPath(allocator, paths.state_path);
        },
        .run_task => |task_options| {
            try runSinglePromptTask(allocator, &app_state, &catalog, task_options, paths.state_path);
        },
        else => unreachable,
    }
}

const RunTaskStreamContext = struct {
    assistant_writer: std.Io.Writer.Allocating,
    usage: TokenUsage = .{},
};

fn runSinglePromptTask(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    catalog: *const models.Catalog,
    options: CliRunTaskOptions,
    state_path: []const u8,
) !void {
    if (options.session_id) |session_id| {
        if (!app_state.switchConversation(session_id)) {
            try writeSessionNotFoundToStderr(session_id);
            return;
        }
    } else {
        try selectStartupConversationWithoutSession(allocator, app_state);
    }

    const prompt_full = try joinPromptPartsAlloc(allocator, options.prompt_parts);
    defer allocator.free(prompt_full);
    const prompt = std.mem.trim(u8, prompt_full, " \t\r\n");
    if (prompt.len == 0) {
        try writeRunTaskMissingPromptToStderr();
        return;
    }

    if (shouldAutoTitleCurrentConversation(app_state.currentConversationConst())) {
        const title = try deriveConversationTitleFromPrompt(allocator, prompt);
        defer allocator.free(title);
        try app_state.setConversationTitle(allocator, title);
    }

    try app_state.appendMessage(allocator, .user, prompt);
    var should_save = true;
    defer if (should_save) app_state.saveToPath(allocator, state_path) catch {};

    const provider_id = app_state.selected_provider_id;
    const model_id = app_state.selected_model_id;
    const api_key = try resolveApiKey(allocator, catalog, provider_id);
    if (api_key == null) {
        try writeMissingApiKeyToStderr(provider_id, firstEnvVarForProvider(catalog, provider_id));
        return;
    }
    defer allocator.free(api_key.?);

    const provider_info = catalog.findProviderConst(provider_id);
    const base_url = if (provider_info) |info| info.api_base else null;

    const stream_messages = try buildStreamMessagesFromConversation(allocator, app_state.currentConversationConst());
    defer allocator.free(stream_messages);

    var stream_context: RunTaskStreamContext = .{
        .assistant_writer = .init(allocator),
    };
    defer stream_context.assistant_writer.deinit();

    provider_client.streamChat(allocator, .{
        .provider_id = provider_id,
        .model_id = model_id,
        .api_key = api_key.?,
        .base_url = base_url,
        .messages = stream_messages,
    }, .{
        .on_token = onRunTaskToken,
        .on_usage = onRunTaskUsage,
        .context = &stream_context,
    }) catch |err| {
        try writeRunTaskProviderErrorToStderr(err, provider_client.lastProviderErrorDetail());
        return err;
    };

    const assistant_text = try stream_context.assistant_writer.toOwnedSlice();
    defer allocator.free(assistant_text);

    if (assistant_text.len > 0) {
        try app_state.appendMessage(allocator, .assistant, assistant_text);
    }
    if (!stream_context.usage.isZero()) {
        app_state.appendTokenUsage(stream_context.usage, selectedModelContextWindow(catalog, provider_id, model_id));
    }
    try app_state.saveToPath(allocator, state_path);
    should_save = false;

    try writeRunTaskOutputToStdout(assistant_text);
}

fn onRunTaskToken(context: ?*anyopaque, token: []const u8) anyerror!void {
    if (token.len == 0) return;
    const run_context: *RunTaskStreamContext = @ptrCast(@alignCast(context.?));
    try run_context.assistant_writer.writer.writeAll(token);
}

fn onRunTaskUsage(context: ?*anyopaque, usage: TokenUsage) anyerror!void {
    const run_context: *RunTaskStreamContext = @ptrCast(@alignCast(context.?));
    run_context.usage.addAssign(usage);
}

fn buildStreamMessagesFromConversation(
    allocator: std.mem.Allocator,
    conversation: *const Conversation,
) ![]provider_client.StreamMessage {
    const messages = try allocator.alloc(provider_client.StreamMessage, conversation.messages.items.len);
    for (conversation.messages.items, 0..) |message, index| {
        messages[index] = .{
            .role = message.role,
            .content = message.content,
        };
    }
    return messages;
}

fn joinPromptPartsAlloc(allocator: std.mem.Allocator, prompt_parts: []const []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    for (prompt_parts, 0..) |part, index| {
        if (index > 0) try writer.writer.writeByte(' ');
        try writer.writer.writeAll(part);
    }
    return writer.toOwnedSlice();
}

fn shouldAutoTitleCurrentConversation(conversation: *const Conversation) bool {
    if (conversation.messages.items.len != 0) return false;
    if (std.mem.eql(u8, conversation.title, "New conversation")) return true;
    return std.mem.startsWith(u8, conversation.title, "Conversation ");
}

fn deriveConversationTitleFromPrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "New conversation");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var previous_was_space = false;
    for (trimmed) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (is_space) {
            if (!previous_was_space) {
                try out.append(allocator, ' ');
                previous_was_space = true;
            }
            continue;
        }

        if (out.items.len >= 96) break;
        try out.append(allocator, byte);
        previous_was_space = false;
    }

    if (out.items.len == 0) return allocator.dupe(u8, "New conversation");
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn resolveApiKey(
    allocator: std.mem.Allocator,
    catalog: *const models.Catalog,
    provider_id: []const u8,
) !?[]u8 {
    if (catalog.findProviderConst(provider_id)) |provider| {
        if (provider.env_vars.items.len > 0) {
            for (provider.env_vars.items) |env_var| {
                const value = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
                    error.EnvironmentVariableNotFound => null,
                    else => return err,
                };
                if (value) |key| return key;
            }
        }
    }

    for (fallbackApiEnvVars(provider_id)) |env_var| {
        const value = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (value) |key| return key;
    }

    return null;
}

fn firstEnvVarForProvider(catalog: *const models.Catalog, provider_id: []const u8) ?[]const u8 {
    if (catalog.findProviderConst(provider_id)) |provider| {
        if (provider.env_vars.items.len > 0) return provider.env_vars.items[0];
    }

    const fallback = fallbackApiEnvVars(provider_id);
    if (fallback.len > 0) return fallback[0];
    return null;
}

fn fallbackApiEnvVars(provider_id: []const u8) []const []const u8 {
    if (std.mem.eql(u8, provider_id, "opencode")) return &.{"OPENCODE_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openai")) return &.{"OPENAI_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openrouter")) return &.{"OPENROUTER_API_KEY"};
    if (std.mem.eql(u8, provider_id, "anthropic")) return &.{"ANTHROPIC_API_KEY"};
    if (std.mem.eql(u8, provider_id, "google")) return &.{ "GOOGLE_GENERATIVE_AI_API_KEY", "GEMINI_API_KEY" };
    if (std.mem.eql(u8, provider_id, "zenmux")) return &.{"ZENMUX_API_KEY"};
    return &.{};
}

fn selectedModelContextWindow(
    catalog: *const models.Catalog,
    provider_id: []const u8,
    model_id: []const u8,
) ?i64 {
    const provider = catalog.findProviderConst(provider_id) orelse return null;
    for (provider.models.items) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return model.context_window;
    }
    return null;
}

fn writeRunTaskOutputToStdout(text: []const u8) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    try stdout_writer.interface.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') {
        try stdout_writer.interface.writeByte('\n');
    }
}

fn writeRunTaskMissingPromptToStderr() !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};
    try stderr_writer.interface.writeAll("missing prompt\nUsage: zolt run \"<prompt>\"\n");
}

fn writeMissingApiKeyToStderr(provider_id: []const u8, env_hint: ?[]const u8) !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    if (env_hint) |hint| {
        try stderr_writer.interface.print(
            "missing API key for provider {s}\nSet env var: {s}\n",
            .{ provider_id, hint },
        );
    } else {
        try stderr_writer.interface.print(
            "missing API key for provider {s}\n",
            .{provider_id},
        );
    }
}

fn writeRunTaskProviderErrorToStderr(err: anyerror, detail: ?[]const u8) !void {
    var output_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    if (detail) |provider_detail| {
        try stderr_writer.interface.print("provider request failed: {s}\n", .{provider_detail});
        return;
    }
    try stderr_writer.interface.print("provider request failed: {s}\n", .{@errorName(err)});
}

fn parseCliAction(args: []const []const u8) CliAction {
    if (args.len == 0) return .{ .run_tui = .{} };

    if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            return .show_help;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "version")) {
            return .show_version;
        }
    }

    if (std.mem.eql(u8, args[0], "run")) {
        return parseRunTaskCliAction(args[1..]);
    }

    var run_options: CliRunOptions = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            if (run_options.session_id != null) return .{ .invalid = arg };

            const session_id = args[index + 1];
            if (session_id.len == 0 or session_id[0] == '-') return .{ .invalid = arg };
            run_options.session_id = session_id;
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--session=")) {
            if (run_options.session_id != null) return .{ .invalid = arg };
            const session_id = arg["--session=".len..];
            if (session_id.len == 0) return .{ .invalid = arg };
            run_options.session_id = session_id;
            index += 1;
            continue;
        }

        return .{ .invalid = arg };
    }

    return .{ .run_tui = run_options };
}

fn parseRunTaskCliAction(args: []const []const u8) CliAction {
    var run_options: CliRunOptions = .{};
    var index: usize = 0;

    while (index < args.len) {
        const arg = args[index];
        if (!std.mem.startsWith(u8, arg, "-")) break;

        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            if (run_options.session_id != null) return .{ .invalid = arg };

            const session_id = args[index + 1];
            if (session_id.len == 0 or session_id[0] == '-') return .{ .invalid = arg };
            run_options.session_id = session_id;
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--session=")) {
            if (run_options.session_id != null) return .{ .invalid = arg };
            const session_id = arg["--session=".len..];
            if (session_id.len == 0) return .{ .invalid = arg };
            run_options.session_id = session_id;
            index += 1;
            continue;
        }

        return .{ .invalid = arg };
    }

    if (index >= args.len) return .{ .invalid = "run" };
    return .{
        .run_task = .{
            .session_id = run_options.session_id,
            .prompt_parts = args[index..],
        },
    };
}

fn writeHelpToStdout() !void {
    var output_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    try stdout_writer.interface.writeAll(
        "zolt: minimal terminal AI chat\n" ++
            "Usage:\n" ++
            "  zolt\n" ++
            "  zolt run \"<prompt>\"\n" ++
            "  zolt -s <conversation-id>\n" ++
            "  zolt --session <conversation-id>\n" ++
            "  zolt run --session <conversation-id> \"<prompt>\"\n" ++
            "  zolt -h | --help | help\n" ++
            "  zolt -V | --version | version\n" ++
            "\n" ++
            "Requires an interactive TTY for chat mode.\n" ++
            "The run subcommand is non-interactive and prints assistant output to stdout.\n",
    );
}

fn writeVersionToStdout() !void {
    var output_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    try stdout_writer.interface.print("zolt {s} (zig {s})\n", .{ APP_VERSION, builtin.zig_version_string });
}

fn writeInvalidArgToStderr(arg: []const u8) !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    try stderr_writer.interface.print("invalid argument(s): {s}\nTry: zolt --help\n", .{arg});
}

fn writeSessionNotFoundToStderr(session_id: []const u8) !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    try stderr_writer.interface.print("session not found: {s}\nUse /sessions in zolt to view available conversation ids.\n", .{session_id});
}

fn selectStartupConversationWithoutSession(allocator: std.mem.Allocator, app_state: *AppState) !void {
    var newest_blank_index: ?usize = null;
    var newest_blank_updated: i64 = std.math.minInt(i64);

    for (app_state.conversations.items, 0..) |conversation, index| {
        if (conversation.messages.items.len != 0) continue;

        const conversation_updated = @max(conversation.updated_ms, conversation.created_ms);
        if (newest_blank_index == null or conversation_updated >= newest_blank_updated) {
            newest_blank_index = index;
            newest_blank_updated = conversation_updated;
        }
    }

    if (newest_blank_index) |index| {
        app_state.current_index = index;
        return;
    }

    _ = try app_state.createConversation(allocator, "New conversation");
}

fn probePathsWritable(allocator: std.mem.Allocator, paths: *const Paths) !void {
    const probe_state = try std.fmt.allocPrint(allocator, "{s}.probe", .{paths.state_path});
    defer allocator.free(probe_state);

    var state_file = try createFileForPath(probe_state, .{ .truncate = true });
    state_file.close();
    try deleteFileForPath(probe_state);

    const probe_models = try std.fmt.allocPrint(allocator, "{s}.probe", .{paths.models_cache_path});
    defer allocator.free(probe_models);

    var models_file = try createFileForPath(probe_models, .{ .truncate = true });
    models_file.close();
    try deleteFileForPath(probe_models);
}

fn createFileForPath(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

fn deleteFileForPath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteFileAbsolute(path);
    }
    return std.fs.cwd().deleteFile(path);
}

test "parseCliAction recognizes help aliases" {
    try std.testing.expect(parseCliAction(&.{"-h"}) == .show_help);
    try std.testing.expect(parseCliAction(&.{"--help"}) == .show_help);
    try std.testing.expect(parseCliAction(&.{"help"}) == .show_help);
}

test "parseCliAction recognizes version aliases" {
    try std.testing.expect(parseCliAction(&.{"-V"}) == .show_version);
    try std.testing.expect(parseCliAction(&.{"--version"}) == .show_version);
    try std.testing.expect(parseCliAction(&.{"version"}) == .show_version);
}

test "parseCliAction handles invalid and empty args" {
    const run_action = parseCliAction(&.{});
    switch (run_action) {
        .run_tui => |run_options| try std.testing.expect(run_options.session_id == null),
        else => return error.TestUnexpectedResult,
    }

    const invalid = parseCliAction(&.{"--wat"});
    switch (invalid) {
        .invalid => |arg| try std.testing.expectEqualStrings("--wat", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction parses session flags" {
    const short_flag = parseCliAction(&.{ "-s", "abc123" });
    switch (short_flag) {
        .run_tui => |run_options| try std.testing.expectEqualStrings("abc123", run_options.session_id.?),
        else => return error.TestUnexpectedResult,
    }

    const long_flag = parseCliAction(&.{ "--session", "def456" });
    switch (long_flag) {
        .run_tui => |run_options| try std.testing.expectEqualStrings("def456", run_options.session_id.?),
        else => return error.TestUnexpectedResult,
    }

    const equals_flag = parseCliAction(&.{"--session=ghi789"});
    switch (equals_flag) {
        .run_tui => |run_options| try std.testing.expectEqualStrings("ghi789", run_options.session_id.?),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction rejects bad session usage" {
    const missing = parseCliAction(&.{"-s"});
    switch (missing) {
        .invalid => |arg| try std.testing.expectEqualStrings("-s", arg),
        else => return error.TestUnexpectedResult,
    }

    const duplicate = parseCliAction(&.{ "--session", "a1", "--session", "b2" });
    switch (duplicate) {
        .invalid => |arg| try std.testing.expectEqualStrings("--session", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction parses run subcommand prompt and session flags" {
    const basic_run = parseCliAction(&.{ "run", "hello", "world" });
    switch (basic_run) {
        .run_task => |options| {
            try std.testing.expect(options.session_id == null);
            try std.testing.expectEqual(@as(usize, 2), options.prompt_parts.len);
            try std.testing.expectEqualStrings("hello", options.prompt_parts[0]);
            try std.testing.expectEqualStrings("world", options.prompt_parts[1]);
        },
        else => return error.TestUnexpectedResult,
    }

    const run_with_session = parseCliAction(&.{ "run", "--session", "abc123", "explain", "this" });
    switch (run_with_session) {
        .run_task => |options| {
            try std.testing.expectEqualStrings("abc123", options.session_id.?);
            try std.testing.expectEqual(@as(usize, 2), options.prompt_parts.len);
            try std.testing.expectEqualStrings("explain", options.prompt_parts[0]);
            try std.testing.expectEqualStrings("this", options.prompt_parts[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction rejects invalid run usage" {
    const missing_prompt = parseCliAction(&.{"run"});
    switch (missing_prompt) {
        .invalid => |arg| try std.testing.expectEqualStrings("run", arg),
        else => return error.TestUnexpectedResult,
    }

    const unknown_flag = parseCliAction(&.{ "run", "--wat", "test" });
    switch (unknown_flag) {
        .invalid => |arg| try std.testing.expectEqualStrings("--wat", arg),
        else => return error.TestUnexpectedResult,
    }
}

test "selectStartupConversationWithoutSession chooses newest blank conversation" {
    const allocator = std.testing.allocator;
    var app_state = try AppState.init(allocator);
    defer app_state.deinit(allocator);

    try app_state.appendMessage(allocator, .user, "keep this non-empty");
    _ = try app_state.createConversation(allocator, "New conversation");
    const newest_blank_id = try app_state.createConversation(allocator, "New conversation");

    try selectStartupConversationWithoutSession(allocator, &app_state);
    try std.testing.expectEqualStrings(newest_blank_id, app_state.currentConversationConst().id);
    try std.testing.expectEqual(@as(usize, 0), app_state.currentConversationConst().messages.items.len);
}

test "selectStartupConversationWithoutSession creates blank when all conversations are non-empty" {
    const allocator = std.testing.allocator;
    var app_state = try AppState.init(allocator);
    defer app_state.deinit(allocator);

    try app_state.appendMessage(allocator, .user, "hello");
    const before_count = app_state.conversations.items.len;

    try selectStartupConversationWithoutSession(allocator, &app_state);

    try std.testing.expectEqual(before_count + 1, app_state.conversations.items.len);
    try std.testing.expectEqual(@as(usize, 0), app_state.currentConversationConst().messages.items.len);
}

test {
    _ = @import("paths.zig");
    _ = @import("state.zig");
    _ = @import("models.zig");
    _ = @import("provider_client.zig");
    _ = @import("config.zig");
    _ = @import("keybindings.zig");
    _ = @import("tui.zig");
}
