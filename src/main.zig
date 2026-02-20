//! zolt: a minimal terminal AI chat client.

const std = @import("std");
const builtin = @import("builtin");

const app_config = @import("config.zig");
const models = @import("models.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const tui = @import("tui.zig");
const APP_VERSION = "0.1.0-dev";

const CliRunOptions = struct {
    session_id: ?[]const u8 = null,
};

const CliRunTaskOutputFormat = enum {
    text,
    logs,
    json,
    json_stream,
};

const CliRunTaskOptions = struct {
    session_id: ?[]const u8 = null,
    output_format: CliRunTaskOutputFormat = .text,
    prompt_parts: []const []const u8,
};

const CliListModelsOptions = struct {
    provider_id: ?[]const u8 = null,
    search_query: ?[]const u8 = null,
    select: bool = false,
    set_default_model_id: ?[]const u8 = null,
};

const CliAction = union(enum) {
    run_tui: CliRunOptions,
    run_task: CliRunTaskOptions,
    list_models: CliListModelsOptions,
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
        .run_tui, .run_task, .list_models => {},
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
    if (cli_action == .list_models) {
        var catalog = blk: {
            const loaded = models.loadOrRefresh(allocator, paths.models_cache_path) catch |err| {
                try writeModelsLoadFailedToStderr(err);
                return;
            };
            break :blk loaded.catalog;
        };
        defer catalog.deinit(allocator);
        defer paths.deinit(allocator);

        try writeModelsListToStdout(allocator, &catalog, cli_action.list_models, paths.config_path);
        return;
    }

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
            try app_state.setActiveProvider(allocator, provider_id);
        }
        if (cfg.model_id) |model_id| {
            try app_state.setActiveModel(allocator, model_id);
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
        if (cfg.openai_auth_mode) |auth_mode| {
            startup_options.openai_auth_mode = switch (auth_mode) {
                .auto => .auto,
                .api_key => .api_key,
                .codex => .codex,
            };
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
                if (!(try app_state.switchConversation(allocator, session_id))) {
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
            try runSinglePromptTask(allocator, &paths, &app_state, &catalog, task_options, startup_options);
        },
        .list_models => |options| {
            try writeModelsListToStdout(allocator, &catalog, options, paths.config_path);
        },
        else => unreachable,
    }
}

fn runSinglePromptTask(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
    options: CliRunTaskOptions,
    startup_options: tui.StartupOptions,
) !void {
    if (options.session_id) |session_id| {
        if (!(try app_state.switchConversation(allocator, session_id))) {
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

    switch (options.output_format) {
        .text => {
            const assistant_text = try tui.runTaskPrompt(allocator, paths, app_state, catalog, prompt, startup_options);
            defer allocator.free(assistant_text);
            try writeRunTaskOutputToStdout(assistant_text);
        },
        .logs => {
            var logger: RunTaskLogEmitter = .{};
            const assistant_text = try tui.runTaskPromptWithObserver(
                allocator,
                paths,
                app_state,
                catalog,
                prompt,
                startup_options,
                .{
                    .on_event = onRunTaskLogEvent,
                    .context = &logger,
                },
            );
            allocator.free(assistant_text);
        },
        .json_stream => {
            var writer: RunTaskJsonStreamEmitter = .{};
            const assistant_text = try tui.runTaskPromptWithObserver(
                allocator,
                paths,
                app_state,
                catalog,
                prompt,
                startup_options,
                .{
                    .on_event = onRunTaskJsonStreamEvent,
                    .context = &writer,
                },
            );
            allocator.free(assistant_text);
        },
        .json => {
            var collector: RunTaskEventCollector = .{};
            try collector.init(allocator);
            defer collector.deinit();

            const assistant_text = try tui.runTaskPromptWithObserver(
                allocator,
                paths,
                app_state,
                catalog,
                prompt,
                startup_options,
                .{
                    .on_event = onRunTaskCollectEvent,
                    .context = &collector,
                },
            );
            defer allocator.free(assistant_text);
            try writeRunTaskJsonOutputToStdout(
                allocator,
                app_state,
                prompt,
                assistant_text,
                collector.events.items,
            );
        },
    }
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

const RunTaskCapturedEventKind = enum {
    token,
    tool_call,
    tool_result,
    final,
};

const RunTaskCapturedEvent = struct {
    kind: RunTaskCapturedEventKind,
    text: []u8,
};

const RunTaskEventCollector = struct {
    allocator: std.mem.Allocator = undefined,
    events: std.ArrayList(RunTaskCapturedEvent) = .empty,

    fn init(self: *RunTaskEventCollector, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .events = .empty,
        };
    }

    fn deinit(self: *RunTaskEventCollector) void {
        for (self.events.items) |event| {
            self.allocator.free(event.text);
        }
        self.events.deinit(self.allocator);
    }
};

const RunTaskLogEmitter = struct {};
const RunTaskJsonStreamEmitter = struct {};

fn onRunTaskCollectEvent(context: ?*anyopaque, event: tui.RunTaskEvent) anyerror!void {
    const collector: *RunTaskEventCollector = @ptrCast(@alignCast(context.?));
    const mapped = mapRunTaskEvent(event);

    if (mapped.kind == .token and collector.events.items.len > 0) {
        const last_index = collector.events.items.len - 1;
        if (collector.events.items[last_index].kind == .token) {
            const previous = collector.events.items[last_index].text;
            const merged = try collector.allocator.realloc(previous, previous.len + mapped.text.len);
            @memcpy(merged[previous.len..], mapped.text);
            collector.events.items[last_index].text = merged;
            return;
        }
    }

    try collector.events.append(collector.allocator, .{
        .kind = mapped.kind,
        .text = try collector.allocator.dupe(u8, mapped.text),
    });
}

fn onRunTaskLogEvent(context: ?*anyopaque, event: tui.RunTaskEvent) anyerror!void {
    _ = context;
    const mapped = mapRunTaskEvent(event);
    switch (mapped.kind) {
        .token => return,
        .tool_call => {
            try writeStdoutRaw(mapped.text);
            try writeStdoutRaw("\n");
        },
        .tool_result => {
            try writeStdoutRaw(mapped.text);
            try writeStdoutRaw("\n");
        },
        .final => {
            try writeStdoutRaw("[final]\n");
            try writeStdoutRaw(mapped.text);
            if (mapped.text.len == 0 or mapped.text[mapped.text.len - 1] != '\n') {
                try writeStdoutRaw("\n");
            }
        },
    }
}

fn onRunTaskJsonStreamEvent(context: ?*anyopaque, event: tui.RunTaskEvent) anyerror!void {
    _ = context;
    const mapped = mapRunTaskEvent(event);
    try writeRunTaskJsonStreamLine(mapped.kind, mapped.text);
}

const MappedRunTaskEvent = struct {
    kind: RunTaskCapturedEventKind,
    text: []const u8,
};

fn mapRunTaskEvent(event: tui.RunTaskEvent) MappedRunTaskEvent {
    return switch (event) {
        .token => |text| .{ .kind = .token, .text = text },
        .tool_call => |text| .{ .kind = .tool_call, .text = text },
        .tool_result => |text| .{ .kind = .tool_result, .text = text },
        .final => |text| .{ .kind = .final, .text = text },
    };
}

fn runTaskCapturedEventKindLabel(kind: RunTaskCapturedEventKind) []const u8 {
    return switch (kind) {
        .token => "token",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .final => "final",
    };
}

fn writeRunTaskJsonStreamLine(kind: RunTaskCapturedEventKind, text: []const u8) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    var jw: std.json.Stringify = .{ .writer = &stdout_writer.interface };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(runTaskCapturedEventKindLabel(kind));
    try jw.objectField("text");
    try jw.write(text);
    try jw.endObject();
    try stdout_writer.interface.writeByte('\n');
}

fn writeRunTaskJsonOutputToStdout(
    allocator: std.mem.Allocator,
    app_state: *const AppState,
    prompt: []const u8,
    response: []const u8,
    events: []const RunTaskCapturedEvent,
) !void {
    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try jw.beginObject();
    try jw.objectField("provider");
    try jw.write(app_state.selected_provider_id);
    try jw.objectField("model");
    try jw.write(app_state.selected_model_id);
    try jw.objectField("session_id");
    try jw.write(app_state.currentConversationConst().id);
    try jw.objectField("prompt");
    try jw.write(prompt);
    try jw.objectField("response");
    try jw.write(response);
    try jw.objectField("events");
    try jw.beginArray();
    for (events) |event| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(runTaskCapturedEventKindLabel(event.kind));
        try jw.objectField("text");
        try jw.write(event.text);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();

    const payload = try payload_writer.toOwnedSlice();
    defer allocator.free(payload);
    try writeRunTaskOutputToStdout(payload);
}

fn writeStdoutRaw(text: []const u8) !void {
    var start: usize = 0;
    while (start < text.len) {
        const written = try std.posix.write(std.fs.File.stdout().handle, text[start..]);
        if (written == 0) return error.WriteFailed;
        start += written;
    }
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
    try stderr_writer.interface.writeAll(
        "missing prompt\n" ++
            "Usage: zolt run [--session <id>] [--output <text|logs|json|json-stream>] \"<prompt>\"\n",
    );
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
    if (std.mem.eql(u8, args[0], "models") or std.mem.eql(u8, args[0], "list-models")) {
        return parseListModelsCliAction(args[1..]);
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

fn parseListModelsCliAction(args: []const []const u8) CliAction {
    var options: CliListModelsOptions = .{};
    var index: usize = 0;

    while (index < args.len) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--provider")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            if (options.provider_id != null) return .{ .invalid = arg };
            const provider_id = args[index + 1];
            if (provider_id.len == 0 or provider_id[0] == '-') return .{ .invalid = arg };
            options.provider_id = provider_id;
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--provider=")) {
            if (options.provider_id != null) return .{ .invalid = arg };
            const provider_id = arg["--provider=".len..];
            if (provider_id.len == 0) return .{ .invalid = arg };
            options.provider_id = provider_id;
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--search")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            if (options.search_query != null) return .{ .invalid = arg };
            const query = args[index + 1];
            if (query.len == 0 or query[0] == '-') return .{ .invalid = arg };
            options.search_query = query;
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--search=")) {
            if (options.search_query != null) return .{ .invalid = arg };
            const query = arg["--search=".len..];
            if (query.len == 0) return .{ .invalid = arg };
            options.search_query = query;
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--select")) {
            options.select = true;
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--set-default")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            if (options.set_default_model_id != null) return .{ .invalid = arg };
            const model_id = args[index + 1];
            if (model_id.len == 0 or model_id[0] == '-') return .{ .invalid = arg };
            options.set_default_model_id = model_id;
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--set-default=")) {
            if (options.set_default_model_id != null) return .{ .invalid = arg };
            const model_id = arg["--set-default=".len..];
            if (model_id.len == 0) return .{ .invalid = arg };
            options.set_default_model_id = model_id;
            index += 1;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') return .{ .invalid = arg };
        if (options.provider_id != null) return .{ .invalid = arg };
        options.provider_id = arg;
        index += 1;
    }

    if ((options.select or options.set_default_model_id != null) and options.provider_id == null) {
        return .{ .invalid = "models" };
    }

    return .{ .list_models = options };
}

fn parseRunTaskCliAction(args: []const []const u8) CliAction {
    var run_options: CliRunOptions = .{};
    var output_format: CliRunTaskOutputFormat = .text;
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

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (index + 1 >= args.len) return .{ .invalid = arg };
            const parsed = parseRunTaskOutputFormat(args[index + 1]) orelse return .{ .invalid = arg };
            output_format = parsed;
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

        if (std.mem.startsWith(u8, arg, "--output=")) {
            const value = arg["--output=".len..];
            const parsed = parseRunTaskOutputFormat(value) orelse return .{ .invalid = arg };
            output_format = parsed;
            index += 1;
            continue;
        }

        return .{ .invalid = arg };
    }

    if (index >= args.len) return .{ .invalid = "run" };
    return .{
        .run_task = .{
            .session_id = run_options.session_id,
            .output_format = output_format,
            .prompt_parts = args[index..],
        },
    };
}

fn parseRunTaskOutputFormat(value: []const u8) ?CliRunTaskOutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "logs")) return .logs;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "json-stream")) return .json_stream;
    if (std.mem.eql(u8, value, "ndjson")) return .json_stream;
    if (std.mem.eql(u8, value, "jsonl")) return .json_stream;
    return null;
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
            "  zolt run --output <text|logs|json|json-stream> \"<prompt>\"\n" ++
            "  zolt models [provider-id]\n" ++
            "  zolt models --provider <provider-id>\n" ++
            "  zolt models --provider <provider-id> --search <query>\n" ++
            "  zolt models --provider <provider-id> --select [--search <query>]\n" ++
            "  zolt models --provider <provider-id> --set-default <model-id>\n" ++
            "  zolt -s <conversation-id>\n" ++
            "  zolt --session <conversation-id>\n" ++
            "  zolt run --session <conversation-id> \"<prompt>\"\n" ++
            "  zolt -h | --help | help\n" ++
            "  zolt -V | --version | version\n" ++
            "\n" ++
            "Requires an interactive TTY for chat mode.\n" ++
            "The run subcommand is non-interactive and prints assistant output to stdout.\n" ++
            "Run output modes:\n" ++
            "  text        final assistant response only (default)\n" ++
            "  logs        tool call/result logs + final response\n" ++
            "  json        one JSON object with response + events\n" ++
            "  json-stream newline-delimited JSON events while running\n" ++
            "\n" ++
            "Models listing:\n" ++
            "  zolt models                 list providers and model counts\n" ++
            "  zolt models opencode        list model IDs for provider\n" ++
            "  zolt models -p openai       same as above\n" ++
            "  zolt models -p openai -q codex  filter provider models\n" ++
            "  zolt models -p openai --select  choose and save default model\n",
    );
}

