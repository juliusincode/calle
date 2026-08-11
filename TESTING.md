# Manual verification guide (TESTING.md)

This is a step-by-step checklist for manually verifying calle's
functionality - useful after pulling changes, before a release, or
just to see everything work. `zig build test` (automated, mock-based)
covers the logic; this guide covers the parts that only show up when
real bytes go over a real socket: the CLI, the TCP transport, and
timing-sensitive things like reconnects.

No real hardware or OpenOCD installation is required - `scripts/` has
two small fake OpenOCD servers for this purpose. If you *do* have real
hardware, see [With real OpenOCD](#with-real-openocd-optional) at the
end.

Estimated time: ~15 minutes for the full checklist.

## 0. Prerequisites

```sh
zig version   # should print 0.16.0 or match build.zig.zon's minimum_zig_version
python3 --version   # any Python 3 works, used only for the fake servers
```

## 1. Automated checks

Run these first - if any of these fail, nothing below will work
either.

```sh
zig build test --summary all   # should print N/N tests passed
zig build                       # should complete with no output = success
zig fmt --check .               # should complete with no output = success
```

**Expected:** all three commands exit 0. The test count grows over
time; check the number printed matches what [README.md](README.md)
claims for "current" - if it doesn't, either a test was added without
updating the README, or something's broken.

## 2. Start the fake OpenOCD server

In a separate terminal, from the repo root:

```sh
python3 scripts/fake_openocd.py 6666
```

Leave it running. It logs every command it receives and echoes back
`echo: <command>`, so you can visually confirm exactly what calle put
on the wire. All steps below assume it's running on port 6666 unless
noted otherwise.

## 3. CLI basics

```sh
zig build run -- -h
```
**Expected:** usage text, no attempt to connect.

```sh
zig build run -- --host 127.0.0.1 --port 6666 targets
```
**Expected:** prints `echo: targets`. Server log shows `received:
b'targets'`.

```sh
zig build run -- --host 127.0.0.1 --port 6666 frobnicate
```
**Expected:** clean error (`error: UnknownSubcommand`) + usage text,
exit code 1. No connection attempt reaches the server (check the
server's log didn't print anything new).

## 4. REPL mode

```sh
zig build run -- --host 127.0.0.1 --port 6666
```
**Expected:** `connected. type 'quit' to exit.`, then a `calle>`
prompt. Type a few commands, confirm each gets echoed back correctly
and the server log shows each one. Type `quit` - process exits
cleanly (exit code 0).

## 5. Every typed subcommand

Run each of these (one-shot mode) and confirm the server log shows
the *exact* command string noted:

| Command | Expected on the wire |
|---|---|
| `calle --host 127.0.0.1 --port 6666 halt` | `halt` |
| `calle --host 127.0.0.1 --port 6666 resume` | `resume` |
| `calle --host 127.0.0.1 --port 6666 targets` | `targets` |
| `calle --host 127.0.0.1 --port 6666 reset halt` | `reset halt` |
| `calle --host 127.0.0.1 --port 6666 reset run` | `reset run` |
| `calle --host 127.0.0.1 --port 6666 flash probe` | `flash probe 0` |
| `calle --host 127.0.0.1 --port 6666 flash info` | `flash info 0` |
| `calle --host 127.0.0.1 --port 6666 flash write fw.bin` | `flash write_image erase fw.bin` |
| `calle --host 127.0.0.1 --port 6666 flash write fw.bin --addr 0x08000000` | `flash write_image erase fw.bin 0x8000000` |
| `calle --host 127.0.0.1 --port 6666 flash verify fw.bin` | `verify_image fw.bin` |
| `calle --host 127.0.0.1 --port 6666 reg` | `reg` |
| `calle --host 127.0.0.1 --port 6666 reg pc` | `reg pc` |
| `calle --host 127.0.0.1 --port 6666 reg r0 0x1000` | `reg r0 0x1000` |
| `calle --host 127.0.0.1 --port 6666 bp` | `bp` |
| `calle --host 127.0.0.1 --port 6666 bp 0x08000000 2` | `bp 0x8000000 2` |
| `calle --host 127.0.0.1 --port 6666 bp 0x08000000 4 hw` | `bp 0x8000000 4 hw` |
| `calle --host 127.0.0.1 --port 6666 rbp 0x08000000` | `rbp 0x8000000` |
| `calle --host 127.0.0.1 --port 6666 wp` | `wp` |
| `calle --host 127.0.0.1 --port 6666 wp 0x20000000 4 w` | `wp 0x20000000 4 w` |
| `calle --host 127.0.0.1 --port 6666 rwp 0x20000000` | `rwp 0x20000000` |
| `calle --host 127.0.0.1 --port 6666 mem read 0x20000000` | `mdw 0x20000000` |
| `calle --host 127.0.0.1 --port 6666 mem read 0x20000000 8` | `mdw 0x20000000 8` |
| `calle --host 127.0.0.1 --port 6666 mem write 0x20000000 0x1234` | `mww 0x20000000 0x1234` |
| `calle --host 127.0.0.1 --port 6666 mem dump ram.bin 0x20000000 1024` | `dump_image ram.bin 0x20000000 0x400` |
| `calle --host 127.0.0.1 --port 6666 raw "custom command"` | `custom command` |

(Prefix each with `zig build run --` when running from source rather
than a built binary.)

## 6. Large responses (execAlloc / growable buffer)

There's no built-in command that produces a huge response, but you can
fake one by editing `scripts/fake_openocd.py`'s echo line temporarily
to return something large (e.g. `resp = b"echo: " + cmd + b" " + b"x" * 10000`),
restart the server, and confirm calle prints the whole thing without
truncating or erroring. Revert the edit afterward.

## 7. Verbosity flags

```sh
zig build run -- --host 127.0.0.1 --port 6666 -v targets
```
**Expected:** stderr shows `info: connecting to ...`, `info: > targets`,
`info: < (N bytes)`. stdout still just shows `echo: targets`.

```sh
zig build run -- --host 127.0.0.1 --port 6666 -vv targets
```
**Expected:** same as above, plus a `debug: < echo: targets` line
(only visible in debug builds - `zig build` without `-Doptimize`
defaults to Debug, so this should show).

```sh
zig build run -- --host 127.0.0.1 --port 6666 targets 2>/dev/null
```
**Expected:** no log lines at all (quiet by default), just
`echo: targets` on stdout.

## 8. Config file precedence

```sh
mkdir -p /tmp/calle-test && cd /tmp/calle-test
cat > .calle.conf <<'EOF'
host = 127.0.0.1
port = 6666
EOF
/path/to/calle/zig-out/bin/calle targets
```
**Expected:** connects using the config file's host/port with zero
flags given - `echo: targets`.

```sh
/path/to/calle/zig-out/bin/calle --port 9999 targets
```
**Expected:** tries port 9999 instead (should fail with
`ConnectionRefused` unless something's listening there) - confirms
CLI flags override the config file.

```sh
CALLE_HOST=10.0.0.1 CALLE_PORT=1234 /path/to/calle/zig-out/bin/calle targets
```
**Expected:** still connects to 127.0.0.1:6666 from the config file,
*not* the env vars - confirms config file beats env vars.

```sh
echo "protocol = telnet" > .calle.conf
/path/to/calle/zig-out/bin/calle targets
```
**Expected:** clean error (`error: failed to parse .calle.conf:
UnknownKey`), exit code 1, no connection attempt.

```sh
rm .calle.conf
/path/to/calle/zig-out/bin/calle --host 127.0.0.1 --port 6666 targets
```
**Expected:** works normally - a missing config file is not an error.

Clean up: `rm -rf /tmp/calle-test`.

## 9. Batch/scripting mode

```sh
cat > /tmp/flash-and-verify.calle <<'EOF'
# flash-and-verify.calle
reset halt
flash write_image erase firmware.bin 0x08000000
verify_image firmware.bin
reset run
EOF
zig build run -- --host 127.0.0.1 --port 6666 script /tmp/flash-and-verify.calle
```
**Expected:** all four commands run in order; server log shows all
four `received:` lines; exit code 0.

```sh
zig build run -- --host 127.0.0.1 --port 6666 script /tmp/does-not-exist.calle
```
**Expected:** clean error (`could not read script file ...
FileNotFound`), exit code 1.

To verify the "stops at first failure" behavior specifically, you need
a server that fails partway through - `scripts/flaky_openocd.py`
isn't quite shaped for this (it always succeeds on the first command),
so this one's easiest to confirm by reading `runScript` in
`src/main.zig` alongside its test coverage, or by temporarily editing
`scripts/fake_openocd.py` to close the connection after N commands and
confirming (via the server's log) that commands after the failure
point never arrive.

## 10. Reconnect + backoff

Stop `fake_openocd.py` if it's still running (Ctrl+C), then:

```sh
python3 scripts/flaky_openocd.py 6668 0.5 &
sleep 0.3
(printf 'targets\n'; sleep 0.1; printf 'targets\n'; printf 'quit\n') \
  | zig build run -- --host 127.0.0.1 --port 6668 -v
```

**Expected:** first `targets` returns `first-response-before-drop`.
Server then hangs up hard and comes back after 0.5s. The second
`targets` triggers (on stderr) `reconnect attempt 1 failed, retrying
in 200ms...` and `reconnect attempt 2 failed, retrying in 400ms...`,
then stdout shows `[reconnected]` followed by
`second-response-after-reconnect`. Exit code 0.

If the timing doesn't line up on your machine (the reconnect succeeds
on the first attempt with no backoff messages, or fails entirely),
adjust the `sleep 0.1` between the two `targets` and/or the downtime
argument to `flaky_openocd.py` - see the comments in the script.

## 11. Argument validation edge cases

```sh
zig build run -- --host                    # missing flag value
zig build run -- --port not-a-number       # invalid port
zig build run -- flash write               # missing required path
zig build run -- bp 0x1000                 # missing required len
zig build run -- wp 0x1000 4 x             # invalid watch mode
zig build run -- mem erase                 # unknown mem subcommand
```
**Expected:** every one of these prints a clean, specific error and
exits non-zero - no stack traces, no attempted connection.

## With real OpenOCD (optional)

If you have OpenOCD and a supported debug adapter:

```sh
openocd -f interface/<your-adapter>.cfg -f target/<your-target>.cfg
```

Then repeat section 5 against `--port 6666` (OpenOCD's real Tcl-RPC
port) instead of the fake server, with a real target connected. Watch
for:

- Responses that don't match the fake server's `echo:` format - that's
  expected, real OpenOCD returns real data (register values, flash
  bank info, etc.) instead of an echo.
- `flash write`/`flash verify` against a real flash bank - use a
  throwaway/test image first, this writes real flash.
- The `[reconnected]` behavior if you restart OpenOCD mid-session.
