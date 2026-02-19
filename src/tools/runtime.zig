//! Tool execution runtime extracted from tui.zig.

const std = @import("std");
const patch_tool = @import("../patch_tool.zig");

const READ_TOOL_MAX_OUTPUT_BYTES: usize = 24 * 1024;
const APPLY_PATCH_TOOL_MAX_PATCH_BYTES: usize = 256 * 1024;
const APPLY_PATCH_PREVIEW_MAX_LINES: usize = 120;
const COMMAND_TOOL_DEFAULT_YIELD_MS: u32 = 700;
const WEB_SEARCH_DEFAULT_RESULTS: u8 = 5;
const WEB_SEARCH_MAX_RESULTS: u8 = 10;
const WEB_SEARCH_MAX_RESPONSE_BYTES: usize = 256 * 1024;
const IMAGE_TOOL_MAX_FILE_BYTES: usize = 64 * 1024 * 1024;

const ParsedRgLine = struct {
    path: []const u8,
    line: u32,
    col: u32,
    text: []const u8,
};

const ListDirInput = struct {
    path: []u8,
    recursive: bool = false,
    max_entries: u16 = 200,
};

const ReadFileInput = struct {
    path: []u8,
    max_bytes: u32 = 12 * 1024,
};

const GrepFilesInput = struct {
    query: []u8,
    path: []u8,
    glob: ?[]u8 = null,
    max_matches: u16 = 200,

    fn deinit(self: *GrepFilesInput, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.path);
        if (self.glob) |glob| allocator.free(glob);
    }
};

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

const ApplyPatchPreview = struct {
    text: []u8,
    included_lines: usize,
    omitted_lines: usize,
};

const ExecCommandInput = struct {
    cmd: []u8,
    yield_ms: u32 = COMMAND_TOOL_DEFAULT_YIELD_MS,
};

const WriteStdinInput = struct {
    session_id: u32,
    chars: []u8,
    yield_ms: u32 = COMMAND_TOOL_DEFAULT_YIELD_MS,
};

const WebSearchEngine = enum {
    duckduckgo,
    exa,
};

const WebSearchInput = struct {
    query: []u8,
    limit: u8 = WEB_SEARCH_DEFAULT_RESULTS,
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

const ViewImageInput = struct {
    path: []u8,
};

const ImageFileInfo = struct {
    bytes: u64,
    format: []const u8,
    mime: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    sha256_hex: ?[]u8 = null,

    fn deinit(self: *ImageFileInfo, allocator: std.mem.Allocator) void {
        if (self.sha256_hex) |sha| allocator.free(sha);
    }
};

pub fn runReadToolCommand(app: anytype, command_text: []const u8) ![]u8 {
    var parsed_args = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(app.allocator, command_text);
    defer parsed_args.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(app.allocator);

    while (parsed_args.next()) |token| {
        try argv.append(app.allocator, token);
        if (argv.items.len > 64) {
            return std.fmt.allocPrint(app.allocator, "[read-result]\ncommand: {s}\nerror: too many arguments", .{command_text});
        }
    }

    if (argv.items.len == 0) {
        return std.fmt.allocPrint(app.allocator, "[read-result]\ncommand: {s}\nerror: empty command", .{command_text});
    }

    if (!isAllowedReadCommand(argv.items)) {
        return std.fmt.allocPrint(
            app.allocator,
            "[read-result]\ncommand: {s}\nerror: command not allowed ({s})",
            .{ command_text, argv.items[0] },
        );
    }

    const result = std.process.Child.run(.{
        .allocator = app.allocator,
        .argv = argv.items,
        .cwd = ".",
        .max_output_bytes = READ_TOOL_MAX_OUTPUT_BYTES,
    }) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[read-result]\ncommand: {s}\nerror: {s}",
            .{ command_text, @errorName(err) },
        );
    };
    defer app.allocator.free(result.stdout);
    defer app.allocator.free(result.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print("[read-result]\ncommand: {s}\nterm: ", .{command_text});
    switch (result.term) {
        .Exited => |code| try output.writer.print("exited:{d}\n", .{code}),
        .Signal => |sig| try output.writer.print("signal:{d}\n", .{sig}),
        .Stopped => |sig| try output.writer.print("stopped:{d}\n", .{sig}),
        .Unknown => |code| try output.writer.print("unknown:{d}\n", .{code}),
    }

    if (result.stdout.len > 0) {
        try output.writer.writeAll("stdout:\n");
        try output.writer.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try output.writer.writeByte('\n');
    }

    if (result.stderr.len > 0) {
        try output.writer.writeAll("stderr:\n");
        try output.writer.writeAll(result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try output.writer.writeByte('\n');
    }

    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try output.writer.writeAll("stdout:\n(no output)\n");
    }

    return output.toOwnedSlice();
}

