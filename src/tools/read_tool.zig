//! READ tool runner.

const std = @import("std");
const common = @import("common.zig");

pub fn run(app: anytype, command_text: []const u8) ![]u8 {
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
        .max_output_bytes = common.READ_TOOL_MAX_OUTPUT_BYTES,
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
