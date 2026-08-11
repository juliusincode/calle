#!/usr/bin/env python3
"""A minimal fake OpenOCD Tcl-RPC server, for manually exercising calle
without real hardware or a real OpenOCD instance.

Speaks the same wire format as OpenOCD's Tcl-RPC port (0x1a-delimited
commands/responses) and echoes back "echo: <command>" for anything it
receives, so you can see exactly what calle sent on the wire.

Usage:
    python3 scripts/fake_openocd.py [port]   # default port 6666

See TESTING.md for how this fits into the manual verification flow.
"""

import socket
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 6666

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
print(f"fake_openocd: listening on 127.0.0.1:{port}", flush=True)

while True:
    conn, addr = s.accept()
    print(f"fake_openocd: client connected from {addr}", flush=True)
    buf = b""
    while True:
        data = conn.recv(4096)
        if not data:
            break
        buf += data
        while b"\x1a" in buf:
            cmd, buf = buf.split(b"\x1a", 1)
            print(f"fake_openocd: received: {cmd!r}", flush=True)
            resp = b"echo: " + cmd
            conn.sendall(resp + b"\x1a")
    conn.close()
    print("fake_openocd: client disconnected", flush=True)
