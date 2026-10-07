# D6 probe: capnp.wasm under WasmKit (plan section 12, M3)

Result (2026-10-06): PASS. WasmKit 0.4.1 (pure Swift; resolves and builds
through SwiftPM) runs the pinned `capnp.wasm` schema compiler with one WASI
preopen (`/` -> a common root), args
`compile -o- --no-standard-import -I<include> --src-prefix=... <schema>`,
and its stdout is a CodeGeneratorRequest byte-identical to the one the
capnp-zig Wasmtime toolchain produced (`cmp` against the committed
Tests/capnp_testdata/test.request.bin). The compiler spawns no plugins, so
the plugin (the native capnpc-swift binary) runs as a host process on the
request, exactly like capnp-zig's capnp_tool.py does.

This retires the technical risk in D6 option A: the capnpc-swift
artifactbundle can ship capnp.wasm + a WasmKit-based Swift driver. The owner
decides D6; the recommendation is A.

Run it (from a capnp-zig checkout with the bootstrapped toolchain, or any
capnp.wasm):

    cd tools/wasmkit-probe && swift run probe <capnp.wasm> <common-root> <src-prefix> <schema> [include-dir]

For example, with the capnp-swift Tests dir as the root:

    swift run probe <capnp.wasm> <capnp-swift>/Tests capnp_testdata capnp_testdata/test.capnp capnp_testdata
