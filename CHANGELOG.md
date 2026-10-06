# Changelog

All notable changes to capnp-swift are recorded here.

## [Unreleased]

### Added

- Project plan (`docs/plan-2026-10-06.md`), repo rules (`CLAUDE.md`), toolchain pins (`mise.toml`).
- M0 core build (`core/`): capnp-zig v0.20.0 pinned by hash in `core/build.zig.zon`; `zig build xcframework` builds the static `CapnpCore.xcframework` (macOS arm64 + x86_64, `macos.15.0`, ReleaseSafe, DWARF kept, no bundled compiler-rt); `apple_root.zig` overrides for a library inside a host app (trap panic through a host hook, no-op log, `std.Io.failing` debug Io, no signal handlers, C allocator). `-Dios=true` adds iOS slices; they fail to compile until capnp-zig handoff H1.
- C ABI v0 (`core/include/capnp_core.h`, Clang module `CapnpCore`): `capnp_core_abi_version`, `capnp_core_features`, `capnp_core_version` (`"core 0.0.1 / capnp-zig 0.20.0 / capnpc_zig-0.20.0-nUdu..."`: core version, pinned version and pinned package hash, all from the zon), `capnp_core_set_panic_hook`; test hooks `capnp_core_debug_trap` and `capnp_core_debug_selftest`. A `zig build test` gate checks the header against the Zig exports both ways (names, arity, scalar widths, function-pointer signatures, struct layouts).
- Connection core spike (`core/src/conn.zig`, `effects.zig`, `cap_remap.zig`): `Conn` = detached capnp-zig `Peer` + `Framer` + an effect queue (one effect in flight, every payload its own allocation, terminal effects reserved up front). Host payloads are standalone messages with a `caps[]` table; outbound caps are remapped onto the Peer's origin-tagged pointers, inbound payloads are copied out with imports retained. Exactly one RETURN per question, including `deinit_ctx`-only ends and questions the Peer leaves open at transport close. Every `handleFrame` error is fatal (Abort, then CLOSE_REQUESTED), except an orderly remote Abort. 21 tests in `core/src/conn_test.zig`, incl. `caps_roundtrip` and an allocation-failure sweep; no upstream helper needed (H6 dropped).
- Swift package skeleton: products `Capnp` (placeholder), `CapnpRPC` (`CapnpCoreInfo`), `CapnpNW` (placeholder); `binaryTarget(path: "CapnpCore.xcframework")`; `platforms` lists macOS 15 only until M5 ships the iOS slices (iOS 18), and `CapnpRPC` refuses to build for other platforms (`#error`).
- Tests: `ExecutorProbe` (NW callbacks on the connection actor's `DispatchSerialQueue` run isolated to the actor), `CapnpCoreInfo`, `CoreSelftest` (a bootstrap + call round trip through the linked Peer inside a Swift process).
- Gates: `scripts/check-symbols.sh` (exact allowlist of the core's libSystem imports; denies Darwin SPI, spawning and thread creation; `--strict` for release), `scripts/check-dsym.sh` (a trap in a Zig frame symbolicates to its source line through an app dSYM, via `Examples/TrapProbe`), `scripts/ablate.py` (break one line, prove the suite fails, restore).
- Handoffs (drafts, `docs/handoffs/`): H1 capnp-zig iOS gate + `-Dfd-passing`; H2 Zig fork `Io.Threaded` on iOS (`handoff-zig-fork-ios-nullfile.md`); H3 QUIC baseline wire spec + TCP doc fix; H5 answer-finished hook + typed promise rejection; H8 allocation-free cancel at transport close; Zig fork `zig fetch` cache-tarball defect.

### Fixed (M0 review, 2026-10-06)

- Inbound payload copies are bounded by their frame. Params or results whose pointers alias one blob were copied once per alias (a 72 KB Call became a 65.6 MB `INBOUND_CALL`). Now such params refuse the call (`PayloadCopyExceedsFrame` exception to the caller) and such results end the question with `RETURN{EXCEPTION}`; the clone's memory is capped at 4x the frame plus 4 KiB.
- A remote Abort is an orderly close: no Abort is sent back, `pushBytes` returns `error.Closed`, `last_error` is `RemoteAbort` and `remote_abort_reason` keeps the remote's reason, which also becomes the reason of the open questions' `RETURN{DISCONNECTED}`.
- `Conn.Options.now_ns` (required; C ABI `capnp_conn_new(opts, now_uptime_ns, out)` in M1): questions sent before the first tick are timed from creation. The clock used to read 0, so the first real tick expired a Bootstrap sent at connect.
- `Conn.Stats` counters are u64 and saturate; the 2^32-th RETURN on one connection used to hit an integer-overflow trap in the ReleaseSafe slices.
- `transportClosed` queues a `RETURN{DISCONNECTED}` for every open question before it returns, also when capnp-zig's cancel pass skips them under OOM (H8). New counter `Stats.terminal_via_close_sweep`.
- `finish` and `release` are no-ops once the connection is closed for any reason (protocol failure, remote Abort, transport closed), not only after the transport closed.
- Docs: the M0 symbol gate is reported open (owner decision D7, plan §12); H2 renamed to `handoff-zig-fork-ios-nullfile.md` and its cited paths fixed; the ablation of every M0 gate test is recorded in plan §8.

### Known issues

- The M0 symbol gate is OPEN (plan §8, owner decision D7): `scripts/check-symbols.sh` passes only through the allowlist's KNOWN SPI section, because the linked capnp-zig fd closer imports `___ulock_wait2`, `___ulock_wake` and `_pthread_create` (plan §11). `--strict`, which enforces the gate as written, fails until capnp-zig handoff H1 lands or the owner approves the exception.
