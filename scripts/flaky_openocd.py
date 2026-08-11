#!/usr/bin/env python3
"""A fake OpenOCD Tcl-RPC server that answers one command, then hangs
up hard (RST, not a clean close), waits, and comes back up on the same
port - simulating OpenOCD restarting mid-session (e.g. after a `reset`
that power-cycles the debug adapter).

Use this to manually verify calle's reconnect + backoff behavior (see
TESTING.md). With `-v`/`-vv`, calle should log failed reconnect
attempts with growing delays before recovering transparently.

Usage:
    python3 scripts/flaky_openocd.py [port] [downtime_seconds]
    # defaults: port 6666, downtime 0.5s
"""

import socket
import struct
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 6666
downtime = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5


def serve_once(response: bytes, hang_up_hard: bool) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(1)
    print(f"flaky_openocd: listening on 127.0.0.1:{port}", flush=True)

    conn, _ = s.accept()
    print("flaky_openocd: client connected", flush=True)
    buf = b""
    while b"\x1a" not in buf:
        data = conn.recv(4096)
        if not data:
            break
        buf += data
    cmd, _, _ = buf.partition(b"\x1a")
    print(f"flaky_openocd: received: {cmd!r}", flush=True)
    conn.sendall(response + b"\x1a")

    if hang_up_hard:
        # SO_LINGER with a zero timeout forces an RST on close instead
        # of a clean FIN, so the client's *next* write fails right
        # away instead of hanging until a keepalive timeout.
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))

    conn.close()
    s.close()


serve_once(b"first-response-before-drop", hang_up_hard=True)
print(f"flaky_openocd: gone for {downtime}s, then restarting on the same port...", flush=True)
time.sleep(downtime)
serve_once(b"second-response-after-reconnect", hang_up_hard=False)
print("flaky_openocd: done", flush=True)
