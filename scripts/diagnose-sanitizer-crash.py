#!/usr/bin/env python3
"""Capture a stopped ASan test process without changing the failed gate status."""
import os
import pathlib
import shlex
import signal
import subprocess
import sys

if len(sys.argv) > 1:
    binary = pathlib.Path(sys.argv[1])
else:
    folder = subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()
    binary = pathlib.Path(folder) / 'capnp-swiftPackageTests.xctest/Contents/MacOS/capnp-swiftPackageTests'
    if not binary.is_file():
        binary = pathlib.Path(folder) / 'CapnpRPCTests.xctest/Contents/MacOS/CapnpRPCTests'
if not binary.is_file():
    print('Sanitizer diagnosis: no built test executable is available.', flush=True)
    sys.exit(0)
libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
if 'libclang_rt.asan' not in libraries:
    print('Sanitizer diagnosis: the available test executable is not an ASan build.', flush=True)
    sys.exit(0)
print('Sanitizer diagnosis: failure-only debugger run of ' + str(binary), flush=True)
headers = subprocess.check_output(['xcrun', 'otool', '-hv', str(binary)], text=True)
target_environment = {}
target = [str(binary), '--testing-library', 'swift-testing']
if 'BUNDLE' in headers:
    # Swift 6.4 builds test bundles loaded by a helper, not launchable binaries.
    swiftc = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    toolchain_usr = swiftc.parent.parent
    helper = toolchain_usr / 'libexec/swift/pm/swiftpm-testing-helper'
    developer = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    runtimes = sorted((toolchain_usr / 'lib/clang').glob('*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib'))
    if not helper.is_file() or not runtimes:
        print('Sanitizer diagnosis: no matching bundle helper or ASan runtime is available.', flush=True)
        sys.exit(0)
    target_environment['DYLD_FRAMEWORK_PATH'] = str(platform / 'Library/Frameworks')
    target_environment['DYLD_LIBRARY_PATH'] = str(platform / 'usr/lib') + ':' + str(toolchain_usr / 'lib/swift/macosx')
    target_environment['DYLD_INSERT_LIBRARIES'] = str(runtimes[-1])
    target = [str(helper), '--test-bundle-path', str(binary), '--sanitize=address',
              str(binary), '--testing-library', 'swift-testing']
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
