//! Path discovery and filesystem locations for zig-ai.

const std = @import("std");
const SCOPE_DIR_NAME = "workspaces";

pub const Paths = struct {
    data_dir: []u8,
    cache_dir: []u8,
    state_path: []u8,
    models_cache_path: []u8,
    config_path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Paths {
        const data_home = try xdgHome(allocator, "XDG_DATA_HOME", ".local/share");
        defer allocator.free(data_home);

        const cache_home = try xdgHome(allocator, "XDG_CACHE_HOME", ".cache");
        defer allocator.free(cache_home);

        const data_dir = try std.fs.path.join(allocator, &.{ data_home, "zig-ai" });
        errdefer allocator.free(data_dir);

        const cache_dir = try std.fs.path.join(allocator, &.{ cache_home, "zig-ai" });
        errdefer allocator.free(cache_dir);

        const scope_root = try resolveWorkspaceScopeRoot(allocator);
        defer allocator.free(scope_root);

        const scope_id = try buildWorkspaceScopeId(allocator, scope_root);
        defer allocator.free(scope_id);

        const state_path = try buildScopedStatePath(allocator, data_dir, scope_id);
        errdefer allocator.free(state_path);

        const models_cache_path = try std.fs.path.join(allocator, &.{ cache_dir, "models.json" });
        errdefer allocator.free(models_cache_path);

        const config_path = try defaultConfigPath(allocator);
        errdefer allocator.free(config_path);

        return .{
            .data_dir = data_dir,
            .cache_dir = cache_dir,
            .state_path = state_path,
            .models_cache_path = models_cache_path,
            .config_path = config_path,
        };
    }

    pub fn initWorkspaceFallback(allocator: std.mem.Allocator) !Paths {
        const scope_root = try resolveWorkspaceScopeRoot(allocator);
        defer allocator.free(scope_root);

        const base_dir = try std.fs.path.join(allocator, &.{ scope_root, ".zig-ai" });
        defer allocator.free(base_dir);

        const data_dir = try std.fs.path.join(allocator, &.{ base_dir, "data" });
        errdefer allocator.free(data_dir);

        const cache_dir = try std.fs.path.join(allocator, &.{ base_dir, "cache" });
        errdefer allocator.free(cache_dir);

        const scope_id = try buildWorkspaceScopeId(allocator, scope_root);
        defer allocator.free(scope_id);

        const state_path = try buildScopedStatePath(allocator, data_dir, scope_id);
        errdefer allocator.free(state_path);

        const models_cache_path = try std.fs.path.join(allocator, &.{ cache_dir, "models.json" });
        errdefer allocator.free(models_cache_path);

        const config_path = try defaultConfigPath(allocator);
        errdefer allocator.free(config_path);

        return .{
            .data_dir = data_dir,
            .cache_dir = cache_dir,
            .state_path = state_path,
            .models_cache_path = models_cache_path,
            .config_path = config_path,
        };
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
        allocator.free(self.cache_dir);
        allocator.free(self.state_path);
        allocator.free(self.models_cache_path);
        allocator.free(self.config_path);
    }

    pub fn ensureDirs(self: *const Paths) !void {
        try std.fs.cwd().makePath(self.data_dir);
        try std.fs.cwd().makePath(self.cache_dir);
        if (std.fs.path.dirname(self.state_path)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
        if (std.fs.path.dirname(self.models_cache_path)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
    }

    fn xdgHome(allocator: std.mem.Allocator, env_name: []const u8, home_suffix: []const u8) ![]u8 {
        const from_env = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (from_env) |value| {
            return value;
        }

        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        return std.fs.path.join(allocator, &.{ home, home_suffix });
    }

    fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
        const config_home = try xdgHome(allocator, "XDG_CONFIG_HOME", ".config");
        defer allocator.free(config_home);
        return std.fs.path.join(allocator, &.{ config_home, "zolt", "config.jsonc" });
    }

    fn resolveWorkspaceScopeRoot(allocator: std.mem.Allocator) ![]u8 {
        if (try tryGitTopLevel(allocator)) |git_root| {
            return git_root;
        }
        return std.process.getCwdAlloc(allocator);
    }

    fn tryGitTopLevel(allocator: std.mem.Allocator) !?[]u8 {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .cwd = ".",
            .max_output_bytes = 16 * 1024,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return null,
            else => return null,
        }

        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, trimmed));
    }

    fn buildWorkspaceScopeId(allocator: std.mem.Allocator, scope_root: []const u8) ![]u8 {
        const basename = std.fs.path.basename(scope_root);
        const label = try sanitizeScopeLabel(
            allocator,
            if (basename.len == 0) "workspace" else basename,
        );
        defer allocator.free(label);

        const hash = std.hash.Wyhash.hash(0, scope_root);
        return std.fmt.allocPrint(allocator, "{s}-{x}", .{ label, hash });
    }

    fn sanitizeScopeLabel(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        const limit = @min(input.len, 48);
        for (input[0..limit]) |byte| {
            if (std.ascii.isAlphanumeric(byte)) {
                try out.append(allocator, std.ascii.toLower(byte));
                continue;
            }

            if (byte == '-' or byte == '_') {
                try out.append(allocator, byte);
                continue;
            }

            if (out.items.len == 0 or out.items[out.items.len - 1] != '-') {
                try out.append(allocator, '-');
            }
        }

        while (out.items.len > 0 and (out.items[out.items.len - 1] == '-' or out.items[out.items.len - 1] == '_')) {
            _ = out.pop();
        }

        if (out.items.len == 0) {
            try out.appendSlice(allocator, "workspace");
        }

        return out.toOwnedSlice(allocator);
    }

    fn buildScopedStatePath(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        scope_id: []const u8,
    ) ![]u8 {
        const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{scope_id});
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ data_dir, SCOPE_DIR_NAME, filename });
    }
};
