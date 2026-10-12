#!/usr/bin/env python3
"""Run both directions against the independent C++ reference RPC implementation."""
import pathlib
import selectors
import subprocess
import sys


def pair(server_path, client_path, kind, expected):
    server = subprocess.Popen([str(server_path), 'server', kind], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(server.stdout, selectors.EVENT_READ)
            if not selector.select(10):
                raise RuntimeError('CPP_TYPED_RPC_FAIL: server did not announce its port')
            line = server.stdout.readline().strip()
        if not line.startswith('PORT ') or not line[5:].isdigit():
            raise RuntimeError('CPP_TYPED_RPC_FAIL: invalid server port: ' + line)
        target = line[5:] if client_path.name == 'swift-peer' else '127.0.0.1:' + line[5:]
        result = subprocess.run([str(client_path), 'client', kind, target], capture_output=True,
                                text=True, timeout=20)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            raise RuntimeError('CPP_TYPED_RPC_FAIL: cross-implementation client failed')
        passes = sum(line.startswith('PASS: ') for line in result.stdout.splitlines())
        if passes != expected:
            raise RuntimeError(f'CPP_TYPED_RPC_FAIL: expected {expected} checks, got {passes}')
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        sys.stderr.write(server.stderr.read())
        server.stdout.close()
        server.stderr.close()


def main():
    swift, cpp = map(pathlib.Path, sys.argv[1:])
    for server, client in [(cpp, swift), (swift, cpp)]:
        for kind, count in [('child', 6), ('named', 3), ('swap', 1), ('batch', 1)]:
            print(f'PAIR: {client.name} client -> {server.name} server ({kind})', flush=True)
            pair(server, client, kind, count)
    print('PASS: 22 open generic RPC checks across both C++/Swift directions')


if __name__ == '__main__':
    main()
