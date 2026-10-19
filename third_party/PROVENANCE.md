third_party/capnp-zig is a read-only export of the pinned tag (git archive
v0.27.0, commit in capnp-zig/.pin-commit), the same tag core/build.zig.zon
pins and the nightly's CAPNP_ZIG_TAG names. The M4 gate builds the Zig e2e
peers from here (zig build e2e-zig-server-install e2e-zig-client-install;
add -Dquic=true for the H11 QUIC matrix) and the C++ reference peers
(tests/e2e/cpp), so the matrix tests exactly the tagged code. Never edit
anything under this directory.
