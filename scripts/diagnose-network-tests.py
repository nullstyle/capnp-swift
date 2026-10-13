#!/usr/bin/env python3
"""Repeat real network tests without rebuilding; identify the exact SDK trap.

Build once with `swift build --build-tests --sanitize=thread`, then run this.
A clean run reports only that the trap was not reproduced, never that it is fixed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

SELECTIONS = {
    'quic': ('QUICTests', 2),
    'network': ('QUICTests|TCPTests|M5Tests|ExecutorProbeTests', 12),
    'all': (None, 71),
}
TRAP = re.compile(r'Network/Connection\.swift:\d+: Fatal error: Neither nw nor nwGroup is initialized')


def verdict(output, exit_code, scope):
    if TRAP.search(output):
        return 1, 'NETWORK_INIT_TRAP: Neither nw nor nwGroup is initialized'
    if exit_code != 0:
        return 2, 'NETWORK_DIAG_FAIL: unexpected test process failure'
    if re.search(r'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|runtime error:', output):
        return 2, 'NETWORK_DIAG_FAIL: sanitizer finding'
    counts = [int(n) for n in re.findall(r'Test run with (\d+) tests?[^\n]*passed', output)]
    if sum(counts) != SELECTIONS[scope][1]:
        return 2, 'NETWORK_DIAG_FAIL: missing or wrong selected test count'
    cases = [int(n) for n in re.findall(
        r'Test case[^\n]*iteration\s+→\s+(\d+)[^\n]*parallel QUIC connections[^\n]*passed', output)]
    if sorted(cases) != list(range(16)):
        return 2, 'NETWORK_DIAG_FAIL: missing or duplicate parallel QUIC cases'
    return 0, 'NETWORK_DIAG_PASS: exact selection completed; trap not reproduced'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope', choices=SELECTIONS, default='quic')
    parser.add_argument('--sanitizer', choices=['normal', 'thread', 'address'], default='thread')
    parser.add_argument('--repetitions', type=int, default=32)
    parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 64:
        parser.error('NETWORK_DIAG_FAIL: repetitions must be 1...64')
    if not 10 <= args.timeout <= 300:
        parser.error('NETWORK_DIAG_FAIL: timeout must be 10...300 seconds')
    folder = Path(tempfile.mkdtemp(prefix='capnp-network-tests-'))
    print('NETWORK_DIAG_ARTIFACTS: ' + str(folder), flush=True)
    bin_path = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip())
    names = ['CapnpRPCTests', 'capnp-swiftPackageTests']
    candidates = [bin_path / (name + '.xctest/Contents/MacOS/' + name) for name in names]
    binary = next((p for p in candidates if p.is_file()), None)
    if binary is None:
        print('NETWORK_DIAG_FAIL: no built RPC test bundle', flush=True)
        return 2
    binaries = [binary]
    conformance = bin_path / 'CapnpConformanceTests.xctest/Contents/MacOS/CapnpConformanceTests'
    if args.scope == 'all' and conformance.is_file():
        binaries.append(conformance)
    identities = []
    for binary in binaries:
        libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
        instrumented = ('libclang_rt.tsan' in libraries, 'libclang_rt.asan' in libraries)
        expected = {'normal': (False, False), 'thread': (True, False), 'address': (False, True)}
        if instrumented != expected[args.sanitizer]:
            print('NETWORK_DIAG_FAIL: test bundle does not match requested sanitizer: ' + str(binary), flush=True)
            return 2
        identities.append({'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()})
    command = ['swift', 'test', '--skip-build', '--verbose']
    if args.sanitizer != 'normal':
        command += ['--sanitize=' + args.sanitizer]
    selection = SELECTIONS[args.scope][0]
    if selection:
        command += ['--filter', selection]
    # Match the original failing CI's untraced workload. Stream-id logging
    # can change SDK getter calls and scheduling, so add it only in a later probe.
    environment = dict(os.environ, CAPNP_QUIC_TRACE='0')
    records = []
    result = 0
    for attempt in range(1, args.repetitions + 1):
        log = folder / ('attempt-' + str(attempt) + '.log')
        started = time.monotonic()
        with log.open('w') as stream:
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)
            timed_out = False
            try:
                process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        output = log.read_text(errors='replace')
        result, message = verdict(output, process.returncode, args.scope)
        if timed_out and result != 1:
            result, message = 2, 'NETWORK_DIAG_FAIL: test process exceeded its time bound'
        records.append({'attempt': attempt, 'process_exit': process.returncode,
                        'diagnostic_exit': result, 'verdict': message,
                        'seconds': round(time.monotonic() - started, 3), 'log': str(log)})
        print(message + ' scope=' + args.scope + ' attempt=' + str(attempt), flush=True)
        if result:
            # The complete log remains on disk. Avoid huge reader-fuzz CASE dumps.
            lines = output.splitlines()
            for line in lines:
                if TRAP.search(line) or 'error:' in line or 'stop reason' in line:
                    print(line[:1000], flush=True)
            for line in [line for line in lines if '[quic]' in line][-30:]:
                print(line[:1000], flush=True)
            break
    (folder / 'results.json').write_text(json.dumps(
        {'scope': args.scope, 'sanitizer': args.sanitizer, 'command': command, 'test_binaries': identities,
         'CAPNP_QUIC_TRACE': '0',
         'requested_repetitions': args.repetitions, 'attempts': records}, indent=2) + '\n')
    print('NETWORK_DIAG_SUMMARY: scope=' + args.scope + ' completed=' + str(len(records))
          + ' requested=' + str(args.repetitions) + ' result=' + str(result), flush=True)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
