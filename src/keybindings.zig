//! Configurable keybinding defaults and parser helpers.

const std = @import("std");

pub const KEY_UP_ARROW: u8 = 243;
pub const KEY_DOWN_ARROW: u8 = 244;
pub const KEY_PAGE_UP: u8 = 245;
pub const KEY_PAGE_DOWN: u8 = 246;

pub const NormalKeybindings = struct {
    quit: u8 = 'q',
    insert_mode: u8 = 'i',
    append_mode: u8 = 'a',
    cursor_left: u8 = 'h',
    cursor_right: u8 = 'l',
    delete_char: u8 = 'x',
    scroll_up: u8 = 'k',
    scroll_down: u8 = 'j',
    strip_left: u8 = 'H',
    strip_right: u8 = 'L',
    command_palette: u8 = 16, // Ctrl-P
    slash_command: u8 = '/',
};

pub const InsertKeybindings = struct {
    escape: u8 = 27,
    backspace: u8 = 127,
    submit: u8 = '\n',
    accept_picker: u8 = '\t',
    picker_prev_or_palette: u8 = 16, // Ctrl-P
    picker_next: u8 = 14, // Ctrl-N
    paste_image: u8 = 22, // Ctrl-V
};

pub const Keybindings = struct {
    normal: NormalKeybindings = .{},
    insert: InsertKeybindings = .{},
};

pub fn parseKeyByte(name: []const u8) !u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidKeybindingValue;

    if (trimmed.len == 1) {
        return trimmed[0];
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "esc") or std.ascii.eqlIgnoreCase(trimmed, "escape")) return 27;
    if (std.ascii.eqlIgnoreCase(trimmed, "enter") or std.ascii.eqlIgnoreCase(trimmed, "return")) return '\n';
    if (std.ascii.eqlIgnoreCase(trimmed, "tab")) return '\t';
    if (std.ascii.eqlIgnoreCase(trimmed, "backspace") or std.ascii.eqlIgnoreCase(trimmed, "delete")) return 127;
    if (std.ascii.eqlIgnoreCase(trimmed, "space")) return ' ';
    if (std.ascii.eqlIgnoreCase(trimmed, "up")) return KEY_UP_ARROW;
    if (std.ascii.eqlIgnoreCase(trimmed, "down")) return KEY_DOWN_ARROW;
    if (std.ascii.eqlIgnoreCase(trimmed, "pgup") or std.ascii.eqlIgnoreCase(trimmed, "pageup")) return KEY_PAGE_UP;
    if (std.ascii.eqlIgnoreCase(trimmed, "pgdn") or std.ascii.eqlIgnoreCase(trimmed, "pagedown")) return KEY_PAGE_DOWN;

    if (trimmed.len == 6 and std.ascii.eqlIgnoreCase(trimmed[0..5], "ctrl-")) {
        const key_char = trimmed[5];
        if (!std.ascii.isAlphabetic(key_char)) return error.InvalidKeybindingValue;
        const lower = std.ascii.toLower(key_char);
        return @as(u8, lower - 'a' + 1);
    }

    return error.InvalidKeybindingValue;
}

test "parseKeyByte supports named keys" {
    try std.testing.expectEqual(@as(u8, 27), try parseKeyByte("esc"));
    try std.testing.expectEqual(@as(u8, '\n'), try parseKeyByte("enter"));
    try std.testing.expectEqual(@as(u8, '\t'), try parseKeyByte("tab"));
    try std.testing.expectEqual(@as(u8, 127), try parseKeyByte("backspace"));
    try std.testing.expectEqual(@as(u8, KEY_UP_ARROW), try parseKeyByte("up"));
    try std.testing.expectEqual(@as(u8, KEY_PAGE_DOWN), try parseKeyByte("pgdn"));
}

test "parseKeyByte supports ctrl and single-character keys" {
    try std.testing.expectEqual(@as(u8, 16), try parseKeyByte("ctrl-p"));
    try std.testing.expectEqual(@as(u8, 22), try parseKeyByte("CTRL-V"));
    try std.testing.expectEqual(@as(u8, 'q'), try parseKeyByte("q"));
    try std.testing.expectEqual(@as(u8, 'H'), try parseKeyByte("H"));
}

test "parseKeyByte rejects invalid inputs" {
    try std.testing.expectError(error.InvalidKeybindingValue, parseKeyByte(""));
    try std.testing.expectError(error.InvalidKeybindingValue, parseKeyByte("ctrl-1"));
    try std.testing.expectError(error.InvalidKeybindingValue, parseKeyByte("ctrl-aa"));
    try std.testing.expectError(error.InvalidKeybindingValue, parseKeyByte("nonsense-key"));
}
