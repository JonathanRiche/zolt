//! VIEW_IMAGE tool runner.

const std = @import("std");
const common = @import("common.zig");

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

pub fn run(app: anytype, payload: []const u8) ![]u8 {
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

    if (common.isOpenAiCompatibleProviderId(app.app_state.selected_provider_id)) {
        const api_key = try app.resolveApiKey(app.app_state.selected_provider_id);
        defer if (api_key) |key| app.allocator.free(key);

        if (api_key) |key| {
            const provider_info = app.catalog.findProviderConst(app.app_state.selected_provider_id);
            const base_url = if (provider_info) |info|
                (info.api_base orelse common.defaultBaseUrlForProviderId(app.app_state.selected_provider_id) orelse "")
            else
                (common.defaultBaseUrlForProviderId(app.app_state.selected_provider_id) orelse "");
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

fn parseViewImageInput(allocator: std.mem.Allocator, payload: []const u8) !ViewImageInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{ .path = try allocator.dupe(u8, common.trimMatchingOuterQuotes(trimmed)) };
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

    return .{ .path = try allocator.dupe(u8, common.trimMatchingOuterQuotes(std.mem.trim(u8, path_text, " \t\r\n"))) };
}

fn inspectImageFile(allocator: std.mem.Allocator, path: []const u8, include_hash: bool) !?ImageFileInfo {
    var file = common.openFileForPath(path, .{}) catch |err| switch (err) {
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
        const content = try readFileAllAlloc(allocator, path, common.IMAGE_TOOL_MAX_FILE_BYTES);
        defer allocator.free(content);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        info.sha256_hex = try allocator.dupe(u8, &digest_hex);
    }

    return info;
}

fn readFileAllAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try common.openFileForPath(path, .{});
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
