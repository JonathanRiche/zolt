//! zolt: a minimal terminal AI chat client.

const std = @import("std");

const app_config = @import("config.zig");
const models = @import("models.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const tui = @import("tui.zig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        var output_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&output_buffer);
        defer stdout_writer.interface.flush() catch {};
        try stdout_writer.interface.writeAll(
            "zolt: minimal terminal AI chat\n" ++
                "Usage: zolt\n" ++
                "Requires an interactive TTY.\n",
        );
        return;
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

test {
    _ = @import("paths.zig");
    _ = @import("state.zig");
    _ = @import("models.zig");
    _ = @import("provider_client.zig");
    _ = @import("config.zig");
    _ = @import("tui.zig");
}
