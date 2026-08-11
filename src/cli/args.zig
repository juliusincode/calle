//! Pure argument-parsing logic, deliberately kept separate from
//! main.zig: main.zig's root module isn't exercised by `zig build
//! test` (it's a separate executable root, not part of the `calle`
//! library module), so anything with actual logic worth testing lives
//! here instead, and main.zig just calls into it.
//!
//! Grammar:
//!   calle [--host H] [--port P] <subcommand> [args...]
//!   calle [--host H] [--port P]                 (no subcommand -> REPL)
//!   calle -h | --help | help
//!
//! `--host`/`--port` must come before the subcommand; everything from
//! the subcommand name onward belongs to that subcommand. This is a
//! breaking change from the earlier `calle [host] [port] -- <command>`
//! grammar - positional host/port was ambiguous with subcommand names
//! once real subcommands existed (is "targets" a hostname or the
//! `targets` subcommand?).

const std = @import("std");

pub const Config = struct {
    host: []const u8,
    port: u16,
    /// 0 = quiet (default), 1 = -v, 2+ = -vv. Higher means more
    /// detail about what's happening on the wire (commands sent,
    /// reconnect attempts).
    verbosity: u8 = 0,
};

pub const ResetMode = enum { halt, run };

pub const FlashWrite = struct {
    path: []const u8,
    addr: ?u32,
};

pub const FlashVerify = struct {
    path: []const u8,
};

pub const WatchMode = @import("../commands/breakpoints.zig").WatchMode;

pub const RegRead = struct {
    name: []const u8,
};

pub const RegWrite = struct {
    name: []const u8,
    value: u32,
};

pub const BpSet = struct {
    addr: u32,
    len: u32,
    hw: bool,
};

pub const BpRemove = struct {
    addr: u32,
};

pub const WpSet = struct {
    addr: u32,
    len: u32,
    mode: ?WatchMode,
};

pub const WpRemove = struct {
    addr: u32,
};

pub const MemRead = struct {
    addr: u32,
    count: ?u32,
};

pub const MemWrite = struct {
    addr: u32,
    value: u32,
};

pub const MemDump = struct {
    path: []const u8,
    addr: u32,
    size: u32,
};

/// A parsed subcommand. `.repl` means "no subcommand was given, start
/// the interactive REPL instead of running one command and exiting."
pub const Subcommand = union(enum) {
    repl,
    halt,
    resume_target,
    targets,
    reset: ResetMode,
    flash_probe,
    flash_info,
    flash_write: FlashWrite,
    flash_verify: FlashVerify,
    reg_list,
    reg_read: RegRead,
    reg_write: RegWrite,
    bp_list,
    bp_set: BpSet,
    bp_remove: BpRemove,
    wp_list,
    wp_set: WpSet,
    wp_remove: WpRemove,
    mem_read: MemRead,
    mem_write: MemWrite,
    mem_dump: MemDump,
    script: struct { path: []const u8 },
    /// Escape hatch for anything without a typed subcommand yet - the
    /// argument is sent to OpenOCD verbatim. Needs shell quoting for
    /// multi-word commands: `calle raw "reset halt"`.
    raw: []const u8,
};

pub const Action = union(enum) {
    /// Print usage and exit successfully - requested via -h/--help/help.
    help,
    run: struct {
        config: Config,
        subcommand: Subcommand,
    },
};

pub const ParseError = error{
    InvalidPort,
    InvalidAddress,
    InvalidValue,
    InvalidLength,
    InvalidCount,
    InvalidSize,
    InvalidWatchMode,
    MissingFlagValue,
    MissingSubcommandArgument,
    UnknownSubcommand,
    UnknownFlashSubcommand,
    UnknownMemSubcommand,
    UnknownFlag,
};

const help_flags = [_][]const u8{ "-h", "--help", "help" };

