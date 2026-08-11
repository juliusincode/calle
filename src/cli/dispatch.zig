//! Maps a parsed `Subcommand` to the actual OpenOCD command string that
//! needs to be sent. Deliberately pure and side-effect free (no
//! Transport, no Session) so the mapping itself - the actual "typed
//! subcommand" value proposition - has direct unit test coverage,
//! independent of any networking concerns.

const std = @import("std");
const Subcommand = @import("args.zig").Subcommand;

pub const Error = error{
    /// `.repl` has no single command string - the caller is expected
    /// to branch on `.repl` before calling this.
    NotACommand,
} || std.fmt.BufPrintError;

/// Writes the OpenOCD command string for `subcommand` into `buf` and
/// returns the used portion. For subcommands with no parameters, the
/// returned slice may point directly at a string literal rather than
/// `buf` - callers should not assume the result lives in `buf`.
pub fn commandString(subcommand: Subcommand, buf: []u8) Error![]const u8 {
    return switch (subcommand) {
        .repl => error.NotACommand,
        .script => error.NotACommand,
        .halt => "halt",
        .resume_target => "resume",
        .targets => "targets",
        .reset => |mode| switch (mode) {
            .halt => "reset halt",
            .run => "reset run",
        },
        .flash_probe => "flash probe 0",
        .flash_info => "flash info 0",
        .flash_write => |w| if (w.addr) |addr|
            try std.fmt.bufPrint(buf, "flash write_image erase {s} 0x{x}", .{ w.path, addr })
        else
            try std.fmt.bufPrint(buf, "flash write_image erase {s}", .{w.path}),
        .flash_verify => |v| try std.fmt.bufPrint(buf, "verify_image {s}", .{v.path}),
        .reg_list => "reg",
        .reg_read => |r| try std.fmt.bufPrint(buf, "reg {s}", .{r.name}),
        .reg_write => |r| try std.fmt.bufPrint(buf, "reg {s} 0x{x}", .{ r.name, r.value }),
        .bp_list => "bp",
        .bp_set => |b| if (b.hw)
            try std.fmt.bufPrint(buf, "bp 0x{x} {d} hw", .{ b.addr, b.len })
        else
            try std.fmt.bufPrint(buf, "bp 0x{x} {d}", .{ b.addr, b.len }),
        .bp_remove => |b| try std.fmt.bufPrint(buf, "rbp 0x{x}", .{b.addr}),
        .wp_list => "wp",
        .wp_set => |w| if (w.mode) |m|
            try std.fmt.bufPrint(buf, "wp 0x{x} {d} {s}", .{ w.addr, w.len, @tagName(m) })
        else
            try std.fmt.bufPrint(buf, "wp 0x{x} {d}", .{ w.addr, w.len }),
        .wp_remove => |w| try std.fmt.bufPrint(buf, "rwp 0x{x}", .{w.addr}),
        .mem_read => |m| if (m.count) |c|
            try std.fmt.bufPrint(buf, "mdw 0x{x} {d}", .{ m.addr, c })
        else
            try std.fmt.bufPrint(buf, "mdw 0x{x}", .{m.addr}),
        .mem_write => |m| try std.fmt.bufPrint(buf, "mww 0x{x} 0x{x}", .{ m.addr, m.value }),
        .mem_dump => |m| try std.fmt.bufPrint(buf, "dump_image {s} 0x{x} 0x{x}", .{ m.path, m.addr, m.size }),
        .raw => |cmd| cmd,
    };
}

test "simple subcommands map to their fixed command strings" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("halt", try commandString(.halt, &buf));
    try std.testing.expectEqualStrings("resume", try commandString(.resume_target, &buf));
    try std.testing.expectEqualStrings("targets", try commandString(.targets, &buf));
    try std.testing.expectEqualStrings("reset halt", try commandString(.{ .reset = .halt }, &buf));
    try std.testing.expectEqualStrings("reset run", try commandString(.{ .reset = .run }, &buf));
    try std.testing.expectEqualStrings("flash probe 0", try commandString(.flash_probe, &buf));
    try std.testing.expectEqualStrings("flash info 0", try commandString(.flash_info, &buf));
}

