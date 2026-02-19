//! Shared helpers/constants for tool modules.

const std = @import("std");

pub const READ_TOOL_MAX_OUTPUT_BYTES: usize = 24 * 1024;
pub const APPLY_PATCH_TOOL_MAX_PATCH_BYTES: usize = 256 * 1024;
pub const APPLY_PATCH_PREVIEW_MAX_LINES: usize = 120;
pub const COMMAND_TOOL_DEFAULT_YIELD_MS: u32 = 700;
pub const WEB_SEARCH_DEFAULT_RESULTS: u8 = 5;
pub const WEB_SEARCH_MAX_RESULTS: u8 = 10;
pub const WEB_SEARCH_MAX_RESPONSE_BYTES: usize = 256 * 1024;
pub const IMAGE_TOOL_MAX_FILE_BYTES: usize = 64 * 1024 * 1024;

pub const ParsedRgLine = struct {
    path: []const u8,
    line: u32,
    col: u32,
    text: []const u8,
};

pub fn openDirForPath(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) return std.fs.openDirAbsolute(path, flags);
    return std.fs.cwd().openDir(path, flags);
}

pub fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, flags);
    return std.fs.cwd().openFile(path, flags);
}

pub fn dirEntryKindLabel(kind: std.fs.Dir.Entry.Kind) []const u8 {
    return switch (kind) {
        .directory => "dir",
        .file => "file",
        .sym_link => "link",
        .named_pipe => "pipe",
        .character_device => "char",
        .block_device => "block",
        .unix_domain_socket => "sock",
        else => "other",
    };
}

pub fn parseRgLine(line: []const u8) ?ParsedRgLine {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, line, first + 1, ':') orelse return null;
    const third = std.mem.indexOfScalarPos(u8, line, second + 1, ':') orelse return null;
    if (first == 0 or second <= first + 1 or third <= second + 1) return null;

    const line_no = std.fmt.parseInt(u32, line[first + 1 .. second], 10) catch return null;
    const col_no = std.fmt.parseInt(u32, line[second + 1 .. third], 10) catch return null;
    return .{ .path = line[0..first], .line = line_no, .col = col_no, .text = line[third + 1 ..] };
}

pub fn looksBinary(content: []const u8) bool {
    if (std.mem.indexOfScalar(u8, content, 0) != null) return true;
    if (content.len == 0) return false;

    const sample_len = @min(content.len, 1024);
    var control_count: usize = 0;
    for (content[0..sample_len]) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) control_count += 1;
    }
    return control_count * 10 > sample_len;
}

pub fn trimMatchingOuterQuotes(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    if (text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    if (text[0] == '\'' and text[text.len - 1] == '\'') return text[1 .. text.len - 1];
    return text;
}

pub fn jsonFieldU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else null,
        .float => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @as(u32, @intFromFloat(number)) else null,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch null,
        else => null,
    };
}

pub fn jsonFieldBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        .string => |text| blk: {
            if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on") or std.mem.eql(u8, text, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off") or std.mem.eql(u8, text, "0")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

pub fn sanitizeCommandYieldMs(limit: u32) u32 {
    if (limit == 0) return COMMAND_TOOL_DEFAULT_YIELD_MS;
    return @min(limit, @as(u32, 5000));
}

pub fn sanitizeListDirMaxEntries(limit: u32) u16 {
    if (limit == 0) return 200;
    return @as(u16, @intCast(@min(limit, @as(u32, 1000))));
}

pub fn sanitizeReadFileMaxBytes(limit: u32) u32 {
    if (limit == 0) return 12 * 1024;
    return @min(limit, @as(u32, 256 * 1024));
}

pub fn sanitizeGrepMatches(limit: u32) u16 {
    if (limit == 0) return 200;
    return @as(u16, @intCast(@min(limit, @as(u32, 2000))));
}

pub fn sanitizeProjectSearchMaxFiles(limit: u32) u8 {
    if (limit == 0) return 8;
    return @as(u8, @intCast(@min(limit, @as(u32, 24))));
}

pub fn sanitizeProjectSearchMatches(limit: u32) u16 {
    if (limit == 0) return 300;
    return @as(u16, @intCast(@min(limit, @as(u32, 5000))));
}

pub fn sanitizeWebSearchLimit(limit: u32) u8 {
    if (limit == 0) return WEB_SEARCH_DEFAULT_RESULTS;
    return @as(u8, @intCast(@min(limit, WEB_SEARCH_MAX_RESULTS)));
}

pub fn readHttpResponseBodyAlloc(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [64 * 1024]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };

    return body_writer.toOwnedSlice();
}

pub fn isOpenAiCompatibleProviderId(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") or
        std.mem.eql(u8, provider_id, "openrouter") or
        std.mem.eql(u8, provider_id, "opencode") or
        std.mem.eql(u8, provider_id, "zenmux");
}

pub fn defaultBaseUrlForProviderId(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider_id, "opencode")) return "https://opencode.ai/zen/v1";
    if (std.mem.eql(u8, provider_id, "zenmux")) return "https://zenmux.ai/api/v1";
    return null;
}
