//! Flash-related OpenOCD commands. Split out from commands.zig to show
//! the intended extension pattern: one file per command "area"
//! (target control, flash, memory, ...), all built on the same
//! `session.exec(...)` primitive.

const std = @import("std");

pub fn probe(session: anytype, out: []u8) ![]const u8 {
    return session.exec("flash probe 0", out);
}

pub fn info(session: anytype, out: []u8) ![]const u8 {
    return session.exec("flash info 0", out);
}

/// Erases and writes `path` to flash, optionally at a specific address.
/// If `addr` is null, OpenOCD uses the address embedded in the image
/// (e.g. from an ELF file).
pub fn writeImage(session: anytype, path: []const u8, addr: ?u32, out: []u8) ![]const u8 {
    var cmd_buf: [256]u8 = undefined;
    const cmd = if (addr) |a|
        try std.fmt.bufPrint(&cmd_buf, "flash write_image erase {s} 0x{x}", .{ path, a })
    else
        try std.fmt.bufPrint(&cmd_buf, "flash write_image erase {s}", .{path});
    return session.exec(cmd, out);
}

pub fn verifyImage(session: anytype, path: []const u8, out: []u8) ![]const u8 {
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "verify_image {s}", .{path});
    return session.exec(cmd, out);
}

test "writeImage builds the erase+write command without an address" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try writeImage(session, "firmware.bin", null, &buf);

    try std.testing.expectEqualStrings(
        "flash write_image erase firmware.bin" ++ [_]u8{0x1a},
        mock.written(),
    );
}

test "writeImage includes the address when given" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const TclSession = @import("../session/session.zig").TclSession;

    const script = "0" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    _ = try writeImage(session, "firmware.bin", 0x08000000, &buf);

    try std.testing.expectEqualStrings(
        "flash write_image erase firmware.bin 0x8000000" ++ [_]u8{0x1a},
        mock.written(),
    );
}