fn writeModelsListToStdout(
    allocator: std.mem.Allocator,
    catalog: *const models.Catalog,
    options: CliListModelsOptions,
    config_path: []const u8,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (options.provider_id) |provider_id| {
        const provider = catalog.findProviderConst(provider_id) orelse {
            try writeModelProviderNotFoundToStderr(catalog, provider_id);
            return;
        };

        try stdout_writer.interface.print(
            "provider: {s} ({s})\nmodels: {d}\n",
            .{ provider.id, provider.name, provider.models.items.len },
        );
        if (provider.env_vars.items.len > 0) {
            try stdout_writer.interface.print("api_key_env: {s}\n", .{provider.env_vars.items[0]});
        }

        if (options.set_default_model_id) |model_id| {
            const model = findModelById(provider, model_id) orelse {
                try writeModelNotFoundToStderr(provider, model_id);
                return;
            };

            try app_config.setDefaultProviderModelAtPath(allocator, config_path, provider.id, model.id);
            try stdout_writer.interface.print(
                "saved defaults to {s}\nprovider: {s}\nmodel: {s}\n",
                .{ config_path, provider.id, model.id },
            );
            return;
        }

        var matched_indexes: std.ArrayList(usize) = .empty;
        defer matched_indexes.deinit(allocator);
        for (provider.models.items, 0..) |model, model_index| {
            if (modelMatchesSearch(model, options.search_query)) {
                try matched_indexes.append(allocator, model_index);
            }
        }

        if (options.search_query) |query| {
            try stdout_writer.interface.print("filtered: {d}/{d}  query:{s}\n", .{
                matched_indexes.items.len,
                provider.models.items.len,
                query,
            });
        }

        if (options.select) {
            const selected_model_index = selectModelIndexInteractively(
                allocator,
                provider,
                matched_indexes.items,
                options.search_query,
            ) catch |err| switch (err) {
                error.NotATerminal => {
                    try writeModelsSelectionNeedsTtyToStderr();
                    return;
                },
                error.InvalidSelection => {
                    try writeModelsSelectionInvalidToStderr();
                    return;
                },
                else => return err,
            };

            if (selected_model_index) |model_index| {
                const selected = provider.models.items[model_index];
                try app_config.setDefaultProviderModelAtPath(allocator, config_path, provider.id, selected.id);
                try stdout_writer.interface.print(
                    "saved defaults to {s}\nprovider: {s}\nmodel: {s}\n",
                    .{ config_path, provider.id, selected.id },
                );
            } else {
                try stdout_writer.interface.writeAll("selection canceled\n");
            }
            return;
        }

        try stdout_writer.interface.writeAll("\nmodel ids:\n");
        for (matched_indexes.items) |model_index| {
            const model = provider.models.items[model_index];
            if (model.context_window) |window| {
                try stdout_writer.interface.print("- {s}  (ctx:{d})\n", .{ model.id, window });
            } else {
                try stdout_writer.interface.print("- {s}\n", .{model.id});
            }
        }
        if (matched_indexes.items.len > 0) {
            const first = provider.models.items[matched_indexes.items[0]];
            try stdout_writer.interface.print(
                "\nconfig.jsonc example:\n{{\n  \"provider\": \"{s}\",\n  \"model\": \"{s}\"\n}}\n",
                .{ provider.id, first.id },
            );
        }
        return;
    }

    try stdout_writer.interface.print("providers: {d}\n", .{catalog.providers.items.len});
    try stdout_writer.interface.writeAll("usage: zolt models <provider-id>\n\n");
    for (catalog.providers.items) |provider| {
        if (provider.env_vars.items.len > 0) {
            try stdout_writer.interface.print(
                "- {s} ({s}) models:{d} key:{s}\n",
                .{ provider.id, provider.name, provider.models.items.len, provider.env_vars.items[0] },
            );
        } else {
            try stdout_writer.interface.print(
                "- {s} ({s}) models:{d}\n",
                .{ provider.id, provider.name, provider.models.items.len },
            );
        }
    }
}

