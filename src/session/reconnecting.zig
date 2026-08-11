//! A thin wrapper around `Session` that retries once with a freshly
//! established `Transport` if a command fails. This covers the common
//! case of OpenOCD (or the network path to it) dropping the
//! connection between commands - e.g. after a `reset` that also
//! power-cycles the debug adapter, or a transient network hiccup.
//!
//! The command itself is retried exactly once - a command failing
//! twice in a row is surfaced as a real error rather than silently
//! retried forever. *Establishing* a fresh connection can retry more
//! than once, though: `max_connect_attempts` controls how many times
//! `connect_fn` is called before giving up on a single reconnect, and
//! `delay_fn` (if set) is called between failed attempts - e.g. to
//! sleep with backoff. This is deliberately kept separate from actual
//! sleeping/timing concerns: `Reconnecting` itself stays free of any
//! `std.Io` dependency, so it's fully testable with `MockTransport`
//! and no real clock. See `TcpConnectCtx` in `src/main.zig` for how
//! the CLI wires in real delays via `std.Io.sleep`.

const std = @import("std");
const Transport = @import("../transport/transport.zig").Transport;
const session_mod = @import("session.zig");

pub fn Reconnecting(comptime ProtocolImpl: type) type {
    return struct {
        session: session_mod.Session(ProtocolImpl),
        connect_fn: *const fn (ctx: *anyopaque) anyerror!Transport,
        connect_ctx: *anyopaque,

        /// How many times to call `connect_fn` before giving up on a
        /// single reconnect attempt. 1 (the default) means "try once,
        /// no retries at the connection level."
        max_connect_attempts: u32 = 1,
        /// Called between failed connect attempts (never before the
        /// first, never after the last) with the 1-based attempt
        /// number that just failed. Typically used to sleep with
        /// backoff; left `null` for no delay.
        delay_fn: ?*const fn (ctx: *anyopaque, failed_attempt: u32) void = null,
        delay_ctx: *anyopaque = undefined,

        /// Incremented every time a reconnect succeeds; purely
        /// informational (e.g. for logging), never read internally.
        reconnect_count: u32 = 0,

        const Self = @This();

        pub fn init(
            transport: Transport,
            connect_ctx: *anyopaque,
            connect_fn: *const fn (ctx: *anyopaque) anyerror!Transport,
        ) Self {
            return .{
                .session = session_mod.Session(ProtocolImpl).init(transport),
                .connect_fn = connect_fn,
                .connect_ctx = connect_ctx,
            };
        }

        pub fn exec(self: *Self, cmd: []const u8, out: []u8) ![]const u8 {
            return self.session.exec(cmd, out) catch |first_err| blk: {
                self.reconnect() catch break :blk first_err;
                break :blk self.session.exec(cmd, out) catch first_err;
            };
        }

        pub fn execAlloc(self: *Self, gpa: std.mem.Allocator, cmd: []const u8) ![]u8 {
            return self.session.execAlloc(gpa, cmd) catch |first_err| blk: {
                self.reconnect() catch break :blk first_err;
                break :blk self.session.execAlloc(gpa, cmd) catch first_err;
            };
        }

        /// Tries `connect_fn` up to `max_connect_attempts` times,
        /// calling `delay_fn` between failed attempts. Returns the
        /// last attempt's error if all attempts fail.
        fn reconnect(self: *Self) !void {
            self.session.transport.close();

            var attempt: u32 = 1;
            while (true) : (attempt += 1) {
                if (self.connect_fn(self.connect_ctx)) |t| {
                    self.session.transport = t;
                    self.reconnect_count += 1;
                    return;
                } else |err| {
                    if (attempt >= self.max_connect_attempts) return err;
                    if (self.delay_fn) |d| d(self.delay_ctx, attempt);
                }
            }
        }

        pub fn close(self: *Self) void {
            self.session.close();
        }
    };
}

const MockTransport = @import("../transport/mock.zig").MockTransport;
const TclRpcProtocol = @import("../protocol/tcl_rpc.zig").TclRpcProtocol;

/// Test-only helper: a connect function backed by a fixed list of
/// mocks, handed out one at a time (simulating "the Nth (re)connect
/// attempt gets this transport"), with an optional number of
/// guaranteed failures before it starts succeeding, and a record of
/// which attempt numbers `delay_fn` was called with.
const MockConnector = struct {
    mocks: []MockTransport,
    next: usize = 0,
    fail_first_n: usize = 0,
    delay_calls: [8]u32 = undefined,
    delay_call_count: usize = 0,

    fn connect(ctx: *anyopaque) anyerror!Transport {
        const self: *MockConnector = @ptrCast(@alignCast(ctx));
        if (self.fail_first_n > 0) {
            self.fail_first_n -= 1;
            return error.SimulatedConnectFailure;
        }
        if (self.next >= self.mocks.len) return error.NoMoreMocks;
        const t = self.mocks[self.next].transport();
        self.next += 1;
        return t;
    }

    fn delay(ctx: *anyopaque, failed_attempt: u32) void {
        const self: *MockConnector = @ptrCast(@alignCast(ctx));
        if (self.delay_call_count < self.delay_calls.len) {
            self.delay_calls[self.delay_call_count] = failed_attempt;
            self.delay_call_count += 1;
        }
    }
};