test "flash write without an address" {
    var buf: [64]u8 = undefined;
    const cmd = try commandString(.{ .flash_write = .{ .path = "firmware.bin", .addr = null } }, &buf);
    try std.testing.expectEqualStrings("flash write_image erase firmware.bin", cmd);
}

test "flash write with an address" {
    var buf: [64]u8 = undefined;
    const cmd = try commandString(.{ .flash_write = .{ .path = "firmware.bin", .addr = 0x08000000 } }, &buf);
    try std.testing.expectEqualStrings("flash write_image erase firmware.bin 0x8000000", cmd);
}

test "flash verify" {
    var buf: [64]u8 = undefined;
    const cmd = try commandString(.{ .flash_verify = .{ .path = "firmware.bin" } }, &buf);
    try std.testing.expectEqualStrings("verify_image firmware.bin", cmd);
}

test "reg subcommands" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("reg", try commandString(.reg_list, &buf));
    try std.testing.expectEqualStrings("reg pc", try commandString(.{ .reg_read = .{ .name = "pc" } }, &buf));
    try std.testing.expectEqualStrings(
        "reg r0 0x1000",
        try commandString(.{ .reg_write = .{ .name = "r0", .value = 0x1000 } }, &buf),
    );
}

test "bp/rbp subcommands" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("bp", try commandString(.bp_list, &buf));
    try std.testing.expectEqualStrings(
        "bp 0x8000000 2",
        try commandString(.{ .bp_set = .{ .addr = 0x08000000, .len = 2, .hw = false } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "bp 0x8000000 4 hw",
        try commandString(.{ .bp_set = .{ .addr = 0x08000000, .len = 4, .hw = true } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "rbp 0x8000000",
        try commandString(.{ .bp_remove = .{ .addr = 0x08000000 } }, &buf),
    );
}

test "wp/rwp subcommands" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("wp", try commandString(.wp_list, &buf));
    try std.testing.expectEqualStrings(
        "wp 0x20000000 4",
        try commandString(.{ .wp_set = .{ .addr = 0x20000000, .len = 4, .mode = null } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "wp 0x20000000 4 w",
        try commandString(.{ .wp_set = .{ .addr = 0x20000000, .len = 4, .mode = .w } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "rwp 0x20000000",
        try commandString(.{ .wp_remove = .{ .addr = 0x20000000 } }, &buf),
    );
}

test "mem subcommands" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mdw 0x20000000",
        try commandString(.{ .mem_read = .{ .addr = 0x20000000, .count = null } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "mdw 0x20000000 8",
        try commandString(.{ .mem_read = .{ .addr = 0x20000000, .count = 8 } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "mww 0x20000000 0x1234",
        try commandString(.{ .mem_write = .{ .addr = 0x20000000, .value = 0x1234 } }, &buf),
    );
    try std.testing.expectEqualStrings(
        "dump_image ram.bin 0x20000000 0x400",
        try commandString(.{ .mem_dump = .{ .path = "ram.bin", .addr = 0x20000000, .size = 1024 } }, &buf),
    );
}

test "raw passes its argument through untouched, ignoring buf entirely" {
    var buf: [4]u8 = undefined; // deliberately too small to hold the command
    const cmd = try commandString(.{ .raw = "reset halt" }, &buf);
    try std.testing.expectEqualStrings("reset halt", cmd);
}

test "repl reports NotACommand" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotACommand, commandString(.repl, &buf));
}

test "script reports NotACommand (it drives multiple exec calls, not one)" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotACommand, commandString(.{ .script = .{ .path = "x" } }, &buf));
}

test "a too-small buffer reports NoSpaceLeft for parameterized commands" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        commandString(.{ .flash_write = .{ .path = "firmware.bin", .addr = null } }, &buf),
    );
}
