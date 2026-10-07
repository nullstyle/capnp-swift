third_party/capnp-zig is a read-only export of the pinned tag (git archive
v0.21.0, commit in capnp-zig/.pin-commit), the same pin core/build.zig.zon
holds. The M4 gate builds the Zig e2e peers from here (zig build
e2e-zig-server-install e2e-zig-client-install) so the matrix tests exactly
the tagged code. Never edit anything under this directory.
