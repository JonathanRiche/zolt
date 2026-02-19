//! WEB_SEARCH tool runner.

const std = @import("std");
const common = @import("common.zig");

const WebSearchEngine = enum {
    duckduckgo,
    exa,
};

const WebSearchInput = struct {
    query: []u8,
    limit: u8 = common.WEB_SEARCH_DEFAULT_RESULTS,
    engine: WebSearchEngine = .duckduckgo,
};

const WebSearchResultItem = struct {
    title: []u8,
    url: []u8,

    fn deinit(self: *WebSearchResultItem, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
    }
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    const input = parseWebSearchInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[web-search-result]\nerror: invalid payload (expected plain query text or JSON with query and optional limit/engine)");
    };
    defer app.allocator.free(input.query);

    if (input.query.len == 0) {
        return app.allocator.dupe(u8, "[web-search-result]\nerror: empty query");
    }

    const results = switch (input.engine) {
        .duckduckgo => runDuckDuckGoWebSearch(app.allocator, input.query, input.limit) catch |err| {
            return std.fmt.allocPrint(
                app.allocator,
                "[web-search-result]\nengine: {s}\nquery: {s}\nerror: {s}",
                .{ webSearchEngineLabel(input.engine), input.query, @errorName(err) },
            );
        },
        .exa => runExaWebSearch(app.allocator, input.query, input.limit) catch |err| {
            return switch (err) {
                error.EnvironmentVariableNotFound => std.fmt.allocPrint(
                    app.allocator,
                    "[web-search-result]\nengine: exa\nquery: {s}\nerror: missing EXA_API_KEY",
                    .{input.query},
                ),
                else => std.fmt.allocPrint(
                    app.allocator,
                    "[web-search-result]\nengine: exa\nquery: {s}\nerror: {s}",
                    .{ input.query, @errorName(err) },
                ),
            };
        },
    };
    defer {
        for (results) |*item| item.deinit(app.allocator);
        app.allocator.free(results);
    }

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print(
        "[web-search-result]\nengine: {s}\nquery: {s}\nresults: {d}\n",
        .{ webSearchEngineLabel(input.engine), input.query, results.len },
    );

    for (results, 0..) |item, index| {
        try output.writer.print("{d}. {s}\n", .{ index + 1, item.title });
        try output.writer.print("   url: {s}\n", .{item.url});
    }

    if (results.len == 0) {
        try output.writer.writeAll("note: no results found\n");
    }

    return output.toOwnedSlice();
}

fn parseWebSearchInput(allocator: std.mem.Allocator, payload: []const u8) !WebSearchInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .query = try allocator.dupe(u8, trimmed), .limit = common.WEB_SEARCH_DEFAULT_RESULTS, .engine = .duckduckgo };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("q") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const limit = common.sanitizeWebSearchLimit(common.jsonFieldU32(object, "limit") orelse common.jsonFieldU32(object, "count") orelse common.jsonFieldU32(object, "max_results") orelse common.WEB_SEARCH_DEFAULT_RESULTS);

    const engine: WebSearchEngine = blk: {
        const engine_value = object.get("engine") orelse object.get("provider") orelse break :blk .duckduckgo;
        const engine_name = switch (engine_value) {
            .string => |text| text,
            else => return error.InvalidToolPayload,
        };
        break :blk parseWebSearchEngineName(engine_name) orelse return error.InvalidToolPayload;
    };

    return .{ .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")), .limit = limit, .engine = engine };
}

fn parseWebSearchEngineName(input: []const u8) ?WebSearchEngine {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "duckduckgo") or std.ascii.eqlIgnoreCase(trimmed, "ddg")) return .duckduckgo;
    if (std.ascii.eqlIgnoreCase(trimmed, "exa")) return .exa;
    return null;
}

fn webSearchEngineLabel(engine: WebSearchEngine) []const u8 {
    return switch (engine) {
        .duckduckgo => "duckduckgo",
        .exa => "exa",
    };
}