fn isHelpFlag(arg: []const u8) bool {
    for (help_flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// `args` is the full argv slice, including args[0] (the program name).
/// `env_host` / `env_port` come from CALLE_HOST / CALLE_PORT and are
/// used as fallbacks when no `--host`/`--port` flag is given; explicit
/// flags always win over them.
pub fn parse(
    args: []const []const u8,
    env_host: ?[]const u8,
    env_port: ?[]const u8,
) ParseError!Action {
    var host: []const u8 = env_host orelse "127.0.0.1";
    var port: u16 = 6666;
    if (env_port) |p| {
        port = std.fmt.parseInt(u16, p, 10) catch return error.InvalidPort;
    }
    var verbosity: u8 = 0;

    var i: usize = 1;
    while (i < args.len) {
        const a = args[i];
        if (isHelpFlag(a)) return .help;

        if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            host = args[i];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbosity +|= 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-vv")) {
            verbosity +|= 2;
            i += 1;
            continue;
        }

        // First token that isn't a recognized global flag: everything
        // from here on belongs to the subcommand.
        break;
    }

    const config = Config{ .host = host, .port = port, .verbosity = verbosity };

    if (i >= args.len) {
        return .{ .run = .{ .config = config, .subcommand = .repl } };
    }

    const subcommand = try parseSubcommand(args[i..]);
    return .{ .run = .{ .config = config, .subcommand = subcommand } };
}

/// `rest[0]` is the subcommand name, `rest[1..]` are its arguments.
fn parseSubcommand(rest: []const []const u8) ParseError!Subcommand {
    const name = rest[0];

    if (std.mem.eql(u8, name, "halt")) return .halt;
    if (std.mem.eql(u8, name, "resume")) return .resume_target;
    if (std.mem.eql(u8, name, "targets")) return .targets;

    if (std.mem.eql(u8, name, "reset")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        if (std.mem.eql(u8, rest[1], "halt")) return .{ .reset = .halt };
        if (std.mem.eql(u8, rest[1], "run")) return .{ .reset = .run };
        return error.UnknownSubcommand;
    }

    if (std.mem.eql(u8, name, "flash")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        const sub = rest[1];

        if (std.mem.eql(u8, sub, "probe")) return .flash_probe;
        if (std.mem.eql(u8, sub, "info")) return .flash_info;

        if (std.mem.eql(u8, sub, "write")) {
            if (rest.len < 3) return error.MissingSubcommandArgument;
            const path = rest[2];
            var addr: ?u32 = null;
            if (rest.len >= 4) {
                if (!std.mem.eql(u8, rest[3], "--addr") or rest.len < 5) {
                    return error.UnknownFlag;
                }
                addr = std.fmt.parseInt(u32, rest[4], 0) catch return error.InvalidAddress;
            }
            return .{ .flash_write = .{ .path = path, .addr = addr } };
        }

        if (std.mem.eql(u8, sub, "verify")) {
            if (rest.len < 3) return error.MissingSubcommandArgument;
            return .{ .flash_verify = .{ .path = rest[2] } };
        }

        return error.UnknownFlashSubcommand;
    }

    if (std.mem.eql(u8, name, "reg")) {
        if (rest.len < 2) return .reg_list;
        if (rest.len == 2) return .{ .reg_read = .{ .name = rest[1] } };
        const value = std.fmt.parseInt(u32, rest[2], 0) catch return error.InvalidValue;
        return .{ .reg_write = .{ .name = rest[1], .value = value } };
    }

    if (std.mem.eql(u8, name, "bp")) {
        if (rest.len < 2) return .bp_list;
        if (rest.len < 3) return error.MissingSubcommandArgument;
        const addr = std.fmt.parseInt(u32, rest[1], 0) catch return error.InvalidAddress;
        const len = std.fmt.parseInt(u32, rest[2], 0) catch return error.InvalidLength;
        var hw = false;
        if (rest.len >= 4) {
            if (!std.mem.eql(u8, rest[3], "hw")) return error.UnknownFlag;
            hw = true;
        }
        return .{ .bp_set = .{ .addr = addr, .len = len, .hw = hw } };
    }

    if (std.mem.eql(u8, name, "rbp")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        const addr = std.fmt.parseInt(u32, rest[1], 0) catch return error.InvalidAddress;
        return .{ .bp_remove = .{ .addr = addr } };
    }

    if (std.mem.eql(u8, name, "wp")) {
        if (rest.len < 2) return .wp_list;
        if (rest.len < 3) return error.MissingSubcommandArgument;
        const addr = std.fmt.parseInt(u32, rest[1], 0) catch return error.InvalidAddress;
        const len = std.fmt.parseInt(u32, rest[2], 0) catch return error.InvalidLength;
        var mode: ?WatchMode = null;
        if (rest.len >= 4) {
            mode = std.meta.stringToEnum(WatchMode, rest[3]) orelse return error.InvalidWatchMode;
        }
        return .{ .wp_set = .{ .addr = addr, .len = len, .mode = mode } };
    }

    if (std.mem.eql(u8, name, "rwp")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        const addr = std.fmt.parseInt(u32, rest[1], 0) catch return error.InvalidAddress;
        return .{ .wp_remove = .{ .addr = addr } };
    }

    if (std.mem.eql(u8, name, "mem")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        const sub = rest[1];

        if (std.mem.eql(u8, sub, "read")) {
            if (rest.len < 3) return error.MissingSubcommandArgument;
            const addr = std.fmt.parseInt(u32, rest[2], 0) catch return error.InvalidAddress;
            var count: ?u32 = null;
            if (rest.len >= 4) {
                count = std.fmt.parseInt(u32, rest[3], 0) catch return error.InvalidCount;
            }
            return .{ .mem_read = .{ .addr = addr, .count = count } };
        }

        if (std.mem.eql(u8, sub, "write")) {
            if (rest.len < 4) return error.MissingSubcommandArgument;
            const addr = std.fmt.parseInt(u32, rest[2], 0) catch return error.InvalidAddress;
            const value = std.fmt.parseInt(u32, rest[3], 0) catch return error.InvalidValue;
            return .{ .mem_write = .{ .addr = addr, .value = value } };
        }

        if (std.mem.eql(u8, sub, "dump")) {
            if (rest.len < 5) return error.MissingSubcommandArgument;
            const addr = std.fmt.parseInt(u32, rest[3], 0) catch return error.InvalidAddress;
            const size = std.fmt.parseInt(u32, rest[4], 0) catch return error.InvalidSize;
            return .{ .mem_dump = .{ .path = rest[2], .addr = addr, .size = size } };
        }

        return error.UnknownMemSubcommand;
    }

    if (std.mem.eql(u8, name, "script")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        return .{ .script = .{ .path = rest[1] } };
    }

    if (std.mem.eql(u8, name, "raw")) {
        if (rest.len < 2) return error.MissingSubcommandArgument;
        return .{ .raw = rest[1] };
    }

    return error.UnknownSubcommand;
}

pub const usage_text =
    \\calle - a modular OpenOCD client (Tcl-RPC by default, port 6666)
    \\
    \\Usage:
    \\  calle [--host H] [--port P] [-v|-vv]       interactive REPL
    \\  calle [--host H] [--port P] [-v|-vv] <subcommand>
    \\                                              run one command, exit
    \\  calle -h | --help | help                    show this help
    \\
    \\Subcommands:
    \\  halt                       halt the target
    \\  resume                     resume the target
    \\  targets                    list configured targets
    \\  reset halt | reset run     reset, then halt or resume
    \\  flash probe                probe flash bank 0
    \\  flash info                 show flash bank 0 info
    \\  flash write <path> [--addr 0xADDR]
    \\                              erase and write an image to flash
    \\  flash verify <path>        verify flash contents against an image
    \\  reg                        list all registers
    \\  reg <name>                 read a register
    \\  reg <name> <value>         write a register
    \\  bp                         list breakpoints
    \\  bp <addr> <len> [hw]       set a breakpoint
    \\  rbp <addr>                 remove a breakpoint
    \\  wp                         list watchpoints
    \\  wp <addr> <len> [r|w|a]    set a watchpoint
    \\  rwp <addr>                 remove a watchpoint
    \\  mem read <addr> [count]    read word(s) from memory
    \\  mem write <addr> <value>   write a word to memory
    \\  mem dump <path> <addr> <size>
    \\                              dump memory to a file (on the OpenOCD host)
    \\  raw "<command>"            send a raw OpenOCD command (quote it!)
    \\  script <path>              run each line of <path> as a command,
    \\                              stop at the first failure
    \\
    \\Defaults: --host 127.0.0.1 --port 6666
    \\Overridable via CALLE_HOST / CALLE_PORT env vars; --host/--port
    \\take precedence over those.
    \\
    \\-v shows what's sent/received and reconnect attempts; -vv adds
    \\more detail (bytes received per response).
    \\
;

test "no arguments falls back to defaults and starts the REPL" {
    const action = try parse(&.{"calle"}, null, null);
    try std.testing.expect(action == .run);
    try std.testing.expectEqualStrings("127.0.0.1", action.run.config.host);
    try std.testing.expectEqual(@as(u16, 6666), action.run.config.port);
    try std.testing.expect(action.run.subcommand == .repl);
}

test "-h anywhere requests help" {
    try std.testing.expect((try parse(&.{ "calle", "-h" }, null, null)) == .help);
    try std.testing.expect((try parse(&.{ "calle", "--help" }, null, null)) == .help);
    try std.testing.expect((try parse(&.{ "calle", "help" }, null, null)) == .help);
    try std.testing.expect((try parse(&.{ "calle", "--host", "10.0.0.1", "-h" }, null, null)) == .help);
}

test "--host and --port override the defaults" {
    const action = try parse(&.{ "calle", "--host", "10.0.0.1", "--port", "4444" }, null, null);
    try std.testing.expectEqualStrings("10.0.0.1", action.run.config.host);
    try std.testing.expectEqual(@as(u16, 4444), action.run.config.port);
    try std.testing.expect(action.run.subcommand == .repl);
}

test "env vars are used when no flags are given" {
    const action = try parse(&.{"calle"}, "10.0.0.9", "1234");
    try std.testing.expectEqualStrings("10.0.0.9", action.run.config.host);
    try std.testing.expectEqual(@as(u16, 1234), action.run.config.port);
}

test "flags take precedence over env vars" {
    const action = try parse(&.{ "calle", "--host", "10.0.0.1", "--port", "4444" }, "10.0.0.9", "1234");
    try std.testing.expectEqualStrings("10.0.0.1", action.run.config.host);
    try std.testing.expectEqual(@as(u16, 4444), action.run.config.port);
}

test "a flag without a value reports MissingFlagValue" {
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "calle", "--host" }, null, null));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "calle", "--port" }, null, null));
}

