#!/usr/bin/env python3
"""Reject empty simulator filters and missing repetitions, even if Xcode exits 0."""
import pathlib
import re
import sys

if len(sys.argv) < 3:
    raise SystemExit("usage: check-ios-simulator-logs.py network.log [network.log ...] stress.log")

stress_name = "64 connections x 10k calls, each with a callback (the TSan gate)"
quic_name = "parallel QUIC connections complete and close over the baseline wire"
for filename in sys.argv[1:-1]:
    network = pathlib.Path(filename).read_text()
    if f'Test "{stress_name}" started' in network:
        raise SystemExit("loopback stress unexpectedly ran with simulator networking")
    counts = re.findall(r"Test run with (\d+) tests in 12 suites passed", network)
    # More suites/tests are allowed as the package grows. Identify the runtime
    # process through its distinctive parallel QUIC check below.
    if not counts:
        counts = re.findall(r"Test run with (\d+) tests in \d+ suites passed", network)
    if not any(int(count) >= 37 for count in counts):
        raise SystemExit(f"network selection must run the complete baseline: {filename}")
    if not re.search(r'Test "' + re.escape(quic_name) + r'" with 16 test cases passed', network):
        raise SystemExit(f"network selection must pass all 16 parallel QUIC cases: {filename}")

stress = pathlib.Path(sys.argv[-1]).read_text()
if not re.search(r"Test run with 1 tests? in .* passed", stress) or not re.search(
    r'Test "' + re.escape(stress_name) + r'" passed', stress
):
    raise SystemExit("loopback stress filter must select and pass exactly one test")
print(f"simulator: {len(sys.argv) - 2} networking runs and 64 x 10k stress passed")
