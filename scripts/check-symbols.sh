#!/usr/bin/env bash
# check-symbols.sh -- the Zig core links only what we reviewed.
#
# Plan §1.1, §10, §11 and M0 gate. For every architecture of every slice in
# CapnpCore.xcframework (or of the archives given as arguments):
#
#   1. Every undefined symbol (`nm -u`, minus symbols another member of the
#      same archive defines) must be listed in scripts/symbols-allowlist.txt.
#   2. These are DENIED (Darwin SPI, spawning, threads):
#        ___ulock_*            Darwin SPI (std futex through Io.Threaded)
#        ___getdirentries64    Darwin SPI (std directory iteration)
#        _posix_spawn*         process spawning in a library
#        _pthread_create       the core must not start threads
#      A denied symbol always fails when it is in the regular part of the
#      allowlist. The ONLY exception is the allowlist's
#        "KNOWN SPI (tracked: plan §11 risk, owner decision needed before 0.1)"
#      section: a denied symbol listed there is reported in a loud banner
#      instead of failing. `--strict` ignores that section, so it fails on
#      every denied symbol; the 0.1 release gate runs with `--strict`.
#   3. No archive may DEFINE _memcpy, _memset or _memmove (bundled compiler-rt
#      would rebind the app's copies to Zig's), and every defined external
#      symbol must be a capnp_* ABI export.
#   4. The allowlist must be exact: an entry no slice needs any more fails
#      (in both sections), so the list keeps documenting what the core really
#      imports, and the KNOWN SPI section must be emptied once the denied
#      imports are gone.
#
# Usage: scripts/check-symbols.sh [--strict] [archive.a ...]
# Prints the undefined symbols of each architecture. Exit 0 = pass.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
allowlist_file="$repo/scripts/symbols-allowlist.txt"

strict=0
if [[ "${1:-}" == "--strict" ]]; then
    strict=1
    shift
fi

archives=("$@")
if [[ ${#archives[@]} -eq 0 ]]; then
    shopt -s nullglob
    archives=("$repo"/CapnpCore.xcframework/*/libcapnp_core.a)
    shopt -u nullglob
    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "check-symbols: FAIL: no CapnpCore.xcframework/*/libcapnp_core.a;" \
            "run: cd core && mise exec -- zig build xcframework" >&2
        exit 1
    fi
fi

[[ -f "$allowlist_file" ]] || {
    echo "check-symbols: FAIL: missing $allowlist_file" >&2
    exit 1
}

# Split the allowlist into its regular part and the KNOWN SPI section
# (between "# BEGIN KNOWN SPI" and "# END KNOWN SPI").
section_lines() {
    awk -v want="$1" '
        /^# BEGIN KNOWN SPI/ { in_spi = 1; next }
        /^# END KNOWN SPI/   { in_spi = 0; next }
        (want == "spi") == (in_spi == 1) { print }
    ' "$allowlist_file" | sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' | sort -u
}
allowlist="$(section_lines regular)"
known_spi="$(section_lines spi)"
if [[ "$(grep -c '^# BEGIN KNOWN SPI' "$allowlist_file" || true)" != "$(grep -c '^# END KNOWN SPI' "$allowlist_file" || true)" ]]; then
    echo "check-symbols: FAIL: unbalanced KNOWN SPI markers in $allowlist_file" >&2
    exit 1
fi

denied_re='^(___ulock_.*|___getdirentries64|_posix_spawn.*|_pthread_create)$'
forbidden_defined_re='^(_memcpy|_memset|_memmove)$'

failures=0
fail() {
    echo "  FAIL: $*"
    failures=$((failures + 1))
}

while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    [[ "$sym" =~ $denied_re ]] ||
        fail "KNOWN SPI section lists $sym, which is not a denied symbol; move it to the regular list"
done <<<"$known_spi"

used_all=""
spi_used=""
for lib in "${archives[@]}"; do
    [[ -f "$lib" ]] || {
        echo "check-symbols: FAIL: no such archive: $lib" >&2
        exit 1
    }
    for arch in $(lipo -archs "$lib"); do
        echo "== ${lib#"$repo"/} [$arch]"
        # nm prints "archive(member):" headers and blank lines; keep names only.
        defined="$(nm -g -U -arch "$arch" "$lib" | awk 'NF == 3 { print $3 }' | sort -u)"
        undefined="$(nm -u -arch "$arch" "$lib" | awk 'NF == 1 && $1 !~ /:$/ { print $1 }' | sort -u)"
        undefined="$(comm -23 <(echo "$undefined") <(echo "$defined") | sed '/^$/d')"

        count=$(grep -c . <<<"$undefined" || true)
        echo "   undefined ($count):"
        if [[ -n "$undefined" ]]; then
            # shellcheck disable=SC2001 # prefix every line
            sed 's/^/     /' <<<"$undefined"
        fi
        used_all+="$undefined"$'\n'

        while IFS= read -r sym; do
            [[ -z "$sym" ]] && continue
            if [[ "$sym" =~ $denied_re ]]; then
                if [[ $strict -eq 0 ]] && grep -qxF -- "$sym" <<<"$known_spi"; then
                    spi_used+="$sym ($arch)"$'\n'
                else
                    fail "$arch imports denied symbol $sym"
                fi
            elif ! grep -qxF -- "$sym" <<<"$allowlist"; then
                fail "$arch imports $sym, which is not in scripts/symbols-allowlist.txt"
            fi
        done <<<"$undefined"

        while IFS= read -r sym; do
            [[ -z "$sym" ]] && continue
            if [[ "$sym" =~ $forbidden_defined_re ]]; then
                fail "$arch DEFINES $sym (bundled compiler-rt/libc; the app's $sym would bind to Zig's)"
            elif [[ "$sym" != _capnp_* ]]; then
                fail "$arch defines external symbol $sym outside the capnp_* ABI namespace"
            fi
        done <<<"$defined"
    done
done

used_sorted="$(sed '/^$/d' <<<"$used_all" | sort -u)"
stale="$(comm -23 <(printf '%s\n%s\n' "$allowlist" "$known_spi" | sed '/^$/d' | sort -u) <(echo "$used_sorted") | sed '/^$/d')"
if [[ -n "$stale" ]]; then
    while IFS= read -r sym; do
        fail "allowlist entry $sym is not imported by any checked slice; remove it"
    done <<<"$stale"
fi

if [[ $failures -gt 0 ]]; then
    echo "check-symbols: FAIL ($failures problem(s))"
    exit 1
fi

if [[ -n "$spi_used" ]]; then
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "check-symbols: KNOWN SPI -- these DENIED imports pass ONLY because the"
    echo "KNOWN SPI section of scripts/symbols-allowlist.txt lists them"
    echo "(tracked: plan §11 risk, owner decision needed before 0.1):"
    # shellcheck disable=SC2001 # prefix every line
    sed '/^$/d; s/^/    /' <<<"$spi_used"
    echo "Not releasable: \`scripts/check-symbols.sh --strict\` fails on them."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "check-symbols: OK WITH KNOWN SPI"
    exit 0
fi
echo "check-symbols: OK"
