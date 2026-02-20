//! REQUEST_USER_INPUT tool runner.

const std = @import("std");

const MAX_QUESTIONS: usize = 3;
const MAX_OPTIONS_PER_QUESTION: usize = 4;

const Choice = struct {
    label: []u8,
    description: []u8,

    fn deinit(self: *Choice, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

const Question = struct {
    header: []u8,
    id: []u8,
    prompt: []u8,
    options: std.ArrayList(Choice) = .empty,

    fn deinit(self: *Question, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.id);
        allocator.free(self.prompt);
        for (self.options.items) |*option| option.deinit(allocator);
        self.options.deinit(allocator);
    }
};

const RequestUserInputPayload = struct {
    questions: std.ArrayList(Question) = .empty,

    fn deinit(self: *RequestUserInputPayload, allocator: std.mem.Allocator) void {
        for (self.questions.items) |*question| question.deinit(allocator);
        self.questions.deinit(allocator);
    }
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    var parsed = parseRequestUserInputPayload(app.allocator, payload) catch |err| {
        return switch (err) {
            error.InvalidToolPayload => app.allocator.dupe(
                u8,
                "[request-user-input-result]\nerror: invalid payload (expected JSON with questions:[{header,id,question,options:[{label,description}]}])",
            ),
            error.QuestionCountOutOfRange => std.fmt.allocPrint(
                app.allocator,
                "[request-user-input-result]\nerror: invalid payload (questions must contain 1..{d} items)",
                .{MAX_QUESTIONS},
            ),
            error.OptionCountOutOfRange => app.allocator.dupe(
                u8,
                "[request-user-input-result]\nerror: invalid payload (each question must include 2..4 options)",
            ),
            else => std.fmt.allocPrint(
                app.allocator,
                "[request-user-input-result]\nerror: {s}",
                .{@errorName(err)},
            ),
        };
    };
    defer parsed.deinit(app.allocator);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.writeAll("[request-user-input-result]\n");
    try output.writer.writeAll("status: ok\n");
    try output.writer.writeAll("mode: non_blocking_inline\n");
    try output.writer.print("questions: {d}\n", .{parsed.questions.items.len});
    for (parsed.questions.items, 0..) |question, question_index| {
        try output.writer.print("question {d}:\n", .{question_index + 1});
        try output.writer.print("  header: {s}\n", .{question.header});
        try output.writer.print("  id: {s}\n", .{question.id});
        try output.writer.print("  prompt: {s}\n", .{question.prompt});
        for (question.options.items, 0..) |option, option_index| {
            try output.writer.print(
                "  - {d}) {s} :: {s}\n",
                .{ option_index + 1, option.label, option.description },
            );
        }
    }
    try output.writer.writeAll("reply_hint: Ask the user to reply in chat with one choice per question using `<id>: <label>`.\n");

    return output.toOwnedSlice();
}

fn parseRequestUserInputPayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !RequestUserInputPayload {
    const body = extractPayloadBody(payload) orelse return error.InvalidToolPayload;
    if (body.len == 0 or body[0] != '{') return error.InvalidToolPayload;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidToolPayload,
    };

    const questions_value = root.get("questions") orelse return error.InvalidToolPayload;
    const questions_array = switch (questions_value) {
        .array => |array| array.items,
        else => return error.InvalidToolPayload,
    };
    if (questions_array.len == 0 or questions_array.len > MAX_QUESTIONS) return error.QuestionCountOutOfRange;

    var out: RequestUserInputPayload = .{};
    errdefer out.deinit(allocator);

    for (questions_array) |question_value| {
        const question_obj = switch (question_value) {
            .object => |value| value,
            else => return error.InvalidToolPayload,
        };

        const header = try parseRequiredStringAlloc(allocator, question_obj, "header");
        errdefer allocator.free(header);
        const id = try parseRequiredStringAlloc(allocator, question_obj, "id");
        errdefer allocator.free(id);
        const prompt = try parseRequiredStringAlloc(allocator, question_obj, "question");
        errdefer allocator.free(prompt);

        const options_value = question_obj.get("options") orelse return error.InvalidToolPayload;
        const options_array = switch (options_value) {
            .array => |array| array.items,
            else => return error.InvalidToolPayload,
        };
        if (options_array.len < 2 or options_array.len > MAX_OPTIONS_PER_QUESTION) {
            return error.OptionCountOutOfRange;
        }

        var question: Question = .{
            .header = header,
            .id = id,
            .prompt = prompt,
        };
        errdefer question.deinit(allocator);

        for (options_array) |option_value| {
            const option_obj = switch (option_value) {
                .object => |value| value,
                else => return error.InvalidToolPayload,
            };
            try question.options.append(allocator, .{
                .label = try parseRequiredStringAlloc(allocator, option_obj, "label"),
                .description = try parseRequiredStringAlloc(allocator, option_obj, "description"),
            });
        }

        try out.questions.append(allocator, question);
    }

    return out;
}

fn parseRequiredStringAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidToolPayload;
    const text = switch (value) {
        .string => |string| std.mem.trim(u8, string, " \t\r\n"),
        else => return error.InvalidToolPayload,
    };
    if (text.len == 0) return error.InvalidToolPayload;
    return allocator.dupe(u8, text);
}

fn extractPayloadBody(payload: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<REQUEST_USER_INPUT>")) {
        const rest = trimmed["<REQUEST_USER_INPUT>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</REQUEST_USER_INPUT>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```request_user_input")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const after_marker = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (after_marker.len >= "REQUEST_USER_INPUT".len and std.mem.startsWith(u8, after_marker, "REQUEST_USER_INPUT")) {
            return std.mem.trimLeft(u8, after_marker["REQUEST_USER_INPUT".len..], " \t:");
        }
    }

    return trimmed;
}

test "parseRequestUserInputPayload parses valid payload" {
    const allocator = std.testing.allocator;
    const payload =
        "<REQUEST_USER_INPUT>\n" ++
        "{\"questions\":[{\"header\":\"Provider\",\"id\":\"provider_choice\",\"question\":\"Pick provider\",\"options\":[{\"label\":\"OpenAI\",\"description\":\"Use OpenAI models\"},{\"label\":\"Anthropic\",\"description\":\"Use Claude models\"}]}]}\n" ++
        "</REQUEST_USER_INPUT>";

    var parsed = try parseRequestUserInputPayload(allocator, payload);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.questions.items.len);
    const question = parsed.questions.items[0];
    try std.testing.expectEqualStrings("Provider", question.header);
    try std.testing.expectEqualStrings("provider_choice", question.id);
    try std.testing.expectEqual(@as(usize, 2), question.options.items.len);
}

test "parseRequestUserInputPayload rejects invalid option count" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"questions":[{"header":"h","id":"q","question":"pick","options":[{"label":"one","description":"only one"}]}]}
    ;
    try std.testing.expectError(error.OptionCountOutOfRange, parseRequestUserInputPayload(allocator, payload));
}
