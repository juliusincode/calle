//! Pure, testable line-reading logic for the REPL. Extracted out of
//! main.zig for the same reason as args.zig/dispatch.zig/
//! config_file.zig: main.zig itself has no test coverage (it's a
//! separate executable root module, not part of the `calle` library
//! module that `zig build test` exercises).
//!
//! This exists specifically because a real bug lived here undetected:
//! on a too-long line, the original code returned `error.LineTooLong`
//! without draining the rest of the oversized line first - the
//! leftover bytes then got misread as a separate, shorter "line" on
//! the next call. Only caught by manual end-to-end testing (see
//! TESTING.md), which is exactly the kind of thing that should have
//! been a unit test from the start.

const std = @import("std");

pub const Error = error{
    /// No bytes were read at all before the source ran out (a clean
    /// "nothing more to read" - e.g. Ctrl-D on an interactive stdin).
    EndOfStream,
    /// The line exceeded `buf`'s capacity. The rest of the oversized
    /// line (up to the next newline, or EOF) has already been drained
    /// from `source` by the time this is returned - the next call
    /// starts at the next real line boundary, not mid-line.
    LineTooLong,
};

/// Reads a line (without a trailing `\n` or `\r`) from `source`, which
/// must have a `fn nextByte(self) anyerror!?u8` method returning `null`
/// on end of input. Real I/O errors from `nextByte` propagate as-is
/// (widened into the `anyerror` return type) so callers can tell them
/// apart from `Error.EndOfStream`/`Error.LineTooLong`.
pub fn readLine(source: anytype, buf: []u8) anyerror![]const u8 {
    var len: usize = 0;
    var too_long = false;

    while (true) {
        const maybe_byte = try source.nextByte();
        const byte = maybe_byte orelse {
            if (len == 0 and !too_long) return Error.EndOfStream;
            break;
        };

        if (byte == '\n') break;
        if (byte == '\r') continue;
        if (too_long) continue; // draining: discard, just look for '\n'/EOF

        if (len >= buf.len) {
            too_long = true;
            continue;
        }
        buf[len] = byte;
        len += 1;
    }

    if (too_long) return Error.LineTooLong;
    return buf[0..len];
}

const MockByteSource = struct {
    data: []const u8,
    pos: usize = 0,

    fn nextByte(self: *MockByteSource) anyerror!?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }
};

test "a simple line without CR" {
    var src = MockByteSource{ .data = "hello\n" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try readLine(&src, &buf));
}

test "CRLF line endings have the CR stripped" {
    var src = MockByteSource{ .data = "hello\r\n" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try readLine(&src, &buf));
}

test "immediate EOF reports EndOfStream" {
    var src = MockByteSource{ .data = "" };
    var buf: [64]u8 = undefined;
    try std.testing.expectError(Error.EndOfStream, readLine(&src, &buf));
}

test "a final line with no trailing newline before EOF still succeeds" {
    var src = MockByteSource{ .data = "no newline here" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("no newline here", try readLine(&src, &buf));
}

test "multiple lines read in sequence" {
    var src = MockByteSource{ .data = "first\nsecond\nthird\n" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("first", try readLine(&src, &buf));
    try std.testing.expectEqualStrings("second", try readLine(&src, &buf));
    try std.testing.expectEqualStrings("third", try readLine(&src, &buf));
    try std.testing.expectError(Error.EndOfStream, readLine(&src, &buf));
}

test "an oversized line reports LineTooLong" {
    var src = MockByteSource{ .data = "aaaaaaaaaa\n" }; // 10 'a's
    var buf: [4]u8 = undefined; // too small for 10 bytes
    try std.testing.expectError(Error.LineTooLong, readLine(&src, &buf));
}

test "regression: the rest of an oversized line is drained, not leaked into the next call" {
    // This is the exact bug: without draining, the "bbbb" after the
    // too-long "aaaa..." line would be misread as its own short line.
    var src = MockByteSource{ .data = "aaaaaaaaaa\nbbbb\n" };
    var buf: [4]u8 = undefined;

    try std.testing.expectError(Error.LineTooLong, readLine(&src, &buf));
    // The *next* call must see "bbbb", not leftover fragments of the
    // previous line.
    try std.testing.expectEqualStrings("bbbb", try readLine(&src, &buf));
    try std.testing.expectError(Error.EndOfStream, readLine(&src, &buf));
}

test "an oversized final line with no trailing newline is still fully drained" {
    var src = MockByteSource{ .data = "aaaaaaaaaa" }; // no trailing \n, hits EOF while draining
    var buf: [4]u8 = undefined;
    try std.testing.expectError(Error.LineTooLong, readLine(&src, &buf));
    try std.testing.expectError(Error.EndOfStream, readLine(&src, &buf));
}