pub fn runListDirToolPayload(app: anytype, payload: []const u8) ![]u8 {
    const input = parseListDirInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[list-dir-result]\nerror: invalid payload (expected plain path or JSON with path, recursive, max_entries)");
    };
    defer app.allocator.free(input.path);

    var dir = openDirForPath(input.path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[list-dir-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        );
    };
    defer dir.close();

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print(
        "[list-dir-result]\npath: {s}\nrecursive: {s}\nmax_entries: {d}\n",
        .{ input.path, if (input.recursive) "true" else "false", input.max_entries },
    );

    var count: u32 = 0;
    var truncated = false;

    if (input.recursive) {
        var walker = try dir.walk(app.allocator);
        defer walker.deinit();

        while (true) {
            const entry = walker.next() catch |err| {
                try output.writer.print("error: {s}\n", .{@errorName(err)});
                break;
            };
            if (entry == null) break;

            if (count >= input.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            try output.writer.print(
                "{d}. [{s}] {s}\n",
                .{ count, dirEntryKindLabel(entry.?.kind), entry.?.path },
            );
        }
    } else {
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                try output.writer.print("error: {s}\n", .{@errorName(err)});
                break;
            };
            if (entry == null) break;

            if (count >= input.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            try output.writer.print(
                "{d}. [{s}] {s}\n",
                .{ count, dirEntryKindLabel(entry.?.kind), entry.?.name },
            );
        }
    }

    if (count == 0) {
        try output.writer.writeAll("note: no entries\n");
    }
    if (truncated) {
        try output.writer.writeAll("note: truncated by max_entries\n");
    }

    return output.toOwnedSlice();
}

pub fn runReadFileToolPayload(app: anytype, payload: []const u8) ![]u8 {
    const input = parseReadFileInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[read-file-result]\nerror: invalid payload (expected plain path or JSON with path and optional max_bytes)");
    };
    defer app.allocator.free(input.path);

    var file = openFileForPath(input.path, .{}) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        );
    };
    defer file.close();

    const content = file.readToEndAlloc(app.allocator, input.max_bytes) catch |err| switch (err) {
        error.FileTooBig => return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: file too big (max_bytes:{d})",
            .{ input.path, input.max_bytes },
        ),
        else => return std.fmt.allocPrint(
            app.allocator,
            "[read-file-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        ),
    };
    defer app.allocator.free(content);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print(
        "[read-file-result]\npath: {s}\nbytes: {d}\n",
        .{ input.path, content.len },
    );
    if (looksBinary(content)) {
        try output.writer.writeAll("note: file appears binary; content omitted\n");
        return output.toOwnedSlice();
    }

    try output.writer.writeAll("content:\n");
    try output.writer.writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

