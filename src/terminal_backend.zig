//! Terminal input/raw-mode backend boundary for the current ANSI TUI.
//! This is the first step toward swapping in a libvaxis low-level backend.

const std = @import("std");
const keybindings = @import("keybindings.zig");

const KEY_UP_ARROW: u8 = keybindings.KEY_UP_ARROW;
const KEY_DOWN_ARROW: u8 = keybindings.KEY_DOWN_ARROW;
const KEY_PAGE_UP: u8 = keybindings.KEY_PAGE_UP;
const KEY_PAGE_DOWN: u8 = keybindings.KEY_PAGE_DOWN;

pub const RawMode = struct {
    original_termios: std.posix.termios,

    pub fn enable() !RawMode {
        const stdin_handle = std.fs.File.stdin().handle;
        const original = try std.posix.tcgetattr(stdin_handle);

        var raw = original;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_handle, .NOW, raw);
        return .{ .original_termios = original };
    }

    pub fn disable(self: *const RawMode) void {
        const stdin_handle = std.fs.File.stdin().handle;
        std.posix.tcsetattr(stdin_handle, .NOW, self.original_termios) catch {};
    }
};

pub fn stdinHasPendingByte(timeout_ms: i32) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.fs.File.stdin().handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = try std.posix.poll(&poll_fds, timeout_ms);
    return ready_count > 0 and (poll_fds[0].revents & std.posix.POLL.IN) == std.posix.POLL.IN;
}

pub fn mapEscapeSequenceToKey() !?u8 {
    if (!try stdinHasPendingByte(2)) return null;

    var second: [1]u8 = undefined;
    const second_read = try std.posix.read(std.fs.File.stdin().handle, second[0..]);
    if (second_read == 0) return null;
    if (second[0] != '[' and second[0] != 'O') return null;

    if (!try stdinHasPendingByte(2)) return null;

    var third: [1]u8 = undefined;
    const third_read = try std.posix.read(std.fs.File.stdin().handle, third[0..]);
    if (third_read == 0) return null;

    switch (third[0]) {
        'A' => return KEY_UP_ARROW,
        'B' => return KEY_DOWN_ARROW,
        '5', '6' => {
            if (second[0] != '[') return null;
            if (!try stdinHasPendingByte(2)) return null;

            var fourth: [1]u8 = undefined;
            const fourth_read = try std.posix.read(std.fs.File.stdin().handle, fourth[0..]);
            if (fourth_read == 0 or fourth[0] != '~') return null;

            return if (third[0] == '5') KEY_PAGE_UP else KEY_PAGE_DOWN;
        },
        else => return null,
    }
}
