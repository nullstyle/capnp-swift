// CapnpCore.xcframework ships a macOS slice only until milestone M5 (plan §8):
// the iOS slices need capnp-zig handoff H1. Building CapnpRPC for any other
// platform fails here with a clear message instead of a missing-slice link
// error. M5 removes this check together with adding `.iOS(.v18)` to
// Package.swift's `platforms`.
#if !os(macOS)
#error("capnp-swift: CapnpRPC supports macOS only until milestone M5 (iOS slices need capnp-zig handoff H1; see docs/plan-2026-10-06.md §8)")
#endif
