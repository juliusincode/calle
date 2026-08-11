//! Framing for OpenOCD's Tcl RPC interface (port 6666 by default).
//! Simpler than telnet: no IAC noise, commands and responses are
//! separated by a single 0x1a (Ctrl-Z) byte instead of a newline.
//! This is the port you should use for scripting/automation.

const std = @import("std");
const Transport = @import("../transport/transport.zig").Transport;

const DELIM: u8 = 0x1a;

pub const TclRpcProtocol = struct {
    pub fn sendCommand(t: Transport, cmd: []const u8) !void {
        try t.writeAll(cmd);
        try t.writeAll(&[_]u8{DELIM});
    }

    pub fn readResponse(t: Transport, out: []u8) ![]const u8 {
        var len: usize = 0;
        var byte: [1]u8 = undefined;

        while (true) {
            const n = try t.read(&byte);
            if (n == 0) break; // EOF
            if (byte[0] == DELIM) break;

            if (len >= out.len) return error.ResponseTooLong;
            out[len] = byte[0];
            len += 1;
        }

        return out[0..len];
    }

    /// Same framing as `readResponse`, but grows a heap-allocated buffer
    /// instead of failing on a fixed-size one. Use this for commands
    /// whose output length isn't known up front (e.g. `flash write_image`
    /// progress output). Caller owns the returned slice.
    pub fn readResponseAlloc(t: Transport, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var byte: [1]u8 = undefined;

        while (true) {
            const n = try t.read(&byte);
            if (n == 0) break; // EOF
            if (byte[0] == DELIM) break;

            try list.append(gpa, byte[0]);
        }

        return list.toOwnedSlice(gpa);
    }
};

test "sendCommand appends 0x1a" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    var mock = Mock.init("");
    try TclRpcProtocol.sendCommand(mock.transport(), "reset halt");
    try std.testing.expectEqualStrings("reset halt" ++ [_]u8{0x1a}, mock.written());
}

test "readResponseAlloc grows past a size that would overflow a fixed buffer" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const script = "a very long simulated flash-write progress log" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const resp = try TclRpcProtocol.readResponseAlloc(mock.transport(), std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("a very long simulated flash-write progress log", resp);
}

test "readResponse stops at 0x1a" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    const script = "target halted due to debug-request" ++ [_]u8{0x1a} ++ "rest is ignored";
    var mock = Mock.init(script);
    var buf: [64]u8 = undefined;
    const resp = try TclRpcProtocol.readResponse(mock.transport(), &buf);
    try std.testing.expectEqualStrings("target halted due to debug-request", resp);
}
