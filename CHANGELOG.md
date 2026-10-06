# Changelog

All notable changes to capnp-swift are recorded here.

## [Unreleased]

### Added

- Project plan (`docs/plan-2026-10-06.md`), repo rules (`CLAUDE.md`), toolchain pins (`mise.toml`).
- M0 core build (`core/`): capnp-zig v0.20.0 pinned by hash in `core/build.zig.zon`; `zig build xcframework` builds the static `CapnpCore.xcframework` (macOS arm64 + x86_64, `macos.15.0`, ReleaseSafe, DWARF kept, no bundled compiler-rt); `apple_root.zig` overrides for a library inside a host app (trap panic through a host hook, no-op log, `std.Io.failing` debug Io, no signal handlers, C allocator). `-Dios=true` adds iOS slices; they fail to compile until capnp-zig handoff H1.
- C ABI v0 (`core/include/capnp_core.h`, Clang module `CapnpCore`): `capnp_core_abi_version`, `capnp_core_features`, `capnp_core_version` (`"core 0.0.1 / capnp-zig 0.20.0"`, from the zon), `capnp_core_set_panic_hook`; test hooks `capnp_core_debug_trap` and `capnp_core_debug_selftest`. A `zig build test` gate checks the header against the Zig exports both ways (names, arity, scalar widths, function-pointer signatures, struct layouts).
- Connection core spike (`core/src/conn.zig`, `effects.zig`, `cap_remap.zig`): `Conn` = detached capnp-zig `Peer` + `Framer` + an effect queue (one effect in flight, every payload its own allocation, terminal effects reserved up front). Host payloads are standalone messages with a `caps[]` table; outbound caps are remapped onto the Peer's origin-tagged pointers, inbound payloads are copied out with imports retained. Exactly one RETURN per question, including `deinit_ctx`-only ends. Every `handleFrame` error is fatal (Abort, then CLOSE_REQUESTED). 12 tests in `core/src/conn_test.zig`, incl. `caps_roundtrip`; no upstream helper needed (H6 dropped).
- Swift package skeleton: products `Capnp` (placeholder), `CapnpRPC` (`CapnpCoreInfo`), `CapnpNW` (placeholder); `binaryTarget(path: "CapnpCore.xcframework")`; macOS 15 / iOS 18.
- Tests: `ExecutorProbe` (NW callbacks on the connection actor's `DispatchSerialQueue` run isolated to the actor), `CapnpCoreInfo`, `CoreSelftest` (a bootstrap + call round trip through the linked Peer inside a Swift process).
- Gates: `scripts/check-symbols.sh` (exact allowlist of the core's libSystem imports; denies Darwin SPI, spawning and thread creation; `--strict` for release), `scripts/check-dsym.sh` (a trap in a Zig frame symbolicates to its source line through an app dSYM, via `Examples/TrapProbe`), `scripts/ablate.py` (break one line, prove the suite fails, restore).
- Handoffs (drafts, `docs/handoffs/`): H1 capnp-zig iOS gate + `-Dfd-passing`; H2 Zig fork `Io.Threaded` on iOS; H3 QUIC baseline wire spec + TCP doc fix; H5 answer-finished hook + typed promise rejection; Zig fork `zig fetch` cache-tarball defect.

### Known issues

- `scripts/check-symbols.sh` passes only through the allowlist's KNOWN SPI section: the linked capnp-zig fd closer imports `___ulock_wait2`, `___ulock_wake` and `_pthread_create` (plan §11; owner decision needed before 0.1). `--strict` fails until capnp-zig handoff H1 lands.