pub fn runGrepFilesToolPayload(app: anytype, payload: []const u8) ![]u8 {
    var input = parseGrepFilesInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[grep-files-result]\nerror: invalid payload (expected plain query or JSON with query/path/glob/max_matches)");
    };
    defer input.deinit(app.allocator);

    if (input.query.len == 0) {
        return app.allocator.dupe(u8, "[grep-files-result]\nerror: empty query");
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
    });
    if (input.glob) |glob| {
        try argv.appendSlice(app.allocator, &.{ "--glob", glob });
    }
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
            "[grep-files-result]\nquery: {s}\npath: {s}\nerror: {s}",
            .{ input.query, input.path, @errorName(err) },
        );
    };
    defer app.allocator.free(result.stdout);
    defer app.allocator.free(result.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print("[grep-files-result]\nquery: {s}\npath: {s}\n", .{ input.query, input.path });
    if (input.glob) |glob| try output.writer.print("glob: {s}\n", .{glob});

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        .Signal => |sig| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg terminated by signal {d}", .{sig}),
        .Stopped => |sig| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg stopped by signal {d}", .{sig}),
        .Unknown => |code| return std.fmt.allocPrint(app.allocator, "[grep-files-result]\nerror: rg unknown term {d}", .{code}),
    };

    if (exit_code == 1) {
        try output.writer.writeAll("matches: 0\nnote: no matches\n");
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

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var total_matches: u32 = 0;
    var emitted_matches: u32 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        total_matches += 1;
        if (emitted_matches < input.max_matches) {
            emitted_matches += 1;
            try output.writer.print("{s}\n", .{line});
        }
    }

    try output.writer.print("matches: {d}\n", .{total_matches});
    if (total_matches > emitted_matches) {
        try output.writer.print("note: truncated output ({d} hidden)\n", .{total_matches - emitted_matches});
    }

    return output.toOwnedSlice();
}

