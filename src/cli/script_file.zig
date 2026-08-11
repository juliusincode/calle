//! Parsing for batch script files used by `calle script <path>`.
//! Deliberately pure - takes file contents as a string, does no
//! filesystem access itself - so it's testable without touching disk.
//! main.zig reads the actual file and hands the contents here.
//!
//! Format: one OpenOCD command per line. Blank lines and lines
//! starting with `#` are ignored. No quoting, no escaping - each
//! non-empty, non-comment line is sent to OpenOCD verbatim (trimmed
//! of surrounding whitespace), same as the `raw` subcommand.
//!
//!     # flash-and-verify.calle
//!     reset halt
//!     flash write_image erase firmware.bin 0x08000000
//!     verify_image firmware.bin
//!     reset run

const std = @import("std");

/// Iterates the runnable command lines in a script file's contents,
/// skipping blank lines and `#` comments and trimming whitespace.
pub const LineIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(contents: []const u8) LineIterator {
        return .{ .lines = std.mem.splitScalar(u8, contents, '\n') };
    }

    /// Returns the next runnable command, or `null` when there are no
    /// more lines left.
    pub fn next(self: *LineIterator) ?[]const u8 {
        while (self.lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

test "an empty script has no commands" {
    var it = LineIterator.init("");
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "blank lines and comments are skipped" {
    var it = LineIterator.init(
        \\# a comment
        \\
        \\halt
        \\
        \\# reset halt (commented out, should not run)
        \\reset run
        \\
    );
    try std.testing.expectEqualStrings("halt", it.next().?);
    try std.testing.expectEqualStrings("reset run", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "surrounding whitespace and CR are trimmed" {
    var it = LineIterator.init("  halt  \r\n\treset run\t\r\n");
    try std.testing.expectEqualStrings("halt", it.next().?);
    try std.testing.expectEqualStrings("reset run", it.next().?);
}

test "a file with no trailing newline still yields its last line" {
    var it = LineIterator.init("halt\nresume");
    try std.testing.expectEqualStrings("halt", it.next().?);
    try std.testing.expectEqualStrings("resume", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "a file of only comments/blanks yields no commands" {
    var it = LineIterator.init("# nothing to do here\n\n   \n# still nothing\n");
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "a real-looking flash-and-verify script" {
    var it = LineIterator.init(
        \\# flash-and-verify.calle
        \\reset halt
        \\flash write_image erase firmware.bin 0x08000000
        \\verify_image firmware.bin
        \\reset run
        \\
    );
    try std.testing.expectEqualStrings("reset halt", it.next().?);
    try std.testing.expectEqualStrings("flash write_image erase firmware.bin 0x08000000", it.next().?);
    try std.testing.expectEqualStrings("verify_image firmware.bin", it.next().?);
    try std.testing.expectEqualStrings("reset run", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}
