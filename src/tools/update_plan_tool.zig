//! UPDATE_PLAN tool runner.

const std = @import("std");

const MAX_PLAN_ITEMS: usize = 64;

const PlanStatus = enum {
    pending,
    in_progress,
    completed,
};

const PlanItem = struct {
    step: []u8,
    status: PlanStatus,

    fn deinit(self: *PlanItem, allocator: std.mem.Allocator) void {
        allocator.free(self.step);
    }
};

const UpdatePlanInput = struct {
    explanation: ?[]u8 = null,
    items: std.ArrayList(PlanItem) = .empty,

    fn deinit(self: *UpdatePlanInput, allocator: std.mem.Allocator) void {
        if (self.explanation) |value| allocator.free(value);
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    var parsed = parseUpdatePlanInput(app.allocator, payload) catch |err| {
        return switch (err) {
            error.InvalidToolPayload => app.allocator.dupe(
                u8,
                "[update-plan-result]\nerror: invalid payload (expected JSON object with plan:[{step,status}])",
            ),
            error.MultipleInProgress => app.allocator.dupe(
                u8,
                "[update-plan-result]\nerror: invalid payload (at most one in_progress step is allowed)",
            ),
            error.EmptyPlan => app.allocator.dupe(
                u8,
                "[update-plan-result]\nerror: invalid payload (plan must contain at least one step)",
            ),
            error.PlanTooLarge => std.fmt.allocPrint(
                app.allocator,
                "[update-plan-result]\nerror: invalid payload (plan has too many steps; max:{d})",
                .{MAX_PLAN_ITEMS},
            ),
            else => std.fmt.allocPrint(
                app.allocator,
                "[update-plan-result]\nerror: {s}",
                .{@errorName(err)},
            ),
        };
    };
    defer parsed.deinit(app.allocator);

    var in_progress_count: usize = 0;
    for (parsed.items.items) |item| {
        if (item.status == .in_progress) in_progress_count += 1;
    }

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.writeAll("[update-plan-result]\nstatus: ok\n");
    if (parsed.explanation) |explanation| {
        try output.writer.print("explanation: {s}\n", .{explanation});
    }
    try output.writer.print("steps: {d}\n", .{parsed.items.items.len});
    try output.writer.print("in_progress: {d}\n", .{in_progress_count});
    try output.writer.writeAll("plan:\n");
    for (parsed.items.items) |item| {
        try output.writer.print("- [{s}] {s}\n", .{ statusLabel(item.status), item.step });
    }

    return output.toOwnedSlice();
}

fn parseUpdatePlanInput(allocator: std.mem.Allocator, payload: []const u8) !UpdatePlanInput {
    const body = extractPayloadBody(payload) orelse return error.InvalidToolPayload;
    if (body.len == 0 or body[0] != '{') return error.InvalidToolPayload;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidToolPayload,
    };

    var input: UpdatePlanInput = .{};
    errdefer input.deinit(allocator);

    if (object.get("explanation")) |value| {
        const text = switch (value) {
            .string => |string| std.mem.trim(u8, string, " \t\r\n"),
            .null => "",
            else => return error.InvalidToolPayload,
        };
        if (text.len > 0) input.explanation = try allocator.dupe(u8, text);
    }

    const plan_value = object.get("plan") orelse return error.InvalidToolPayload;
    const plan_array = switch (plan_value) {
        .array => |items| items.items,
        else => return error.InvalidToolPayload,
    };

    if (plan_array.len == 0) return error.EmptyPlan;
    if (plan_array.len > MAX_PLAN_ITEMS) return error.PlanTooLarge;

    var in_progress_count: usize = 0;
    for (plan_array) |entry| {
        const step_object = switch (entry) {
            .object => |value| value,
            else => return error.InvalidToolPayload,
        };

        const step_value = step_object.get("step") orelse return error.InvalidToolPayload;
        const step_text = switch (step_value) {
            .string => |string| std.mem.trim(u8, string, " \t\r\n"),
            else => return error.InvalidToolPayload,
        };
        if (step_text.len == 0) return error.InvalidToolPayload;

        const status_value = step_object.get("status") orelse return error.InvalidToolPayload;
        const status_text = switch (status_value) {
            .string => |string| std.mem.trim(u8, string, " \t\r\n"),
            else => return error.InvalidToolPayload,
        };
        const status = parseStatus(status_text) orelse return error.InvalidToolPayload;

        if (status == .in_progress) {
            in_progress_count += 1;
            if (in_progress_count > 1) return error.MultipleInProgress;
        }

        try input.items.append(allocator, .{
            .step = try allocator.dupe(u8, step_text),
            .status = status,
        });
    }

    return input;
}

fn extractPayloadBody(payload: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<UPDATE_PLAN>")) {
        const rest = trimmed["<UPDATE_PLAN>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</UPDATE_PLAN>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```update_plan")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const after_marker = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (after_marker.len >= "UPDATE_PLAN".len and std.mem.startsWith(u8, after_marker, "UPDATE_PLAN")) {
            return std.mem.trimLeft(u8, after_marker["UPDATE_PLAN".len..], " \t:");
        }
    }

    return trimmed;
}

fn parseStatus(value: []const u8) ?PlanStatus {
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(value, "completed")) return .completed;
    if (std.ascii.eqlIgnoreCase(value, "in_progress")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(value, "in-progress")) return .in_progress;
    return null;
}

fn statusLabel(status: PlanStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .in_progress => "in_progress",
        .completed => "completed",
    };
}

test "parseUpdatePlanInput parses xml payload and enforces status rules" {
    const allocator = std.testing.allocator;
    const payload =
        "<UPDATE_PLAN>\n" ++
        "{\"explanation\":\"doing work\",\"plan\":[{\"step\":\"Audit files\",\"status\":\"completed\"},{\"step\":\"Implement change\",\"status\":\"in_progress\"},{\"step\":\"Run tests\",\"status\":\"pending\"}]}\n" ++
        "</UPDATE_PLAN>";

    var input = try parseUpdatePlanInput(allocator, payload);
    defer input.deinit(allocator);

    try std.testing.expectEqualStrings("doing work", input.explanation.?);
    try std.testing.expectEqual(@as(usize, 3), input.items.items.len);
    try std.testing.expectEqual(.completed, input.items.items[0].status);
    try std.testing.expectEqual(.in_progress, input.items.items[1].status);
    try std.testing.expectEqual(.pending, input.items.items[2].status);
}

test "parseUpdatePlanInput rejects multiple in_progress steps" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"plan":[{"step":"one","status":"in_progress"},{"step":"two","status":"in_progress"}]}
    ;

    try std.testing.expectError(error.MultipleInProgress, parseUpdatePlanInput(allocator, payload));
}