pub fn runProjectSearchToolPayload(app: anytype, payload: []const u8) ![]u8 {
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

        const rg_line = parseRgLine(line) orelse continue;
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

pub fn runApplyPatchToolPatch(app: anytype, patch_text: []const u8) ![]u8 {
    const trimmed_patch = std.mem.trim(u8, patch_text, " \t\r\n");
    if (trimmed_patch.len == 0) {
        return app.allocator.dupe(u8, "[apply-patch-result]\nerror: empty patch payload");
    }

    if (trimmed_patch.len > APPLY_PATCH_TOOL_MAX_PATCH_BYTES) {
        return std.fmt.allocPrint(
            app.allocator,
            "[apply-patch-result]\nerror: patch too large ({d} bytes > {d})",
            .{ trimmed_patch.len, APPLY_PATCH_TOOL_MAX_PATCH_BYTES },
        );
    }

    if (!isValidApplyPatchPayload(trimmed_patch)) {
        return app.allocator.dupe(u8, "[apply-patch-result]\nerror: invalid patch payload; expected codex apply_patch format");
    }

    const stats = patch_tool.applyCodexPatch(app.allocator, trimmed_patch) catch |err| {
        const detail = switch (err) {
            error.FileNotFound => "target file not found",
            error.UpdateTargetMissing => "update target file not found (use *** Add File for new files)",
            error.DeleteTargetMissing => "delete target file not found",
            error.AddTargetExists => "add target already exists (use *** Update File instead)",
            error.PatchContextNotFound => "patch context not found in target file",
            error.MissingBeginPatch => "missing *** Begin Patch header",
            error.MissingEndPatch => "missing *** End Patch trailer",
            error.InvalidPatchHeader => "invalid patch operation header",
            error.InvalidPatchPath => "invalid or empty patch path",
            error.InvalidAddFileLine => "invalid add-file body line (expected leading +)",
            error.InvalidUpdateLine => "invalid update hunk line (expected ' ', '+', '-', or @@)",
            error.EmptyPatchOperations => "patch contains no operations",
            else => @errorName(err),
        };
        return std.fmt.allocPrint(
            app.allocator,
            "[apply-patch-result]\nerror: {s}",
            .{detail},
        );
    };

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print(
        "[apply-patch-result]\nbytes: {d}\nops:{d} files_changed:{d} added:{d} updated:{d} deleted:{d} moved:{d}\nstatus: ok\n",
        .{
            trimmed_patch.len,
            stats.operations,
            stats.files_changed,
            stats.added,
            stats.updated,
            stats.deleted,
            stats.moved,
        },
    );

    const preview = try buildApplyPatchPreview(app.allocator, trimmed_patch, APPLY_PATCH_PREVIEW_MAX_LINES);
    defer app.allocator.free(preview.text);
    if (preview.included_lines > 0) {
        try output.writer.writeAll("diff_preview:\n");
        try output.writer.writeAll(preview.text);
    }
    if (preview.omitted_lines > 0) {
        try output.writer.print(
            "note: preview truncated ({d} patch lines omitted)\n",
            .{preview.omitted_lines},
        );
    }

    return output.toOwnedSlice();
}

pub fn runExecCommandToolPayload(app: anytype, payload: []const u8) ![]u8 {
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

pub fn runWriteStdinToolPayload(app: anytype, payload: []const u8) ![]u8 {
    var input = parseWriteStdinInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[write-stdin-result]\nerror: invalid payload (expected JSON with session_id, chars, optional yield_ms)");
    };
    defer app.allocator.free(input.chars);

    const session = app.findCommandSessionById(input.session_id) orelse {
        return std.fmt.allocPrint(app.allocator, "[write-stdin-result]\nerror: session not found ({d})", .{input.session_id});
    };

    if (session.finished) {
        var output: std.Io.Writer.Allocating = .init(app.allocator);
        defer output.deinit();
        try output.writer.print("[write-stdin-result]\nsession_id: {d}\nchars_written: 0\n", .{session.id});
        try app.appendCommandSessionStateLine(&output.writer, session);
        return output.toOwnedSlice();
    }

    var written: usize = 0;
    if (input.chars.len > 0) {
        const stdin_file = session.child.stdin orelse {
            return std.fmt.allocPrint(app.allocator, "[write-stdin-result]\nsession_id: {d}\nerror: session stdin is closed", .{session.id});
        };

        while (written < input.chars.len) {
            const n = std.posix.write(stdin_file.handle, input.chars[written..]) catch |err| switch (err) {
                error.BrokenPipe => {
                    session.child.stdin.?.close();
                    session.child.stdin = null;
                    break;
                },
                else => return std.fmt.allocPrint(
                    app.allocator,
                    "[write-stdin-result]\nsession_id: {d}\nerror: {s}",
                    .{ session.id, @errorName(err) },
                ),
            };
            written += n;
        }
    }

    const drained = try app.drainCommandSessionOutput(session, input.yield_ms);
    defer app.allocator.free(drained.stdout);
    defer app.allocator.free(drained.stderr);

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.print("[write-stdin-result]\nsession_id: {d}\nchars_written: {d}\n", .{
        session.id,
        written,
    });
    try app.appendCommandSessionStateLine(&output.writer, session);
    try app.appendCommandDrainOutput(&output.writer, drained);
    return output.toOwnedSlice();
}

pub fn runWebSearchToolPayload(app: anytype, payload: []const u8) ![]u8 {
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

pub fn runViewImageToolPayload(app: anytype, payload: []const u8) ![]u8 {
    const input = parseViewImageInput(app.allocator, payload) catch {
        return app.allocator.dupe(u8, "[view-image-result]\nerror: invalid payload (expected plain path or JSON with path)");
    };
    defer app.allocator.free(input.path);

    if (input.path.len == 0) {
        return app.allocator.dupe(u8, "[view-image-result]\nerror: empty path");
    }

    const maybe_image_info = inspectImageFile(app.allocator, input.path, true) catch |err| {
        return std.fmt.allocPrint(
            app.allocator,
            "[view-image-result]\npath: {s}\nerror: {s}",
            .{ input.path, @errorName(err) },
        );
    };
    if (maybe_image_info == null) {
        return std.fmt.allocPrint(
            app.allocator,
            "[view-image-result]\npath: {s}\nerror: unsupported or unknown image format",
            .{input.path},
        );
    }
    var image_info = maybe_image_info.?;
    defer image_info.deinit(app.allocator);

    if (image_info.format.len == 0) {
        return std.fmt.allocPrint(
            app.allocator,
            "[view-image-result]\npath: {s}\nerror: unsupported or unknown image format",
            .{input.path},
        );
    }

    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();

    try output.writer.print(
        "[view-image-result]\npath: {s}\nbytes: {d}\nformat: {s}\nmime: {s}\n",
        .{ input.path, image_info.bytes, image_info.format, image_info.mime },
    );
    if (image_info.width != null and image_info.height != null) {
        try output.writer.print("dimensions: {d}x{d}\n", .{ image_info.width.?, image_info.height.? });
    } else {
        try output.writer.writeAll("dimensions: unknown\n");
    }
    if (image_info.sha256_hex) |sha| {
        try output.writer.print("sha256: {s}\n", .{sha});
    }

    var vision_note: []const u8 = "metadata-only";
    var vision_caption: ?[]u8 = null;
    defer if (vision_caption) |caption| app.allocator.free(caption);
    var vision_error: ?[]u8 = null;
    defer if (vision_error) |detail| app.allocator.free(detail);

    if (isOpenAiCompatibleProviderId(app.app_state.selected_provider_id)) {
        const api_key = try app.resolveApiKey(app.app_state.selected_provider_id);
        defer if (api_key) |key| app.allocator.free(key);

        if (api_key) |key| {
            const provider_info = app.catalog.findProviderConst(app.app_state.selected_provider_id);
            const base_url = if (provider_info) |info|
                (info.api_base orelse defaultBaseUrlForProviderId(app.app_state.selected_provider_id) orelse "")
            else
                (defaultBaseUrlForProviderId(app.app_state.selected_provider_id) orelse "");
            if (base_url.len > 0) {
                const vision_result = try app.tryVisionCaptionOpenAiCompatible(
                    input.path,
                    image_info.mime,
                    app.app_state.selected_provider_id,
                    base_url,
                    key,
                );
                if (vision_result.caption) |caption| {
                    vision_note = "visual-caption-ok";
                    vision_caption = caption;
                } else if (vision_result.error_detail) |detail| {
                    vision_note = "visual-caption-failed";
                    vision_error = detail;
                } else {
                    vision_note = "visual-caption-unavailable";
                }
            } else {
                vision_note = "visual-caption-unsupported-provider-base-url";
            }
        } else {
            vision_note = "visual-caption-missing-api-key";
        }
    } else {
        vision_note = "visual-caption-unsupported-provider";
    }

    if (vision_caption) |caption| {
        try output.writer.writeAll("vision_caption:\n");
        try output.writer.writeAll(caption);
        if (caption.len == 0 or caption[caption.len - 1] != '\n') {
            try output.writer.writeByte('\n');
        }
    } else if (vision_error) |detail| {
        try output.writer.print("vision_error: {s}\n", .{detail});
    }
    try output.writer.print("note: {s}\n", .{vision_note});

    return output.toOwnedSlice();
}

fn openDirForPath(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) return std.fs.openDirAbsolute(path, flags);
    return std.fs.cwd().openDir(path, flags);
}

fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, flags);
    return std.fs.cwd().openFile(path, flags);
}

