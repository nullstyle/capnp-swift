#!/usr/bin/env bash
# Self-test of the pair scripts' server-start retry (plan §8 M9, G3), with
# fake peers: no build needed. A server that exits before it is ready (the
# port race: "Address already in use") must get a new port, up to 3 tries.
#
#   scripts/e2e-pair-retry-test.sh        prints TAP; exit 0 when all pass
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d /tmp/capnp-e2e-retry-XXXXXX)
trap 'rm -rf "$work"' EXIT

# The fake server fails while $FAKE_FAILS (a file) holds a count above 0.
# Then it listens on --port (TCP) or prints READY (--transport quic).
cat >"$work/fake-server" <<'EOF'
#!/usr/bin/env bash
port=0; quic=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port=$2; shift ;;
    --transport) [ "$2" = quic ] && quic=1; shift ;;
  esac
  shift
done
left=$(cat "$FAKE_FAILS")
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) >"$FAKE_FAILS"
  echo "fake-server: bind 127.0.0.1:$port: Address already in use" >&2
  exit 1
fi
if [ "$quic" = 1 ]; then echo READY; exec sleep 60; fi
exec python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
while True:
    c, _ = s.accept(); c.close()' "$port"
EOF
cat >"$work/fake-client" <<'EOF'
#!/usr/bin/env bash
echo "ok 1 - fake client ran"
echo "1..1"
EOF
chmod +x "$work/fake-server" "$work/fake-client"
# e2e-pair-quic.sh takes the Swift peers from a directory.
mkdir "$work/swift"
ln -s ../fake-server "$work/swift/e2e-swift-server"
ln -s ../fake-client "$work/swift/e2e-swift-client"

n=0; failed=0
check() { # check <description> <condition: 0 = true>
  n=$((n + 1))
  if [ "$2" = 0 ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; failed=1; fi
}

export FAKE_FAILS="$work/fails"

echo 1 >"$FAKE_FAILS"
out=$(scripts/e2e-pair.sh "$work/fake-server" "$work/fake-client" fake 2>&1); rc=$?
check "tcp: a server that fails once gets a new port, and the run passes" $rc
printf '%s' "$out" | grep -q "exited before it was ready (try 1)"; check "tcp: the retry is reported" $?

echo 9 >"$FAKE_FAILS"
start=$(date +%s)
out=$(scripts/e2e-pair.sh "$work/fake-server" "$work/fake-client" fake 2>&1); rc=$?
[ "$rc" != 0 ]; check "tcp: a server that never starts still fails, after 3 tries" $?
[ "$(cat "$FAKE_FAILS")" = 6 ]; check "tcp: exactly 3 starts were tried" $?
[ $(( $(date +%s) - start )) -lt 20 ]; check "tcp: a dead server ends the wait early" $?

echo 1 >"$FAKE_FAILS"
out=$(scripts/e2e-pair-quic.sh "$work/fake-server" "$work/fake-client" "$work/swift" fake 2>&1); rc=$?
check "quic: a server that fails once gets a new port, and the run passes" $rc
printf '%s' "$out" | grep -q "exited before READY (try 1)"; check "quic: the retry is reported" $?

echo 9 >"$FAKE_FAILS"
out=$(scripts/e2e-pair-quic.sh "$work/fake-server" "$work/fake-client" "$work/swift" fake 2>&1); rc=$?
[ "$rc" != 0 ]; check "quic: a server that never starts still fails" $?

echo "1..$n"
exit $failed
