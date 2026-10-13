#!/usr/bin/env python3
"""Capture a stopped ASan test process without changing the failed gate status."""
import os
import pathlib
import signal
import subprocess
import sys

if len(sys.argv) > 1:
    binary = pathlib.Path(sys.argv[1])
else:
    folder = subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip()
    binary = pathlib.Path(folder) / 'capnp-swiftPackageTests.xctest/Contents/MacOS/capnp-swiftPackageTests'
if not binary.is_file():
    print('Sanitizer diagnosis: no built test executable is available.', flush=True)
    sys.exit(0)
libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
if 'libclang_rt.asan' not in libraries:
    print('Sanitizer diagnosis: the available test executable is not an ASan build.', flush=True)
    sys.exit(0)
print('Sanitizer diagnosis: failure-only debugger run of ' + str(binary), flush=True)
command = ['xcrun', 'lldb', '--no-lldbinit', '--no-use-colors', '--batch',
           '-o', 'settings set target.disable-aslr false', '-o', 'run',
           '-k', 'process status', '-k', 'thread backtrace all', '-k', 'frame select 0',
           '-k', 'register read --all', '-k', 'disassemble --frame', '-k', 'image list -o -f',
           '--', str(binary), '--testing-library', 'swift-testing']
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
