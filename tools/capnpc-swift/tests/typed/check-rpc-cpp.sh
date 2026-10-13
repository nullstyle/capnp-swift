#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
if ! command -v capnp >/dev/null || ! pkg-config --exists capnp-rpc; then
    if [[ ${1:-} == --require-cpp ]]; then
        echo 'CPP_TYPED_RPC_FAIL: C++ reference compiler and capnp-rpc are required' >&2
        exit 1
    fi
    echo 'SKIP: open generic C++ RPC requires capnp and pkg-config capnp-rpc'
    exit 0
fi
if [[ -n ${CAPNP_TYPED_CPP_SCRATCH:-} ]]; then
    scratch=$CAPNP_TYPED_CPP_SCRATCH
    mkdir -p "$scratch"
else
    scratch=$(mktemp -d /tmp/capnp-open-rpc-cpp.XXXXXX)
    trap 'rm -rf "$scratch"' EXIT
fi
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'CPP_TYPED_RPC_FAIL: missing macOS core archive' >&2
    exit 1
fi
(cd tools/capnpc-swift && mise exec -- zig build)
tools/capnpc-swift/zig-out/bin/capnpc-swift --typed --output-dir="$scratch" < tools/type-resolver-spike/fixtures/method_generics.request.bin
tools/capnpc-swift/zig-out/bin/capnpc-swift --typed --output-dir="$scratch" < "$script_dir/cpp_streams.request.bin"
capnp compile -oc++:"$scratch" --src-prefix=tools/type-resolver-spike/fixtures tools/type-resolver-spike/fixtures/method_generics.capnp
capnp compile -oc++:"$scratch" --src-prefix="$script_dir" "$script_dir/cpp_streams.capnp"
python3 - "$scratch" "$script_dir" <<'PY'
import pathlib, shlex, subprocess, sys
scratch, source = map(pathlib.Path, sys.argv[1:])
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'capnp-rpc'], text=True))
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-I', str(scratch),
                str(source / 'method_rpc_peer.c++'), str(scratch / 'method_generics.capnp.c++'),
                str(scratch / 'cpp_streams.capnp.c++'),
                '-o', str(scratch / 'cpp-peer'), *flags], check=True)
PY
swift_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -module-cache-path "$scratch/module-cache")
xcrun swiftc "${swift_flags[@]}" -module-name Capnp -emit-library -emit-module \
    Sources/Capnp/*.swift -o "$scratch/libCapnp.dylib" -emit-module-path "$scratch/Capnp.swiftmodule"
xcrun swiftc "${swift_flags[@]}" -Xcc -Wno-comment -module-name CapnpRPC -emit-library -emit-module \
    -I "$scratch" -I "$core/Headers" -L "$scratch" -lCapnp \
    Sources/CapnpRPC/*.swift "$core/libcapnp_core.a" -o "$scratch/libCapnpRPC.dylib" \
    -emit-module-path "$scratch/CapnpRPC.swiftmodule" -Xlinker -rpath -Xlinker "$scratch"
xcrun swiftc "${swift_flags[@]}" -Xcc -Wno-comment -module-name CapnpNW -emit-library -emit-module \
    -I "$scratch" -I "$core/Headers" -L "$scratch" -lCapnp -lCapnpRPC \
    Sources/CapnpNW/CapnpNW.swift Sources/CapnpNW/TCPTransport.swift \
    Sources/CapnpNW/UnixTransport.swift Sources/CapnpNW/RPCListener.swift -o "$scratch/libCapnpNW.dylib" \
    -emit-module-path "$scratch/CapnpNW.swiftmodule" -Xlinker -rpath -Xlinker "$scratch"
xcrun swiftc "${swift_flags[@]}" -Xcc -Wno-comment -I "$scratch" -I "$core/Headers" \
    -L "$scratch" -lCapnp -lCapnpRPC -lCapnpNW -Xlinker -rpath -Xlinker "$scratch" \
    "$scratch/method_generics.swift" "$scratch/cpp_streams.swift" "$script_dir/CppRPCMain.swift" -o "$scratch/swift-peer"
python3 "$script_dir/run-rpc-cpp.py" "$scratch/swift-peer" "$scratch/cpp-peer"
