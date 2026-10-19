Copied from the capnp-zig checkout at v0.21.0 (tests/e2e/schemas/), the
same pin the core used then. The M4 gate pairs e2e-swift-server/client against
the Zig peers over these scenarios (plan section 8, M4). On 2026-10-18 all
six files were byte-identical to v0.27.0 (`cmp`).

cap_passing.capnp: copied from capnp-zig v0.27.0 (tag commit `71ddc46`,
tests/e2e/schemas/) for the M8 scenarios pass_back and pipelined_params
(plan section 8, M8). Its bindings are not in e2e.request.bin. They are
generated with the typed API added, into their own folder
`interop/e2e/gen/typed/` (still the CapnpE2E module), because the plugin's
`--check` requires the folder to hold only the files it makes. `just
generate` writes them and `just generate-check` diffs them:

    swift package --allow-writing-to-package-directory capnp-generate --typed \
      --output-dir interop/e2e/gen/typed interop/e2e/schemas/cap_passing.capnp
