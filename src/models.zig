//! models.dev cache and provider/model catalog extraction.
//!
//! Usage:
//!   - Call `loadOrRefresh(allocator, cache_path)` to read the cached catalog or
//!     fetch from models.dev if missing.
//!   - Use `catalog.findProviderConst("openai")` to access providers.
//!   - Use `catalog.hasModel("openai", "gpt-4.1")` to check availability.
//!   - Remember to `catalog.deinit(allocator)` when done.

const std = @import("std");

pub const MODELS_DEV_API_URL = "https://models.dev/api.json";

pub const ModelInfo = struct {
    id: []u8,
    name: []u8,
    context_window: ?i64 = null,

    pub fn deinit(self: *ModelInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

pub const ProviderInfo = struct {
    id: []u8,
    name: []u8,
    api_base: ?[]u8,
    env_vars: std.ArrayList([]u8) = .empty,
    models: std.ArrayList(ModelInfo) = .empty,

    pub fn deinit(self: *ProviderInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.api_base) |api_base| allocator.free(api_base);

        for (self.env_vars.items) |env_var| {
            allocator.free(env_var);
        }
        self.env_vars.deinit(allocator);

        for (self.models.items) |*model| {
            model.deinit(allocator);
        }
        self.models.deinit(allocator);
    }
};

pub const Catalog = struct {
    providers: std.ArrayList(ProviderInfo) = .empty,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.providers.items) |*provider| {
            provider.deinit(allocator);
        }
        self.providers.deinit(allocator);
    }

    pub fn findProviderConst(self: *const Catalog, provider_id: []const u8) ?*const ProviderInfo {
        for (self.providers.items) |*provider| {
            if (std.mem.eql(u8, provider.id, provider_id)) return provider;
        }
        return null;
    }

    pub fn findProvider(self: *Catalog, provider_id: []const u8) ?*ProviderInfo {
        for (self.providers.items) |*provider| {
            if (std.mem.eql(u8, provider.id, provider_id)) return provider;
        }
        return null;
    }

    pub fn hasModel(self: *const Catalog, provider_id: []const u8, model_id: []const u8) bool {
        const provider = self.findProviderConst(provider_id) orelse return false;
        for (provider.models.items) |model| {
            if (std.mem.eql(u8, model.id, model_id)) return true;
        }
        return false;
    }
};

pub const LoadResult = struct {
    catalog: Catalog,
    loaded_from_cache: bool,
};

pub fn loadFromPath(allocator: std.mem.Allocator, cache_path: []const u8) !Catalog {
    var file = try openFileForPath(cache_path, .{});
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buffer);

    var content_writer: std.Io.Writer.Allocating = .init(allocator);
    defer content_writer.deinit();

    _ = try file_reader.interface.streamRemaining(&content_writer.writer);
    const content = try content_writer.toOwnedSlice();
    defer allocator.free(content);

    return parseCatalogFromJson(allocator, content);
}

pub fn loadOrRefresh(allocator: std.mem.Allocator, cache_path: []const u8) !LoadResult {
    const cached = loadFromPath(allocator, cache_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (cached) |catalog| {
        return .{
            .catalog = catalog,
            .loaded_from_cache = true,
        };
    }

    try refreshToPath(allocator, cache_path);

    return .{
        .catalog = try loadFromPath(allocator, cache_path),
        .loaded_from_cache = false,
    };
}

pub fn refreshToPath(allocator: std.mem.Allocator, cache_path: []const u8) !void {
    if (std.fs.path.dirname(cache_path)) |dirname| {
        try std.fs.cwd().makePath(dirname);
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = MODELS_DEV_API_URL },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "zig-ai/0.1" },
        },
        .response_writer = &response_writer.writer,
    });

    if (result.status != .ok) {
        return error.UnexpectedHttpStatus;
    }

    const payload = try response_writer.toOwnedSlice();
    defer allocator.free(payload);

    var file = try createFileForPath(cache_path, .{ .truncate = true });
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    defer file_writer.interface.flush() catch {};

    try file_writer.interface.writeAll(payload);
}

