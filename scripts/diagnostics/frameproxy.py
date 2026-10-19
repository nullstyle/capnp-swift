#!/usr/bin/env python3
"""A TCP proxy that logs every Cap'n Proto frame between two e2e peers.

  frameproxy.py LISTEN_PORT TARGET_PORT LOG [--coalesce N]

Point the client at 127.0.0.1:LISTEN_PORT and the server at TARGET_PORT.
Each segment-table frame is decoded with `capnp decode rpc.capnp Message`
($CAPNP_RPC_SCHEMA, default Homebrew's) and written to LOG with a timestamp,
plus one line per read ("chunk N bytes"), so the log shows which frames
reached the other side in one read. The proxy forwards each read as one
write and decodes later, so it does not change the timing.

--coalesce N holds the N client->server frames after the first one
(Bootstrap) and sends them in ONE write: the server then reads them in one
push. plan section 8 M8 used `--coalesce 4` to force the "answer still
pending" case (native H9) with the Zig client.
"""
import os
import queue
import socket
import struct
import subprocess
import sys
import threading
import time

RPC = os.environ.get("CAPNP_RPC_SCHEMA", "/opt/homebrew/include/capnp/rpc.capnp")
t0 = time.monotonic()
pending = queue.Queue()  # (log file, line head, frame or None), decoded by logger()


def frame_len(buf):
    """Length of the first complete frame in buf, or None."""
    if len(buf) < 4:
        return None
    nseg = struct.unpack_from("<I", buf, 0)[0] + 1
    head = 4 + 4 * nseg
    head += head % 8
    if len(buf) < head:
        return None
    total = head + 8 * sum(struct.unpack_from("<%dI" % nseg, buf, 4))
    return total if len(buf) >= total else None


def note(logf, text, frame=None):
    pending.put((logf, "%9.3f ms %s" % ((time.monotonic() - t0) * 1000, text), frame))


def logger():
    while True:
        logf, head, frame = pending.get()
        if frame is not None:
            out = subprocess.run(["capnp", "decode", "--short", RPC, "Message"], input=frame, capture_output=True)
            head += " " + (out.stdout or out.stderr).decode(errors="replace").strip()
        logf.write(head + "\n")
        logf.flush()


def pump(src, dst, direction, logf, coalesce):
    buf, seen, held = b"", 0, []
    while True:
        try:
            data = src.recv(65536)
        except OSError:
            data = b""
        if not data:
            if held:
                dst.sendall(b"".join(held))
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            return
        note(logf, "%s chunk %d bytes" % (direction, len(data)))
        holding = coalesce > 0
        if not holding:
            dst.sendall(data)
        buf += data
        while (n := frame_len(buf)) is not None:
            frame, buf = buf[:n], buf[n:]
            seen += 1
            if holding and seen > 1:
                held.append(frame)
                note(logf, "%s [held]" % direction, frame)
                if len(held) == coalesce:
                    dst.sendall(b"".join(held))
                    note(logf, "%s sent %d held frames in one write" % (direction, coalesce))
                    held, coalesce = [], 0
                continue
            if holding:
                dst.sendall(frame)
            note(logf, direction, frame)


def main():
    listen, target, logpath = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    coalesce = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[4] == "--coalesce" else 0
    logf = open(logpath, "w")
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", listen))
    ls.listen(8)
    threading.Thread(target=logger, daemon=True).start()
    print("READY", flush=True)
    while True:
        c, _ = ls.accept()
        s = socket.create_connection(("127.0.0.1", target))
        for sock in (c, s):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=pump, args=(c, s, "C->S", logf, coalesce), daemon=True).start()
        threading.Thread(target=pump, args=(s, c, "S->C", logf, 0), daemon=True).start()


if __name__ == "__main__":
    main()
