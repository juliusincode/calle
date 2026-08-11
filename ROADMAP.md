# Roadmap

calle started as a minimal, modular OpenOCD client. This roadmap tracks
where it's headed. Nothing here is a promise or a deadline - just the
plan as it currently stands, roughly ordered by priority.

## Foundations (done)

The initial architecture, still the shape everything else builds on:

- [x] Transport interface (vtable) with TCP and in-memory Mock backends
- [x] Two protocol framings: telnet-line (port 4444) and Tcl-RPC (port 6666)
- [x] Generic `Session(Protocol)` wiring transport + protocol into `exec()`
- [x] Typed command helpers (`commands/commands.zig`,
      `commands/flash.zig`) as a library API, independent of the CLI
- [x] Unit tests, fully mock-based, no real network needed (run
      `zig build test` for the current count - it keeps growing)
- [x] Verified end-to-end against a real Zig 0.16.0 compiler and fake
      OpenOCD servers throughout, not just at unit-test level

Everything below tracks what's been added on top of that foundation,
and what's still open. See [README.md](README.md) for the current CLI
grammar and architecture in detail - it's kept up to date, this file
is more of a changelog-plus-plan.

## Near-term

- [x] **Clean process exit on connect/command failure.** `main()` used
      to `return err` after logging, which made Zig dump its raw error
      return trace (file/line stack of internal std.Io/network
      frames) on top of the already-printed clean error message - e.g.
      just running `calle` with nothing listening produced a full
      stack trace instead of a one-line error. Fixed by calling
      `std.process.exit(1)` after logging instead, consistently across
      every failure path in `main.zig` (connect, command dispatch,
      command execution, config file, non-EOF stdin errors).
- [x] **`LineTooLong` didn't drain the rest of the oversized line.**
      Found while manually testing the fix above: on a too-long REPL
      input line, the old code returned the error without consuming
      the remaining unread bytes up to the newline - they'd then get
      misread as a separate, shorter "line" on the next prompt. Fixed,
      and the line-reading logic was pulled out into
      `src/cli/line_reader.zig` (pure, byte-source-abstracted) so it
      has real unit test coverage now, including a regression test
      for this exact bug - it had none before precisely because it
      lived in `main.zig`, which `zig build test` doesn't reach.

- [x] **Response buffer overflow handling.** Added `execAlloc` /
      `readResponseAlloc` (allocator-backed, growable) alongside the
      original fixed-buffer `exec` / `readResponse`. The CLI now uses
      `execAlloc` throughout, so REPL and one-shot responses no longer
      truncate. `exec` with a fixed buffer is still available for
      callers that want a no-allocation fast path with a known
      response size.
- [ ] **Structured error responses.** OpenOCD's Tcl-RPC returns plain
      text; there's no reliable success/failure signal beyond
      convention (e.g. `"0"` for many commands). Investigate whether
      OpenOCD exposes anything more structured, and otherwise document
      the conventions calle relies on.
- [x] **Connection resilience.** `session.Reconnecting(Protocol)` wraps
      a `Session` and retries once with a freshly established
      transport if a command fails (e.g. OpenOCD restarted, or a
      transient network drop). Exactly one retry - a command failing
      twice in a row surfaces as a real error rather than retrying
      forever. The CLI uses `ReconnectingTclSession` by default.
      Verified against a real socket: a fake server that hangs up hard
      after one command and comes back up on the same port a second
      later - the client reconnects transparently, no error surfaced
      to the user.
- [x] **Env var support** for host and port (`CALLE_HOST` /
      `CALLE_PORT`), CLI args still take precedence. A config *file*
      (for per-project defaults, default protocol, etc.) is still
      open.
- [x] **Config file support**: an optional `.calle.conf` in the
      current directory (`host = ...` / `port = ...`, `#` comments,
      one setting per line). Precedence: CLI flags > `.calle.conf` >
      `CALLE_HOST`/`CALLE_PORT` env vars > built-in default. Parsing
      (`src/cli/config_file.zig`) is pure and unit tested; reading the
      actual file happens in `main.zig` and was verified end-to-end
      (config-file-only, CLI-overrides-config-file,
      config-file-overrides-env-var, missing file falls through
      cleanly, malformed file reports a clean error instead of a
      crash). Saved target aliases / other settings beyond host+port
      are still open if they turn out to be useful.
- [x] **CI.** `.github/workflows/ci.yml` runs `zig build test`,
      `zig build`, and `zig fmt --check .` on every push/PR to `main`.
      Uses `mlugg/setup-zig@v2`, which resolves the Zig version from
      `build.zig.zon`'s `minimum_zig_version` automatically. A git repo
      was also initialized (this was missing until now) - push it to
      GitHub (or wherever) to activate the workflow; it does nothing
      until there's a remote to trigger on.

## Medium-term

- [ ] **Unify the two command layers.** `commands/commands.zig` +
      `commands/flash.zig` + `commands/registers.zig` +
      `commands/breakpoints.zig` + `commands/memory.zig` (a typed
      *library* API, `session: anytype`, value-receiver friendly) and
      `cli/dispatch.zig` (a typed *CLI* mapping, string-building only)
      currently duplicate the OpenOCD command strings for things like
      `reset halt`, `flash write_image`, `bp`/`wp`, `reg`, `mdw`/`mww`.
      The duplication has grown with each new command area, which
      makes this more worth doing than when it was just `reset halt`
      and `flash write_image` - but the underlying reason it hasn't
      happened yet is unchanged: `session.Reconnecting`'s methods take
      a pointer receiver (`self: *Self`, since reconnecting mutates
      state), which doesn't compose cleanly with `commands.zig`'s
      `session: anytype` value-parameter pattern without callers
      remembering to pass `&session` explicitly. Worth revisiting once
      there's a second consumer of `commands/commands.zig` to see
      which direction (library helpers take pointers everywhere, or
      dispatch.zig calls into the library layer) fits better in
      practice.

