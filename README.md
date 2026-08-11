# calle

A modular OpenOCD client written in Zig 0.16, built primarily around
OpenOCD's Tcl-RPC interface (port 6666 by default).

**Status:** builds and passes all tests against the real Zig 0.16.0
compiler. `zig build test` (119/119, fully mock-based, no network
required) and an end-to-end smoke test of `zig build run` against a
fake OpenOCD server (real TCP connection, `targets` / `reset halt` over
Tcl-RPC, REPL including `quit`) both pass.

```sh
zig build test                                    # 119/119 green, no network needed
zig build run -- --host 127.0.0.1 --port 6666     # interactive REPL

# typed subcommands, for scripts:
zig build run -- --host 127.0.0.1 --port 6666 reset halt
zig build run -- --host 127.0.0.1 --port 6666 flash write firmware.bin --addr 0x08000000

# CALLE_HOST / CALLE_PORT env vars work too, flags take precedence:
CALLE_HOST=127.0.0.1 CALLE_PORT=6666 zig build run -- targets
```

## Why calle exists

OpenOCD's telnet console (port 4444) is meant for humans: a prompt,
some telnet escape noise, interactive use. Its Tcl-RPC port (port
6666) is meant for programs: plain text commands, responses separated
by a single `0x1a` (Ctrl-Z) byte, no prompt, no escape sequences.
calle's default path talks Tcl-RPC, which makes it a better fit than a
plain terminal/telnet client for scripting, CI, or building tooling on
top of OpenOCD.

## Architecture

```
src/
  transport/    Raw byte input/output. Transport is an interface
                 (vtable), currently with TCP and Mock backends.
  protocol/     Framing: telnet-line (port 4444) vs. Tcl-RPC with a
                 0x1a separator (port 6666).
  session/      Wires Transport + Protocol into exec(cmd) -> response.
  commands/     Typed OpenOCD commands (halt, resetHalt, flash.*, ...)
                 built on top of session.exec().
  main.zig      CLI REPL.
```

### Transport

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    // read / writeAll / close
};
```

A classic Zig interface: a pointer plus a vtable. Two backends exist
today:

- `transport/tcp.zig` - real TCP, built on Zig 0.16's `std.Io.net`.
- `transport/mock.zig` - an in-memory backend used by every test in
  this project. Feed it a scripted byte sequence as "what the server
  sends", then inspect what was written to it.

Adding a new backend (e.g. serial, for talking to a debug adapter
directly) means implementing three functions - `read`, `write`,
`close` - and exposing them through a `transport()` method. No shared
base class, no changes to any other file required.

### Protocol

A "protocol" is any type providing:

```zig
fn sendCommand(t: Transport, cmd: []const u8) !void
fn readResponse(t: Transport, out: []u8) ![]const u8
```

Two exist: `TelnetLineProtocol` (newline-terminated, filters telnet IAC
sequences) and `TclRpcProtocol` (`0x1a`-terminated). Both operate
purely through the `Transport` interface, so they're testable without
any real networking - see the tests at the bottom of each file in
`src/protocol/`.

### Session

`Session(comptime ProtocolImpl: type)` is a small generic type that
combines a `Transport` with a protocol implementation and exposes two
ways to run a command:

- `exec(cmd, out) -> response` - writes into a caller-provided fixed
  buffer, no allocation. Fails with `error.ResponseTooLong` if the
  response doesn't fit. Good for short, known-size responses.
- `execAlloc(gpa, cmd) -> response` - grows a heap-allocated buffer as
  needed. Caller owns and must free the returned slice. Good for
  responses of unknown or potentially large size (e.g.
  `flash write_image` progress output). The CLI uses this
  everywhere.

`TelnetSession` and `TclSession` are the two instantiations. Because
the protocol is comptime duck-typed, both sessions share identical
code for both methods.

`session.Reconnecting(ProtocolImpl)` wraps a `Session` and adds
resilience: if `exec`/`execAlloc` fails, it closes the current
transport, calls a supplied reconnect callback to establish a fresh
one, and retries the command exactly once. A command that fails twice
in a row surfaces the *original* error rather than retrying forever.

Establishing the fresh connection itself can retry more than once,
independent of the single command retry above:
`max_connect_attempts` (default 1) controls how many times the
reconnect callback is called before giving up, and an optional
`delay_fn` runs between failed attempts - e.g. to sleep with backoff.
`Reconnecting` stays free of any `std.Io`/timing dependency itself, so
this stays fully unit-testable with `MockTransport` and no real clock;
the actual sleeping lives in the caller's `delay_fn`. The CLI sets
`max_connect_attempts = 3` with exponential backoff via `std.Io.sleep`
- see `TcpConnectCtx` in `src/main.zig`.

`ReconnectingTclSession` is the ready-made alias, and it's what the
CLI uses by default.

### Commands

Thin, typed wrappers around `session.exec(...)`, so application code
reads `commands.resetHalt(session, &buf)` instead of embedding raw
strings like `"reset halt"` everywhere. Grouped by area, one file
each, all following the same pattern:

- `commands.flash` - `probe`, `info`, `writeImage`, `verifyImage`
  (`src/commands/flash.zig`)
- `commands.registers` - `list`, `read`, `write`
  (`src/commands/registers.zig`)
- `commands.breakpoints` - `listBreakpoints`, `setBreakpoint`,
  `removeBreakpoint`, `listWatchpoints`, `setWatchpoint`,
  `removeWatchpoint` (`src/commands/breakpoints.zig`)
- `commands.memory` - `readWords`, `writeWord`, `dumpImage`
  (`src/commands/memory.zig`)

Command syntax for all of these was checked against the OpenOCD
User's Guide before implementing (e.g. `bp [address len [hw]]`,
`wp [address len [(r|w|a)]]`, `reg [name [val]]`) rather than guessed.

## Extending calle

**New command:** add a function to `src/commands/commands.zig`, or a
new file like `src/commands/target.zig` for a new command "area"
(mirroring `flash.zig`). Any function taking `session: anytype` works
with both `TelnetSession` and `TclSession`.

```zig
pub fn writeMemory(session: anytype, addr: u32, value: u32, out: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "mww 0x{x} 0x{x}", .{ addr, value });
    return session.exec(cmd, out);
}
```

If your new file is only reachable through another file's re-export
(like `commands.flash` is reachable via `commands.zig`), make sure the
re-exporting file has its own
`test { std.testing.refAllDecls(@This()); }` block - see
[Gotcha: `refAllDecls` is not recursive](#gotcha-refalldecls-is-not-recursive)
below, or your new file's tests silently won't run.

**New transport backend:** add a new file to `src/transport/`
implementing `Transport.VTable`'s three functions. `src/transport/mock.zig`
is the simplest reference implementation (~50 lines).

**New protocol:** add a new file to `src/protocol/` with the
`sendCommand` / `readResponse` function pair. Instantiate a new
`Session(YourProtocol)` in `src/session/session.zig` if you want a
named alias like `TelnetSession`/`TclSession`.

See [ROADMAP.md](ROADMAP.md) for the current list of planned
extensions.

## CLI usage

```
calle [--host H] [--port P]                interactive REPL
calle [--host H] [--port P] <subcommand>   run one command, print the
                                            response, exit
