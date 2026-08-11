//! Session wires Transport + Protocol together into a simple
//! request/response cycle. Generic over the protocol so telnet- and
//! Tcl-RPC-based sessions can share the exact same code.

const std = @import("std");
const Transport = @import("../transport/transport.zig").Transport;

pub fn Session(comptime ProtocolImpl: type) type {
    return struct {
        transport: Transport,

        const Self = @This();

        pub fn init(t: Transport) Self {
            return .{ .transport = t };
        }

        /// Sends `cmd`, waits for the response and writes it into `out`.
        /// The returned slice points into `out` - its lifetime is the
        /// caller's responsibility.
        pub fn exec(self: Self, cmd: []const u8, out: []u8) ![]const u8 {
            try ProtocolImpl.sendCommand(self.transport, cmd);
            return ProtocolImpl.readResponse(self.transport, out);
        }

        /// Same as `exec`, but grows a heap-allocated buffer instead of
        /// writing into a caller-provided fixed one. Use this when the
        /// response length isn't known up front. Caller owns the
        /// returned slice and must free it.
        pub fn execAlloc(self: Self, gpa: std.mem.Allocator, cmd: []const u8) ![]u8 {
            try ProtocolImpl.sendCommand(self.transport, cmd);
            return ProtocolImpl.readResponseAlloc(self.transport, gpa);
        }

        pub fn close(self: Self) void {
            self.transport.close();
        }
    };
}

pub const TelnetSession = Session(@import("../protocol/telnet_line.zig").TelnetLineProtocol);
pub const TclSession = Session(@import("../protocol/tcl_rpc.zig").TclRpcProtocol);

pub const Reconnecting = @import("reconnecting.zig").Reconnecting;
pub const ReconnectingTclSession = Reconnecting(@import("../protocol/tcl_rpc.zig").TclRpcProtocol);

test {
    // See the `refAllDecls is not recursive` note in commands.zig -
    // reconnecting.zig's own tests need this to actually run.
    std.testing.refAllDecls(@This());
}

test "TclSession exec sends a command and returns the response" {
    const Mock = @import("../transport/mock.zig").MockTransport;

    const script = "0" ++ [_]u8{0x1a}; // typical OpenOCD "0" for success
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try session.exec("targets", &buf);

    try std.testing.expectEqualStrings("0", resp);
    try std.testing.expectEqualStrings("targets" ++ [_]u8{0x1a}, mock.written());
}

test "TclSession execAlloc grows past what a small fixed buffer could hold" {
    const Mock = @import("../transport/mock.zig").MockTransport;

    const script = "a long response that would not fit in a tiny buffer" ++ [_]u8{0x1a};
    var mock = Mock.init(script);
    const session = TclSession.init(mock.transport());

    const resp = try session.execAlloc(std.testing.allocator, "targets");
    defer std.testing.allocator.free(resp);

    try std.testing.expectEqualStrings("a long response that would not fit in a tiny buffer", resp);
}

test "TelnetSession exec works the same way with newline framing" {
    const Mock = @import("../transport/mock.zig").MockTransport;

    var mock = Mock.init("target halted\n");
    const session = TelnetSession.init(mock.transport());

    var buf: [32]u8 = undefined;
    const resp = try session.exec("halt", &buf);

    try std.testing.expectEqualStrings("target halted", resp);
    try std.testing.expectEqualStrings("halt\n", mock.written());
}