fn dirEntryKindLabel(kind: std.fs.Dir.Entry.Kind) []const u8 {
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

fn parseRgLine(line: []const u8) ?ParsedRgLine {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, line, first + 1, ':') orelse return null;
    const third = std.mem.indexOfScalarPos(u8, line, second + 1, ':') orelse return null;
    if (first == 0 or second <= first + 1 or third <= second + 1) return null;

    const line_no = std.fmt.parseInt(u32, line[first + 1 .. second], 10) catch return null;
    const col_no = std.fmt.parseInt(u32, line[second + 1 .. third], 10) catch return null;
    return .{ .path = line[0..first], .line = line_no, .col = col_no, .text = line[third + 1 ..] };
}

fn projectSearchHitLessThan(_: void, lhs: ProjectSearchFileHit, rhs: ProjectSearchFileHit) bool {
    if (lhs.hits != rhs.hits) return lhs.hits > rhs.hits;
    if (lhs.first_line != rhs.first_line) return lhs.first_line < rhs.first_line;
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn looksBinary(content: []const u8) bool {
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

fn isAllowedReadCommand(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const command = argv[0];
    if (command.len == 0) return false;
    if (std.mem.indexOfScalar(u8, command, '/')) |_| return false;

    if (std.mem.eql(u8, command, "git")) return isAllowedReadGitCommand(argv[1..]);

    const allowlist = [_][]const u8{ "rg", "grep", "ls", "cat", "find", "head", "tail", "sed", "wc", "stat", "pwd" };
    for (allowlist) |allowed| if (std.mem.eql(u8, command, allowed)) return true;
    return false;
}

fn isAllowedReadGitCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const subcommand = args[0];
    if (subcommand.len == 0 or subcommand[0] == '-') return false;

    const allowlist = [_][]const u8{ "status", "diff", "show", "log", "rev-parse", "ls-files" };
    for (allowlist) |allowed| if (std.mem.eql(u8, subcommand, allowed)) return true;
    return false;
}

fn isValidApplyPatchPayload(patch_text: []const u8) bool {
    const has_begin = std.mem.startsWith(u8, patch_text, "*** Begin Patch");
    const has_end = std.mem.indexOf(u8, patch_text, "*** End Patch") != null;
    return has_begin and has_end;
}

fn buildApplyPatchPreview(allocator: std.mem.Allocator, patch_text: []const u8, max_lines: usize) !ApplyPatchPreview {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var lines = std.mem.splitScalar(u8, patch_text, '\n');
    var included: usize = 0;
    var omitted: usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const include_line = std.mem.startsWith(u8, line, "***") or
            std.mem.startsWith(u8, line, "@@") or
            std.mem.startsWith(u8, line, "+") or
            std.mem.startsWith(u8, line, "-") or
            std.mem.startsWith(u8, line, " ");
        if (!include_line) continue;

        if (included >= max_lines) {
            omitted += 1;
            continue;
        }
        included += 1;
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }

    return .{
        .text = try out.toOwnedSlice(),
        .included_lines = included,
        .omitted_lines = omitted,
    };
}

