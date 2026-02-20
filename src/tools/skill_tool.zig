//! SKILL tool runner.

const std = @import("std");
const common = @import("common.zig");

const SKILL_TOOL_MAX_FILE_BYTES: usize = 256 * 1024;
const SKILL_TOOL_MAX_LISTED_FILES: usize = 12;

const SkillInput = struct {
    name: []u8,
};

pub fn run(app: anytype, payload: []const u8) ![]u8 {
    const input = parseSkillInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[skill-result]\nerror: invalid payload (expected plain name or JSON with field name)");
    };
    defer app.allocator.free(input.name);

    try app.ensureSkillsLoaded();
    const skill = app.findSkillByName(input.name) orelse {
        return std.fmt.allocPrint(
            app.allocator,
            "[skill-result]\nname: {s}\nerror: skill not found",
            .{input.name},
        );
    };

    var skill_file = common.openFileForPath(skill.path, .{}) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[skill-result]\nname: {s}\npath: {s}\nerror: {s}",
            .{ skill.name, skill.path, @errorName(err) },
        );
    };
    defer skill_file.close();

    const content = skill_file.readToEndAlloc(app.allocator, SKILL_TOOL_MAX_FILE_BYTES) catch |err| switch (err) {
        error.FileTooBig => return std.fmt.allocPrint(
            app.allocator,
            "[skill-result]\nname: {s}\npath: {s}\nerror: skill file too large (max:{d} bytes)",
            .{ skill.name, skill.path, SKILL_TOOL_MAX_FILE_BYTES },
        ),
        else => return std.fmt.allocPrint(
            app.allocator,
            "[skill-result]\nname: {s}\npath: {s}\nerror: {s}",
            .{ skill.name, skill.path, @errorName(err) },
        ),
    };
    defer app.allocator.free(content);

    const sample_files = try sampleSkillFilesAlloc(app.allocator, skill.base_dir, SKILL_TOOL_MAX_LISTED_FILES);
    defer app.allocator.free(sample_files);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print(
        "[skill-result]\nname: {s}\ndescription: {s}\npath: {s}\nbase_dir: {s}\nscope: {s}\n",
        .{ skill.name, skill.description, skill.path, skill.base_dir, app.skillScopeLabel(skill.scope) },
    );
    if (sample_files.len > 0) {
        try output.writer.writeAll("sample_files:\n");
        try output.writer.writeAll(sample_files);
        if (sample_files[sample_files.len - 1] != '\n') try output.writer.writeByte('\n');
    }

    try output.writer.print(
        "content:\n<skill_content name=\"{s}\" path=\"{s}\">\n",
        .{ skill.name, skill.path },
    );
    try output.writer.writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    try output.writer.print("</skill_content>\n", .{});

    return output.toOwnedSlice();
}

fn parseSkillInput(allocator: std.mem.Allocator, payload: []const u8) !SkillInput {
    var trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const after_marker = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (after_marker.len >= 5 and std.mem.startsWith(u8, after_marker, "SKILL")) {
            trimmed = std.mem.trimLeft(u8, after_marker["SKILL".len..], " \t:");
        }
    }

    if (trimmed.len > 0 and trimmed[0] == '$') {
        trimmed = std.mem.trimLeft(u8, trimmed[1..], " \t");
    }
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .name = try allocator.dupe(u8, common.trimMatchingOuterQuotes(trimmed)),
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const name_value = object.get("name") orelse object.get("skill") orelse return error.InvalidToolPayload;
    const name_text = switch (name_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .name = try allocator.dupe(u8, common.trimMatchingOuterQuotes(std.mem.trim(u8, name_text, " \t\r\n"))),
    };
}

fn sampleSkillFilesAlloc(allocator: std.mem.Allocator, base_dir: []const u8, limit: usize) ![]u8 {
    var dir = common.openDirForPath(base_dir, .{ .iterate = true }) catch {
        return allocator.dupe(u8, "");
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var count: usize = 0;
    while (count < limit) {
        const maybe_entry = try walker.next();
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.path), "SKILL.md")) continue;

        try output.writer.print("- {s}\n", .{entry.path});
        count += 1;
    }

    return output.toOwnedSlice();
}
