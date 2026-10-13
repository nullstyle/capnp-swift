#!/usr/bin/env bash
# Bounded diagnostic runner. No Capnp dependency or source edits; retains logs.
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
probe_source="$probe_dir/diagnostics/NetworkQUICOrder.swift"
sanitizer=${1:-thread}
mode=${2:-concurrent}
repetitions=${3:-16}
case "$sanitizer" in normal|thread|address) ;; *) echo 'QUIC_ORDER_FAIL: unsupported sanitizer' >&2; exit 2 ;; esac
case "$mode" in concurrent|queued-start|inline-start|open-only|construct-only) ;; *) echo 'QUIC_ORDER_FAIL: unsupported mode' >&2; exit 2 ;; esac
case "$repetitions" in ''|*[!0-9]*) echo 'QUIC_ORDER_FAIL: repetitions must be 1...64' >&2; exit 2 ;; esac
if [[ "$repetitions" -lt 1 || "$repetitions" -gt 64 ]]; then echo 'QUIC_ORDER_FAIL: repetitions must be 1...64' >&2; exit 2; fi
probe_scratch=$(mktemp -d "${TMPDIR:-/tmp}/capnp-public-quic-order.XXXXXX")
printf 'QUIC_ORDER_ARTIFACTS: %s\n' "$probe_scratch"
xcrun swiftc --version
xcrun --show-sdk-version
sw_vers
swift_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -g -parse-as-library)
if [[ "$sanitizer" != normal ]]; then swift_flags+=("-sanitize=$sanitizer"); fi
xcrun swiftc "${swift_flags[@]}" "$probe_source" -o "$probe_scratch/probe"
connections=1
if [[ "$mode" == concurrent ]]; then connections=16; fi
failures=0
for ((iteration=1; iteration<=repetitions; iteration++)); do
    order=starts-first
    if ((iteration % 2 == 0)); then order=opens-first; fi
    probe_exit=0
    "$probe_scratch/probe" "$mode" "$connections" "$order" > "$probe_scratch/run-$iteration.log" 2>&1 || probe_exit=$?
    cat "$probe_scratch/run-$iteration.log"
    if [[ "$probe_exit" != 0 ]]; then
        printf 'QUIC_ORDER_FAIL: mode=%s iteration=%s exit=%s\n' "$mode" "$iteration" "$probe_exit" >&2
        failures=$((failures + 1))
    elif ! grep -q '^QUIC_ORDER_SURVIVED:' "$probe_scratch/run-$iteration.log"; then
        printf 'QUIC_ORDER_FAIL: missing survival marker iteration=%s\n' "$iteration" >&2
        failures=$((failures + 1))
    fi
done
printf 'QUIC_ORDER_SUMMARY: mode=%s sanitizer=%s processes=%s connections_per_process=%s failures=%s\n' "$mode" "$sanitizer" "$repetitions" "$connections" "$failures"
if [[ "$failures" != 0 ]]; then exit 1; fi
