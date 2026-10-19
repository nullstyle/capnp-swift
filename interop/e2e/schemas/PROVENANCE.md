Copied from the capnp-zig checkout at v0.21.0 (tests/e2e/schemas/), the
same pin the core used then. The M4 gate pairs e2e-swift-server/client against
the Zig peers over these scenarios (plan section 8, M4). On 2026-10-18 all
six files were byte-identical to v0.27.0 (`cmp`).

Their bindings live in `interop/e2e/gen/erased/` (erased generation; M9
moved them there so each generated folder has its own check). `just
generate` writes them and `just generate-check` diffs them:

    swift package --allow-writing-to-package-directory capnp-generate \
      --output-dir interop/e2e/gen/erased --include interop/e2e/schemas \
      interop/e2e/schemas/{game_types,game_world,chat,inventory,matchmaking,resolve_disembargo}.capnp

Until M9 nothing checked them, and `game_world.swift` had drifted: its
`AreaQuery.filter` setters `byKind`/`byFaction` did not write the union
discriminant. `e2e.request.bin` is the original M4 request.

cap_passing.capnp: copied from capnp-zig v0.27.0 (tag commit `71ddc46`,
tests/e2e/schemas/) for the M8 scenarios pass_back and pipelined_params
(plan section 8, M8). Its bindings are not in e2e.request.bin. They are
generated with the typed API added, into their own folder
`interop/e2e/gen/typed/` (still the CapnpE2E module), because the plugin's
`--check` requires the folder to hold only the files it makes. `just
generate` writes them and `just generate-check` diffs them:

    swift package --allow-writing-to-package-directory capnp-generate --typed \
      --output-dir interop/e2e/gen/typed interop/e2e/schemas/cap_passing.capnp