fn parseExecCommandInput(allocator: std.mem.Allocator, payload: []const u8) !ExecCommandInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .cmd = try allocator.dupe(u8, trimmed), .yield_ms = COMMAND_TOOL_DEFAULT_YIELD_MS };
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

    const yield_ms = sanitizeCommandYieldMs(jsonFieldU32(object, "yield_ms") orelse jsonFieldU32(object, "yield_time_ms") orelse COMMAND_TOOL_DEFAULT_YIELD_MS);

    return .{ .cmd = try allocator.dupe(u8, std.mem.trim(u8, cmd_text, " \t\r\n")), .yield_ms = yield_ms };
}

fn parseWriteStdinInput(allocator: std.mem.Allocator, payload: []const u8) !WriteStdinInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidToolPayload;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const session_value = object.get("session_id") orelse object.get("session") orelse return error.InvalidToolPayload;
    const session_id = switch (session_value) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else return error.InvalidToolPayload,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch return error.InvalidToolPayload,
        else => return error.InvalidToolPayload,
    };

    const chars_text = if (object.get("chars")) |chars_value|
        switch (chars_value) {
            .string => |text| text,
            else => return error.InvalidToolPayload,
        }
    else
        "";

    const yield_ms = sanitizeCommandYieldMs(jsonFieldU32(object, "yield_ms") orelse jsonFieldU32(object, "yield_time_ms") orelse COMMAND_TOOL_DEFAULT_YIELD_MS);

    return .{ .session_id = session_id, .chars = try allocator.dupe(u8, chars_text), .yield_ms = yield_ms };
}

fn parseWebSearchInput(allocator: std.mem.Allocator, payload: []const u8) !WebSearchInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .query = try allocator.dupe(u8, trimmed), .limit = WEB_SEARCH_DEFAULT_RESULTS, .engine = .duckduckgo };
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

    const limit = sanitizeWebSearchLimit(jsonFieldU32(object, "limit") orelse jsonFieldU32(object, "count") orelse jsonFieldU32(object, "max_results") orelse WEB_SEARCH_DEFAULT_RESULTS);

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

fn parseViewImageInput(allocator: std.mem.Allocator, payload: []const u8) !ViewImageInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, trimMatchingOuterQuotes(trimmed)) };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("file") orelse return error.InvalidToolPayload;
    const path_text = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{ .path = try allocator.dupe(u8, trimMatchingOuterQuotes(std.mem.trim(u8, path_text, " \t\r\n"))) };
}

