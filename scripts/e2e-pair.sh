#!/usr/bin/env bash
# Pair two e2e peers over TCP and score TAP, following capnp-zig's
# tools/e2e_self.zig contract (plan section 8, M4): reserve a port, start
# the server, probe until it accepts, run the client under a deadline,
# count `ok `/`not ok ` lines on stdout+stderr, and require exit 0 with at
# least one passing line per schema. A line listed in
# scripts/e2e-known-limits.sh may fail (shown as `# TODO <reason>`); the
# client's exit 1 is then expected.
#
#   e2e-pair.sh [--transport=tcp|unix] <server-bin> <client-bin> [schema ...]
#
# Default schemas: the seven matrix scenarios.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/e2e-known-limits.sh

TRANSPORT=tcp
case "${1:-}" in
  --transport=unix) TRANSPORT=unix; shift ;;
  --transport=tcp) shift ;;
  --transport=*) echo "e2e-pair.sh: unknown ${1}" >&2; exit 2 ;;
esac
SERVER="$1"; CLIENT="$2"; shift 2
SCHEMAS=("$@")
[ ${#SCHEMAS[@]} -eq 0 ] && SCHEMAS=(game_world chat inventory matchmaking resolve_disembargo pass_back pipelined_params)

# Run CMD under an absolute deadline; exit 124 when it expires. macOS has
# no `timeout` (CI runners neither), so fall back to background + poll.
with_deadline() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

total_pass=0; total_fail=0; total_known=0
for schema in "${SCHEMAS[@]}"; do
  sock=""
  server_log="$(mktemp /tmp/capnp-e2e-server-XXXXXX).log"
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
    "$SERVER" --host "$host_arg" --schema "$schema" >"$server_log" 2>&1 &
  else
    "$SERVER" --host "$host_arg" --port "$port" --schema "$schema" >"$server_log" 2>&1 &
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
    echo "  # server output was:"; sed 's/^/  # /' "$server_log"
    total_fail=$((total_fail+1))
    kill $server_pid 2>/dev/null; wait $server_pid 2>/dev/null
    continue
  fi
  # Client under an absolute 60 s deadline; TAP lines counted on both streams.
  if [ "$TRANSPORT" = unix ]; then
    out=$( { with_deadline 60 "$CLIENT" --host "$host_arg" --schema "$schema" 2>&1; echo "EXIT=$?"; } )
  else
    out=$( { with_deadline 60 "$CLIENT" --host "$host_arg" --port "$port" --schema "$schema" 2>&1; echo "EXIT=$?"; } )
  fi
  exit_code=$(echo "$out" | grep -o 'EXIT=[0-9]*' | tail -1 | cut -d= -f2)
  e2e_tally "$SERVER" "$CLIENT" "$schema" "$out" "$exit_code"
  echo "# $schema: pass=$TALLY_PASS fail=$TALLY_FAIL known=$TALLY_KNOWN exit=$exit_code"
  printf '%s' "$TALLY_LINES"
  total_pass=$((total_pass+TALLY_PASS)); total_fail=$((total_fail+TALLY_FAIL)); total_known=$((total_known+TALLY_KNOWN))
  kill $server_pid 2>/dev/null; wait $server_pid 2>/dev/null
  [ -n "$sock" ] && rm -rf "$sockdir"
done
echo "1..$((total_pass+total_fail+total_known))"
echo "# total pass=$total_pass fail=$total_fail known=$total_known"
[ "$total_fail" -eq 0 ] && [ "$total_pass" -gt 0 ]
