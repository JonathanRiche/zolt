//! Provider HTTP client and streaming token extraction.

const std = @import("std");

const Role = @import("state.zig").Role;
const DECOMPRESS_BUFFER_SIZE = 64 * 1024;

pub const StreamMessage = struct {
    role: Role,
    content: []const u8,
};

pub const StreamRequest = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: []const u8,
    base_url: ?[]const u8,
    messages: []const StreamMessage,
};

pub const StreamCallbacks = struct {
    on_token: *const fn (context: ?*anyopaque, token: []const u8) anyerror!void,
    context: ?*anyopaque = null,
};

threadlocal var last_error_buffer: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn lastProviderErrorDetail() ?[]const u8 {
    if (last_error_len == 0) return null;
    return last_error_buffer[0..last_error_len];
}

fn clearLastProviderErrorDetail() void {
    last_error_len = 0;
}

pub fn streamChat(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
) !void {
    clearLastProviderErrorDetail();

    if (std.mem.eql(u8, request.provider_id, "anthropic")) {
        return streamAnthropic(allocator, request, callbacks);
    }
    if (std.mem.eql(u8, request.provider_id, "google")) {
        return streamGoogle(allocator, request, callbacks);
    }
    if (isOpenAiCompatibleProvider(request.provider_id)) {
        return streamOpenAiCompatible(allocator, request, callbacks);
    }

    return error.UnsupportedProvider;
}

fn streamOpenAiCompatible(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
) !void {
    const base_url = request.base_url orelse defaultBaseUrl(request.provider_id) orelse return error.MissingProviderBaseUrl;

    const endpoint = try joinUrl(allocator, base_url, "/chat/completions");
    defer allocator.free(endpoint);

    const payload = try buildOpenAiPayload(allocator, request);
    defer allocator.free(payload);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(auth_header);

    var extra_headers: [2]std.http.Header = .{
        .{ .name = "HTTP-Referer", .value = "https://opencode.ai/" },
        .{ .name = "X-Title", .value = "zig-ai" },
    };

    const use_referrer_headers = std.mem.eql(u8, request.provider_id, "openrouter") or
        std.mem.eql(u8, request.provider_id, "opencode") or
        std.mem.eql(u8, request.provider_id, "zenmux");

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .extra_headers = if (use_referrer_headers) extra_headers[0..] else &.{},
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };

    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        const error_body = readResponseBodyAlloc(allocator, &response) catch "";
        defer if (error_body.len > 0) allocator.free(error_body);

        if (shouldRetryWithLegacyCompletions(response.head.status, error_body)) {
            return streamOpenAiLegacyCompletions(allocator, request, callbacks, use_referrer_headers);
        }

        std.log.err("openai-compatible request failed: status={s} body={s}", .{ @tagName(response.head.status), error_body });
        setLastProviderErrorDetail(response.head.status, error_body);
        return error.ProviderRequestFailed;
    }

    try streamSseResponse(allocator, &response, callbacks, extractOpenAiTokenAlloc);
}

fn streamOpenAiLegacyCompletions(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
    use_referrer_headers: bool,
) !void {
    const base_url = request.base_url orelse defaultBaseUrl(request.provider_id) orelse return error.MissingProviderBaseUrl;

    const endpoint = try joinUrl(allocator, base_url, "/completions");
    defer allocator.free(endpoint);

    const payload = try buildOpenAiLegacyCompletionsPayload(allocator, request);
    defer allocator.free(payload);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(auth_header);

    var extra_headers: [2]std.http.Header = .{
        .{ .name = "HTTP-Referer", .value = "https://opencode.ai/" },
        .{ .name = "X-Title", .value = "zig-ai" },
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .extra_headers = if (use_referrer_headers) extra_headers[0..] else &.{},
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };

    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        const error_body = readResponseBodyAlloc(allocator, &response) catch "";
        defer if (error_body.len > 0) allocator.free(error_body);

        if (shouldRetryWithResponsesEndpoint(response.head.status, error_body)) {
            return streamOpenAiResponses(allocator, request, callbacks, use_referrer_headers);
        }

        std.log.err("openai legacy completions request failed: status={s} body={s}", .{ @tagName(response.head.status), error_body });
        setLastProviderErrorDetail(response.head.status, error_body);
        return error.ProviderRequestFailed;
    }

    try streamSseResponse(allocator, &response, callbacks, extractOpenAiTokenAlloc);
}

