//! READ_FILE tool runner.

const std = @import("std");
const common = @import("common.zig");

const ReadFileInput = struct {
    path: []u8,
    max_bytes: u32 = 12 * 1024,
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    const input = parseReadFileInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[read-file-result]\nerror: invalid payload (expected plain path or JSON with path and optional max_bytes)");
    };
    defer app.allocator.free(input.path);

    var file = common.openFileForPath(input.path, .{}) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        );
    };
    defer file.close();

    const content = file.readToEndAlloc(app.allocator, input.max_bytes) catch |err| switch (err) {
        error.FileTooBig => return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: file too big (max_bytes:{d})",
            .{ input.path, input.max_bytes },
        ),
        else => return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        ),
    };
    defer app.allocator.free(content);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print(
        "[read-file-result]\npath: {s}\nbytes: {d}\n",
        .{ input.path, content.len },
    );
    if (common.looksBinary(content)) {
        try output.writer.writeAll("note: file appears binary; content omitted\n");
        return output.toOwnedSlice();
    }

    try output.writer.writeAll("content:\n");
    try output.writer.writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

fn parseReadFileInput(allocator: std.mem.Allocator, payload: []const u8) !ReadFileInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, trimmed), .max_bytes = 12 * 1024 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("file") orelse return error.InvalidToolPayload;
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .max_bytes = common.sanitizeReadFileMaxBytes(common.jsonFieldU32(object, "max_bytes") orelse common.jsonFieldU32(object, "limit") orelse 12 * 1024),
    };
}