test "an invalid port reports InvalidPort instead of a raw parse panic" {
    try std.testing.expectError(error.InvalidPort, parse(&.{ "calle", "--port", "not-a-port" }, null, null));
}

test "an invalid port from an env var also reports InvalidPort" {
    try std.testing.expectError(error.InvalidPort, parse(&.{"calle"}, null, "not-a-port"));
}

test "simple subcommands parse correctly" {
    try std.testing.expect((try parse(&.{ "calle", "halt" }, null, null)).run.subcommand == .halt);
    try std.testing.expect((try parse(&.{ "calle", "resume" }, null, null)).run.subcommand == .resume_target);
    try std.testing.expect((try parse(&.{ "calle", "targets" }, null, null)).run.subcommand == .targets);
}

test "reset requires halt or run" {
    const halt = try parse(&.{ "calle", "reset", "halt" }, null, null);
    try std.testing.expectEqual(ResetMode.halt, halt.run.subcommand.reset);

    const run = try parse(&.{ "calle", "reset", "run" }, null, null);
    try std.testing.expectEqual(ResetMode.run, run.run.subcommand.reset);

    try std.testing.expectError(error.MissingSubcommandArgument, parse(&.{ "calle", "reset" }, null, null));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{ "calle", "reset", "sideways" }, null, null));
}

