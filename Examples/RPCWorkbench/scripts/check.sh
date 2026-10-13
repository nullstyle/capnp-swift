#!/usr/bin/env bash
set -euo pipefail
fail() { echo "WORKBENCH_GATE_FAIL: $*" >&2; exit 1; }
sample=$(cd "$(dirname "$0")/.." && pwd)
"$sample/scripts/generate.sh" --check
logs=$(mktemp -d /tmp/capnp-workbench-check.XXXXXX)
swift test --package-path "$sample" --filter NetworkTests > "$logs/tests.log" 2>&1
rg -q 'Test run with 2 tests in 1 suite passed' "$logs/tests.log" || fail 'network test selection'
swift build --package-path "$sample" --product workbench-smoke > "$logs/build.log" 2>&1
bin=$(swift build --package-path "$sample" --product workbench-smoke --show-bin-path)
"$bin/workbench-smoke" > "$logs/smoke.log" 2>&1
[[ $(rg -c '^WORKBENCH_PASS' "$logs/smoke.log") == 21 ]] || fail 'total smoke selection'
[[ $(rg -c '^WORKBENCH_PASS \[TCP\]' "$logs/smoke.log") == 10 ]] || fail 'TCP smoke selection'
[[ $(rg -c '^WORKBENCH_PASS \[Sample TLS\]' "$logs/smoke.log") == 10 ]] || fail 'TLS smoke selection'
rg -q '^WORKBENCH_PASS: wrong TLS certificate pin rejects connection$' "$logs/smoke.log" || fail 'wrong-pin smoke selection'
echo "PASS: checked generation, two tests with three network cases, 21 smoke checks; logs: $logs"
