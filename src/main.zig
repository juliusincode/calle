//! calle CLI - talks to OpenOCD over its Tcl-RPC port.
//!
//! See `calle.cli.args.usage_text` (also printed by `-h`/`--help`) for
//! usage. Argument parsing itself lives in src/cli/args.zig, where it
//! has real unit test coverage - this file just wires stdin/stdout/the
//! network to that logic.
//!
//! Verified against the real Zig 0.16.0 compiler, including an
//! end-to-end smoke test against a fake OpenOCD server.

const std = @import("std");
const calle = @import("calle");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();

    const config_file = readConfigFile(io, init.arena.allocator()) catch |err| {
        std.log.err("failed to parse .calle.conf: {t}", .{err});
        std.process.exit(1);
    };

    const action = calle.cli.args.parse(
        args,
        config_file.host orelse init.environ_map.get("CALLE_HOST"),
        // parseInt below turns a port number back into a string so it
        // can flow through the same fallback slot as CALLE_PORT - a
        // bit roundabout, but keeps cli.args.parse's signature (and
        // its precedence logic) untouched by adding a third source.
        blk: {
            if (config_file.port) |p| {
                break :blk try std.fmt.allocPrint(init.arena.allocator(), "{d}", .{p});
            }
            break :blk init.environ_map.get("CALLE_PORT");
        },
    ) catch |err| {
        std.log.err("{t}", .{err});
        try stdout.writeStreamingAll(io, calle.cli.args.usage_text);
        std.process.exit(1);
    };

    const run = switch (action) {
        .help => {
            try stdout.writeStreamingAll(io, calle.cli.args.usage_text);
            return;
        },
        .run => |r| r,
    };

    if (run.config.verbosity >= 1) {
        std.log.info("connecting to {s}:{d}", .{ run.config.host, run.config.port });
    }

    var connect_ctx = TcpConnectCtx{
        .io = io,
        .gpa = gpa,
        .host = run.config.host,
        .port = run.config.port,
        .verbosity = run.config.verbosity,
    };
    defer connect_ctx.deinit();

    const initial_transport = TcpConnectCtx.connect(&connect_ctx) catch |err| {
        std.log.err("failed to connect to {s}:{d}: {t}", .{ run.config.host, run.config.port, err });
        return err;
    };
    var session = calle.session.ReconnectingTclSession.init(initial_transport, &connect_ctx, TcpConnectCtx.connect);
    session.max_connect_attempts = 3;
    session.delay_fn = TcpConnectCtx.delay;
    session.delay_ctx = &connect_ctx;
    defer session.close();

    if (run.subcommand != .repl) {
        var cmd_buf: [512]u8 = undefined;
        const cmd = calle.cli.dispatch.commandString(run.subcommand, &cmd_buf) catch |err| {
            std.log.err("could not build command: {t}", .{err});
            return err;
        };
        const response = execLogged(io, stdout, &session, gpa, cmd, run.config.verbosity) catch |err| {
            std.log.err("command failed: {t}", .{err});
            return err;
        };
        defer gpa.free(response);
        try stdout.writeStreamingAll(io, response);
        try stdout.writeStreamingAll(io, "\n");
        return;
    }

    try stdout.writeStreamingAll(io, "connected. type 'quit' to exit.\n");

    var line_buf: [1024]u8 = undefined;

    while (true) {
        try stdout.writeStreamingAll(io, "calle> ");

        const line = readLine(io, stdin, &line_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) break;

        const response = execLogged(io, stdout, &session, gpa, line, run.config.verbosity) catch |err| {
            std.log.err("command failed: {t}", .{err});
            continue;
        };
        defer gpa.free(response);
        try stdout.writeStreamingAll(io, response);
        try stdout.writeStreamingAll(io, "\n");
    }
}

/// Runs one command through `session`, optionally printing what's being
/// sent/received (-v) and byte counts (-vv), and noting when a
/// reconnect happened along the way.
fn execLogged(
    io: std.Io,
    stdout: std.Io.File,
    session: *calle.session.ReconnectingTclSession,
    gpa: std.mem.Allocator,
    cmd: []const u8,
    verbosity: u8,
) ![]u8 {
    if (verbosity >= 1) {
        std.log.info("> {s}", .{cmd});
    }
    const reconnects_before = session.reconnect_count;
    const response = try session.execAlloc(gpa, cmd);
    if (session.reconnect_count != reconnects_before) {
        try stdout.writeStreamingAll(io, "[reconnected]\n");
    }
    if (verbosity >= 1) {
        std.log.info("< ({d} bytes)", .{response.len});
    }
    if (verbosity >= 2) {
        std.log.debug("< {s}", .{response});
    }
    return response;
}

/// Reads `.calle.conf` from the current working directory, if it
/// exists, and parses it. Returns an all-null config if the file
/// doesn't exist. The returned struct's `host` (if set) points into
/// memory allocated from `gpa` - callers should use an arena or
/// otherwise ensure `gpa` outlives the returned value.
fn readConfigFile(io: std.Io, gpa: std.mem.Allocator) !calle.cli.config_file.ParsedConfigFile {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, ".calle.conf", gpa, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return calle.cli.config_file.parse(contents);
}

/// Connects (or reconnects) a TCP transport to a fixed host/port,
/// handed to `ReconnectingTclSession` as its reconnect callback. The
/// underlying `TcpTransport` is heap-allocated because its `Transport`
/// interface points into its own internal read/write buffers, so it
/// needs a stable address across reconnects (see the comment in
/// transport/tcp.zig).
const TcpConnectCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
    verbosity: u8 = 0,
    current: ?*calle.transport.tcp.TcpTransport = null,

    fn connect(ptr: *anyopaque) anyerror!calle.transport.Transport {
        const self: *TcpConnectCtx = @ptrCast(@alignCast(ptr));
        if (self.current) |old| self.gpa.destroy(old);
        self.current = null;

        const t = try self.gpa.create(calle.transport.tcp.TcpTransport);
        errdefer self.gpa.destroy(t);
        t.* = try calle.transport.tcp.TcpTransport.connect(self.io, self.host, self.port);
        self.current = t;
        return t.transport();
    }

    /// Exponential backoff between failed reconnect attempts: 200ms,
    /// 400ms, 800ms, ... capped at 3.2s.
    fn delay(ptr: *anyopaque, failed_attempt: u32) void {
        const self: *TcpConnectCtx = @ptrCast(@alignCast(ptr));
        const shift: u6 = @min(failed_attempt - 1, 4);
        const delay_ms: i64 = @as(i64, 200) << shift;
        if (self.verbosity >= 1) {
            std.log.info("reconnect attempt {d} failed, retrying in {d}ms...", .{ failed_attempt, delay_ms });
        }
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(delay_ms), .awake) catch {};
    }

    fn deinit(self: *TcpConnectCtx) void {
        if (self.current) |t| self.gpa.destroy(t);
        self.current = null;
    }
};

/// Reads a line from stdin, without the trailing newline. Deliberately
/// kept simple (byte by byte) rather than relying on a specific
/// Io.Reader convenience method.
fn readLine(io: std.Io, file: std.Io.File, buf: []u8) ![]const u8 {
    var len: usize = 0;
    var byte: [1]u8 = undefined;

    while (true) {
        const n = try file.readStreaming(io, &.{&byte});
        if (n == 0) {
            if (len == 0) return error.EndOfStream;
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        if (len >= buf.len) return error.LineTooLong;
        buf[len] = byte[0];
        len += 1;
    }

    return buf[0..len];
}