fn modelMatchesSearch(model: models.ModelInfo, query: ?[]const u8) bool {
    const search = query orelse return true;
    const trimmed = std.mem.trim(u8, search, " \t\r\n");
    if (trimmed.len == 0) return true;
    return containsAsciiIgnoreCase(model.id, trimmed) or containsAsciiIgnoreCase(model.name, trimmed);
}

fn findModelById(provider: *const models.ProviderInfo, model_id: []const u8) ?models.ModelInfo {
    for (provider.models.items) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return model;
    }
    return null;
}

fn selectModelIndexInteractively(
    allocator: std.mem.Allocator,
    provider: *const models.ProviderInfo,
    matched_indexes: []const usize,
    search_query: ?[]const u8,
) !?usize {
    if (!std.posix.isatty(std.fs.File.stdin().handle) or !std.posix.isatty(std.fs.File.stdout().handle)) {
        return error.NotATerminal;
    }

    var output_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (search_query) |query| {
        try stdout_writer.interface.print(
            "select from {d} model(s) for provider {s} (query:{s})\n",
            .{ matched_indexes.len, provider.id, query },
        );
    } else {
        try stdout_writer.interface.print(
            "select from {d} model(s) for provider {s}\n",
            .{ matched_indexes.len, provider.id },
        );
    }

    if (matched_indexes.len == 0) {
        try stdout_writer.interface.writeAll("no models match the current query\n");
        return null;
    }

    for (matched_indexes, 0..) |model_index, display_index| {
        const model = provider.models.items[model_index];
        if (model.context_window) |window| {
            try stdout_writer.interface.print("{d}. {s}  (ctx:{d})\n", .{ display_index + 1, model.id, window });
        } else {
            try stdout_writer.interface.print("{d}. {s}\n", .{ display_index + 1, model.id });
        }
    }

    try stdout_writer.interface.print("choice [1-{d}] (enter to cancel): ", .{matched_indexes.len});
    try stdout_writer.interface.flush();

    const line = try readLineFromStdinAlloc(allocator, 64);
    defer allocator.free(line);

    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    const selected = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidSelection;
    if (selected < 1 or selected > matched_indexes.len) return error.InvalidSelection;
    return matched_indexes[selected - 1];
}