fn runDuckDuckGoWebSearch(allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]WebSearchResultItem {
    var encoded_query_writer: std.Io.Writer.Allocating = .init(allocator);
    defer encoded_query_writer.deinit();
    try (std.Uri.Component{ .raw = query }).formatQuery(&encoded_query_writer.writer);
    const encoded_query = try encoded_query_writer.toOwnedSlice();
    defer allocator.free(encoded_query);

    const endpoint = try std.fmt.allocPrint(allocator, "https://duckduckgo.com/html/?q={s}&kl=us-en", .{encoded_query});
    defer allocator.free(endpoint);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const fetch_result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "Zolt/0.1" } },
        .response_writer = &response_writer.writer,
        .keep_alive = false,
    });
    if (fetch_result.status != .ok) return error.WebSearchHttpStatus;

    const html_body = try response_writer.toOwnedSlice();
    defer allocator.free(html_body);
    if (html_body.len == 0) return error.EmptyResponseBody;
    if (html_body.len > common.WEB_SEARCH_MAX_RESPONSE_BYTES) return error.ResponseTooLarge;

    return parseDuckDuckGoHtmlResults(allocator, html_body, limit);
}

fn runExaWebSearch(allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]WebSearchResultItem {
    const exa_api_key = try std.process.getEnvVarOwned(allocator, "EXA_API_KEY");
    defer allocator.free(exa_api_key);

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();
    var jw: std.json.Stringify = .{ .writer = &payload_writer.writer };
    try jw.beginObject();
    try jw.objectField("query");
    try jw.write(query);
    try jw.objectField("numResults");
    try jw.write(limit);
    try jw.endObject();
    const payload = try payload_writer.toOwnedSlice();
    defer allocator.free(payload);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var extra_headers: [1]std.http.Header = .{.{ .name = "x-api-key", .value = exa_api_key }};

    const uri = try std.Uri.parse("https://api.exa.ai/search");
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "Zolt/0.1" },
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
    if (response.head.status != .ok) return error.WebSearchHttpStatus;

    const json_body = try common.readHttpResponseBodyAlloc(allocator, &response);
    defer allocator.free(json_body);
    if (json_body.len == 0) return error.EmptyResponseBody;
    if (json_body.len > common.WEB_SEARCH_MAX_RESPONSE_BYTES) return error.ResponseTooLarge;

    return parseExaJsonResults(allocator, json_body, limit);
}

fn parseDuckDuckGoHtmlResults(allocator: std.mem.Allocator, html: []const u8, limit: u8) ![]WebSearchResultItem {
    var results: std.ArrayList(WebSearchResultItem) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit(allocator);
    }

    var cursor: usize = 0;
    while (results.items.len < @as(usize, limit)) {
        const marker = std.mem.indexOfPos(u8, html, cursor, "result__a") orelse break;
        const tag_start = std.mem.lastIndexOfScalar(u8, html[0..marker], '<') orelse {
            cursor = marker + "result__a".len;
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, html, marker, '>') orelse break;
        if (tag_start + 2 > tag_end or html[tag_start + 1] != 'a') {
            cursor = marker + "result__a".len;
            continue;
        }

        const close_anchor = std.mem.indexOfPos(u8, html, tag_end + 1, "</a>") orelse break;
        const tag = html[tag_start .. tag_end + 1];
        const href_raw = extractAnchorHref(tag) orelse {
            cursor = close_anchor + "</a>".len;
            continue;
        };

        const title_raw = html[tag_end + 1 .. close_anchor];
        const title = try stripHtmlTagsAndDecodeAlloc(allocator, title_raw);
        errdefer allocator.free(title);
        if (title.len == 0) {
            allocator.free(title);
            cursor = close_anchor + "</a>".len;
            continue;
        }

        const href_decoded = try decodeHtmlEntitiesAlloc(allocator, href_raw);
        defer allocator.free(href_decoded);
        const normalized_url = try normalizeSearchResultUrlAlloc(allocator, href_decoded);

        try results.append(allocator, .{ .title = title, .url = normalized_url });

        cursor = close_anchor + "</a>".len;
    }

    return results.toOwnedSlice(allocator);
}