test "exec succeeds directly without reconnecting when the transport is healthy" {
    const script = "0" ++ [_]u8{0x1a};
    var healthy = MockTransport.init(script);
    var mocks = [_]MockTransport{MockTransport.init("")};
    var connector = MockConnector{ .mocks = &mocks };

    var rs = Reconnecting(TclRpcProtocol).init(healthy.transport(), &connector, MockConnector.connect);

    var buf: [32]u8 = undefined;
    const resp = try rs.exec("targets", &buf);

    try std.testing.expectEqualStrings("0", resp);
    try std.testing.expectEqual(@as(u32, 0), rs.reconnect_count);
}

test "exec reconnects once and retries after a write failure" {
    var dead = MockTransport.init("");
    dead.fail_writes_remaining = 1;

    const script = "0" ++ [_]u8{0x1a};
    var mocks = [_]MockTransport{MockTransport.init(script)};

    var connector = MockConnector{ .mocks = &mocks };
    var rs = Reconnecting(TclRpcProtocol).init(dead.transport(), &connector, MockConnector.connect);

    var buf: [32]u8 = undefined;
    const resp = try rs.exec("targets", &buf);

    try std.testing.expectEqualStrings("0", resp);
    try std.testing.expectEqual(@as(u32, 1), rs.reconnect_count);
    try std.testing.expectEqualStrings("targets" ++ [_]u8{0x1a}, mocks[0].written());
}

test "exec surfaces the original error if the retry also fails" {
    var dead = MockTransport.init("");
    dead.fail_writes_remaining = 1;
    var also_dead_arr = [_]MockTransport{MockTransport.init("")};
    also_dead_arr[0].fail_writes_remaining = 1;

    var connector = MockConnector{ .mocks = &also_dead_arr };
    var rs = Reconnecting(TclRpcProtocol).init(dead.transport(), &connector, MockConnector.connect);

    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.SimulatedFailure, rs.exec("targets", &buf));
    try std.testing.expectEqual(@as(u32, 1), rs.reconnect_count);
}

test "execAlloc also reconnects and retries on failure" {
    var dead = MockTransport.init("");
    dead.fail_writes_remaining = 1;

    const script = "long response after reconnect" ++ [_]u8{0x1a};
    var mocks = [_]MockTransport{MockTransport.init(script)};

    var connector = MockConnector{ .mocks = &mocks };
    var rs = Reconnecting(TclRpcProtocol).init(dead.transport(), &connector, MockConnector.connect);

    const resp = try rs.execAlloc(std.testing.allocator, "targets");
    defer std.testing.allocator.free(resp);

    try std.testing.expectEqualStrings("long response after reconnect", resp);
    try std.testing.expectEqual(@as(u32, 1), rs.reconnect_count);
}

test "reconnect retries the connection itself up to max_connect_attempts, with delay_fn between failures" {
    var dead = MockTransport.init("");
    dead.fail_writes_remaining = 1;

    const script = "0" ++ [_]u8{0x1a};
    var mocks = [_]MockTransport{MockTransport.init(script)};

    var connector = MockConnector{ .mocks = &mocks, .fail_first_n = 2 };
    var rs = Reconnecting(TclRpcProtocol).init(dead.transport(), &connector, MockConnector.connect);
    rs.max_connect_attempts = 3;
    rs.delay_fn = MockConnector.delay;
    rs.delay_ctx = &connector;

    var buf: [32]u8 = undefined;
    const resp = try rs.exec("targets", &buf);

    try std.testing.expectEqualStrings("0", resp);
    // Exactly one successful reconnect, even though it took 3 underlying
    // connect() calls (2 failures + 1 success) to get there.
    try std.testing.expectEqual(@as(u32, 1), rs.reconnect_count);
    try std.testing.expectEqual(@as(usize, 2), connector.delay_call_count);
    try std.testing.expectEqual(@as(u32, 1), connector.delay_calls[0]);
    try std.testing.expectEqual(@as(u32, 2), connector.delay_calls[1]);
}

test "reconnect gives up after max_connect_attempts and exec surfaces the original command error" {
    var dead = MockTransport.init("");
    dead.fail_writes_remaining = 1;

    var connector = MockConnector{ .mocks = &.{}, .fail_first_n = 10 };
    var rs = Reconnecting(TclRpcProtocol).init(dead.transport(), &connector, MockConnector.connect);
    rs.max_connect_attempts = 3;
    rs.delay_fn = MockConnector.delay;
    rs.delay_ctx = &connector;

    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.SimulatedFailure, rs.exec("targets", &buf));

    try std.testing.expectEqual(@as(u32, 0), rs.reconnect_count);
    // delay_fn runs between failures, so twice for three total attempts.
    try std.testing.expectEqual(@as(usize, 2), connector.delay_call_count);
}
