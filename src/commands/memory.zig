//! Generic memory access commands (as opposed to flash-specific ones
//! in commands/flash.zig). OpenOCD syntax (verified against the
//! OpenOCD User's Guide, "General Commands"):
//!
//!   mdw addr [count]   - display word(s)
//!   mww addr value     - write a word
//!   dump_image file address size - dump memory to a binary file

const std = @import("std");

/// Reads one or more 32-bit words starting at `addr`. `count` (if
/// given) is how many words to read; omit for a single word.
pub fn readWords(session: anytype, addr: u32, count: ?u32, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = if (count) |c|
        try std.fmt.bufPrint(&cmd_buf, "mdw 0x{x} {d}", .{ addr, c })
    else
        try std.fmt.bufPrint(&cmd_buf, "mdw 0x{x}", .{addr});
    return session.exec(cmd, out);
}

/// Writes a single 32-bit word to memory (memory-write-word).
pub fn writeWord(session: anytype, addr: u32, value: u32, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "mww 0x{x} 0x{x}", .{ addr, value });
    return session.exec(cmd, out);
}

/// Dumps `size` bytes of target memory starting at `addr` to `path`
/// on the machine running OpenOCD (not the local machine, if OpenOCD
/// is remote).
pub fn dumpImage(session: anytype, path: []const u8, addr: u32, size: u32, out: []u8) ![]const u8 {
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "dump_image {s} 0x{x} 0x{x}", .{ path, addr, size });
    return session.exec(cmd, out);
}

test "readWords without a count" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0x00000000" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try readWords(session, 0x20000000, null, &buf);

    try std.testing.expectEqualStrings("mdw 0x20000000" ++ [_]u8{0x1a}, mock.written());
}

test "readWords with a count" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "..." ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try readWords(session, 0x20000000, 4, &buf);

    try std.testing.expectEqualStrings("mdw 0x20000000 4" ++ [_]u8{0x1a}, mock.written());
}

test "writeWord formats address and value as hex" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try writeWord(session, 0x20000000, 0x1234, &buf);

    try std.testing.expectEqualStrings("mww 0x20000000 0x1234" ++ [_]u8{0x1a}, mock.written());
}

test "dumpImage" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "dumped 1024 bytes" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try dumpImage(session, "ram.bin", 0x20000000, 1024, &buf);

    try std.testing.expectEqualStrings("dumped 1024 bytes", resp);
    try std.testing.expectEqualStrings("dump_image ram.bin 0x20000000 0x400" ++ [_]u8{0x1a}, mock.written());
}