calle -h | --help | help                   show usage and exit
```

Subcommands:

```
halt                                halt the target
resume                               resume the target
targets                              list configured targets
reset halt | reset run               reset, then halt or resume
flash probe                          probe flash bank 0
flash info                           show flash bank 0 info
flash write <path> [--addr 0xADDR]   erase and write an image to flash
flash verify <path>                  verify flash contents against an image
reg                                  list all registers
reg <name>                           read a register
reg <name> <value>                   write a register
bp                                   list breakpoints
bp <addr> <len> [hw]                 set a breakpoint
rbp <addr>                           remove a breakpoint
wp                                   list watchpoints
wp <addr> <len> [r|w|a]              set a watchpoint
rwp <addr>                           remove a watchpoint
mem read <addr> [count]              read word(s) from memory
mem write <addr> <value>             write a word to memory
mem dump <path> <addr> <size>        dump memory to a file (on the OpenOCD host)
raw "<command>"                      send a raw OpenOCD command (quote it!)
script <path>                        run each line of <path> as a command,
                                      stop at the first failure
```

Addresses/values/lengths accept both hex (`0x08000000`) and decimal.

A script file has one OpenOCD command per line; blank lines and lines
starting with `#` are ignored:

```
# flash-and-verify.calle
reset halt
flash write_image erase firmware.bin 0x08000000
verify_image firmware.bin
reset run
```

`--host` and `--port` default to `127.0.0.1` and `6666` (OpenOCD's
Tcl-RPC port), and can also be set via the `CALLE_HOST` / `CALLE_PORT`
environment variables. Explicit flags win over env vars, which win
over the built-in default. `-h`/`--help`/`help` are recognized
anywhere on the command line and print usage instead of trying to
connect.

`-v` / `--verbose` logs each command sent and its response size (to
stderr, via `std.log`); `-vv` additionally logs the full response
body. Reconnects are logged at `-v` already, shown inline as
`[reconnected]` on stdout right before the (now successful) response.

**Connection resilience:** the CLI uses `session.Reconnecting` with up
to 3 connect attempts and exponential backoff (200ms, 400ms, 800ms...)
if a command fails - see the Session section below.

