//! Optional startup configuration loaded from JSONC.

const std = @import("std");
const keybindings = @import("keybindings.zig");

pub const Theme = enum {
    codex,
    plain,
    forest,
};

pub const UiMode = enum {
    compact,
    comfy,
};

pub const OpenAiAuthMode = enum {
    auto,
    api_key,
    codex,
};

pub const Config = struct {
    provider_id: ?[]u8 = null,
    model_id: ?[]u8 = null,
    theme: ?Theme = null,
    ui_mode: ?UiMode = null,
    openai_auth_mode: ?OpenAiAuthMode = null,
    keybindings: ?keybindings.Keybindings = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.provider_id) |provider_id| allocator.free(provider_id);
        if (self.model_id) |model_id| allocator.free(model_id);
    }
};

const RawConfig = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    default_provider_id: ?[]const u8 = null,
    default_model_id: ?[]const u8 = null,
    selected_provider_id: ?[]const u8 = null,
    selected_model_id: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    ui: ?[]const u8 = null,
    ui_mode: ?[]const u8 = null,
    compact_mode: ?bool = null,
    openai_auth: ?[]const u8 = null,
    openai_auth_mode: ?[]const u8 = null,
    keybindings: ?RawKeybindings = null,
    hotkeys: ?RawKeybindings = null,
};

const RawKeybindings = struct {
    normal: ?RawNormalKeybindings = null,
    insert: ?RawInsertKeybindings = null,
};

const RawNormalKeybindings = struct {
    quit: ?[]const u8 = null,
    insert_mode: ?[]const u8 = null,
    append_mode: ?[]const u8 = null,
    cursor_left: ?[]const u8 = null,
    cursor_right: ?[]const u8 = null,
    delete_char: ?[]const u8 = null,
    scroll_up: ?[]const u8 = null,
    scroll_down: ?[]const u8 = null,
    strip_left: ?[]const u8 = null,
    strip_right: ?[]const u8 = null,
    command_palette: ?[]const u8 = null,
    slash_command: ?[]const u8 = null,
};

const RawInsertKeybindings = struct {
    escape: ?[]const u8 = null,
    backspace: ?[]const u8 = null,
    submit: ?[]const u8 = null,
    accept_picker: ?[]const u8 = null,
    picker_prev_or_palette: ?[]const u8 = null,
    picker_next: ?[]const u8 = null,
    paste_image: ?[]const u8 = null,
};

pub fn loadOptionalFromPath(allocator: std.mem.Allocator, path: []const u8) !?Config {
    var file = openFileForPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);
    var content_writer: std.Io.Writer.Allocating = .init(allocator);
    defer content_writer.deinit();

    _ = try reader.interface.streamRemaining(&content_writer.writer);
    const content = try content_writer.toOwnedSlice();
    defer allocator.free(content);

    return @as(?Config, try parseConfigJsonc(allocator, content));
}

fn parseConfigJsonc(allocator: std.mem.Allocator, text: []const u8) !Config {
    const stripped = try stripJsonCommentsAlloc(allocator, text);
    defer allocator.free(stripped);

    const parsed = try std.json.parseFromSlice(RawConfig, allocator, stripped, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    });
    defer parsed.deinit();

    return configFromRaw(allocator, parsed.value);
}

fn configFromRaw(allocator: std.mem.Allocator, raw: RawConfig) !Config {
    var config: Config = .{};
    errdefer config.deinit(allocator);

    const provider_source = raw.provider orelse raw.default_provider_id orelse raw.selected_provider_id;
    const model_source = raw.model orelse raw.default_model_id orelse raw.selected_model_id;

    config.provider_id = try dupeTrimmedIfNotEmpty(allocator, provider_source);
    config.model_id = try dupeTrimmedIfNotEmpty(allocator, model_source);

    if (raw.theme) |theme_name| {
        const parsed_theme = parseThemeName(theme_name) orelse return error.InvalidThemeName;
        config.theme = parsed_theme;
    }

    if (raw.ui orelse raw.ui_mode) |ui_name| {
        const parsed_ui = parseUiModeName(ui_name) orelse return error.InvalidUiMode;
        config.ui_mode = parsed_ui;
    } else if (raw.compact_mode) |compact_mode| {
        config.ui_mode = if (compact_mode) .compact else .comfy;
    }

    if (raw.openai_auth orelse raw.openai_auth_mode) |auth_mode_name| {
        const parsed = parseOpenAiAuthModeName(auth_mode_name) orelse return error.InvalidOpenAiAuthMode;
        config.openai_auth_mode = parsed;
    }

    if (raw.keybindings orelse raw.hotkeys) |raw_keybindings| {
        config.keybindings = try parseKeybindings(raw_keybindings);
    }

    return config;
}

