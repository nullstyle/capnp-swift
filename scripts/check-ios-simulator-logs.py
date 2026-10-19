#!/usr/bin/env python3
"""Verify isolated simulator selections retain every baseline workload."""
import argparse
import pathlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("network", nargs="+", type=pathlib.Path)
parser.add_argument("--quic", nargs="+", type=pathlib.Path)
parser.add_argument("--runtime", required=True, type=pathlib.Path)
parser.add_argument("--conformance", required=True, type=pathlib.Path)
parser.add_argument("--stress", required=True, type=pathlib.Path)
parser.add_argument("--quic-order", required=True, type=pathlib.Path)
args = parser.parse_args()

stress_name = "64 connections x 10k calls, each with a callback (the TSan gate)"
quic_name = "parallel QUIC connections complete and close over the baseline wire"
e_order_name = "E-order: 1000 calls on one capability start in arrival order"
fuzz_name = "mutated fixture bytes never trap the generated readers"
bench_name = "per-u32 read cost over the binary fixture"
quic_order_name = "E-order over QUIC: 1000 calls on one capability start in send order"
cpp_name = "the four C++ fixture encodings match pretty.json through generated readers"
network_suites = {"TCP", "M5", "QUIC", "ExecutorProbe"}
conformance_suites = {"Conformance", "ImportTargets", "VendorCorpus", "ReaderFuzz", "ReadBench"}
runtime_baseline_suites = {
    "Capnp.Message", "CapnpRuntime", "CoreSelftest", "CapnpCoreInfo",
    "Loopback", "M2", "StreamWindow", "Lifecycle",
}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def suites(text):
    return set(re.findall(r'Suite "([^"]+)" started', text))


def passed_count(text, selection):
    counts = re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", text)
    require(len(counts) == 1, f"{selection} filter must have exactly one successful Swift Testing result")
    return int(counts[0])


def passed(text, name, cases=None):
    suffix = r'" passed' if cases is None else rf'" with {cases} test cases passed'
    return re.search(r'Test "' + re.escape(name) + suffix, text) is not None


def started(text, name):
    return f'Test "{name}" started' in text


network_counts = []
separate = args.quic is not None
require(not separate or len(args.quic) == len(args.network), "separate QUIC must have one log per networking repetition")
for filename in args.network:
    text = filename.read_text()
    count = passed_count(text, "network")
    if separate:
        require(count >= 8, f"separate network selection must retain its eight-test baseline: {filename}")
        require(suites(text) == network_suites - {"QUIC"}, f"separate network selection must contain only TCP M5 ExecutorProbe: {filename}")
    else:
        require(count >= 10, f"network selection must retain its ten-test baseline: {filename}")
        require(suites(text) == network_suites, f"network selection must contain only TCP M5 QUIC ExecutorProbe: {filename}")
    require(not any(started(text, name) for name in (stress_name, e_order_name, fuzz_name, bench_name, quic_order_name)),
            f"network selection must exclude pure RPC conformance and stress workloads: {filename}")
    if not separate:
        require(passed(text, quic_name, cases=16), f"network selection must pass all 16 parallel QUIC cases: {filename}")
    network_counts.append(count)

quic_counts = []
for filename in args.quic or []:
    text = filename.read_text()
    count = passed_count(text, "QUIC")
    require(count >= 2, f"separate QUIC selection must retain its two-test baseline: {filename}")
    require(suites(text) == {"QUIC"}, f"separate QUIC selection must contain only QUIC: {filename}")
    require(passed(text, quic_name, cases=16), f"separate QUIC selection must pass all 16 parallel cases: {filename}")
    require(not any(started(text, name) for name in (stress_name, e_order_name, fuzz_name, bench_name, quic_order_name)),
            f"separate QUIC selection must exclude other workloads: {filename}")
    quic_counts.append(count)

runtime = args.runtime.read_text()
runtime_count = passed_count(runtime, "runtime")
require(runtime_count >= 27, "runtime selection must retain its 27-test baseline")
require(not suites(runtime) & (network_suites | conformance_suites), "runtime selection must exclude networking and conformance suites")
require(runtime_baseline_suites <= suites(runtime), "runtime selection must retain all baseline pure RPC suites")
require(not started(runtime, stress_name), "runtime selection must exclude 64 x 10k stress")
require(not started(runtime, quic_order_name), "runtime selection must exclude the QUIC E-order load")
require(passed(runtime, e_order_name), "runtime selection must exercise 1000-call E-order")

conformance = args.conformance.read_text()
conformance_count = passed_count(conformance, "conformance")
require(conformance_count >= 9, "conformance selection must retain its nine-test baseline")
require(conformance_suites <= suites(conformance), "conformance selection must retain all five baseline suites")
require(not suites(conformance) & (network_suites | runtime_baseline_suites), "conformance selection must exclude RPC suites")
require(passed(conformance, fuzz_name, cases=2), "conformance selection must exercise both reader-fuzz seeds")
require(passed(conformance, bench_name), "conformance selection must exercise the per-u32 reader benchmark")
require(passed(conformance, cpp_name), "conformance selection must exercise the independent C++ fixtures")

stress = args.stress.read_text()
require(passed_count(stress, "stress") == 1 and passed(stress, stress_name)
        and suites(stress) == {"Loopback"}, "stress filter must select and pass exactly the 64 x 10k test")

quic_order = args.quic_order.read_text()
require(passed_count(quic_order, "QUIC order") == 1 and passed(quic_order, quic_order_name, cases=4)
        and suites(quic_order) == {"QUIC order"}, "QUIC order filter must select and pass exactly the 4-case QUIC E-order test")

baseline_total = network_counts[0] + (quic_counts[0] if separate else 0) + runtime_count + conformance_count + 2
print(f"simulator: {len(network_counts)} networking runs ({network_counts}), "
      f"{len(quic_counts)} separate QUIC runs ({quic_counts}), {runtime_count} other RPC, "
      f"{conformance_count} conformance, one 64 x 10k stress test and one QUIC E-order test passed; "
      f"{baseline_total} tests across all selections")