### Config file

An optional `.calle.conf` in the current directory sets per-project
defaults for `host`/`port`:

```
# .calle.conf
host = 192.168.1.50
port = 6666
```

One `key = value` per line, `#` starts a comment, blank lines are
ignored. Precedence, highest to lowest: CLI flags (`--host`/`--port`)
> `.calle.conf` > `CALLE_HOST`/`CALLE_PORT` env vars > built-in
default (`127.0.0.1:6666`). A missing `.calle.conf` is not an error;
an unparseable one (unknown key, bad port, line without `=`) is,
reported clearly rather than silently ignored. Parsing lives in
`src/cli/config_file.zig`, kept as a pure function (string in, parsed
struct out) so it's unit tested without touching the filesystem;
`main.zig` does the actual file read.

**Breaking change note:** earlier versions took `host`/`port` as
positional arguments (`calle 127.0.0.1 6666`) and ran a one-shot
command via `calle host port -- "command"`. That grammar became
ambiguous once real subcommand names existed (is `targets` a hostname
or the `targets` subcommand?), so host/port moved to `--host`/`--port`
flags and raw commands moved to the explicit `raw "<command>"`
subcommand.

Argument parsing (`src/cli/args.zig`) and the subcommand-to-OpenOCD-
command mapping (`src/cli/dispatch.zig`) are both unit tested. This
matters because `main.zig` itself isn't: it's a separate executable
root module, not part of the `calle` library module that
`zig build test` exercises - so any logic worth testing needs to live
in a file the library imports, not in `main.zig` directly.

### Two command layers

There are two independent places that know how to build OpenOCD
command strings, and that's not an accident-turned-into-a-feature -
it's a real seam that's worth understanding if you're extending
either:

- `commands/commands.zig` + `commands/flash.zig` +
  `commands/registers.zig` + `commands/breakpoints.zig` +
  `commands/memory.zig` - a typed *library* API for code that holds a
  `Session` directly (`session: anytype`, works with a session passed
  by value or by pointer).
- `cli/dispatch.zig` - a typed *CLI* mapping from a parsed
  `Subcommand` to a command string, with no session/networking
  involved at all.

They currently duplicate a fair number of command strings by now
(`reset halt`, `flash write_image ...`, `bp`/`wp`, `reg`,
`mdw`/`mww`...). The reason they're not unified: the CLI uses
`session.Reconnecting`, whose `exec`/`execAlloc` take a pointer
receiver (`self: *Self`, since reconnecting mutates the session's
transport) - calling that through `commands.zig`'s
`session: anytype` value-parameter pattern requires callers to
remember to pass `&session` rather than `session`, which is an easy
thing to get subtly wrong. Keeping `dispatch.zig` as a plain,
session-free string builder sidesteps that entirely. See
[ROADMAP.md](ROADMAP.md) for the plan to revisit this once there's a
second real consumer of the library API to design against.

## Testing

`zig build test` covers the logic (mock-based, no network). For a
manual, end-to-end verification checklist covering the CLI, real TCP
connections, reconnect/backoff timing, and the config file - things
that only show up with real bytes on a real socket - see
[TESTING.md](TESTING.md). It uses the fake OpenOCD servers in
`scripts/` so no real hardware or OpenOCD install is needed.

`zig build test` covers:

- Telnet framing: newline handling, IAC filtering, buffer overflow,
  and the allocator-backed growable variant
- Tcl-RPC framing: `0x1a` separation, and the allocator-backed
  growable variant
- Session layer: command out, response in, for both protocols and both
  `exec`/`execAlloc`
- Commands layer: `resetHalt`, `raw`
- Flash commands: `writeImage` (with and without an explicit address),
  `verifyImage`
- Register commands: `list`, `read`, `write`
- Breakpoint/watchpoint commands: set/remove/list for both, with and
  without the optional `hw` flag / watch mode
- Memory commands: `readWords` (with/without count), `writeWord`,
  `dumpImage`
- CLI argument parsing (`src/cli/args.zig`): defaults, `--host`/`--port`
  flags, `-v`/`-vv`/`--verbose`, `-h`/`--help`/`help` in any position,
  env var fallback, flag-over-env precedence, every subcommand's
  parsing (including `flash write` with/without `--addr`, hex and
  decimal addresses, `raw`), and error cases (missing flag value,
  invalid port, unknown subcommand, missing subcommand argument)
- CLI command dispatch (`src/cli/dispatch.zig`): every `Subcommand`
  maps to the right OpenOCD command string, including the
  `.repl -> error.NotACommand` guard and buffer-too-small handling