pub fn parseCatalogFromJson(allocator: std.mem.Allocator, json_text: []const u8) !Catalog {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    var catalog: Catalog = .{};
    errdefer catalog.deinit(allocator);

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidModelsJson,
    };

    var provider_iter = root.iterator();
    while (provider_iter.next()) |provider_entry| {
        const provider_value = provider_entry.value_ptr.*;

        const provider_object = switch (provider_value) {
            .object => |object| object,
            else => continue,
        };

        const provider_id = jsonFieldString(provider_object, "id") orelse provider_entry.key_ptr.*;
        const provider_name = jsonFieldString(provider_object, "name") orelse provider_id;

        var provider: ProviderInfo = .{
            .id = try allocator.dupe(u8, provider_id),
            .name = try allocator.dupe(u8, provider_name),
            .api_base = null,
        };
        errdefer provider.deinit(allocator);

        if (jsonFieldString(provider_object, "api")) |api_base| {
            provider.api_base = try allocator.dupe(u8, api_base);
        }

        if (provider_object.get("env")) |env_value| {
            switch (env_value) {
                .array => |env_array| {
                    for (env_array.items) |entry| {
                        switch (entry) {
                            .string => |env_var| try provider.env_vars.append(allocator, try allocator.dupe(u8, env_var)),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (provider_object.get("models")) |models_value| {
            switch (models_value) {
                .object => |models_object| {
                    var model_iter = models_object.iterator();
                    while (model_iter.next()) |model_entry| {
                        const model_value = model_entry.value_ptr.*;
                        const model_object = switch (model_value) {
                            .object => |object| object,
                            else => continue,
                        };

                        const model_id = jsonFieldString(model_object, "id") orelse model_entry.key_ptr.*;
                        const model_name = jsonFieldString(model_object, "name") orelse model_id;
                        const context_window = jsonModelContextWindow(model_object);

                        const model: ModelInfo = .{
                            .id = try allocator.dupe(u8, model_id),
                            .name = try allocator.dupe(u8, model_name),
                            .context_window = context_window,
                        };
                        try provider.models.append(allocator, model);
                    }
                },
                else => {},
            }
        }

        std.sort.pdq(ModelInfo, provider.models.items, {}, modelLessThan);
        try catalog.providers.append(allocator, provider);
    }

    std.sort.pdq(ProviderInfo, catalog.providers.items, {}, providerLessThan);
    return catalog;
}

fn jsonFieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonFieldI64(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @as(i64, @intFromFloat(number)),
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn jsonModelContextWindow(object: std.json.ObjectMap) ?i64 {
    const limit_value = object.get("limit") orelse return null;
    const limit_object = switch (limit_value) {
        .object => |obj| obj,
        else => return null,
    };
    return jsonFieldI64(limit_object, "context");
}

fn providerLessThan(_: void, left: ProviderInfo, right: ProviderInfo) bool {
    return std.mem.lessThan(u8, left.id, right.id);
}

fn modelLessThan(_: void, left: ModelInfo, right: ModelInfo) bool {
    const left_latest = containsAsciiIgnoreCase(left.id, "latest");
    const right_latest = containsAsciiIgnoreCase(right.id, "latest");
    if (left_latest != right_latest) return left_latest;

    const left_date_score = modelDateScore(left.id);
    const right_date_score = modelDateScore(right.id);
    if (left_date_score != right_date_score) return left_date_score > right_date_score;

    const left_version_score = modelVersionScore(left.id);
    const right_version_score = modelVersionScore(right.id);
    if (left_version_score != right_version_score) return left_version_score > right_version_score;

    const left_priority = modelPriorityBucket(left.id);
    const right_priority = modelPriorityBucket(right.id);
    if (left_priority != right_priority) return left_priority < right_priority;

    // Fall back to descending lexical order so newer suffixes like 5.3 sort above 5.2.
    return std.mem.lessThan(u8, right.id, left.id);
}

fn modelDateScore(model_id: []const u8) u32 {
    var best: u32 = 0;
    var i: usize = 0;
    while (i < model_id.len) : (i += 1) {
        if (!std.ascii.isDigit(model_id[i])) continue;

        if (i + 10 <= model_id.len and std.ascii.isDigit(model_id[i + 0]) and std.ascii.isDigit(model_id[i + 1]) and std.ascii.isDigit(model_id[i + 2]) and std.ascii.isDigit(model_id[i + 3]) and model_id[i + 4] == '-' and std.ascii.isDigit(model_id[i + 5]) and std.ascii.isDigit(model_id[i + 6]) and model_id[i + 7] == '-' and std.ascii.isDigit(model_id[i + 8]) and std.ascii.isDigit(model_id[i + 9])) {
            const year = parseDecU16(model_id[i .. i + 4]);
            const month = parseDecU8(model_id[i + 5 .. i + 7]);
            const day = parseDecU8(model_id[i + 8 .. i + 10]);
            const score = packDate(year, month, day);
            if (score > best) best = score;
        }

        if (i + 8 <= model_id.len and std.ascii.isDigit(model_id[i + 0]) and std.ascii.isDigit(model_id[i + 1]) and std.ascii.isDigit(model_id[i + 2]) and std.ascii.isDigit(model_id[i + 3]) and std.ascii.isDigit(model_id[i + 4]) and std.ascii.isDigit(model_id[i + 5]) and std.ascii.isDigit(model_id[i + 6]) and std.ascii.isDigit(model_id[i + 7])) {
            const year = parseDecU16(model_id[i .. i + 4]);
            const month = parseDecU8(model_id[i + 4 .. i + 6]);
            const day = parseDecU8(model_id[i + 6 .. i + 8]);
            const score = packDate(year, month, day);
            if (score > best) best = score;
        }
    }
    return best;
}

fn modelVersionScore(model_id: []const u8) u64 {
    var best: u64 = 0;
    var i: usize = 0;
    while (i < model_id.len) : (i += 1) {
        if (!std.ascii.isDigit(model_id[i])) continue;
        const major = parseDigitsClamped(model_id, &i);

        var minor: u64 = 0;
        var patch: u64 = 0;

        if (i < model_id.len and model_id[i] == '.' and i + 1 < model_id.len and std.ascii.isDigit(model_id[i + 1])) {
            i += 1;
            minor = parseDigitsClamped(model_id, &i);
            if (i < model_id.len and model_id[i] == '.' and i + 1 < model_id.len and std.ascii.isDigit(model_id[i + 1])) {
                i += 1;
                patch = parseDigitsClamped(model_id, &i);
            }
        }

        const score = major * 1_000_000 + minor * 1_000 + patch;
        if (score > best) best = score;
        if (i > 0) i -= 1;
    }
    return best;
}

fn parseDigitsClamped(text: []const u8, index: *usize) u64 {
    var value: u64 = 0;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {
        value = value * 10 + (text[index.*] - '0');
        if (value > 9_999) {
            while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {}
            return 9_999;
        }
    }
    return value;
}

fn parseDecU16(text: []const u8) u16 {
    var value: u16 = 0;
    for (text) |ch| {
        value = value * 10 + (ch - '0');
    }
    return value;
}

fn parseDecU8(text: []const u8) u8 {
    var value: u8 = 0;
    for (text) |ch| {
        value = value * 10 + (ch - '0');
    }
    return value;
}

fn packDate(year: u16, month: u8, day: u8) u32 {
    if (year < 2000 or year > 2100) return 0;
    if (month < 1 or month > 12) return 0;
    if (day < 1 or day > 31) return 0;
    return @as(u32, year) * 10_000 + @as(u32, month) * 100 + @as(u32, day);
}

fn modelPriorityBucket(model_id: []const u8) usize {
    const hints = [_][]const u8{
        "codex",
        "gpt-5",
        "claude-sonnet-4",
        "big-pickle",
        "gemini-3-pro",
    };

    for (hints, 0..) |hint, index| {
        if (containsAsciiIgnoreCase(model_id, hint)) return index;
    }
    return hints.len;
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

fn createFileForPath(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags);
    }
    return std.fs.cwd().openFile(path, flags);
}

test "parseCatalogFromJson extracts providers and models" {
    const allocator = std.testing.allocator;

    const sample_json =
        "{\"opencode\":{\"id\":\"opencode\",\"name\":\"OpenCode Zen\",\"api\":\"https://opencode.ai/zen/v1\",\"env\":[\"OPENCODE_API_KEY\"],\"models\":{\"claude-opus-4-1\":{\"id\":\"claude-opus-4-1\",\"name\":\"Claude Opus 4.1\"}}},\"openai\":{\"id\":\"openai\",\"name\":\"OpenAI\",\"env\":[\"OPENAI_API_KEY\"],\"models\":{\"gpt-4.1\":{\"id\":\"gpt-4.1\",\"name\":\"GPT-4.1\"}}}}";

    var catalog = try parseCatalogFromJson(allocator, sample_json);
    defer catalog.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), catalog.providers.items.len);

    const opencode = catalog.findProviderConst("opencode") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, opencode.name, "OpenCode Zen"));
    try std.testing.expect(std.mem.eql(u8, opencode.env_vars.items[0], "OPENCODE_API_KEY"));
    try std.testing.expect(catalog.hasModel("opencode", "claude-opus-4-1"));

    const openai = catalog.findProviderConst("openai") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, openai.env_vars.items[0], "OPENAI_API_KEY"));
    try std.testing.expect(catalog.hasModel("openai", "gpt-4.1"));
    try std.testing.expectEqual(@as(?i64, null), openai.models.items[0].context_window);
}

