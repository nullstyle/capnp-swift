# Conformance fixture provenance

Copied verbatim from the capnp-zig checkout at commit `0be3407`
("release: record the v0.21.0 package hash"; the tree of tag `v0.21.0`),
the same pin `core/build.zig.zon` holds. The released capnp-zig package
carries no test assets (`build.zig.zon` `.paths` excludes `tests/`), so the
files are vendored here (plan §8, M3 gates).

- `Tests/capnp_testdata/` — `test.capnp` (the C++ `test.capnp` with
  TestAllTypes etc.), its `capnp/` standard-schema copies, and
  `testdata/{binary,segmented,packed,segmented-packed,pretty.json,short.txt}`.
- `Tests/generated_shape/requests/*.request.bin` — 26 committed
  CodeGeneratorRequests (schema-compiler output; no compiler needed to use
  them). `enum_evolution_v1`/`v2` share a file id, so they must stay separate
  requests (capnp-zig Justfile note).
- `Tests/test_schemas/*.capnp` — 44 schemas: enum evolution v1/v2, keyword
  collisions (`zig_field_names.capnp`), defaults, generics/brands,
  annotations. Sources of the request corpus above; kept for regeneration
  and documentation.

Regenerate a request from a schema (from a capnp-zig checkout at the pin,
after `mise run bootstrap:capnp`):

    mise exec -- uv run --no-project --python 3.13 tools/capnp_tool.py compiler -- \
      compile -o- --src-prefix=<capnp-swift>/Tests/test_schemas \
      <capnp-swift>/Tests/test_schemas/<name>.capnp \
      > <capnp-swift>/Tests/generated_shape/requests/<name>.request.bin
