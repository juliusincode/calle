//! TCP backend for Transport, built on Zig 0.16's `std.Io.net`.
//! Verified against the real Zig 0.16.0 compiler and covered by an
//! end-to-end smoke test against a fake OpenOCD server - `zig build`
//! compiles this cleanly and connecting/exec'ing commands works.

const std = @import("std");
const Transport = @import("transport.zig").Transport;
const Io = std.Io;

pub const TcpTransport = struct {
    io: Io,
    stream: Io.net.Stream,
    read_buf: [4096]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    pub fn connect(io: Io, host: []const u8, port: u16) !TcpTransport {
        const addr = try Io.net.IpAddress.parse(host, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        return .{ .io = io, .stream = stream };
    }

    /// Must be called AFTER `self` has its final memory address (e.g.
    /// right after `var tcp = try TcpTransport.connect(...)`), because
    /// the reader/writer internally point into the buffers inside `self`
    /// - if `self` were copied/moved afterwards, those would become
    /// dangling pointers.
    pub fn transport(self: *TcpTransport) Transport {
        self.reader = self.stream.reader(self.io, &self.read_buf);
        self.writer = self.stream.writer(self.io, &self.write_buf);
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .read = readFn,
        .write = writeFn,
        .close = closeFn,
    };

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return self.reader.interface.readSliceShort(buf);
    }

    fn writeFn(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
        return bytes.len;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.stream.close(self.io);
    }
};