test "loadFromPath reads catalog file" {
    const allocator = std.testing.allocator;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const cache_path = try std.fs.path.join(allocator, &.{ abs_dir, "models.json" });
    defer allocator.free(cache_path);

    const sample_json =
        "{\"anthropic\":{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"env\":[\"ANTHROPIC_API_KEY\"],\"models\":{\"claude-opus-4-1\":{\"id\":\"claude-opus-4-1\",\"name\":\"Claude Opus 4.1\"}}}}";

    var file = try createFileForPath(cache_path, .{ .truncate = true });
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(sample_json);
    try writer.interface.flush();

    var catalog = try loadFromPath(allocator, cache_path);
    defer catalog.deinit(allocator);

    try std.testing.expect(catalog.hasModel("anthropic", "claude-opus-4-1"));
}

test "model ordering prioritizes latest and codex first" {
    const allocator = std.testing.allocator;

    const sample_json =
        "{\"openai\":{\"id\":\"openai\",\"name\":\"OpenAI\",\"models\":{" ++
        "\"gpt-4.1\":{\"id\":\"gpt-4.1\",\"name\":\"GPT-4.1\"}," ++
        "\"gpt-5\":{\"id\":\"gpt-5\",\"name\":\"GPT-5\"}," ++
        "\"gpt-5-codex-2024-11-10\":{\"id\":\"gpt-5-codex-2024-11-10\",\"name\":\"GPT-5 Codex 2024-11-10\"}," ++
        "\"gpt-5.2-codex\":{\"id\":\"gpt-5.2-codex\",\"name\":\"GPT-5.2 Codex\"}," ++
        "\"gpt-5-codex-2025-02-01\":{\"id\":\"gpt-5-codex-2025-02-01\",\"name\":\"GPT-5 Codex 2025-02-01\"}," ++
        "\"gpt-5-chat-latest\":{\"id\":\"gpt-5-chat-latest\",\"name\":\"GPT-5 Chat Latest\"}" ++
        "}}}";

    var catalog = try parseCatalogFromJson(allocator, sample_json);
    defer catalog.deinit(allocator);

    const provider = catalog.findProviderConst("openai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("gpt-5-chat-latest", provider.models.items[0].id);
    try std.testing.expectEqualStrings("gpt-5-codex-2025-02-01", provider.models.items[1].id);
    try std.testing.expectEqualStrings("gpt-5-codex-2024-11-10", provider.models.items[2].id);
}

test "parseCatalogFromJson extracts model context window" {
    const allocator = std.testing.allocator;

    const sample_json =
        "{\"openai\":{\"id\":\"openai\",\"name\":\"OpenAI\",\"models\":{" ++
        "\"gpt-5.2-codex\":{\"id\":\"gpt-5.2-codex\",\"name\":\"GPT-5.2 Codex\",\"limit\":{\"context\":225000}}" ++
        "}}}";

    var catalog = try parseCatalogFromJson(allocator, sample_json);
    defer catalog.deinit(allocator);

    const provider = catalog.findProviderConst("openai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 225000), provider.models.items[0].context_window.?);
}
