#!/usr/bin/env python3
"""Capture a stopped instrumented test process without changing gate status."""
import argparse
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', type=pathlib.Path)
parser.add_argument('--filter', help='Repeat the failing Swift Testing selection')
parser.add_argument('--repetitions', type=int, default=1)
parser.add_argument('--timeout', type=int, default=180, help='Total debugger budget in seconds')
args = parser.parse_args()
if not 1 <= args.repetitions <= 32:
    parser.error('Sanitizer diagnosis: repetitions must be 1...32')
if not 1 <= args.timeout <= 300:
    parser.error('Sanitizer diagnosis: timeout must be 1...300 seconds')
if args.binary is not None:
    binary = args.binary
else:
    folder = subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()
    # Prefer instrumented RPC tests when several products are present.
    # Older SwiftPM versions use one monolithic bundle. Skip stale products
    # which do not contain the sanitizer runtime.
    candidates = [pathlib.Path(folder) / (name + '.xctest/Contents/MacOS/' + name)
                  for name in ['CapnpRPCTests', 'capnp-swiftPackageTests']]
    binary = next((candidate for candidate in candidates if candidate.is_file()
                   and 'libclang_rt.' in subprocess.check_output(
                       ['xcrun', 'otool', '-L', str(candidate)], text=True)), candidates[0])
if not binary.is_file():
    print('Sanitizer diagnosis: no built test executable is available.', flush=True)
    sys.exit(0)
libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
instrumentation = next(((name, option) for name, option in [('asan', 'address'), ('tsan', 'thread')]
                        if 'libclang_rt.' + name in libraries), None)
if instrumentation is None:
    print('Sanitizer diagnosis: the available test executable is not an instrumented build.', flush=True)
    sys.exit(0)
runtime_name, sanitizer_option = instrumentation
print('Sanitizer diagnosis: failure-only debugger run of ' + str(binary), flush=True)
headers = subprocess.check_output(['xcrun', 'otool', '-hv', str(binary)], text=True)
target_environment = {}
target = [str(binary), '--testing-library', 'swift-testing']
if 'BUNDLE' in headers:
    # Some SwiftPM versions load test bundles through a helper.
    swiftc = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    toolchain_usr = swiftc.parent.parent
    helper = toolchain_usr / 'libexec/swift/pm/swiftpm-testing-helper'
    platform = pathlib.Path(subprocess.check_output(
        ['xcrun', '--show-sdk-platform-path'], text=True).strip()) / 'Developer'
    runtimes = sorted((toolchain_usr / 'lib/clang').glob('*/lib/darwin/libclang_rt.' + runtime_name + '_osx_dynamic.dylib'))
    if not helper.is_file() or not runtimes:
        print('Sanitizer diagnosis: no matching bundle helper or sanitizer runtime is available.', flush=True)
        sys.exit(0)
    target_environment['DYLD_FRAMEWORK_PATH'] = str(platform / 'Library/Frameworks')
    target_environment['DYLD_LIBRARY_PATH'] = str(platform / 'usr/lib') + ':' + str(toolchain_usr / 'lib/swift/macosx')
    target_environment['DYLD_INSERT_LIBRARIES'] = str(runtimes[-1])
    target = [str(helper), '--test-bundle-path', str(binary), '--sanitize=' + sanitizer_option,
              str(binary), '--testing-library', 'swift-testing']
if args.filter:
    target += ['--filter', args.filter]
command = ['xcrun', 'lldb', '--no-lldbinit', '--no-use-colors', '--batch',
           '-o', 'settings set target.disable-aslr false']
if target_environment:
    # Set these on the inferior: protected launchers discard inherited DYLD vars.
    command += ['-o', 'settings set target.env-vars ' + ' '.join(
        shlex.quote(key + '=' + value) for key, value in target_environment.items())]
command += ['-o', 'process launch --shell-expand-args false',
           '-k', 'process status', '-k', 'thread backtrace all', '-k', 'frame select 0',
           '-k', 'register read --all', '-k', 'disassemble --frame', '-k', 'image list -o -f',
           '--', *target]
folder = pathlib.Path(tempfile.mkdtemp(prefix='capnp-sanitizer-debugger-'))
print('Sanitizer diagnosis: debugger artifacts ' + str(folder), flush=True)
deadline = time.monotonic() + args.timeout
for attempt in range(1, args.repetitions + 1):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    path = folder / ('attempt-' + str(attempt) + '.log')
    print('Sanitizer diagnosis: debugger attempt ' + str(attempt), flush=True)
    expired = False
    with path.open('w') as stream:
        process = subprocess.Popen(command, start_new_session=True, stdout=stream, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            expired = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    output = path.read_text(errors='replace')
    print(output, flush=True)
    print('Sanitizer diagnosis: debugger exit ' + str(process.returncode)
          + '; the original suite failure remains authoritative.', flush=True)
    if expired:
        print('Sanitizer diagnosis: debugger reached its total time bound.', flush=True)
        break
    if 'stop reason =' in output or process.returncode != 0:
        break