fn readLineFromStdinAlloc(allocator: std.mem.Allocator, max_len: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const read_len = try std.posix.read(std.fs.File.stdin().handle, byte[0..]);
        if (read_len == 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;

        if (output.items.len >= max_len) return error.InvalidSelection;
        try output.append(allocator, byte[0]);
    }

    return output.toOwnedSlice(allocator);
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

fn writeModelNotFoundToStderr(provider: *const models.ProviderInfo, model_id: []const u8) !void {
    var output_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    try stderr_writer.interface.print("model not found for provider {s}: {s}\n", .{ provider.id, model_id });
    try stderr_writer.interface.writeAll("Try: zolt models --provider ");
    try stderr_writer.interface.writeAll(provider.id);
    try stderr_writer.interface.writeAll("\n");
}

fn writeModelsSelectionNeedsTtyToStderr() !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};
    try stderr_writer.interface.writeAll("model selection requires a TTY. Use --set-default <model-id> for non-interactive usage.\n");
}

fn writeModelsSelectionInvalidToStderr() !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};
    try stderr_writer.interface.writeAll("invalid model selection input\n");
}

fn writeModelProviderNotFoundToStderr(catalog: *const models.Catalog, provider_id: []const u8) !void {
    var output_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};

    try stderr_writer.interface.print("provider not found: {s}\navailable providers:\n", .{provider_id});
    for (catalog.providers.items) |provider| {
        try stderr_writer.interface.print("- {s}\n", .{provider.id});
    }
}