test "flash probe and info" {
    try std.testing.expect((try parse(&.{ "calle", "flash", "probe" }, null, null)).run.subcommand == .flash_probe);
    try std.testing.expect((try parse(&.{ "calle", "flash", "info" }, null, null)).run.subcommand == .flash_info);
}

test "flash write without an address" {
    const action = try parse(&.{ "calle", "flash", "write", "firmware.bin" }, null, null);
    try std.testing.expectEqualStrings("firmware.bin", action.run.subcommand.flash_write.path);
    try std.testing.expectEqual(@as(?u32, null), action.run.subcommand.flash_write.addr);
}

test "flash write with --addr, hex and decimal" {
    const hex = try parse(&.{ "calle", "flash", "write", "fw.bin", "--addr", "0x08000000" }, null, null);
    try std.testing.expectEqual(@as(?u32, 0x08000000), hex.run.subcommand.flash_write.addr);

    const dec = try parse(&.{ "calle", "flash", "write", "fw.bin", "--addr", "4096" }, null, null);
    try std.testing.expectEqual(@as(?u32, 4096), dec.run.subcommand.flash_write.addr);
}

test "flash write reports MissingSubcommandArgument without a path" {
    try std.testing.expectError(error.MissingSubcommandArgument, parse(&.{ "calle", "flash", "write" }, null, null));
}

