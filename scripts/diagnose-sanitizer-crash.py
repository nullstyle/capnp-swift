#!/usr/bin/env python3
"""Capture a stopped instrumented test process without changing gate status."""
import argparse
import os
import pathlib
import shlex
import signal
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', type=pathlib.Path)
parser.add_argument('--filter', help='Repeat the failing Swift Testing selection')
args = parser.parse_args()
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
command += ['-o', 'run',
           '-k', 'process status', '-k', 'thread backtrace all', '-k', 'frame select 0',
           '-k', 'register read --all', '-k', 'disassemble --frame', '-k', 'image list -o -f',
           '--', *target]
process = subprocess.Popen(command, start_new_session=True)
try:
    process.wait(timeout=180)
except subprocess.TimeoutExpired:
    print('Sanitizer diagnosis: debugger reached its three-minute bound.', flush=True)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
print('Sanitizer diagnosis: debugger exit ' + str(process.returncode)
      + '; the original suite failure remains authoritative.', flush=True)
