//! LIST_DIR tool runner.

const std = @import("std");
const common = @import("common.zig");

const ListDirInput = struct {
    path: []u8,
    recursive: bool = false,
    max_entries: u16 = 200,
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    const input = parseListDirInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[list-dir-result]\nerror: invalid payload (expected plain path or JSON with path, recursive, max_entries)");
    };
    defer app.allocator.free(input.path);

    var dir = common.openDirForPath(input.path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[list-dir-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        );
    };
    defer dir.close();

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print(
        "[list-dir-result]\npath: {s}\nrecursive: {s}\nmax_entries: {d}\n",
        .{ input.path, if (input.recursive) "true" else "false", input.max_entries },
    );

    var count: u32 = 0;
    var truncated = false;

    if (input.recursive) {
        var walker = try dir.walk(app.allocator);
        defer walker.deinit();

        while (true) {
            const entry = walker.next() catch |err| {
                try output.writer.print("error: {s}\n", .{@errorName(err)});
                break;
            };
            if (entry == null) break;

            if (count >= input.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            try output.writer.print(
                "{d}. [{s}] {s}\n",
                .{ count, common.dirEntryKindLabel(entry.?.kind), entry.?.path },
            );
        }
    } else {
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                try output.writer.print("error: {s}\n", .{@errorName(err)});
                break;
            };
            if (entry == null) break;

            if (count >= input.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            try output.writer.print(
                "{d}. [{s}] {s}\n",
                .{ count, common.dirEntryKindLabel(entry.?.kind), entry.?.name },
            );
        }
    }

    if (count == 0) {
        try output.writer.writeAll("note: no entries\n");
    }
    if (truncated) {
        try output.writer.writeAll("note: truncated by max_entries\n");
    }

    return output.toOwnedSlice();
}

fn parseListDirInput(allocator: std.mem.Allocator, payload: []const u8) !ListDirInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, trimmed), .recursive = false, .max_entries = 200 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("dir") orelse return error.InvalidToolPayload;
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .recursive = common.jsonFieldBool(object, "recursive") orelse common.jsonFieldBool(object, "recurse") orelse false,
        .max_entries = common.sanitizeListDirMaxEntries(common.jsonFieldU32(object, "max_entries") orelse common.jsonFieldU32(object, "limit") orelse 200),
    };
}
