#!/usr/bin/env bash
# Pair two e2e peers over TCP and score TAP, following capnp-zig's
# tools/e2e_self.zig contract (plan section 8, M4): reserve a port, start
# the server, probe until it accepts, run the client under a deadline,
# count `ok `/`not ok ` lines on stdout+stderr, and require exit 0 with at
# least one passing line per schema.
#
#   e2e-pair.sh [--transport=tcp|unix] <server-bin> <client-bin> [schema ...]
#
# Default schemas: the five matrix scenarios.
set -uo pipefail
cd "$(dirname "$0")/.."

TRANSPORT=tcp
if [ "${1:-}" = "--transport=unix" ] || [ "${1:-}" = "-t unix" ]; then
  TRANSPORT=unix; shift
fi
SERVER="$1"; CLIENT="$2"; shift 2
SCHEMAS=("$@")
[ ${#SCHEMAS[@]} -eq 0 ] && SCHEMAS=(game_world chat inventory matchmaking resolve_disembargo)

total_pass=0; total_fail=0
for schema in "${SCHEMAS[@]}"; do
  sock=""
  if [ "$TRANSPORT" = unix ]; then
    sockdir=$(mktemp -d /tmp/capnp-e2e-unix-XXXXXX)
    sock="$sockdir/$schema.sock"
    host_arg="unix:$sock"
    probe() { [ -S "$sock" ] && python3 -c "
import socket, sys
try:
    socket.socket(socket.AF_UNIX).connect('$sock'); sys.exit(0)
except OSError:
    sys.exit(1)"; }
  else
    port=$(python3 -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); print(p)')
    host_arg="127.0.0.1"
    probe() { python3 -c "
import socket, sys
try:
    socket.create_connection(('127.0.0.1', $port), timeout=0.2).close(); sys.exit(0)
except OSError:
    sys.exit(1)"; }
  fi
  if [ "$TRANSPORT" = unix ]; then
    "$SERVER" --host "$host_arg" --schema "$schema" >/dev/null 2>&1 &
  else
    "$SERVER" --host "$host_arg" --port "$port" --schema "$schema" >/dev/null 2>&1 &
  fi
  server_pid=$!
  # Probe until the server accepts (max 30 s).
  ready=0
  for _ in $(seq 1 300); do
    if probe; then ready=1; break; fi
    sleep 0.1
  done
  if [ "$ready" != 1 ]; then
    echo "not ok - $schema: server never became ready"
    total_fail=$((total_fail+1))
    kill $server_pid 2>/dev/null; wait $server_pid 2>/dev/null
    continue
  fi
  # Client under an absolute 60 s deadline; TAP lines counted on both streams.
  if [ "$TRANSPORT" = unix ]; then
    out=$( { timeout 60 "$CLIENT" --host "$host_arg" --schema "$schema" 2>&1; echo "EXIT=$?"; } )
  else
    out=$( { timeout 60 "$CLIENT" --host "$host_arg" --port "$port" --schema "$schema" 2>&1; echo "EXIT=$?"; } )
  fi
  exit_code=$(echo "$out" | grep -o 'EXIT=[0-9]*' | tail -1 | cut -d= -f2)
  pass=$(echo "$out" | grep -c '^ok ')
  fail=$(echo "$out" | grep -c '^not ok ')
  if [ "$exit_code" != 0 ] || [ "$pass" -eq 0 ]; then
    fail=$((fail+1))
  fi
  echo "# $schema: pass=$pass fail=$fail exit=$exit_code"
  echo "$out" | grep -E '^(ok |not ok |1\.\.|# )' | sed 's/^/  /'
  total_pass=$((total_pass+pass)); total_fail=$((total_fail+fail))
  kill $server_pid 2>/dev/null; wait $server_pid 2>/dev/null
  [ -n "$sock" ] && rm -rf "$sockdir"
done
echo "1..$((total_pass+total_fail))"
echo "# total pass=$total_pass fail=$total_fail"
[ "$total_fail" -eq 0 ] && [ "$total_pass" -gt 0 ]