- Reconnect logic (`session.Reconnecting`): succeeds without
  reconnecting when healthy, reconnects and retries once on failure,
  surfaces the original error if the retry also fails, same for both
  `exec` and `execAlloc`; multi-attempt reconnect with `delay_fn`
  called with the right attempt numbers, and giving up (surfacing the
  original command error) once `max_connect_attempts` is exhausted
- Config file parsing (`src/cli/config_file.zig`): host/port parsing,
  comments and blank lines ignored, whitespace trimming, and error
  cases (line without `=`, invalid port, unknown key)
- REPL line reading (`src/cli/line_reader.zig`): normal lines, CRLF
  stripping, EOF handling, multi-line sequences, and - the reason this
  module exists - a regression test that an oversized line is fully
  drained rather than leaking its remainder into the next line read
- Script file parsing (`src/cli/script_file.zig`): blank lines and
  comments skipped, whitespace trimmed, a file with no trailing
  newline, a file of only comments/blanks, and a realistic
  flash-and-verify script

The allocator-backed path (`execAlloc` / `readResponseAlloc`) has also
been smoke-tested against a fake OpenOCD server returning a ~9 KB
response - well past what the old fixed 4096-byte buffer could hold -
to confirm it actually avoids the truncation problem it was built to
fix. Reconnect logic has additionally been smoke-tested against a real
TCP server that hangs up hard after one command and comes back up on
the same port a second later - the client reconnects transparently.
Every typed subcommand - including all 13 register/breakpoint/memory
ones added later - has been run end-to-end against a real fake
OpenOCD server, plus an unknown subcommand correctly prints usage and
exits non-zero instead of trying to connect. Backoff was verified
against a real socket too: a server down for 500ms produces two
logged failed attempts with growing delays (`-v`) before the third
attempt succeeds. Script mode was verified against a real socket for
all four commands of a realistic flash-and-verify script, `-v`'s
completion summary, a missing script file, and - the important
one - that a mid-script failure genuinely stops execution rather than
sending the remaining commands anyway.
The config file's full precedence chain (file-only, CLI-over-file,
file-over-env, missing file, malformed file) was verified end-to-end
as well.

All of it goes through `MockTransport`, so it runs without any real
network connection or a running OpenOCD instance - useful for CI later
on (see [ROADMAP.md](ROADMAP.md)).

### Gotcha: `refAllDecls` is not recursive

`std.testing.refAllDecls` only walks one level of declarations deep.
If file A re-exports file B (`pub const b = @import("b.zig");`) and
only A is reached by the root test's `refAllDecls`, B's own top-level
declarations are referenced, but B's *nested* re-exports are not - so
if B itself re-exports file C the same way, C's tests won't run unless
something else forces C to be analyzed.

The fix used throughout this project: any file that re-exports a
sub-module (like `commands.zig` re-exporting `flash.zig`) gets its own
`test { std.testing.refAllDecls(@This()); }` block, so the chain of
references actually reaches all the way down. If you add a new
sub-module and its tests don't show up in the `zig build test` count,
this is almost always why.

### Gotcha: `main.zig` has zero test coverage

`main.zig` is a separate executable root module, not part of the
`calle` library module - `zig build test` never touches it. A real bug
(`LineTooLong` not draining the rest of the oversized line, so the
leftover bytes got misread as a separate line on the next REPL prompt)
lived there undetected until manual testing turned it up - see
[TESTING.md](TESTING.md) and the git history around
`src/cli/line_reader.zig` for the story.

The house rule this led to: any logic in `main.zig` beyond direct I/O
plumbing (argument parsing, config file parsing, command dispatch,
line reading, ...) gets pulled into its own file under `src/cli/`,
written as a pure function wherever possible, with real unit tests.
`main.zig` itself should only ever be "glue": open a socket, read a
byte, call into a tested function, write a byte. If you're tempted to
add a `while` loop with actual decision-making directly in
`main.zig`, that's usually a sign it wants to be a new `src/cli/*.zig`
file instead.

## Toolchain notes

This project targets Zig 0.16.0 (`minimum_zig_version` in
`build.zig.zon`). Zig 0.16 changed the networking API substantially
(`std.Io` as an interface, "Juicy Main" via `std.process.Init`)
compared to earlier versions - if you're coming from 0.13/0.14 muscle
memory, `src/transport/tcp.zig` and `src/main.zig` are the two places
that look different from what you might expect.

If `zig build` ever complains about the `fingerprint` field in
`build.zig.zon`, it prints the correct value to use directly in the
error message - just paste it in.

## CI

`.github/workflows/ci.yml` runs `zig build test`, `zig build`, and
`zig fmt --check .` on every push/PR to `main`, using
[`mlugg/setup-zig`](https://github.com/mlugg/setup-zig) to install the
Zig version pinned in `build.zig.zon`.