test "flash verify" {
    const action = try parse(&.{ "calle", "flash", "verify", "fw.bin" }, null, null);
    try std.testing.expectEqualStrings("fw.bin", action.run.subcommand.flash_verify.path);
}

test "an unknown flash subcommand is rejected" {
    try std.testing.expectError(error.UnknownFlashSubcommand, parse(&.{ "calle", "flash", "erase-everything" }, null, null));
}

test "reg with no arguments lists registers" {
    const action = try parse(&.{ "calle", "reg" }, null, null);
    try std.testing.expect(action.run.subcommand == .reg_list);
}

test "reg with a name reads a register" {
    const action = try parse(&.{ "calle", "reg", "pc" }, null, null);
    try std.testing.expectEqualStrings("pc", action.run.subcommand.reg_read.name);
}

test "reg with a name and value writes a register" {
    const action = try parse(&.{ "calle", "reg", "r0", "0x1000" }, null, null);
    try std.testing.expectEqualStrings("r0", action.run.subcommand.reg_write.name);
    try std.testing.expectEqual(@as(u32, 0x1000), action.run.subcommand.reg_write.value);
}

test "reg write reports InvalidValue for a bad value" {
    try std.testing.expectError(error.InvalidValue, parse(&.{ "calle", "reg", "r0", "not-a-number" }, null, null));
}

test "bp with no arguments lists breakpoints" {
    const action = try parse(&.{ "calle", "bp" }, null, null);
    try std.testing.expect(action.run.subcommand == .bp_list);
}

test "bp with addr and len sets a breakpoint" {
    const action = try parse(&.{ "calle", "bp", "0x08000000", "2" }, null, null);
    const bp = action.run.subcommand.bp_set;
    try std.testing.expectEqual(@as(u32, 0x08000000), bp.addr);
    try std.testing.expectEqual(@as(u32, 2), bp.len);
    try std.testing.expectEqual(false, bp.hw);
}

test "bp with trailing hw sets the hw flag" {
    const action = try parse(&.{ "calle", "bp", "0x08000000", "4", "hw" }, null, null);
    try std.testing.expectEqual(true, action.run.subcommand.bp_set.hw);
}

test "bp requires len once addr is given" {
    try std.testing.expectError(error.MissingSubcommandArgument, parse(&.{ "calle", "bp", "0x08000000" }, null, null));
}

test "bp rejects an unknown trailing flag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "calle", "bp", "0x08000000", "2", "nope" }, null, null));
}

test "rbp removes a breakpoint by address" {
    const action = try parse(&.{ "calle", "rbp", "0x08000000" }, null, null);
    try std.testing.expectEqual(@as(u32, 0x08000000), action.run.subcommand.bp_remove.addr);
}

test "wp with no arguments lists watchpoints" {
    const action = try parse(&.{ "calle", "wp" }, null, null);
    try std.testing.expect(action.run.subcommand == .wp_list);
}

test "wp with addr and len, no mode" {
    const action = try parse(&.{ "calle", "wp", "0x20000000", "4" }, null, null);
    const wp = action.run.subcommand.wp_set;
    try std.testing.expectEqual(@as(u32, 0x20000000), wp.addr);
    try std.testing.expectEqual(@as(u32, 4), wp.len);
    try std.testing.expectEqual(@as(?WatchMode, null), wp.mode);
}

test "wp with a mode" {
    const action = try parse(&.{ "calle", "wp", "0x20000000", "4", "w" }, null, null);
    try std.testing.expectEqual(WatchMode.w, action.run.subcommand.wp_set.mode.?);
}

test "wp rejects an invalid mode" {
    try std.testing.expectError(error.InvalidWatchMode, parse(&.{ "calle", "wp", "0x20000000", "4", "x" }, null, null));
}

test "rwp removes a watchpoint by address" {
    const action = try parse(&.{ "calle", "rwp", "0x20000000" }, null, null);
    try std.testing.expectEqual(@as(u32, 0x20000000), action.run.subcommand.wp_remove.addr);
}