fn parseKeybindings(raw: RawKeybindings) !keybindings.Keybindings {
    var parsed: keybindings.Keybindings = .{};

    if (raw.normal) |normal| {
        if (normal.quit) |value| parsed.normal.quit = try keybindings.parseKeyByte(value);
        if (normal.insert_mode) |value| parsed.normal.insert_mode = try keybindings.parseKeyByte(value);
        if (normal.append_mode) |value| parsed.normal.append_mode = try keybindings.parseKeyByte(value);
        if (normal.cursor_left) |value| parsed.normal.cursor_left = try keybindings.parseKeyByte(value);
        if (normal.cursor_right) |value| parsed.normal.cursor_right = try keybindings.parseKeyByte(value);
        if (normal.delete_char) |value| parsed.normal.delete_char = try keybindings.parseKeyByte(value);
        if (normal.scroll_up) |value| parsed.normal.scroll_up = try keybindings.parseKeyByte(value);
        if (normal.scroll_down) |value| parsed.normal.scroll_down = try keybindings.parseKeyByte(value);
        if (normal.strip_left) |value| parsed.normal.strip_left = try keybindings.parseKeyByte(value);
        if (normal.strip_right) |value| parsed.normal.strip_right = try keybindings.parseKeyByte(value);
        if (normal.command_palette) |value| parsed.normal.command_palette = try keybindings.parseKeyByte(value);
        if (normal.slash_command) |value| parsed.normal.slash_command = try keybindings.parseKeyByte(value);
    }

    if (raw.insert) |insert| {
        if (insert.escape) |value| parsed.insert.escape = try keybindings.parseKeyByte(value);
        if (insert.backspace) |value| parsed.insert.backspace = try keybindings.parseKeyByte(value);
        if (insert.submit) |value| parsed.insert.submit = try keybindings.parseKeyByte(value);
        if (insert.accept_picker) |value| parsed.insert.accept_picker = try keybindings.parseKeyByte(value);
        if (insert.picker_prev_or_palette) |value| parsed.insert.picker_prev_or_palette = try keybindings.parseKeyByte(value);
        if (insert.picker_next) |value| parsed.insert.picker_next = try keybindings.parseKeyByte(value);
        if (insert.paste_image) |value| parsed.insert.paste_image = try keybindings.parseKeyByte(value);
    }

    return parsed;
}

fn dupeTrimmedIfNotEmpty(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const source = value orelse return null;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn parseThemeName(input: []const u8) ?Theme {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(trimmed, "plain")) return .plain;
    if (std.ascii.eqlIgnoreCase(trimmed, "forest")) return .forest;
    return null;
}

fn parseUiModeName(input: []const u8) ?UiMode {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "compact")) return .compact;
    if (std.ascii.eqlIgnoreCase(trimmed, "comfy")) return .comfy;
    return null;
}

fn parseOpenAiAuthModeName(input: []const u8) ?OpenAiAuthMode {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "api_key")) return .api_key;
    if (std.ascii.eqlIgnoreCase(trimmed, "codex")) return .codex;
    return null;
}

fn stripJsonCommentsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var in_string = false;
    var escaped = false;
    var in_line_comment = false;
    var in_block_comment = false;

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        const next = if (index + 1 < input.len) input[index + 1] else 0;

        if (in_line_comment) {
            if (byte == '\n') {
                in_line_comment = false;
                try output.append(allocator, byte);
            }
            continue;
        }

        if (in_block_comment) {
            if (byte == '*' and next == '/') {
                in_block_comment = false;
                index += 1;
                continue;
            }
            if (byte == '\n') {
                try output.append(allocator, byte);
            }
            continue;
        }

        if (in_string) {
            try output.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        if (byte == '"') {
            in_string = true;
            try output.append(allocator, byte);
            continue;
        }

        if (byte == '/' and next == '/') {
            in_line_comment = true;
            index += 1;
            continue;
        }

        if (byte == '/' and next == '*') {
            in_block_comment = true;
            index += 1;
            continue;
        }

        try output.append(allocator, byte);
    }

    if (in_block_comment) return error.UnterminatedBlockComment;

    return output.toOwnedSlice(allocator);
}

fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags);
    }
    return std.fs.cwd().openFile(path, flags);
}

test "parse jsonc config with comments and aliases" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  // startup defaults
        \\  "default_provider_id": "openai",
        \\  "selected_model_id": "gpt-4.1",
        \\  "theme": "plain",
        \\  /* legacy bool form */
        \\  "compact_mode": false,
        \\  "openai_auth": "codex"
        \\}
    ;

    var config = try parseConfigJsonc(allocator, input);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("openai", config.provider_id.?);
    try std.testing.expectEqualStrings("gpt-4.1", config.model_id.?);
    try std.testing.expect(config.theme.? == .plain);
    try std.testing.expect(config.ui_mode.? == .comfy);
    try std.testing.expect(config.openai_auth_mode.? == .codex);
}

test "stripJsonCommentsAlloc preserves comment-like text inside strings" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "message": "literal // not a comment and /* not block */",
        \\  // real comment
        \\  "ui": "compact"
        \\}
    ;

    const stripped = try stripJsonCommentsAlloc(allocator, input);
    defer allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "literal // not a comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "\"ui\": \"compact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "real comment") == null);
}

test "parse jsonc keybindings overrides" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "keybindings": {
        \\    "normal": {
        \\      "quit": "x",
        \\      "command_palette": "ctrl-o"
        \\    },
        \\    "insert": {
        \\      "picker_next": "ctrl-j",
        \\      "paste_image": "ctrl-y"
        \\    }
        \\  }
        \\}
    ;

    var config = try parseConfigJsonc(allocator, input);
    defer config.deinit(allocator);

    const bindings = config.keybindings.?;
    try std.testing.expectEqual(@as(u8, 'x'), bindings.normal.quit);
    try std.testing.expectEqual(@as(u8, 15), bindings.normal.command_palette);
    try std.testing.expectEqual(@as(u8, 10), bindings.insert.picker_next);
    try std.testing.expectEqual(@as(u8, 25), bindings.insert.paste_image);
}

test "parse jsonc openai auth aliases" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "openai_auth_mode": "api_key"
        \\}
    ;

    var config = try parseConfigJsonc(allocator, input);
    defer config.deinit(allocator);

    try std.testing.expect(config.openai_auth_mode != null);
    try std.testing.expect(config.openai_auth_mode.? == .api_key);
}
