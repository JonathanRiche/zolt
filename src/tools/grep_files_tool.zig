//! GREP_FILES tool runner.

const std = @import("std");
const common = @import("common.zig");

const GrepFilesInput = struct {
    query: []u8,
    path: []u8,
    glob: ?[]u8 = null,
    max_matches: u16 = 200,

    fn deinit(self: *GrepFilesInput, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.path);
        if (self.glob) |glob| allocator.free(glob);
    }
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    var input = parseGrepFilesInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[grep-files-result]\nerror: invalid payload (expected plain query or JSON with query/path/glob/max_matches)");
    };
    defer input.deinit(app.allocator);

    if (input.query.len == 0) {
        return app.allocator.dupe(u8, "[grep-files-result]\nerror: empty query");
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(app.allocator);
    try argv.appendSlice(app.allocator, &.{
        "rg",
        "--line-number",
        "--column",
        "--no-heading",
        "--color",
        "never",
        "--smart-case",
    });
    if (input.glob) |glob| {
        try argv.appendSlice(app.allocator, &.{ "--glob", glob });
    }
    try argv.append(app.allocator, input.query);
    try argv.append(app.allocator, input.path);

    const result = std.process.Child.run(.{
        .allocator = app.allocator,
        .argv = argv.items,
        .cwd = ".",
        .max_output_bytes = 128 * 1024,
    }) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[grep-files-result]\nquery: {s}\npath: {s}\nerror: {s}",
            .{ input.query, input.path, @errorName(err) },
        );
    };
    defer app.allocator.free(result.stdout);
    defer app.allocator.free(result.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print("[grep-files-result]\nquery: {s}\npath: {s}\n", .{ input.query, input.path });
    if (input.glob) |glob| try output.writer.print("glob: {s}\n", .{glob});

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        .Signal => |sig| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg terminated by signal {d}", .{sig}),
        .Stopped => |sig| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg stopped by signal {d}", .{sig}),
        .Unknown => |code| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg unknown term {d}", .{code}),
    };

    if (exit_code == 1) {
        try output.writer.writeAll("matches: 0\nnote: no matches\n");
        return output.toOwnedSlice();
    }
    if (exit_code != 0) {
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            try output.writer.print("error: rg failed ({d}) {s}\n", .{ exit_code, stderr_trimmed });
        } else {
            try output.writer.print("error: rg failed ({d})\n", .{exit_code});
        }
        return output.toOwnedSlice();
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var total_matches: u32 = 0;
    var emitted_matches: u32 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        total_matches += 1;
        if (emitted_matches < input.max_matches) {
            emitted_matches += 1;
            try output.writer.print("{s}\n", .{line});
        }
    }

    try output.writer.print("matches: {d}\n", .{total_matches});
    if (total_matches > emitted_matches) {
        try output.writer.print("note: truncated output ({d} hidden)\n", .{total_matches - emitted_matches});
    }

    return output.toOwnedSlice();
}

fn parseGrepFilesInput(allocator: std.mem.Allocator, payload: []const u8) !GrepFilesInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .query = try allocator.dupe(u8, trimmed), .path = try allocator.dupe(u8, "."), .glob = null, .max_matches = 200 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("pattern") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("dir") orelse std.json.Value{ .string = "." };
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const glob = if (object.get("glob")) |glob_value| switch (glob_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else null;

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .glob = if (glob) |g| try allocator.dupe(u8, std.mem.trim(u8, g, " \t\r\n")) else null,
        .max_matches = common.sanitizeGrepMatches(common.jsonFieldU32(object, "max_matches") orelse common.jsonFieldU32(object, "limit") orelse 200),
    };
}