fn streamOpenAiResponses(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
    use_referrer_headers: bool,
) !void {
    const base_url = request.base_url orelse defaultBaseUrl(request.provider_id) orelse return error.MissingProviderBaseUrl;

    const endpoint = try joinUrl(allocator, base_url, "/responses");
    defer allocator.free(endpoint);

    const payload = try buildOpenAiResponsesPayload(allocator, request);
    defer allocator.free(payload);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(auth_header);

    var extra_headers: [2]std.http.Header = .{
        .{ .name = "HTTP-Referer", .value = "https://opencode.ai/" },
        .{ .name = "X-Title", .value = "zig-ai" },
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .extra_headers = if (use_referrer_headers) extra_headers[0..] else &.{},
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };

    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        const error_body = readResponseBodyAlloc(allocator, &response) catch "";
        defer if (error_body.len > 0) allocator.free(error_body);
        std.log.err("openai responses request failed: status={s} body={s}", .{ @tagName(response.head.status), error_body });
        setLastProviderErrorDetail(response.head.status, error_body);
        return error.ProviderRequestFailed;
    }

    try streamSseResponse(allocator, &response, callbacks, extractOpenAiResponsesTokenAlloc);
}

fn streamAnthropic(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
) !void {
    const base_url = request.base_url orelse defaultBaseUrl("anthropic") orelse return error.MissingProviderBaseUrl;
    const endpoint = try joinUrl(allocator, base_url, "/messages");
    defer allocator.free(endpoint);

    const payload = try buildAnthropicPayload(allocator, request);
    defer allocator.free(payload);

    var extra_headers: [3]std.http.Header = .{
        .{ .name = "x-api-key", .value = request.api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .extra_headers = extra_headers[0..],
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };

    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        const error_body = readResponseBodyAlloc(allocator, &response) catch "";
        defer if (error_body.len > 0) allocator.free(error_body);
        std.log.err("anthropic request failed: status={s} body={s}", .{ @tagName(response.head.status), error_body });
        setLastProviderErrorDetail(response.head.status, error_body);
        return error.ProviderRequestFailed;
    }

    try streamSseResponse(allocator, &response, callbacks, extractAnthropicTokenAlloc);
}

fn streamGoogle(
    allocator: std.mem.Allocator,
    request: StreamRequest,
    callbacks: StreamCallbacks,
) !void {
    const base_url = request.base_url orelse defaultBaseUrl("google") orelse return error.MissingProviderBaseUrl;

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ trimTrailingSlash(base_url), request.model_id, request.api_key },
    );
    defer allocator.free(endpoint);

    const payload = try buildGooglePayload(allocator, request);
    defer allocator.free(payload);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };

    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        const error_body = readResponseBodyAlloc(allocator, &response) catch "";
        defer if (error_body.len > 0) allocator.free(error_body);
        std.log.err("google request failed: status={s} body={s}", .{ @tagName(response.head.status), error_body });
        setLastProviderErrorDetail(response.head.status, error_body);
        return error.ProviderRequestFailed;
    }

    try streamSseResponse(allocator, &response, callbacks, extractGoogleTokenAlloc);
}

fn streamSseResponse(
    allocator: std.mem.Allocator,
    response: *std.http.Client.Response,
    callbacks: StreamCallbacks,
    comptime extract_token: fn (std.mem.Allocator, []const u8) anyerror!?[]u8,
) !void {
    var transfer_buffer: [256 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [DECOMPRESS_BUFFER_SIZE]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    while (true) {
        const maybe_line = try reader.takeDelimiter('\n');
        if (maybe_line == null) break;

        const raw_line = maybe_line.?;
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line[0] == ':') continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;

        const data_text = std.mem.trimLeft(u8, line["data:".len..], " ");
        if (data_text.len == 0) continue;
        if (std.mem.eql(u8, data_text, "[DONE]")) break;

        const maybe_token = try extract_token(allocator, data_text);
        if (maybe_token) |token| {
            defer allocator.free(token);
            if (token.len > 0) {
                try callbacks.on_token(callbacks.context, token);
            }
        }
    }
}

fn readResponseBodyAlloc(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [DECOMPRESS_BUFFER_SIZE]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };

    return body_writer.toOwnedSlice();
}

