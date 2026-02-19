//! WRITE_STDIN tool runner.

const std = @import("std");
const common = @import("common.zig");

const WriteStdinInput = struct {
    session_id: u32,
    chars: []u8,
    yield_ms: u32 = common.COMMAND_TOOL_DEFAULT_YIELD_MS,
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    var input = parseWriteStdinInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[write-stdin-result]\nerror: invalid payload (expected JSON with session_id, chars, optional yield_ms)");
    };
    defer app.allocator.free(input.chars);

    const session = app.findCommandSessionById(input.session_id) orelse {
        return std.fmt.allocPrint(app.allocator, "[write-stdin-result]\nerror: session not found ({d})", .{input.session_id});
    };

    if (session.finished) {
        var output: std.Io.Writer.Allocating = .init(app.allocator);
        defer output.deinit();
        try output.writer.print("[write-stdin-result]\nsession_id: {d}\nchars_written: 0\n", .{session.id});
        try app.appendCommandSessionStateLine(&output.writer, session);
        return output.toOwnedSlice();
    }

    var written: usize = 0;
    if (input.chars.len > 0) {
        const stdin_file = session.child.stdin orelse {
            return std.fmt.allocPrint(app.allocator, "[write-stdin-result]\nsession_id: {d}\nerror: session stdin is closed", .{session.id});
        };

        while (written < input.chars.len) {
            const n = std.posix.write(stdin_file.handle, input.chars[written..]) catch |err| switch (err) {
                error.BrokenPipe => {
                    session.child.stdin.?.close();
                    session.child.stdin = null;
                    break;
                },
                else => return std.fmt.allocPrint(
                    app.allocator,
                    "[write-stdin-result]\nsession_id: {d}\nerror: {s}",
                    .{ session.id, @errorName(err) },
                ),
            };
            written += n;
        }
    }

    const drained = try app.drainCommandSessionOutput(session, input.yield_ms);
    defer app.allocator.free(drained.stdout);
    defer app.allocator.free(drained.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print("[write-stdin-result]\nsession_id: {d}\nchars_written: {d}\n", .{
        session.id,
        written,
    });
    try app.appendCommandSessionStateLine(&output.writer, session);
    try app.appendCommandDrainOutput(&output.writer, drained);
    return output.toOwnedSlice();
}

fn parseWriteStdinInput(allocator: std.mem.Allocator, payload: []const u8) !WriteStdinInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidToolPayload;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const session_value = object.get("session_id") orelse object.get("session") orelse return error.InvalidToolPayload;
    const session_id = switch (session_value) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else return error.InvalidToolPayload,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch return error.InvalidToolPayload,
        else => return error.InvalidToolPayload,
    };

    const chars_text = if (object.get("chars")) |chars_value|
        switch (chars_value) {
            .string => |text| text,
            else => return error.InvalidToolPayload,
        }
    else
        "";

    const yield_ms = common.sanitizeCommandYieldMs(common.jsonFieldU32(object, "yield_ms") orelse common.jsonFieldU32(object, "yield_time_ms") orelse common.COMMAND_TOOL_DEFAULT_YIELD_MS);

    return .{ .session_id = session_id, .chars = try allocator.dupe(u8, chars_text), .yield_ms = yield_ms };
}