test "mem read without a count" {
    const action = try parse(&.{ "calle", "mem", "read", "0x20000000" }, null, null);
    const m = action.run.subcommand.mem_read;
    try std.testing.expectEqual(@as(u32, 0x20000000), m.addr);
    try std.testing.expectEqual(@as(?u32, null), m.count);
}

test "mem read with a count" {
    const action = try parse(&.{ "calle", "mem", "read", "0x20000000", "8" }, null, null);
    try std.testing.expectEqual(@as(?u32, 8), action.run.subcommand.mem_read.count);
}

test "mem write" {
    const action = try parse(&.{ "calle", "mem", "write", "0x20000000", "0x1234" }, null, null);
    const m = action.run.subcommand.mem_write;
    try std.testing.expectEqual(@as(u32, 0x20000000), m.addr);
    try std.testing.expectEqual(@as(u32, 0x1234), m.value);
}

test "mem dump" {
    const action = try parse(&.{ "calle", "mem", "dump", "ram.bin", "0x20000000", "1024" }, null, null);
    const m = action.run.subcommand.mem_dump;
    try std.testing.expectEqualStrings("ram.bin", m.path);
    try std.testing.expectEqual(@as(u32, 0x20000000), m.addr);
    try std.testing.expectEqual(@as(u32, 1024), m.size);
}

test "an unknown mem subcommand is rejected" {
    try std.testing.expectError(error.UnknownMemSubcommand, parse(&.{ "calle", "mem", "erase" }, null, null));
}

test "raw passes its single quoted argument through verbatim" {
    const action = try parse(&.{ "calle", "raw", "reset halt" }, null, null);
    try std.testing.expectEqualStrings("reset halt", action.run.subcommand.raw);
}

test "raw without an argument reports MissingSubcommandArgument" {
    try std.testing.expectError(error.MissingSubcommandArgument, parse(&.{ "calle", "raw" }, null, null));
}

test "script requires a path" {
    const action = try parse(&.{ "calle", "script", "flash-and-verify.calle" }, null, null);
    try std.testing.expectEqualStrings("flash-and-verify.calle", action.run.subcommand.script.path);
}

test "script without a path reports MissingSubcommandArgument" {
    try std.testing.expectError(error.MissingSubcommandArgument, parse(&.{ "calle", "script" }, null, null));
}

test "an unknown top-level subcommand is rejected" {
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{ "calle", "frobnicate" }, null, null));
}

test "--host and --port combine with a subcommand" {
    const action = try parse(&.{ "calle", "--host", "10.0.0.1", "--port", "4444", "halt" }, null, null);
    try std.testing.expectEqualStrings("10.0.0.1", action.run.config.host);
    try std.testing.expectEqual(@as(u16, 4444), action.run.config.port);
    try std.testing.expect(action.run.subcommand == .halt);
}

test "verbosity defaults to 0" {
    const action = try parse(&.{"calle"}, null, null);
    try std.testing.expectEqual(@as(u8, 0), action.run.config.verbosity);
}

test "-v sets verbosity to 1, repeated -v adds up" {
    const once = try parse(&.{ "calle", "-v" }, null, null);
    try std.testing.expectEqual(@as(u8, 1), once.run.config.verbosity);

    const twice = try parse(&.{ "calle", "-v", "-v" }, null, null);
    try std.testing.expectEqual(@as(u8, 2), twice.run.config.verbosity);
}

test "-vv sets verbosity to 2 directly, and --verbose is an alias for -v" {
    const vv = try parse(&.{ "calle", "-vv" }, null, null);
    try std.testing.expectEqual(@as(u8, 2), vv.run.config.verbosity);

    const verbose = try parse(&.{ "calle", "--verbose" }, null, null);
    try std.testing.expectEqual(@as(u8, 1), verbose.run.config.verbosity);
}

test "verbosity flags combine with --host/--port and a subcommand" {
    const action = try parse(&.{ "calle", "-v", "--host", "10.0.0.1", "halt" }, null, null);
    try std.testing.expectEqual(@as(u8, 1), action.run.config.verbosity);
    try std.testing.expectEqualStrings("10.0.0.1", action.run.config.host);
    try std.testing.expect(action.run.subcommand == .halt);
}