fn parseExaJsonResults(allocator: std.mem.Allocator, payload: []const u8, limit: u8) ![]WebSearchResultItem {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidWebSearchResponse,
    };

    const results_value = root.get("results") orelse return error.InvalidWebSearchResponse;
    const results_array = switch (results_value) {
        .array => |array| array,
        else => return error.InvalidWebSearchResponse,
    };

    var out: std.ArrayList(WebSearchResultItem) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (results_array.items) |entry| {
        if (out.items.len >= @as(usize, limit)) break;
        const entry_object = switch (entry) {
            .object => |object| object,
            else => continue,
        };

        const url = if (entry_object.get("url")) |value| switch (value) {
            .string => |text| std.mem.trim(u8, text, " \t\r\n"),
            else => "",
        } else "";
        if (url.len == 0) continue;

        const title_raw = if (entry_object.get("title")) |value| switch (value) {
            .string => |text| std.mem.trim(u8, text, " \t\r\n"),
            else => "",
        } else "";
        const title = if (title_raw.len == 0) url else title_raw;

        try out.append(allocator, .{ .title = try allocator.dupe(u8, title), .url = try allocator.dupe(u8, url) });
    }

    return out.toOwnedSlice(allocator);
}

fn extractAnchorHref(anchor_tag: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, anchor_tag, "href=\"")) |href_start| {
        const start = href_start + "href=\"".len;
        const end = std.mem.indexOfScalarPos(u8, anchor_tag, start, '"') orelse return null;
        return anchor_tag[start..end];
    }
    if (std.mem.indexOf(u8, anchor_tag, "href='")) |href_start| {
        const start = href_start + "href='".len;
        const end = std.mem.indexOfScalarPos(u8, anchor_tag, start, '\'') orelse return null;
        return anchor_tag[start..end];
    }
    return null;
}

fn stripHtmlTagsAndDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var stripped_writer: std.Io.Writer.Allocating = .init(allocator);
    defer stripped_writer.deinit();

    var in_tag = false;
    for (text) |byte| {
        if (byte == '<') {
            in_tag = true;
            continue;
        }
        if (byte == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try stripped_writer.writer.writeByte(byte);
    }

    const stripped = try stripped_writer.toOwnedSlice();
    defer allocator.free(stripped);
    return decodeHtmlEntitiesAlloc(allocator, std.mem.trim(u8, stripped, " \t\r\n"));
}

fn decodeHtmlEntitiesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const tail = text[i..];
            if (std.mem.startsWith(u8, tail, "&amp;")) {
                try out.writer.writeByte('&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&lt;")) {
                try out.writer.writeByte('<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&gt;")) {
                try out.writer.writeByte('>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&quot;")) {
                try out.writer.writeByte('"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&#39;")) {
                try out.writer.writeByte('\'');
                i += 5;
                continue;
            }
        }

        try out.writer.writeByte(text[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn normalizeSearchResultUrlAlloc(allocator: std.mem.Allocator, href: []const u8) ![]u8 {
    if (try decodeDuckDuckGoRedirectUrlAlloc(allocator, href)) |decoded_target| {
        return decoded_target;
    }

    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(allocator, "https:{s}", .{href});
    }

    return allocator.dupe(u8, href);
}

fn decodeDuckDuckGoRedirectUrlAlloc(allocator: std.mem.Allocator, href: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, href, "duckduckgo.com/l/?") == null) return null;

    const param_index = std.mem.indexOf(u8, href, "uddg=") orelse return null;
    const value_start = param_index + "uddg=".len;
    const remaining = href[value_start..];
    const value_end = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
    const encoded_target = remaining[0..value_end];

    const decoded_buffer = try allocator.dupe(u8, encoded_target);
    defer allocator.free(decoded_buffer);
    const decoded = std.Uri.percentDecodeInPlace(decoded_buffer);
    return @as(?[]u8, try allocator.dupe(u8, decoded));
}
