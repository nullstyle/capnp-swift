#!/usr/bin/env bash
# The M6/H11 5-schema QUIC matrix: Swift client vs zig QUIC server and zig
# client vs Swift QUIC server, over the frozen baseline wire (ALPN
# capnp-rpc/1, stream 0, u32-LE frames). Readiness is the server's READY
# line (a QUIC listener has no TCP probe). Exit 0 only when every schema
# passes with zero `not ok` in both pairings.
#
#   e2e-pair-quic.sh <zig-server-bin> <zig-client-bin> [swift-bin-dir] [schema ...]
set -uo pipefail
cd "$(dirname "$0")/.."

ZS="$1"; ZC="$2"; SBIN="${3:-$(swift build --product e2e-swift-client --show-bin-path 2>/dev/null)}"
shift 3 || true
SCHEMAS=("$@")
[ ${#SCHEMAS[@]} -eq 0 ] && SCHEMAS=(game_world chat inventory matchmaking resolve_disembargo)
CERT=Tests/fixtures/tls/test-cert.pem
KEY=Tests/fixtures/tls/test-key.pem

total_pass=0; total_fail=0
for pairing in swift-to-zig zig-to-swift; do
  for schema in "${SCHEMAS[@]}"; do
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    log=$(mktemp /tmp/capnp-e2e-quic-XXXXXX); mv "$log" "$log.txt"; log="$log.txt"
    if [ "$pairing" = swift-to-zig ]; then
      "$ZS" --host 127.0.0.1 --port "$port" --schema "$schema" --transport quic \
        --cert-pem "$CERT" --key-pem "$KEY" >"$log" 2>&1 &
      CLIENT_ARGS=(--host 127.0.0.1 --port "$port" --schema "$schema" --transport quic)
      CLIENT="$SBIN/e2e-swift-client"
    else
      "$SBIN/e2e-swift-server" --host 127.0.0.1 --port "$port" --schema "$schema" --transport quic >"$log" 2>&1 &
      CLIENT_ARGS=(--host 127.0.0.1 --port "$port" --schema "$schema" --transport quic --insecure)
      CLIENT="$ZC"
    fi
    spid=$!
    ready=0
    for _ in $(seq 1 300); do grep -q READY "$log" 2>/dev/null && { ready=1; break; }; sleep 0.1; done
    if [ "$ready" != 1 ]; then
      echo "not ok - $schema ($pairing): server never became ready"
      echo "  # server output was:"; sed 's/^/  # /' "$log"
      total_fail=$((total_fail+1)); kill $spid 2>/dev/null; wait $spid 2>/dev/null; rm -f "$log"; continue
    fi
    out=$( { timeout 60 "$CLIENT" "${CLIENT_ARGS[@]}" 2>&1; echo "EXIT=$?"; } )
    ok=$(printf '%s' "$out" | grep -c "^ok "); nok=$(printf '%s' "$out" | grep -c "^not ok")
    ex=$(printf '%s' "$out" | grep -o "EXIT=[0-9]*" | tail -1)
    if [ "$nok" -eq 0 ] && [ "$ex" = "EXIT=0" ] && [ "$ok" -gt 0 ]; then
      total_pass=$((total_pass+1)); echo "ok - $schema ($pairing): $ok checks"
    else
      total_fail=$((total_fail+1)); echo "not ok - $schema ($pairing): ok=$ok not_ok=$nok $ex"
      printf '%s\n' "$out" | grep "not ok" | head -3
    fi
    kill $spid 2>/dev/null; wait $spid 2>/dev/null; rm -f "$log"
  done
done
echo "# total pass=$total_pass fail=$total_fail"
[ "$total_fail" -eq 0 ]
