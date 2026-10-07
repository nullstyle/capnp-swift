# capnpc-swift plugin test inputs and goldens

`requests/mvp.request.bin` — the CodeGeneratorRequest for
`interop/schemas/mvp.capnp`, produced by the pinned wasm compiler from a
capnp-zig checkout at v0.21.0 (after `mise run bootstrap:capnp`):

    mise exec -- uv run --no-project --python 3.13 tools/capnp_tool.py compiler -- \
      compile -o- --src-prefix=<capnp-swift>/interop/schemas \
      <capnp-swift>/interop/schemas/mvp.capnp > requests/mvp.request.bin

`golden/mvp.swift` — the plugin's expected output for that request.
`zig build test` diffs a fresh run against it; regenerate with
`mise exec -- zig build -Dupdate-goldens`.
