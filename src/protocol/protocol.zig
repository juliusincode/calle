//! A "protocol" in calle is any type that provides these two functions
//! (comptime duck typing, see session/session.zig):
//!
//!   fn sendCommand(t: Transport, cmd: []const u8) !void
//!   fn readResponse(t: Transport, out: []u8) ![]const u8
//!
//! New protocols (e.g. a different debug-adapter framing) don't need a
//! shared base type - just add a new file with these two functions and
//! plug it into Session(...).

pub const TelnetLineProtocol = @import("telnet_line.zig").TelnetLineProtocol;
pub const TclRpcProtocol = @import("tcl_rpc.zig").TclRpcProtocol;
