//! Codex-style apply_patch parser and applier for local file edits.

const std = @import("std");

pub const ApplyStats = struct {
    operations: usize = 0,
    files_changed: usize = 0,
    added: usize = 0,
    updated: usize = 0,
    deleted: usize = 0,
    moved: usize = 0,
};

const PatchLineKind = enum {
    context,
    add,
    remove,
};

const PatchLine = struct {
    kind: PatchLineKind,
    text: []const u8,
};

const UpdateBlock = struct {
    lines: std.ArrayList(PatchLine) = .empty,

    fn deinit(self: *UpdateBlock, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
    }
};

const AddOperation = struct {
    path: []const u8,
    lines: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *AddOperation, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
    }
};

const DeleteOperation = struct {
    path: []const u8,
};

const UpdateOperation = struct {
    path: []const u8,
    move_to: ?[]const u8 = null,
    blocks: std.ArrayList(UpdateBlock) = .empty,

    fn deinit(self: *UpdateOperation, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(allocator);
        }
        self.blocks.deinit(allocator);
    }
};

const Operation = union(enum) {
    add_file: AddOperation,
    delete_file: DeleteOperation,
    update_file: UpdateOperation,

    fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .add_file => |*op| op.deinit(allocator),
            .delete_file => {},
            .update_file => |*op| op.deinit(allocator),
        }
    }
};

