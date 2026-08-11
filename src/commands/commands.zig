//! Typed building blocks for common OpenOCD commands, so application
//! code doesn't need raw strings like "reset halt\n" scattered
//! everywhere.
//!
//! Extend as needed: just add a new function here (or in a new file
//! like commands/flash.zig) that internally calls `session.exec(...)`.
//! Works with any session, telnet- or Tcl-RPC-based (comptime
//! `anytype`).

const std = @import("std");

/// Flash-specific commands live in their own file; reachable as
/// `commands.flash.writeImage(...)` etc.
pub const flash = @import("flash.zig");
/// Register read/write/list; `commands.registers.read(...)` etc.
pub const registers = @import("registers.zig");
/// Breakpoints and watchpoints; `commands.breakpoints.setBreakpoint(...)` etc.
pub const breakpoints = @import("breakpoints.zig");
/// Generic (non-flash) memory access; `commands.memory.readWords(...)` etc.
pub const memory = @import("memory.zig");

pub fn halt(session: anytype, out: []u8) ![]const u8 {
    return session.exec("halt", out);
}

pub fn resetHalt(session: anytype, out: []u8) ![]const u8 {
    return session.exec("reset halt", out);
}

pub fn resetRun(session: anytype, out: []u8) ![]const u8 {
    return session.exec("reset run", out);
}

pub fn resumeTarget(session: anytype, out: []u8) ![]const u8 {
    return session.exec("resume", out);
}

pub fn targets(session: anytype, out: []u8) ![]const u8 {
    return session.exec("targets", out);
}

/// Fallback for anything that doesn't have a typed helper yet.
pub fn raw(session: anytype, cmd: []const u8, out: []u8) ![]const u8 {
    return session.exec(cmd, out);
}

test "resetHalt sends the right command" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try resetHalt(session, &buf);

    try std.testing.expectEqualStrings("0", resp);
    try std.testing.expectEqualStrings("reset halt" ++ [_]u8{0x1a}, mock.written());
}

test {
    // `std.testing.refAllDecls` only walks one level deep, so each
    // "hub" file that re-exports sub-modules (like `flash` here) needs
    // its own call to make sure nested files' tests get registered too.
    std.testing.refAllDecls(@This());
}

test "raw allows arbitrary commands" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "42" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try raw(session, "mww 0x20000000 0x1234", &buf);

    try std.testing.expectEqualStrings("42", resp);
}