fn setLastProviderErrorDetail(status: std.http.Status, body: []const u8) void {
    var sanitized: [220]u8 = undefined;
    const body_preview = sanitizeErrorPreview(body, &sanitized);
    const detail = std.fmt.bufPrint(
        &last_error_buffer,
        "status={s} body={s}",
        .{ @tagName(status), body_preview },
    ) catch "provider request failed";
    last_error_len = detail.len;
}

fn sanitizeErrorPreview(input: []const u8, out: []u8) []const u8 {
    if (out.len == 0) return "";
    var written: usize = 0;
    for (input) |ch| {
        if (written >= out.len) break;
        out[written] = if (std.ascii.isPrint(ch) and ch != '\n' and ch != '\r' and ch != '\t') ch else ' ';
        written += 1;
    }
    return std.mem.trim(u8, out[0..written], " ");
}

fn shouldRetryWithLegacyCompletions(status: std.http.Status, error_body: []const u8) bool {
    if (status != .not_found and status != .bad_request) return false;
    return containsAsciiIgnoreCase(error_body, "not a chat model") and
        containsAsciiIgnoreCase(error_body, "v1/completions");
}

fn shouldRetryWithResponsesEndpoint(status: std.http.Status, error_body: []const u8) bool {
    if (status != .not_found and status != .bad_request) return false;
    return containsAsciiIgnoreCase(error_body, "not supported in the v1/completions endpoint");
}

fn buildOpenAiPayload(allocator: std.mem.Allocator, request: StreamRequest) ![]u8 {
    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(request.model_id);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("messages");
    try jw.beginArray();

    for (request.messages) |message| {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(openAiRole(message.role));
        try jw.objectField("content");
        try jw.write(message.content);
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    return payload_writer.toOwnedSlice();
}

fn buildOpenAiLegacyCompletionsPayload(allocator: std.mem.Allocator, request: StreamRequest) ![]u8 {
    const prompt = try buildLegacyPromptFromMessages(allocator, request.messages);
    defer allocator.free(prompt);

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(request.model_id);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("prompt");
    try jw.write(prompt);
    try jw.endObject();

    return payload_writer.toOwnedSlice();
}

fn buildOpenAiResponsesPayload(allocator: std.mem.Allocator, request: StreamRequest) ![]u8 {
    const prompt = try buildLegacyPromptFromMessages(allocator, request.messages);
    defer allocator.free(prompt);

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(request.model_id);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("input");
    try jw.write(prompt);
    try jw.endObject();

    return payload_writer.toOwnedSlice();
}

fn buildLegacyPromptFromMessages(allocator: std.mem.Allocator, messages: []const StreamMessage) ![]u8 {
    var prompt_writer: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_writer.deinit();

    for (messages) |message| {
        if (message.content.len == 0) continue;
        try prompt_writer.writer.print("{s}: {s}\n\n", .{ openAiRole(message.role), message.content });
    }
    try prompt_writer.writer.writeAll("assistant: ");
    return prompt_writer.toOwnedSlice();
}

fn buildAnthropicPayload(allocator: std.mem.Allocator, request: StreamRequest) ![]u8 {
    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var system_prompt: std.ArrayList(u8) = .empty;
    defer system_prompt.deinit(allocator);

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(request.model_id);
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("max_tokens");
    try jw.write(@as(u32, 4096));

    for (request.messages) |message| {
        if (message.role != .system) continue;
        if (system_prompt.items.len > 0) {
            try system_prompt.appendSlice(allocator, "\n\n");
        }
        try system_prompt.appendSlice(allocator, message.content);
    }

    if (system_prompt.items.len > 0) {
        try jw.objectField("system");
        try jw.write(system_prompt.items);
    }

    try jw.objectField("messages");
    try jw.beginArray();

    for (request.messages) |message| {
        if (message.role == .system) continue;

        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(anthropicRole(message.role));
        try jw.objectField("content");
        try jw.write(message.content);
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    return payload_writer.toOwnedSlice();
}

fn buildGooglePayload(allocator: std.mem.Allocator, request: StreamRequest) ![]u8 {
    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    var system_prompt: std.ArrayList(u8) = .empty;
    defer system_prompt.deinit(allocator);

    var jw: std.json.Stringify = .{
        .writer = &payload_writer.writer,
    };

    try jw.beginObject();

    for (request.messages) |message| {
        if (message.role != .system) continue;
        if (system_prompt.items.len > 0) {
            try system_prompt.appendSlice(allocator, "\n\n");
        }
        try system_prompt.appendSlice(allocator, message.content);
    }

    if (system_prompt.items.len > 0) {
        try jw.objectField("system_instruction");
        try jw.beginObject();
        try jw.objectField("parts");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(system_prompt.items);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
    }

    try jw.objectField("contents");
    try jw.beginArray();

    for (request.messages) |message| {
        if (message.role == .system) continue;

        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(googleRole(message.role));
        try jw.objectField("parts");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(message.content);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    return payload_writer.toOwnedSlice();
}

fn extractOpenAiTokenAlloc(allocator: std.mem.Allocator, data_text: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data_text, .{});
    defer parsed.deinit();

    const choices = objectField(parsed.value, "choices") orelse return null;
    const first_choice = firstArrayItem(choices) orelse return null;

    if (objectField(first_choice, "delta")) |delta| {
        if (objectField(delta, "content")) |content| {
            const text = asString(content) orelse return null;
            return @as(?[]u8, try allocator.dupe(u8, text));
        }
    }

    if (objectField(first_choice, "text")) |text_value| {
        const text = asString(text_value) orelse return null;
        return @as(?[]u8, try allocator.dupe(u8, text));
    }

    return null;
}

fn extractAnthropicTokenAlloc(allocator: std.mem.Allocator, data_text: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data_text, .{});
    defer parsed.deinit();

    const event_type = objectField(parsed.value, "type") orelse return null;
    const event_type_text = asString(event_type) orelse return null;
    if (!std.mem.eql(u8, event_type_text, "content_block_delta")) return null;

    const delta = objectField(parsed.value, "delta") orelse return null;
    const text_value = objectField(delta, "text") orelse return null;
    const text = asString(text_value) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, text));
}

