//! EXEC_COMMAND tool runner.

const std = @import("std");
const common = @import("common.zig");

const ExecCommandInput = struct {
    cmd: []u8,
    yield_ms: u32 = common.COMMAND_TOOL_DEFAULT_YIELD_MS,
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    const input = parseExecCommandInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[exec-result]\nerror: invalid payload (expected JSON with cmd and optional yield_ms)");
    };
    defer app.allocator.free(input.cmd);

    if (input.cmd.len == 0) {
        return app.allocator.dupe(u8, "[exec-result]\nerror: empty command");
    }

    try app.pruneCommandSessionsForCapacity();

    const session = try app.startCommandSession(input.cmd);
    const drained = try app.drainCommandSessionOutput(session, input.yield_ms);
    defer app.allocator.free(drained.stdout);
    defer app.allocator.free(drained.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print("[exec-result]\nsession_id: {d}\ncommand: {s}\n", .{
        session.id,
        session.command_line,
    });
    try app.appendCommandSessionStateLine(&output.writer, session);
    try app.appendCommandDrainOutput(&output.writer, drained);

    return output.toOwnedSlice();
}

fn parseExecCommandInput(allocator: std.mem.Allocator, payload: []const u8) !ExecCommandInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .cmd = try allocator.dupe(u8, trimmed), .yield_ms = common.COMMAND_TOOL_DEFAULT_YIELD_MS };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const cmd_value = object.get("cmd") orelse object.get("command") orelse return error.InvalidToolPayload;
    const cmd_text = switch (cmd_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const yield_ms = common.sanitizeCommandYieldMs(common.jsonFieldU32(object, "yield_ms") orelse common.jsonFieldU32(object, "yield_time_ms") orelse common.COMMAND_TOOL_DEFAULT_YIELD_MS);

    return .{ .cmd = try allocator.dupe(u8, std.mem.trim(u8, cmd_text, " \t\r\n")), .yield_ms = yield_ms };
}
