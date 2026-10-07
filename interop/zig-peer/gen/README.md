# Generated Zig bindings (do not edit)

`mvp.zig` was generated from `interop/schemas/mvp.capnp` by capnp-zig's own
schema toolchain at the pinned tag (v0.20.0):

- the Cap'n Proto compiler: the WASM `capnp` capnp-zig pins
  (`tools/capnp-toolchain.json`, run through Wasmtime 48.0.1 by
  `tools/capnp_tool.py`), bootstrapped with `mise run bootstrap:capnp` in a
  capnp-zig checkout;
- the plugin: `capnpc-zig` built with `zig build` from `git archive v0.20.0`
  of capnp-zig (a scratch copy, never the package cache);
- the command, from the capnp-zig checkout:

```sh
mise exec -- uv run --no-project --python 3.13 tools/capnp_tool.py generate \
  --plugin <scratch>/capnp-zig-v0.20.0/zig-out/bin/capnpc-zig \
  --output <capnp-swift>/interop/zig-peer/gen \
  --plugin-arg=no-reflection \
  -- --src-prefix=<capnp-swift>/interop/schemas <capnp-swift>/interop/schemas/mvp.capnp
```

`no-reflection` leaves out the embedded schema (not needed by the peer).
Regenerate when the schema or the capnp-zig pin changes.
