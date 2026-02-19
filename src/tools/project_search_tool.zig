//! PROJECT_SEARCH tool runner.

const std = @import("std");
const common = @import("common.zig");

const ProjectSearchInput = struct {
    query: []u8,
    path: []u8,
    max_files: u8 = 8,
    max_matches: u16 = 300,

    fn deinit(self: *ProjectSearchInput, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.path);
    }
};

const ProjectSearchFileHit = struct {
    path: []u8,
    hits: u32 = 0,
    first_line: u32 = 0,
    first_col: u32 = 0,
    first_snippet: []u8,

    fn deinit(self: *ProjectSearchFileHit, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.first_snippet);
    }
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    var input = parseProjectSearchInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[project-search-result]\nerror: invalid payload (expected plain query or JSON with query/path/max_files/max_matches)");
    };
    defer input.deinit(app.allocator);

    if (input.query.len == 0) {
        return app.allocator.dupe(u8, "[project-search-result]\nerror: empty query");
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(app.allocator);
    try argv.appendSlice(app.allocator, &.{
        "rg",
        "--line-number",
        "--column",
        "--no-heading",
        "--color",
        "never",
        "--smart-case",
        "--max-count",
        "8",
    });
    try argv.append(app.allocator, input.query);
    try argv.append(app.allocator, input.path);

    const result = std.process.Child.run(.{
        .allocator = app.allocator,
        .argv = argv.items,
        .cwd = ".",
        .max_output_bytes = 128 * 1024,
    }) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[project-search-result]\nquery: {s}\npath: {s}\nerror: {s}",
            .{ input.query, input.path, @errorName(err) },
        );
    };
    defer app.allocator.free(result.stdout);
    defer app.allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => return app.allocator.dupe(u8, "[project-search-result]\nerror: rg did not exit cleanly"),
    };

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print("[project-search-result]\nquery: {s}\npath: {s}\n", .{ input.query, input.path });

    if (exit_code == 1) {
        try output.writer.writeAll("files: 0\nnote: no matches\n");
        return output.toOwnedSlice();
    }
    if (exit_code != 0) {
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            try output.writer.print("error: rg failed ({d}) {s}\n", .{ exit_code, stderr_trimmed });
        } else {
            try output.writer.print("error: rg failed ({d})\n", .{exit_code});
        }
        return output.toOwnedSlice();
    }

    var hits: std.ArrayList(ProjectSearchFileHit) = .empty;
    defer {
        for (hits.items) |*hit| hit.deinit(app.allocator);
        hits.deinit(app.allocator);
    }

    var path_to_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer path_to_index.deinit(app.allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var parsed_matches: u32 = 0;
    while (lines.next()) |raw_line| {
        if (parsed_matches >= input.max_matches) break;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const rg_line = common.parseRgLine(line) orelse continue;
        parsed_matches += 1;

        if (path_to_index.get(rg_line.path)) |existing_index| {
            const hit = &hits.items[existing_index];
            hit.hits += 1;
            if (rg_line.line < hit.first_line or (rg_line.line == hit.first_line and rg_line.col < hit.first_col)) {
                hit.first_line = rg_line.line;
                hit.first_col = rg_line.col;
                app.allocator.free(hit.first_snippet);
                hit.first_snippet = try app.allocator.dupe(u8, rg_line.text);
            }
            continue;
        }

        const new_index = hits.items.len;
        const path_owned = try app.allocator.dupe(u8, rg_line.path);
        errdefer app.allocator.free(path_owned);
        const snippet_owned = try app.allocator.dupe(u8, rg_line.text);
        errdefer app.allocator.free(snippet_owned);

        try hits.append(app.allocator, .{
            .path = path_owned,
            .hits = 1,
            .first_line = rg_line.line,
            .first_col = rg_line.col,
            .first_snippet = snippet_owned,
        });
        try path_to_index.put(app.allocator, hits.items[new_index].path, new_index);
    }

    if (hits.items.len == 0) {
        try output.writer.writeAll("files: 0\nnote: no parseable matches\n");
        return output.toOwnedSlice();
    }

    std.sort.pdq(ProjectSearchFileHit, hits.items, {}, projectSearchHitLessThan);

    const shown = @min(hits.items.len, @as(usize, input.max_files));
    try output.writer.print("files: {d}\n", .{hits.items.len});
    for (hits.items[0..shown], 0..) |hit, index| {
        const snippet = std.mem.trim(u8, hit.first_snippet, " \t\r\n");
        try output.writer.print(
            "{d}. {s} (hits:{d})\n   first: {d}:{d}: {s}\n",
            .{ index + 1, hit.path, hit.hits, hit.first_line, hit.first_col, snippet },
        );
    }
    if (hits.items.len > shown) {
        try output.writer.print("note: omitted {d} files\n", .{hits.items.len - shown});
    }

    return output.toOwnedSlice();
}

fn projectSearchHitLessThan(_: void, lhs: ProjectSearchFileHit, rhs: ProjectSearchFileHit) bool {
    if (lhs.hits != rhs.hits) return lhs.hits > rhs.hits;
    if (lhs.first_line != rhs.first_line) return lhs.first_line < rhs.first_line;
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn parseProjectSearchInput(allocator: std.mem.Allocator, payload: []const u8) !ProjectSearchInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .query = try allocator.dupe(u8, trimmed), .path = try allocator.dupe(u8, "."), .max_files = 8, .max_matches = 300 };
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

    const path_value = object.get("path") orelse std.json.Value{ .string = "." };
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .max_files = common.sanitizeProjectSearchMaxFiles(common.jsonFieldU32(object, "max_files") orelse common.jsonFieldU32(object, "max_results") orelse 8),
        .max_matches = common.sanitizeProjectSearchMatches(common.jsonFieldU32(object, "max_matches") orelse common.jsonFieldU32(object, "max_hits") orelse 300),
    };
}