fn extractGoogleTokenAlloc(allocator: std.mem.Allocator, data_text: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data_text, .{});
    defer parsed.deinit();

    const candidates = objectField(parsed.value, "candidates") orelse return null;
    const first_candidate = firstArrayItem(candidates) orelse return null;
    const content = objectField(first_candidate, "content") orelse return null;
    const parts = objectField(content, "parts") orelse return null;
    const first_part = firstArrayItem(parts) orelse return null;
    const text_value = objectField(first_part, "text") orelse return null;
    const text = asString(text_value) orelse return null;

    return @as(?[]u8, try allocator.dupe(u8, text));
}

fn extractOpenAiResponsesTokenAlloc(allocator: std.mem.Allocator, data_text: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data_text, .{});
    defer parsed.deinit();

    const event_type_value = objectField(parsed.value, "type") orelse return null;
    const event_type = asString(event_type_value) orelse return null;
    if (!std.mem.eql(u8, event_type, "response.output_text.delta")) return null;

    const delta_value = objectField(parsed.value, "delta") orelse return null;
    const delta = asString(delta_value) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, delta));
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn firstArrayItem(value: std.json.Value) ?std.json.Value {
    return switch (value) {
        .array => |array| if (array.items.len > 0) array.items[0] else null,
        else => null,
    };
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .number_string => |text| text,
        else => null,
    };
}

fn defaultBaseUrl(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider_id, "opencode")) return "https://opencode.ai/zen/v1";
    if (std.mem.eql(u8, provider_id, "zenmux")) return "https://zenmux.ai/api/v1";
    if (std.mem.eql(u8, provider_id, "anthropic")) return "https://api.anthropic.com/v1";
    if (std.mem.eql(u8, provider_id, "google")) return "https://generativelanguage.googleapis.com/v1beta";
    return null;
}

fn isOpenAiCompatibleProvider(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") or
        std.mem.eql(u8, provider_id, "openrouter") or
        std.mem.eql(u8, provider_id, "opencode") or
        std.mem.eql(u8, provider_id, "zenmux");
}

fn openAiRole(role: Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
    };
}

fn anthropicRole(role: Role) []const u8 {
    return switch (role) {
        .assistant => "assistant",
        .user, .system => "user",
    };
}

fn googleRole(role: Role) []const u8 {
    return switch (role) {
        .assistant => "model",
        .user, .system => "user",
    };
}

fn trimTrailingSlash(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    if (text[text.len - 1] == '/') return text[0 .. text.len - 1];
    return text;
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    const base = trimTrailingSlash(base_url);
    if (suffix.len == 0) return allocator.dupe(u8, base);

    if (suffix[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
    }

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, suffix });
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }

    return false;
}

