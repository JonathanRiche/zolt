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

const CliAction = union(enum) {
    run_tui: CliRunOptions,
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

    var cli_run_options: CliRunOptions = .{};
    switch (parseCliAction(args[1..])) {
        .run_tui => |run_options| {
            cli_run_options = run_options;
        },
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

    if (cli_run_options.session_id) |session_id| {
        if (!app_state.switchConversation(session_id)) {
            try writeSessionNotFoundToStderr(session_id);
            return;
        }
    } else {
        try selectStartupConversationWithoutSession(allocator, &app_state);
    }

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

fn writeHelpToStdout() !void {
    var output_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
    defer stdout_writer.interface.flush() catch {};

    try stdout_writer.interface.writeAll(
        "zolt: minimal terminal AI chat\n" ++
            "Usage:\n" ++
            "  zolt\n" ++
            "  zolt -s <conversation-id>\n" ++
            "  zolt --session <conversation-id>\n" ++
            "  zolt -h | --help | help\n" ++
            "  zolt -V | --version | version\n" ++
            "\n" ++
            "Requires an interactive TTY for chat mode.\n",
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

    try stderr_writer.interface.print("session not found: {s}\nUse /list in zolt to view available conversation ids.\n", .{session_id});
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
    _ = @import("tui.zig");
}
