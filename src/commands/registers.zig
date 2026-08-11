//! Register commands. OpenOCD's `reg` command triples as list/read/
//! write depending on how many arguments it gets - split here into
//! three explicitly-named functions instead, since "one function that
//! means three different things based on argument count" is exactly
//! the kind of ambiguity typed wrappers exist to remove.

const std = @import("std");

/// Lists all available registers with their current values.
pub fn list(session: anytype, out: []u8) ![]const u8 {
    return session.exec("reg", out);
}

pub fn read(session: anytype, name: []const u8, out: []u8) ![]const u8 {
    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "reg {s}", .{name});
    return session.exec(cmd, out);
}

pub fn write(session: anytype, name: []const u8, value: u32, out: []u8) ![]const u8 {
    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "reg {s} 0x{x}", .{ name, value });
    return session.exec(cmd, out);
}

test "list sends the bare reg command" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "..." ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try list(session, &buf);

    try std.testing.expectEqualStrings("reg" ++ [_]u8{0x1a}, mock.written());
}

test "read sends reg with the register name" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0x08000000" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try read(session, "pc", &buf);

    try std.testing.expectEqualStrings("0x08000000", resp);
    try std.testing.expectEqualStrings("reg pc" ++ [_]u8{0x1a}, mock.written());
}

test "write sends reg with name and hex-formatted value" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try write(session, "r0", 4096, &buf);

    try std.testing.expectEqualStrings("reg r0 0x1000" ++ [_]u8{0x1a}, mock.written());
}
