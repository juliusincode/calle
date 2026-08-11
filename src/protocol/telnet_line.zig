//! Framing for OpenOCD's telnet console (port 4444 by default).
//! Commands are newline-terminated, responses too. We additionally
//! filter out simple telnet IAC sequences (OpenOCD sends a bit of IAC
//! noise on connection setup, but after that it's basically plain
//! line text).

const std = @import("std");
const Transport = @import("../transport/transport.zig").Transport;

const IAC: u8 = 0xFF;
// IAC followed by WILL/WONT/DO/DONT (251..254) has one more option byte.
fn hasOptionByte(cmd: u8) bool {
    return cmd >= 251 and cmd <= 254;
}

pub const TelnetLineProtocol = struct {
    pub fn sendCommand(t: Transport, cmd: []const u8) !void {
        try t.writeAll(cmd);
        try t.writeAll("\n");
    }

    /// Reads one response line, IAC sequences are swallowed.
    /// `out` must be large enough for the response, otherwise
    /// error.ResponseTooLong.
    pub fn readResponse(t: Transport, out: []u8) ![]const u8 {
        var len: usize = 0;
        var byte: [1]u8 = undefined;

        while (true) {
            const n = try t.read(&byte);
            if (n == 0) break; // EOF

            const b = byte[0];

            if (b == IAC) {
                var cmd_buf: [1]u8 = undefined;
                if ((try t.read(&cmd_buf)) == 0) break;
                if (hasOptionByte(cmd_buf[0])) {
                    var opt_buf: [1]u8 = undefined;
                    if ((try t.read(&opt_buf)) == 0) break;
                }
                continue;
            }

            if (b == '\n') break;
            if (b == '\r') continue;

            if (len >= out.len) return error.ResponseTooLong;
            out[len] = b;
            len += 1;
        }

        return out[0..len];
    }

    /// Same framing as `readResponse`, but grows a heap-allocated buffer
    /// instead of failing on a fixed-size one. Use this for commands
    /// whose output length isn't known up front (e.g. long-running
    /// flash operations). Caller owns the returned slice.
    pub fn readResponseAlloc(t: Transport, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var byte: [1]u8 = undefined;

        while (true) {
            const n = try t.read(&byte);
            if (n == 0) break; // EOF

            const b = byte[0];

            if (b == IAC) {
                var cmd_buf: [1]u8 = undefined;
                if ((try t.read(&cmd_buf)) == 0) break;
                if (hasOptionByte(cmd_buf[0])) {
                    var opt_buf: [1]u8 = undefined;
                    if ((try t.read(&opt_buf)) == 0) break;
                }
                continue;
            }

            if (b == '\n') break;
            if (b == '\r') continue;

            try list.append(gpa, b);
        }

        return list.toOwnedSlice(gpa);
    }
};

test "sendCommand appends a newline" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    var mock = Mock.init("");
    try TelnetLineProtocol.sendCommand(mock.transport(), "halt");
    try std.testing.expectEqualStrings("halt\n", mock.written());
}

test "readResponse stops at newline and filters IAC" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    // IAC WILL ECHO (0xFF 0xFB 0x01) followed by "target halted\n"
    const script = [_]u8{
        0xFF, 0xFB, 0x01,
        't',  'a',  'r',
        'g',  'e',  't',
        ' ',  'h',  'a',
        'l',  't',  'e',
        'd',  '\n',
    };
    var mock = Mock.init(&script);
    var buf: [64]u8 = undefined;
    const resp = try TelnetLineProtocol.readResponse(mock.transport(), &buf);
    try std.testing.expectEqualStrings("target halted", resp);
}

test "readResponseAlloc grows past a size that would overflow a fixed buffer" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    // Longer than the 4-byte buffer used in the ResponseTooLong test below.
    var mock = Mock.init("a response too long for any small fixed buffer\n");
    const resp = try TelnetLineProtocol.readResponseAlloc(mock.transport(), std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("a response too long for any small fixed buffer", resp);
}

test "readResponse reports ResponseTooLong for a too-small buffer" {
    const Mock = @import("../transport/mock.zig").MockTransport;
    var mock = Mock.init("a response too long for the buffer\n");
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLong, TelnetLineProtocol.readResponse(mock.transport(), &buf));
}
