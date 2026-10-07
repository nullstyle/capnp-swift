# Vendored schema compiler (D6 option A)

- `capnp.wasm` — the schema compiler compiled to wasm32-wasi, copied from
  the capnp-zig toolchain package (release capnp-wasm-tools-v0.1.0-rc.2;
  capnproto source commit 0c45c08..., per capnp-zig
  tools/capnp-toolchain.json).
  sha256: 5429b7277b18b6e3f65430068ac41ac327ef8dd359603955f16ec576e0c3a14a
  (matches the toolchain's `compiler_sha256`; scripts/make-artifactbundle.sh
  re-verifies it on every bundle build).
- `include/` — the bundled standard schema tree (capnp/*.capnp, go.capnp),
  from the same package (`include_sha256`
  97c87a6cabc07b477f763c816e2a402678e628bffee885bda9d1616b33b44aec covers
  the tree).

Verified 2026-10-06: running this wasm under WasmKit produces a
CodeGeneratorRequest byte-identical to the Wasmtime toolchain's output for
test.capnp (tools/wasmkit-probe).
