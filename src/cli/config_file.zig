//! Parsing for the optional `.calle.conf` config file. Deliberately
//! pure - takes file contents as a string, does no filesystem access
//! itself - so it's testable without touching disk. main.zig reads
//! the actual file (if present) and hands the contents here.
//!
//! Format: one `key = value` pair per line. Blank lines and lines
//! starting with `#` are ignored. Supported keys: `host`, `port`.
//!
//!     # .calle.conf
//!     host = 192.168.1.50
//!     port = 6666
//!
//! Precedence (highest to lowest): CLI flags > config file > env vars
//! > built-in default. See `resolveFallback` in main.zig for how the
//! config file and env vars are combined into the single fallback
//! that `cli.args.parse` expects.

const std = @import("std");

pub const ParsedConfigFile = struct {
    /// Points into the `contents` slice passed to `parse` - keep that
    /// slice alive as long as this is used.
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

pub const ParseError = error{
    /// A non-blank, non-comment line has no `=`.
    InvalidLine,
    /// The value for `port` isn't a valid u16.
    InvalidPort,
    /// A key other than `host`/`port` was used.
    UnknownKey,
};

pub fn parse(contents: []const u8) ParseError!ParsedConfigFile {
    var result = ParsedConfigFile{};
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "host")) {
            result.host = value;
        } else if (std.mem.eql(u8, key, "port")) {
            result.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else {
            return error.UnknownKey;
        }
    }

    return result;
}

test "empty contents parse to an all-null config" {
    const parsed = try parse("");
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.host);
    try std.testing.expectEqual(@as(?u16, null), parsed.port);
}

test "host and port are parsed" {
    const parsed = try parse("host = 192.168.1.50\nport = 6666\n");
    try std.testing.expectEqualStrings("192.168.1.50", parsed.host.?);
    try std.testing.expectEqual(@as(u16, 6666), parsed.port.?);
}

test "blank lines and comments are ignored" {
    const parsed = try parse(
        \\# this is a comment
        \\
        \\host = 10.0.0.1
        \\
        \\# port = 9999 (commented out, should not apply)
        \\port = 4444
        \\
    );
    try std.testing.expectEqualStrings("10.0.0.1", parsed.host.?);
    try std.testing.expectEqual(@as(u16, 4444), parsed.port.?);
}

test "whitespace around keys and values is trimmed" {
    const parsed = try parse("  host   =   10.0.0.9  \n  port=1234\n");
    try std.testing.expectEqualStrings("10.0.0.9", parsed.host.?);
    try std.testing.expectEqual(@as(u16, 1234), parsed.port.?);
}

test "a line without '=' reports InvalidLine" {
    try std.testing.expectError(error.InvalidLine, parse("this is not valid"));
}

test "an invalid port value reports InvalidPort" {
    try std.testing.expectError(error.InvalidPort, parse("port = not-a-port"));
}

test "an unknown key reports UnknownKey" {
    try std.testing.expectError(error.UnknownKey, parse("protocol = telnet"));
}

test "only one of host/port can be set" {
    const parsed = try parse("port = 4444\n");
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.host);
    try std.testing.expectEqual(@as(u16, 4444), parsed.port.?);
}
