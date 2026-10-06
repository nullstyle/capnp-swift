#!/usr/bin/env bash
# check-dsym.sh -- a trap inside the Zig core symbolicates to its source line.
#
# Plan §10: the XCFramework slices keep their DWARF, because an app's dSYM is
# built from the DWARF inside the static library. This gate proves it end to
# end, the way a crash report gets symbolicated:
#
#   1. build the TrapProbe executable (Examples/TrapProbe) with SwiftPM;
#   2. run it: it calls the test hook capnp_core_debug_trap(), which traps in
#      `debugTrapFrame` (core/src/abi.zig); its signal handler prints the
#      trapping PC and the image load address, then exits 42;
#   3. take the dSYM (SwiftPM's, or one made with dsymutil from the debug map);
#   4. require `atos` to map the PC to debugTrapFrame at
#      core/src/abi.zig:<line of the CAPNP_CORE_DEBUG_TRAP_LINE marker>.
#
# Usage: scripts/check-dsym.sh [debug|release]   (default: debug)
# Needs CapnpCore.xcframework (cd core && mise exec -- zig build xcframework).
# Runs the host architecture only.
set -euo pipefail

config="${1:-debug}"
case "$config" in
debug | release) ;;
*)
    echo "usage: $0 [debug|release]" >&2
    exit 2
    ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

fail() {
    echo "check-dsym: FAIL: $*" >&2
    exit 1
}

[[ -d CapnpCore.xcframework ]] ||
    fail "CapnpCore.xcframework is missing; run: cd core && mise exec -- zig build xcframework"

abi="core/src/abi.zig"
line="$(grep -n 'CAPNP_CORE_DEBUG_TRAP_LINE' "$abi" | head -1 | cut -d: -f1)"
[[ -n "$line" ]] || fail "no CAPNP_CORE_DEBUG_TRAP_LINE marker in $abi"
expected="$repo/$abi:$line"

echo "check-dsym: building TrapProbe ($config)"
swift build -c "$config" --product TrapProbe >/dev/null
bin_dir="$(swift build -c "$config" --show-bin-path)"
probe="$bin_dir/TrapProbe"
[[ -x "$probe" ]] || fail "no TrapProbe at $probe"

echo "check-dsym: running $probe"
set +e
output="$("$probe" 2>&1)"
status=$?
set -e
# shellcheck disable=SC2001 # prefix every line
echo "$output" | sed 's/^/  | /'
[[ $status -eq 42 ]] || fail "TrapProbe exited $status, expected 42 (trap caught by its handler)"

arch="$(sed -n 's/^arch=//p' <<<"$output")"
load_address="$(sed -n 's/^load_address=//p' <<<"$output")"
pc="$(sed -n 's/^trap_pc=//p' <<<"$output")"
[[ -n "$arch" && -n "$load_address" && -n "$pc" ]] || fail "TrapProbe did not print arch, load_address and trap_pc"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
dsym="$probe.dSYM"
if [[ ! -d "$dsym" ]]; then
    # Debug builds keep DWARF in the objects (and in libcapnp_core.a) and point
    # at them from the executable's debug map; dsymutil collects it, as Xcode
    # does when it archives an app.
    dsym="$scratch/TrapProbe.dSYM"
    dsymutil "$probe" -o "$dsym"
fi
dwarf="$dsym/Contents/Resources/DWARF/TrapProbe"
[[ -f "$dwarf" ]] || fail "no DWARF in $dsym"

symbolicated="$(atos -fullPath -o "$dwarf" -arch "$arch" -l "$load_address" "$pc")"
echo "check-dsym: atos -fullPath -o <dSYM> -arch $arch -l $load_address $pc"
echo "  -> $symbolicated"

[[ "$symbolicated" == *"debugTrapFrame"* ]] || fail "trapping frame is not debugTrapFrame"
[[ "$symbolicated" == *"($expected)" ]] || fail "trapping frame does not resolve to $expected"

echo "check-dsym: OK ($config, $arch): the trap resolves to $abi:$line"