fn parseListDirInput(allocator: std.mem.Allocator, payload: []const u8) !ListDirInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, trimmed), .recursive = false, .max_entries = 200 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("dir") orelse return error.InvalidToolPayload;
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .recursive = jsonFieldBool(object, "recursive") orelse jsonFieldBool(object, "recurse") orelse false,
        .max_entries = sanitizeListDirMaxEntries(jsonFieldU32(object, "max_entries") orelse jsonFieldU32(object, "limit") orelse 200),
    };
}

fn parseReadFileInput(allocator: std.mem.Allocator, payload: []const u8) !ReadFileInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, trimmed), .max_bytes = 12 * 1024 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("file") orelse return error.InvalidToolPayload;
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .max_bytes = sanitizeReadFileMaxBytes(jsonFieldU32(object, "max_bytes") orelse jsonFieldU32(object, "limit") orelse 12 * 1024),
    };
}

fn parseGrepFilesInput(allocator: std.mem.Allocator, payload: []const u8) !GrepFilesInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .query = try allocator.dupe(u8, trimmed), .path = try allocator.dupe(u8, "."), .glob = null, .max_matches = 200 };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("pattern") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("dir") orelse std.json.Value{ .string = "." };
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const glob = if (object.get("glob")) |glob_value| switch (glob_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else null;

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .glob = if (glob) |g| try allocator.dupe(u8, std.mem.trim(u8, g, " \t\r\n")) else null,
        .max_matches = sanitizeGrepMatches(jsonFieldU32(object, "max_matches") orelse jsonFieldU32(object, "limit") orelse 200),
    };
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
        .max_files = sanitizeProjectSearchMaxFiles(jsonFieldU32(object, "max_files") orelse jsonFieldU32(object, "max_results") orelse 8),
        .max_matches = sanitizeProjectSearchMatches(jsonFieldU32(object, "max_matches") orelse jsonFieldU32(object, "max_hits") orelse 300),
    };
}

fn sanitizeCommandYieldMs(limit: u32) u32 {
    if (limit == 0) return COMMAND_TOOL_DEFAULT_YIELD_MS;
    return @min(limit, @as(u32, 5000));
}

fn sanitizeListDirMaxEntries(limit: u32) u16 {
    if (limit == 0) return 200;
    return @as(u16, @intCast(@min(limit, @as(u32, 1000))));
}

fn sanitizeReadFileMaxBytes(limit: u32) u32 {
    if (limit == 0) return 12 * 1024;
    return @min(limit, @as(u32, 256 * 1024));
}

fn sanitizeGrepMatches(limit: u32) u16 {
    if (limit == 0) return 200;
    return @as(u16, @intCast(@min(limit, @as(u32, 2000))));
}

fn sanitizeProjectSearchMaxFiles(limit: u32) u8 {
    if (limit == 0) return 8;
    return @as(u8, @intCast(@min(limit, @as(u32, 24))));
}

fn sanitizeProjectSearchMatches(limit: u32) u16 {
    if (limit == 0) return 300;
    return @as(u16, @intCast(@min(limit, @as(u32, 5000))));
}

fn sanitizeWebSearchLimit(limit: u32) u8 {
    if (limit == 0) return WEB_SEARCH_DEFAULT_RESULTS;
    return @as(u8, @intCast(@min(limit, WEB_SEARCH_MAX_RESULTS)));
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
    if (html_body.len > WEB_SEARCH_MAX_RESPONSE_BYTES) return error.ResponseTooLarge;

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

    const json_body = try readHttpResponseBodyAlloc(allocator, &response);
    defer allocator.free(json_body);
    if (json_body.len == 0) return error.EmptyResponseBody;
    if (json_body.len > WEB_SEARCH_MAX_RESPONSE_BYTES) return error.ResponseTooLarge;

    return parseExaJsonResults(allocator, json_body, limit);
}

