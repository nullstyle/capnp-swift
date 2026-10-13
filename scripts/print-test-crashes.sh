#!/usr/bin/env bash
# Preserve the OS crash trace when SwiftPM reports only an unexpected signal.
set -euo pipefail
reports=${1:-"$HOME/Library/Logs/DiagnosticReports"}
found=false
for report in "$reports"/capnp-swiftPackageTests*.ips \
              "$reports"/capnp-swiftPackageTests*.crash \
              "$reports"/swiftpm-testing-helper*.ips \
              "$reports"/swiftpm-testing-helper*.crash; do
    [[ -f "$report" ]] || continue
    found=true
    printf 'Test process crash report: %s\n' "$(basename "$report")"
    cat "$report"
done
if [[ "$found" == false ]]; then
    echo 'No test process crash reports were written by the OS.'
fi
