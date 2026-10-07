#!/usr/bin/env bash
# M6 Zig->Swift QUIC lane (plan §8): start the Swift QUIC Greeter server
# (mvp-e2e --serve-quic), run the capnp-zig QUIC client (zig-peer --client),
# and surface the client's TAP. Exit 0 only if every line is ok.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_BIN="$(swift build --product mvp-e2e --show-bin-path 2>/dev/null)/mvp-e2e"
ZIG_PEER="interop/zig-peer/zig-out/bin/zig-peer"

"$SWIFT_BIN" --serve-quic > /tmp/capnp-swift-quic-serve.$$ 2>&1 &
SERVER_PID=$!
cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    rm -f /tmp/capnp-swift-quic-serve.$$
}
trap cleanup EXIT

PORT=""
for _ in $(seq 1 100); do
    PORT=$( { grep -o 'port=[0-9]*' "/tmp/capnp-swift-quic-serve.$$" || true; } | head -1 | cut -d= -f2)
    [ -n "$PORT" ] && break
    sleep 0.1
done
[ -n "$PORT" ] || { echo "quic-pair: server never reported a port" >&2; exit 1; }
echo "# swift QUIC server pid $SERVER_PID on 127.0.0.1:$PORT"

"$ZIG_PEER" --client --transport quic --host 127.0.0.1 --port "$PORT"