fn readHttpResponseBodyAlloc(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
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

fn inspectImageFile(allocator: std.mem.Allocator, path: []const u8, include_hash: bool) !?ImageFileInfo {
    var file = openFileForPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const file_bytes: u64 = @intCast(stat.size);
    if (file_bytes == 0) return null;

    var header: [32]u8 = undefined;
    const header_len = try file.readAll(header[0..]);
    if (header_len == 0) return null;

    const format_info = inspectImageFormatFromHeader(header[0..header_len]) orelse return null;

    var info: ImageFileInfo = .{
        .bytes = file_bytes,
        .format = format_info.format,
        .mime = format_info.mime,
        .width = format_info.width,
        .height = format_info.height,
        .sha256_hex = null,
    };

    if (include_hash) {
        const content = try readFileAllAlloc(allocator, path, IMAGE_TOOL_MAX_FILE_BYTES);
        defer allocator.free(content);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        info.sha256_hex = try allocator.dupe(u8, &digest_hex);
    }

    return info;
}

fn readFileAllAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try openFileForPath(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_bytes);
    if (bytes.len == max_bytes) {
        const stat = try file.stat();
        if (stat.size > max_bytes) {
            allocator.free(bytes);
            return error.FileTooBig;
        }
    }
    return bytes;
}

const ImageFormatInfo = struct {
    format: []const u8,
    mime: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
};

fn inspectImageFormatFromHeader(header: []const u8) ?ImageFormatInfo {
    if (header.len >= 8 and std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n")) {
        const dims = parsePngDimensions(header);
        return .{ .format = "png", .mime = "image/png", .width = dims.width, .height = dims.height };
    }

    if (header.len >= 3 and header[0] == 0xff and header[1] == 0xd8 and header[2] == 0xff) {
        return .{ .format = "jpeg", .mime = "image/jpeg" };
    }

    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) {
        return .{ .format = "webp", .mime = "image/webp" };
    }

    if (header.len >= 6 and (std.mem.eql(u8, header[0..6], "GIF87a") or std.mem.eql(u8, header[0..6], "GIF89a"))) {
        const dims = parseGifDimensions(header);
        return .{ .format = "gif", .mime = "image/gif", .width = dims.width, .height = dims.height };
    }

    if (header.len >= 2 and header[0] == 'B' and header[1] == 'M') {
        return .{ .format = "bmp", .mime = "image/bmp" };
    }

    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "II*\x00")) {
        return .{ .format = "tiff", .mime = "image/tiff" };
    }
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "MM\x00*")) {
        return .{ .format = "tiff", .mime = "image/tiff" };
    }

    return null;
}

const ImageDimensions = struct {
    width: ?u32 = null,
    height: ?u32 = null,
};

fn parsePngDimensions(header: []const u8) ImageDimensions {
    if (header.len < 24) return .{};
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0) return .{};
    return .{ .width = width, .height = height };
}

fn parseGifDimensions(header: []const u8) ImageDimensions {
    if (header.len < 10) return .{};
    const width = std.mem.readInt(u16, header[6..8], .little);
    const height = std.mem.readInt(u16, header[8..10], .little);
    if (width == 0 or height == 0) return .{};
    return .{ .width = width, .height = height };
}

fn isOpenAiCompatibleProviderId(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") or
        std.mem.eql(u8, provider_id, "openrouter") or
        std.mem.eql(u8, provider_id, "opencode") or
        std.mem.eql(u8, provider_id, "zenmux");
}

fn defaultBaseUrlForProviderId(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider_id, "opencode")) return "https://opencode.ai/zen/v1";
    if (std.mem.eql(u8, provider_id, "zenmux")) return "https://zenmux.ai/api/v1";
    return null;
}

fn trimMatchingOuterQuotes(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    if (text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    if (text[0] == '\'' and text[text.len - 1] == '\'') return text[1 .. text.len - 1];
    return text;
}

fn jsonFieldU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else null,
        .float => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @as(u32, @intFromFloat(number)) else null,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch null,
        else => null,
    };
}

fn jsonFieldBool(object: std.json.ObjectMap, key: []const u8) ?bool {
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