- [x] **Reconnect backoff/delay.** `session.Reconnecting` now supports
      `max_connect_attempts` (how many times to retry *establishing* a
      connection) and an optional `delay_fn` called between failed
      attempts. The CLI uses 3 attempts with exponential backoff
      (200ms, 400ms, ...) via `std.Io.sleep`. `Reconnecting` itself
      stays free of any `std.Io`/timing dependency - the actual
      sleeping lives in `main.zig`'s `TcpConnectCtx.delay`, so the
      retry-count logic is still fully unit testable with
      `MockTransport` and no real clock. Verified end-to-end: a fake
      server down for 500ms logs two failed attempts with growing
      backoff before the third attempt succeeds and the session
      recovers transparently.
- [x] **Verbosity flags** (`-v`/`-vv`/`--verbose`). `-v` logs each
      command sent and response size; `-vv` additionally logs the full
      response body (via `std.log.debug`, so it only shows in debug
      builds by default) - useful when redirecting stdout elsewhere but
      still wanting to see responses in the terminal/log. Reconnect
      events (`[reconnected]`) are shown at `-v` already. Parsing is
      unit tested in `cli/args.zig`; the logging behavior itself was
      verified via smoke test since it lives in `main.zig`.

- [x] **Non-interactive mode** for scripting: `calle [host] [port] --
      <command>` runs one raw command and exits (see README). This
      covers the "scriptable from a shell" need without a full
      subcommand parser yet.
- [x] **CLI argument validation.** `-h`/`--help`/`help` (in either
      position) print usage instead of being misparsed as a hostname;
      an invalid port reports a clean error instead of a raw parse
      panic. The parsing logic was moved to `src/cli/args.zig` (out of
      `main.zig`, which has no test coverage of its own) specifically
      so this class of bug gets caught by `zig build test` next time.
- [x] **Real command-line subcommands**: `calle halt`, `calle resume`,
      `calle targets`, `calle reset halt|run`, `calle flash
      probe|info|write <path> [--addr 0xADDR]|verify <path>`, plus
      `calle raw "<command>"` as an escape hatch. Host/port moved from
      positional args to `--host`/`--port` flags (breaking change from
      the earlier `calle [host] [port] -- <command>` grammar, which was
      ambiguous once subcommand names existed - see README). The
      subcommand -> OpenOCD-command-string mapping lives in
      `src/cli/dispatch.zig` as a pure function with its own unit
      tests, independent of `src/cli/args.zig`'s argument parsing.
      Note: this dispatch logic builds raw command strings directly
      rather than calling into `commands/commands.zig` /
      `commands/flash.zig` - see the "Two command layers" note in
      README for why, and the medium-term item below for unifying them.
- [ ] **Telnet transport polish.** The current telnet-line protocol
      handles the common case; OpenOCD's actual telnet console has a
      few more edge cases (prompt handling, multi-line command output)
      that aren't exercised yet.
- [x] **More typed commands**: registers (`commands/registers.zig` -
      `list`/`read`/`write`), breakpoints and watchpoints
      (`commands/breakpoints.zig` - `bp`/`rbp`/`wp`/`rwp`), and generic
      memory access (`commands/memory.zig` - `mdw`/`mww`/`dump_image`,
      moved here from `flash.zig` since `mww` isn't flash-specific).
      All exposed as typed CLI subcommands too (`reg`, `bp`, `rbp`,
      `wp`, `rwp`, `mem read|write|dump`). Command syntax verified
      against the OpenOCD User's Guide before implementing rather than
      guessed - see the doc comments in each file. 20 new unit tests
      (library + CLI parsing + dispatch), plus all 13 new subcommands
      run end-to-end against a real fake OpenOCD server. GDB-server
      control is still open (see below - it's a different enough shape
      that it's worth its own item rather than folding into this one).
- [ ] **GDB-server control**: commands like `gdb_port`, GDB-side
      breakpoint sync, or similar - deferred out of the "more typed
      commands" item above since it's less about single OpenOCD
      commands and more about how calle would relate to a GDB session
      at all; needs its own design pass rather than a quick addition.

## Longer-term / exploratory

- [ ] **Serial transport backend**, for talking to a debug adapter's
      CLI directly instead of through OpenOCD's TCP ports, following
      the same `Transport.VTable` pattern as `transport/tcp.zig`.
- [ ] **Batch/scripting mode**: read a sequence of commands from a
      file and execute them in order, useful for flashing/testing
      pipelines.
- [ ] **Packaging**: prebuilt binaries per platform, or a
      `build.zig.zon` dependency setup so other Zig projects can pull
      calle in as a library rather than just a standalone CLI.

## Explicitly out of scope (for now)

- Reimplementing SSH-grade features (encryption, multiplexing,
  port-forwarding). calle talks to OpenOCD directly on the local
  network / localhost; if you need an encrypted channel to a remote
  OpenOCD instance, tunnel it (e.g. via SSH port-forwarding) rather
  than calle reinventing that wheel.
- A GUI. calle stays a CLI/library tool.

## How to contribute to this roadmap

Pick an item, or propose a new one. The architecture (see
`README.md#architecture`) is deliberately built so that most additions
- new commands, new transports, new protocols - are additive: a new
file plus a couple of tests, without touching existing modules.