const BorrowedLines = struct {
    items: std.ArrayList([]const u8) = .empty,
    trailing_newline: bool = false,

    fn deinit(self: *BorrowedLines, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

pub fn applyCodexPatch(allocator: std.mem.Allocator, patch_text: []const u8) !ApplyStats {
    const trimmed = std.mem.trim(u8, patch_text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPatch;

    var patch_lines = try splitLinesBorrow(allocator, trimmed);
    defer patch_lines.deinit(allocator);

    var operations = try parseOperations(allocator, patch_lines.items.items);
    defer {
        for (operations.items) |*operation| operation.deinit(allocator);
        operations.deinit(allocator);
    }

    var stats: ApplyStats = .{
        .operations = operations.items.len,
    };

    for (operations.items) |operation| {
        switch (operation) {
            .add_file => |add_op| {
                try applyAddFile(allocator, add_op);
                stats.files_changed += 1;
                stats.added += 1;
            },
            .delete_file => |delete_op| {
                try applyDeleteFile(delete_op);
                stats.files_changed += 1;
                stats.deleted += 1;
            },
            .update_file => |update_op| {
                const moved = try applyUpdateFile(allocator, update_op);
                stats.files_changed += 1;
                stats.updated += 1;
                if (moved) stats.moved += 1;
            },
        }
    }

    return stats;
}

fn parseOperations(allocator: std.mem.Allocator, lines: []const []const u8) !std.ArrayList(Operation) {
    if (lines.len == 0 or !std.mem.eql(u8, lines[0], "*** Begin Patch")) {
        return error.MissingBeginPatch;
    }

    var operations: std.ArrayList(Operation) = .empty;
    errdefer {
        for (operations.items) |*operation| operation.deinit(allocator);
        operations.deinit(allocator);
    }

    var line_index: usize = 1;
    var saw_end = false;
    while (line_index < lines.len) {
        const line = lines[line_index];
        if (std.mem.eql(u8, line, "*** End Patch")) {
            saw_end = true;
            break;
        }

        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            var operation: AddOperation = .{
                .path = std.mem.trim(u8, line["*** Add File: ".len..], " \t"),
            };
            if (operation.path.len == 0) return error.InvalidPatchPath;
            errdefer operation.deinit(allocator);

            line_index += 1;
            while (line_index < lines.len and !std.mem.startsWith(u8, lines[line_index], "*** ")) : (line_index += 1) {
                const add_line = lines[line_index];
                if (add_line.len == 0 or add_line[0] != '+') return error.InvalidAddFileLine;
                try operation.lines.append(allocator, add_line[1..]);
            }

            try operations.append(allocator, .{ .add_file = operation });
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Delete File: ")) {
            const path = std.mem.trim(u8, line["*** Delete File: ".len..], " \t");
            if (path.len == 0) return error.InvalidPatchPath;

            try operations.append(allocator, .{
                .delete_file = .{ .path = path },
            });
            line_index += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            var operation: UpdateOperation = .{
                .path = std.mem.trim(u8, line["*** Update File: ".len..], " \t"),
            };
            if (operation.path.len == 0) return error.InvalidPatchPath;
            errdefer operation.deinit(allocator);

            line_index += 1;
            if (line_index < lines.len and std.mem.startsWith(u8, lines[line_index], "*** Move to: ")) {
                const move_to = std.mem.trim(u8, lines[line_index]["*** Move to: ".len..], " \t");
                if (move_to.len == 0) return error.InvalidPatchPath;
                operation.move_to = move_to;
                line_index += 1;
            }

            var current_block: UpdateBlock = .{};
            while (line_index < lines.len and !std.mem.startsWith(u8, lines[line_index], "*** ")) : (line_index += 1) {
                const change_line = lines[line_index];

                if (std.mem.startsWith(u8, change_line, "@@")) {
                    if (current_block.lines.items.len > 0) {
                        try operation.blocks.append(allocator, current_block);
                        current_block = .{};
                    }
                    continue;
                }

                if (change_line.len == 0) return error.InvalidUpdateLine;
                const line_kind: PatchLineKind = switch (change_line[0]) {
                    ' ' => .context,
                    '+' => .add,
                    '-' => .remove,
                    else => return error.InvalidUpdateLine,
                };
                try current_block.lines.append(allocator, .{
                    .kind = line_kind,
                    .text = change_line[1..],
                });
            }

            if (current_block.lines.items.len > 0) {
                try operation.blocks.append(allocator, current_block);
            } else {
                current_block.deinit(allocator);
            }

            if (operation.move_to == null and operation.blocks.items.len == 0) {
                return error.InvalidUpdateLine;
            }

            try operations.append(allocator, .{ .update_file = operation });
            continue;
        }

        return error.InvalidPatchHeader;
    }

    if (!saw_end) return error.MissingEndPatch;
    if (operations.items.len == 0) return error.EmptyPatchOperations;
    return operations;
}

fn applyAddFile(allocator: std.mem.Allocator, operation: AddOperation) !void {
    if (try pathExists(operation.path)) return error.AddTargetExists;

    const body = try joinLines(allocator, operation.lines.items, true);
    defer allocator.free(body);

    try writeTextFile(operation.path, body);
}

fn applyDeleteFile(operation: DeleteOperation) !void {
    deleteFileForPath(operation.path) catch |err| switch (err) {
        error.FileNotFound => return error.DeleteTargetMissing,
        else => return err,
    };
}

fn applyUpdateFile(allocator: std.mem.Allocator, operation: UpdateOperation) !bool {
    const source_text = readTextFileAlloc(allocator, operation.path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.UpdateTargetMissing,
        else => return err,
    };
    defer allocator.free(source_text);

    const target_path = operation.move_to orelse operation.path;
    const moved = operation.move_to != null and !std.mem.eql(u8, target_path, operation.path);

    var updated_text: []u8 = undefined;
    if (operation.blocks.items.len == 0) {
        updated_text = try allocator.dupe(u8, source_text);
    } else {
        var source_lines = try splitLinesBorrow(allocator, source_text);
        defer source_lines.deinit(allocator);

        var applied_lines = try applyUpdateBlocks(allocator, source_lines.items.items, operation.blocks.items);
        defer applied_lines.deinit(allocator);

        updated_text = try joinLines(allocator, applied_lines.items, source_lines.trailing_newline);
    }
    defer allocator.free(updated_text);

    try writeTextFile(target_path, updated_text);
    if (moved) {
        try deleteFileForPath(operation.path);
    }
    return moved;
}

fn applyUpdateBlocks(
    allocator: std.mem.Allocator,
    source_lines: []const []const u8,
    blocks: []const UpdateBlock,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (blocks) |block| {
        if (block.lines.items.len == 0) continue;

        var old_pattern: std.ArrayList([]const u8) = .empty;
        defer old_pattern.deinit(allocator);
        var new_pattern: std.ArrayList([]const u8) = .empty;
        defer new_pattern.deinit(allocator);

        for (block.lines.items) |line| {
            switch (line.kind) {
                .context => {
                    try old_pattern.append(allocator, line.text);
                    try new_pattern.append(allocator, line.text);
                },
                .remove => try old_pattern.append(allocator, line.text),
                .add => try new_pattern.append(allocator, line.text),
            }
        }

        if (old_pattern.items.len == 0) {
            try out.appendSlice(allocator, new_pattern.items);
            continue;
        }

        const match_relative = findSubsequence(source_lines[cursor..], old_pattern.items) orelse return error.PatchContextNotFound;
        const match_index = cursor + match_relative;

        try out.appendSlice(allocator, source_lines[cursor..match_index]);
        try out.appendSlice(allocator, new_pattern.items);
        cursor = match_index + old_pattern.items.len;
    }

    try out.appendSlice(allocator, source_lines[cursor..]);
    return out;
}

fn findSubsequence(haystack: []const []const u8, needle: []const []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (!std.mem.eql(u8, haystack[i + j], needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }

    return null;
}

fn splitLinesBorrow(allocator: std.mem.Allocator, text: []const u8) !BorrowedLines {
    var lines: BorrowedLines = .{
        .trailing_newline = text.len > 0 and text[text.len - 1] == '\n',
    };
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    while (start < text.len) {
        const newline_at = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const raw_line = text[start..newline_at];
        try lines.items.append(allocator, trimTrailingCarriage(raw_line));
        if (newline_at == text.len) break;
        start = newline_at + 1;
    }

    return lines;
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8, trailing_newline: bool) ![]u8 {
    var total_len: usize = 0;
    for (lines) |line| total_len += line.len;
    if (lines.len > 1) total_len += lines.len - 1;
    if (trailing_newline and lines.len > 0) total_len += 1;

    var out = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (lines, 0..) |line, index| {
        @memcpy(out[cursor .. cursor + line.len], line);
        cursor += line.len;
        const is_last = index + 1 == lines.len;
        if (!is_last) {
            out[cursor] = '\n';
            cursor += 1;
        }
    }
    if (trailing_newline and lines.len > 0) {
        out[cursor] = '\n';
        cursor += 1;
    }

    std.debug.assert(cursor == out.len);
    return out;
}

fn trimTrailingCarriage(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn readTextFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try openFileForPath(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeTextFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dirname| {
        try std.fs.cwd().makePath(dirname);
    }

    var file = try createFileForPath(path, .{ .truncate = true });
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(content);
}

fn pathExists(path: []const u8) !bool {
    var file = openFileForPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close();
    return true;
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

fn deleteFileForPath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteFileAbsolute(path);
    }
    return std.fs.cwd().deleteFile(path);
}

test "applyCodexPatch add update delete flow" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/note.txt", .{root});
    defer allocator.free(file_path);

    const add_patch = try std.fmt.allocPrint(
        allocator,
        "*** Begin Patch\n*** Add File: {s}\n+hello\n+world\n*** End Patch",
        .{file_path},
    );
    defer allocator.free(add_patch);

    const add_stats = try applyCodexPatch(allocator, add_patch);
    try std.testing.expectEqual(@as(usize, 1), add_stats.added);

    const after_add = try readTextFileAlloc(allocator, file_path, 1024);
    defer allocator.free(after_add);
    try std.testing.expectEqualStrings("hello\nworld\n", after_add);

    const update_patch = try std.fmt.allocPrint(
        allocator,
        "*** Begin Patch\n*** Update File: {s}\n@@\n hello\n-world\n+zolt\n*** End Patch",
        .{file_path},
    );
    defer allocator.free(update_patch);

    const update_stats = try applyCodexPatch(allocator, update_patch);
    try std.testing.expectEqual(@as(usize, 1), update_stats.updated);

    const after_update = try readTextFileAlloc(allocator, file_path, 1024);
    defer allocator.free(after_update);
    try std.testing.expectEqualStrings("hello\nzolt\n", after_update);

    const delete_patch = try std.fmt.allocPrint(
        allocator,
        "*** Begin Patch\n*** Delete File: {s}\n*** End Patch",
        .{file_path},
    );
    defer allocator.free(delete_patch);

    const delete_stats = try applyCodexPatch(allocator, delete_patch);
    try std.testing.expectEqual(@as(usize, 1), delete_stats.deleted);

    try std.testing.expectError(error.FileNotFound, openFileForPath(file_path, .{}));
}

test "applyCodexPatch updates file without trailing newline" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/single-line.txt", .{root});
    defer allocator.free(file_path);

    try writeTextFile(file_path, "hello");

    const patch = try std.fmt.allocPrint(
        allocator,
        "*** Begin Patch\n*** Update File: {s}\n@@\n-hello\n+zolt\n*** End Patch",
        .{file_path},
    );
    defer allocator.free(patch);

    const stats = try applyCodexPatch(allocator, patch);
    try std.testing.expectEqual(@as(usize, 1), stats.updated);

    const content = try readTextFileAlloc(allocator, file_path, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("zolt", content);
}
