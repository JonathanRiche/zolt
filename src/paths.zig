//! Path discovery and filesystem locations for zig-ai.

const std = @import("std");

pub const Paths = struct {
    data_dir: []u8,
    cache_dir: []u8,
    state_path: []u8,
    models_cache_path: []u8,

    pub fn init(allocator: std.mem.Allocator) !Paths {
        const data_home = try xdgHome(allocator, "XDG_DATA_HOME", ".local/share");
        defer allocator.free(data_home);

        const cache_home = try xdgHome(allocator, "XDG_CACHE_HOME", ".cache");
        defer allocator.free(cache_home);

        const data_dir = try std.fs.path.join(allocator, &.{ data_home, "zig-ai" });
        errdefer allocator.free(data_dir);

        const cache_dir = try std.fs.path.join(allocator, &.{ cache_home, "zig-ai" });
        errdefer allocator.free(cache_dir);

        const state_path = try std.fs.path.join(allocator, &.{ data_dir, "state.json" });
        errdefer allocator.free(state_path);

        const models_cache_path = try std.fs.path.join(allocator, &.{ cache_dir, "models.json" });
        errdefer allocator.free(models_cache_path);

        return .{
            .data_dir = data_dir,
            .cache_dir = cache_dir,
            .state_path = state_path,
            .models_cache_path = models_cache_path,
        };
    }

    pub fn initWorkspaceFallback(allocator: std.mem.Allocator) !Paths {
        const data_dir = try allocator.dupe(u8, ".zig-ai/data");
        errdefer allocator.free(data_dir);

        const cache_dir = try allocator.dupe(u8, ".zig-ai/cache");
        errdefer allocator.free(cache_dir);

        const state_path = try allocator.dupe(u8, ".zig-ai/data/state.json");
        errdefer allocator.free(state_path);

        const models_cache_path = try allocator.dupe(u8, ".zig-ai/cache/models.json");
        errdefer allocator.free(models_cache_path);

        return .{
            .data_dir = data_dir,
            .cache_dir = cache_dir,
            .state_path = state_path,
            .models_cache_path = models_cache_path,
        };
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
        allocator.free(self.cache_dir);
        allocator.free(self.state_path);
        allocator.free(self.models_cache_path);
    }

    pub fn ensureDirs(self: *const Paths) !void {
        try std.fs.cwd().makePath(self.data_dir);
        try std.fs.cwd().makePath(self.cache_dir);
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
};
