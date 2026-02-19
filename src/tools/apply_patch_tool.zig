//! APPLY_PATCH tool runner.

const std = @import("std");
const patch_tool = @import("patch_tool.zig");
const common = @import("common.zig");

const ApplyPatchPreview = struct {
    text: []u8,
    included_lines: usize,
    omitted_lines: usize,
};

pub fn run(app: anytype, patch_text: []const u8) ![]u8 {
    const trimmed_patch = std.mem.trim(u8, patch_text, " \t\r\n");
    if (trimmed_patch.len == 0) {
        return app.allocator.dupe(u8, "[apply-patch-result]\nerror: empty patch payload");
    }

    if (trimmed_patch.len > common.APPLY_PATCH_TOOL_MAX_PATCH_BYTES) {
        return std.fmt.allocPrint(
            app.allocator,
            "[apply-patch-result]\nerror: patch too large ({d} bytes > {d})",
            .{ trimmed_patch.len, common.APPLY_PATCH_TOOL_MAX_PATCH_BYTES },
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

    const preview = try buildApplyPatchPreview(app.allocator, trimmed_patch, common.APPLY_PATCH_PREVIEW_MAX_LINES);
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
