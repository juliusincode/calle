//! calle - a modular OpenOCD client.
//!
//! Layers (each independently swappable/extensible):
//!   transport/  - raw byte input/output (TCP, mock, serial later on)
//!   protocol/   - framing (telnet lines vs. Tcl-RPC 0x1a separation)
//!   session/    - wires transport + protocol together into exec()
//!   commands/   - typed OpenOCD commands built on top of session.exec()

const std = @import("std");

pub const transport = struct {
    pub const Transport = @import("transport/transport.zig").Transport;
    pub const MockTransport = @import("transport/mock.zig").MockTransport;
    pub const tcp = @import("transport/tcp.zig");
};

pub const protocol = @import("protocol/protocol.zig");

pub const session = @import("session/session.zig");

pub const commands = @import("commands/commands.zig");

pub const cli = struct {
    pub const args = @import("cli/args.zig");
    pub const dispatch = @import("cli/dispatch.zig");
    pub const config_file = @import("cli/config_file.zig");
    pub const line_reader = @import("cli/line_reader.zig");

    test {
        // See the `refAllDecls is not recursive` note in commands.zig -
        // same reasoning applies here for the `args`/`dispatch`/
        // `config_file` sub-modules.
        std.testing.refAllDecls(@This());
    }
};

test {
    // Pulls in every `test` block from the imported files so that
    // `zig build test` actually exercises all of them.
    std.testing.refAllDecls(@This());
}
