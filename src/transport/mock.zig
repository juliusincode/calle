//! MockTransport simulates a connection entirely in memory.
//! `in` is the script that the "server" (e.g. OpenOCD) is supposed to
//! send; anything the protocol layer writes ends up in `out_buf` and
//! can be inspected via `written()`. This lets us test the protocol
//! and session layers without ever opening a socket.

const std = @import("std");
const Transport = @import("transport.zig").Transport;

pub const MockTransport = struct {
    in: []const u8,
    in_pos: usize = 0,
    out_buf: [4096]u8 = undefined,
    out_len: usize = 0,
    /// When > 0, the next `write` call fails with error.SimulatedFailure
    /// and decrements this counter instead of writing. Used to test
    /// reconnect/retry logic deterministically without a real socket.
    fail_writes_remaining: usize = 0,

    pub fn init(script: []const u8) MockTransport {
        return .{ .in = script };
    }

    pub fn written(self: *const MockTransport) []const u8 {
        return self.out_buf[0..self.out_len];
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .read = readFn,
        .write = writeFn,
        .close = closeFn,
    };

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        if (self.in_pos >= self.in.len) return 0;
        const n = @min(buf.len, self.in.len - self.in_pos);
        @memcpy(buf[0..n], self.in[self.in_pos..][0..n]);
        self.in_pos += n;
        return n;
    }

    fn writeFn(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        if (self.fail_writes_remaining > 0) {
            self.fail_writes_remaining -= 1;
            return error.SimulatedFailure;
        }
        const space = self.out_buf.len - self.out_len;
        const n = @min(space, bytes.len);
        @memcpy(self.out_buf[self.out_len..][0..n], bytes[0..n]);
        self.out_len += n;
        return n;
    }

    fn closeFn(ptr: *anyopaque) void {
        _ = ptr;
    }
};

test "mock transport echoes writes and serves scripted reads" {
    var mock = MockTransport.init("hello");
    const t = mock.transport();

    try t.writeAll("ping");
    try std.testing.expectEqualStrings("ping", mock.written());

    var buf: [16]u8 = undefined;
    const n = try t.read(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    // EOF afterwards
    const n2 = try t.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n2);
}

test "mock transport can simulate a write failure on demand" {
    var mock = MockTransport.init("");
    mock.fail_writes_remaining = 1;
    const t = mock.transport();

    try std.testing.expectError(error.SimulatedFailure, t.writeAll("ping"));
    // The write never landed.
    try std.testing.expectEqualStrings("", mock.written());

    // The failure was one-shot; the next write succeeds normally.
    try t.writeAll("pong");
    try std.testing.expectEqualStrings("pong", mock.written());
}
