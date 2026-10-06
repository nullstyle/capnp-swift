/*
 * capnp_core.h -- the capnp-swift C ABI (Clang module CapnpCore).
 *
 * A sans-IO Cap'n Proto RPC core: the host (Swift) owns every socket, pushes
 * received bytes in, and pulls outbound frames and events out. The core never
 * touches a socket and never calls into the host except through the panic
 * hook. See docs/plan-2026-10-06.md sections 4 and 4.1.
 *
 * Implemented in Zig (core/src/abi.zig); built into the static
 * CapnpCore.xcframework. Every function declared here must be exported there
 * with the same shape (enforced by `zig build test` in core/).
 */
#ifndef CAPNP_CORE_H
#define CAPNP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must equal capnp_core_abi_version(); the host checks it at connect. */
#define CAPNP_CORE_ABI_VERSION 1

/* ---- Version and features ---------------------------------------------- */

/* The ABI version of the linked core (CAPNP_CORE_ABI_VERSION when it built). */
uint32_t capnp_core_abi_version(void);

/* Feature bits. None are defined yet; always 0. */
uint64_t capnp_core_features(void);

/* "core <version> / capnp-zig <pinned version> / <pinned package hash>".
 * Static, NUL-terminated, never freed. */
const char *capnp_core_version(void);

/* ---- Panic hook -------------------------------------------------------- */

/* Called once when the core panics, then the core executes a trap
 * instruction (the process ends). `msg` is not NUL-terminated and is valid
 * only during the call. The hook must not call back into the core. */
typedef void (*capnp_core_panic_hook)(const char *msg, size_t len);

/* Installs the process-wide panic hook; NULL clears it. Any thread. */
void capnp_core_set_panic_hook(capnp_core_panic_hook hook);

/* ---- Test hook (not part of the supported API) ------------------------- */

/* TEST HOOK ONLY. Executes a trap instruction inside a known Zig frame
 * (core/src/abi.zig) so tooling can prove crash symbolication works. It does
 * not run the panic hook. Never call it from production code. */
__attribute__((noreturn)) void capnp_core_debug_trap(void);

/* TEST HOOK ONLY. Runs a bootstrap + call round trip between two in-process
 * connections inside the core, with the C allocator. Returns 0 on success;
 * otherwise -1 and, when `failure` is not NULL, stores a static,
 * NUL-terminated error name in *failure (NULL on success). */
int32_t capnp_core_debug_selftest(const char **failure);

/* ---- Connection API (C ABI v1) ------------------------------------------
 * capnp_conn_*, capnp_bootstrap, capnp_call, ... land here in M1/M2.
 * ------------------------------------------------------------------------ */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CAPNP_CORE_H */
