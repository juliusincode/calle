//! Breakpoint and watchpoint commands. OpenOCD syntax (verified
//! against the OpenOCD User's Guide, "General Commands"):
//!
//!   bp [address len [hw]]   - list breakpoints, or set one
//!   rbp address             - remove a breakpoint
//!   wp [address len [(r|w|a)]] - list watchpoints, or set one
//!   rwp address              - remove a watchpoint

const std = @import("std");

pub const WatchMode = enum { r, w, a };

pub fn listBreakpoints(session: anytype, out: []u8) ![]const u8 {
    return session.exec("bp", out);
}

pub fn setBreakpoint(session: anytype, addr: u32, len: u32, hw: bool, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = if (hw)
        try std.fmt.bufPrint(&cmd_buf, "bp 0x{x} {d} hw", .{ addr, len })
    else
        try std.fmt.bufPrint(&cmd_buf, "bp 0x{x} {d}", .{ addr, len });
    return session.exec(cmd, out);
}

pub fn removeBreakpoint(session: anytype, addr: u32, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "rbp 0x{x}", .{addr});
    return session.exec(cmd, out);
}

pub fn listWatchpoints(session: anytype, out: []u8) ![]const u8 {
    return session.exec("wp", out);
}

pub fn setWatchpoint(session: anytype, addr: u32, len: u32, mode: ?WatchMode, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = if (mode) |m|
        try std.fmt.bufPrint(&cmd_buf, "wp 0x{x} {d} {s}", .{ addr, len, @tagName(m) })
    else
        try std.fmt.bufPrint(&cmd_buf, "wp 0x{x} {d}", .{ addr, len });
    return session.exec(cmd, out);
}

pub fn removeWatchpoint(session: anytype, addr: u32, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "rwp 0x{x}", .{addr});
    return session.exec(cmd, out);
}

test "listBreakpoints sends the bare bp command" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "..." ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try listBreakpoints(session, &buf);

    try std.testing.expectEqualStrings("bp" ++ [_]u8{0x1a}, mock.written());
}

test "setBreakpoint without hw" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try setBreakpoint(session, 0x08000000, 2, false, &buf);

    try std.testing.expectEqualStrings("bp 0x8000000 2" ++ [_]u8{0x1a}, mock.written());
}

test "setBreakpoint with hw appends the hw flag" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try setBreakpoint(session, 0x08000000, 4, true, &buf);

    try std.testing.expectEqualStrings("bp 0x8000000 4 hw" ++ [_]u8{0x1a}, mock.written());
}

test "removeBreakpoint" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try removeBreakpoint(session, 0x08000000, &buf);

    try std.testing.expectEqualStrings("rbp 0x8000000" ++ [_]u8{0x1a}, mock.written());
}

test "setWatchpoint with and without a mode" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    {
        const script = "0" ++ [_]u8{0x1a};
        var mock = Mock.init(script);
        const session = TclSession.init(mock.transport());
        var buf: [32]u8 = undefined;
        _ = try setWatchpoint(session, 0x20000000, 4, .w, &buf);
        try std.testing.expectEqualStrings("wp 0x20000000 4 w" ++ [_]u8{0x1a}, mock.written());
    }
    {
        const script = "0" ++ [_]u8{0x1a};
        var mock = Mock.init(script);
        const session = TclSession.init(mock.transport());
        var buf: [32]u8 = undefined;
        _ = try setWatchpoint(session, 0x20000000, 4, null, &buf);
        try std.testing.expectEqualStrings("wp 0x20000000 4" ++ [_]u8{0x1a}, mock.written());
    }
}

test "removeWatchpoint" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try removeWatchpoint(session, 0x20000000, &buf);

    try std.testing.expectEqualStrings("rwp 0x20000000" ++ [_]u8{0x1a}, mock.written());
}