test "extractOpenAiTokenAlloc parses delta content" {
    const allocator = std.testing.allocator;

    const line =
        "{\"choices\":[{\"delta\":{\"content\":\"hello\"},\"index\":0}],\"id\":\"x\"}";

    const token = try extractOpenAiTokenAlloc(allocator, line);
    defer if (token) |t| allocator.free(t);

    try std.testing.expect(token != null);
    try std.testing.expect(std.mem.eql(u8, token.?, "hello"));
}

test "extractAnthropicTokenAlloc parses content_block_delta" {
    const allocator = std.testing.allocator;

    const line =
        "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";

    const token = try extractAnthropicTokenAlloc(allocator, line);
    defer if (token) |t| allocator.free(t);

    try std.testing.expect(token != null);
    try std.testing.expect(std.mem.eql(u8, token.?, "world"));
}

test "extractGoogleTokenAlloc parses candidates parts text" {
    const allocator = std.testing.allocator;

    const line =
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini\"}]}}]}";

    const token = try extractGoogleTokenAlloc(allocator, line);
    defer if (token) |t| allocator.free(t);

    try std.testing.expect(token != null);
    try std.testing.expect(std.mem.eql(u8, token.?, "gemini"));
}

test "extractOpenAiResponsesTokenAlloc parses output_text delta" {
    const allocator = std.testing.allocator;

    const line =
        "{\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}";

    const token = try extractOpenAiResponsesTokenAlloc(allocator, line);
    defer if (token) |t| allocator.free(t);

    try std.testing.expect(token != null);
    try std.testing.expect(std.mem.eql(u8, token.?, "Hello"));
}

test "shouldRetryWithLegacyCompletions detects non-chat model errors" {
    try std.testing.expect(shouldRetryWithLegacyCompletions(
        .not_found,
        "{\"error\":{\"message\":\"This is not a chat model and thus not supported in the v1/chat/completions endpoint. Did you mean to use v1/completions?\"}}",
    ));
    try std.testing.expect(!shouldRetryWithLegacyCompletions(.unauthorized, "not a chat model"));
    try std.testing.expect(!shouldRetryWithLegacyCompletions(.not_found, "other error"));
}

test "shouldRetryWithResponsesEndpoint detects legacy completions incompatibility" {
    try std.testing.expect(shouldRetryWithResponsesEndpoint(
        .not_found,
        "{\"error\":{\"message\":\"This model is not supported in the v1/completions endpoint.\"}}",
    ));
    try std.testing.expect(!shouldRetryWithResponsesEndpoint(.unauthorized, "v1/completions endpoint"));
    try std.testing.expect(!shouldRetryWithResponsesEndpoint(.not_found, "other error"));
}

test "buildOpenAiLegacyCompletionsPayload includes prompt transcript" {
    const allocator = std.testing.allocator;

    const messages = [_]StreamMessage{
        .{ .role = .system, .content = "be concise" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "hello" },
    };

    const request: StreamRequest = .{
        .provider_id = "openai",
        .model_id = "gpt-5.2-codex",
        .api_key = "test",
        .base_url = null,
        .messages = messages[0..],
    };

    const payload = try buildOpenAiLegacyCompletionsPayload(allocator, request);
    defer allocator.free(payload);

    try std.testing.expect(containsAsciiIgnoreCase(payload, "\"prompt\""));
    try std.testing.expect(containsAsciiIgnoreCase(payload, "system: be concise"));
    try std.testing.expect(containsAsciiIgnoreCase(payload, "user: hi"));
    try std.testing.expect(containsAsciiIgnoreCase(payload, "assistant: "));
}

test "buildOpenAiResponsesPayload includes input transcript" {
    const allocator = std.testing.allocator;

    const messages = [_]StreamMessage{
        .{ .role = .system, .content = "be concise" },
        .{ .role = .user, .content = "hi" },
    };

    const request: StreamRequest = .{
        .provider_id = "openai",
        .model_id = "gpt-5.2-codex",
        .api_key = "test",
        .base_url = null,
        .messages = messages[0..],
    };

    const payload = try buildOpenAiResponsesPayload(allocator, request);
    defer allocator.free(payload);

    try std.testing.expect(containsAsciiIgnoreCase(payload, "\"input\""));
    try std.testing.expect(containsAsciiIgnoreCase(payload, "system: be concise"));
    try std.testing.expect(containsAsciiIgnoreCase(payload, "user: hi"));
}
