Copied from the capnp-zig checkout at v0.21.0 (its git submodule
vendor/ext/capnp_test, github.com/kaos/capnp_test, Apache-2.0), the same
pin the core uses. The plan's M3 gate runs this corpus through the wasm
compiler's `eval` (CAPNP_TEST_APP in the upstream Makefile's terms).