fn writeModelsLoadFailedToStderr(err: anyerror) !void {
    var output_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&output_buffer);
    defer stderr_writer.interface.flush() catch {};
    try stderr_writer.interface.print(
        "failed to load models cache: {s}\nTry: zolt run \"/models refresh\" (inside TUI) or ensure cache path is writable.\n",
        .{@errorName(err)},
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

test "parseCliAction parses models subcommand variants" {
    const basic = parseCliAction(&.{"models"});
    switch (basic) {
        .list_models => |options| {
            try std.testing.expect(options.provider_id == null);
            try std.testing.expect(options.search_query == null);
            try std.testing.expect(!options.select);
            try std.testing.expect(options.set_default_model_id == null);
        },
        else => return error.TestUnexpectedResult,
    }

    const positional = parseCliAction(&.{ "models", "opencode" });
    switch (positional) {
        .list_models => |options| try std.testing.expectEqualStrings("opencode", options.provider_id.?),
        else => return error.TestUnexpectedResult,
    }

    const long_flag = parseCliAction(&.{ "models", "--provider", "openai" });
    switch (long_flag) {
        .list_models => |options| try std.testing.expectEqualStrings("openai", options.provider_id.?),
        else => return error.TestUnexpectedResult,
    }

    const short_flag = parseCliAction(&.{ "models", "-p", "anthropic" });
    switch (short_flag) {
        .list_models => |options| try std.testing.expectEqualStrings("anthropic", options.provider_id.?),
        else => return error.TestUnexpectedResult,
    }

    const search_flag = parseCliAction(&.{ "models", "-p", "openai", "--search", "codex" });
    switch (search_flag) {
        .list_models => |options| try std.testing.expectEqualStrings("codex", options.search_query.?),
        else => return error.TestUnexpectedResult,
    }

    const select_flag = parseCliAction(&.{ "models", "-p", "openai", "--select" });
    switch (select_flag) {
        .list_models => |options| try std.testing.expect(options.select),
        else => return error.TestUnexpectedResult,
    }

    const set_default_flag = parseCliAction(&.{ "models", "--provider", "openai", "--set-default", "gpt-5.3-codex" });
    switch (set_default_flag) {
        .list_models => |options| try std.testing.expectEqualStrings("gpt-5.3-codex", options.set_default_model_id.?),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction rejects invalid models subcommand args" {
    const missing_provider = parseCliAction(&.{ "models", "--provider" });
    switch (missing_provider) {
        .invalid => |arg| try std.testing.expectEqualStrings("--provider", arg),
        else => return error.TestUnexpectedResult,
    }

    const duplicate_provider = parseCliAction(&.{ "models", "openai", "opencode" });
    switch (duplicate_provider) {
        .invalid => |arg| try std.testing.expectEqualStrings("opencode", arg),
        else => return error.TestUnexpectedResult,
    }

    const set_default_without_provider = parseCliAction(&.{ "models", "--set-default", "gpt-5.3-codex" });
    switch (set_default_without_provider) {
        .invalid => |arg| try std.testing.expectEqualStrings("models", arg),
        else => return error.TestUnexpectedResult,
    }

    const select_without_provider = parseCliAction(&.{ "models", "--select" });
    switch (select_without_provider) {
        .invalid => |arg| try std.testing.expectEqualStrings("models", arg),
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
            try std.testing.expect(options.output_format == .text);
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
            try std.testing.expect(options.output_format == .text);
            try std.testing.expectEqual(@as(usize, 2), options.prompt_parts.len);
            try std.testing.expectEqualStrings("explain", options.prompt_parts[0]);
            try std.testing.expectEqualStrings("this", options.prompt_parts[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseCliAction parses run output format flags" {
    const run_json = parseCliAction(&.{ "run", "--output", "json", "summarize" });
    switch (run_json) {
        .run_task => |options| {
            try std.testing.expect(options.output_format == .json);
            try std.testing.expectEqualStrings("summarize", options.prompt_parts[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    const run_stream = parseCliAction(&.{ "run", "--output=json-stream", "check" });
    switch (run_stream) {
        .run_task => |options| try std.testing.expect(options.output_format == .json_stream),
        else => return error.TestUnexpectedResult,
    }

    const run_logs = parseCliAction(&.{ "run", "-o", "logs", "status" });
    switch (run_logs) {
        .run_task => |options| try std.testing.expect(options.output_format == .logs),
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

    const bad_output = parseCliAction(&.{ "run", "--output", "yaml", "test" });
    switch (bad_output) {
        .invalid => |arg| try std.testing.expectEqualStrings("--output", arg),
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
