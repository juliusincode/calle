//! Transport is the lowest layer: raw byte input/output.
//! It knows nothing about OpenOCD or any framing protocol.
//!
//! New backends (serial, Unix socket, ...) just implement the three
//! functions below and hand back a `Transport` from their own
//! `transport()` method. See transport/mock.zig for the simplest
//! example and transport/tcp.zig for the real backend.

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads as many bytes as are available (at least 1, except on EOF -> 0).
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        /// Writes as many bytes as possible, returns the number actually
        /// written.
        write: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(self: Transport, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    /// Writes the full slice, even if `write` needs to be called multiple times.
    pub fn writeAll(self: Transport, bytes: []const u8) anyerror!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = try self.vtable.write(self.ptr, bytes[offset..]);
            if (n == 0) return error.UnexpectedEof;
            offset += n;
        }
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};
