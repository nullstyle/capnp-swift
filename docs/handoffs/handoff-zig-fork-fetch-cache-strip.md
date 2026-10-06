# HANDOFF — zig fork change branch: `zig fetch <url>` caches a tarball that `zig build` rejects

- **To:** the nullstyle Zig fork (the owner copies this file next to the other `handoff-zig-fork-*.md` files)
- **From:** capnp-swift (M0 integration)
- **Date:** 2026-10-06
- **Status:** DRAFT (the owner sends it)
- **Needed by:** nothing blocks on it. capnp-swift works around it: never run `zig fetch <url>` against a shared cache; `zig build` fetches correctly by itself.

This is a document, not an upstream issue. Nothing here was filed upstream.

## The defect

At tagged **0.17.0**, the CLI `zig fetch <url>` writes the global-cache tarball `p/<hash>.tar.gz` with the archive's top-level directory still in it (`<hash>/capnp-zig-0.20.0/build.zig`, ...). It prints the correct hash. The next `zig build` that has to unpack that tarball (no `zig-pkg/<hash>` yet) unpacks it, hashes the tree one directory too deep, and fails:

```
./build.zig.zon:9:21: error: hash mismatch: manifest declares capnpc_zig-0.20.0-nUduFXM1RwDO9CsVGFgZowhDNaDZ5V5-10qgILp63pqV but the fetched package has N-V-__8AAHM1RwDRbKRfoczCMz957ekheZ0NqoxfcYIOqQMT
```

`zig fetch` also warns `failed to delete temporary directory .../tmp/.tmp-<hex>: DirNotEmpty`. A `zig fetch <url>` run against a GOOD cache entry overwrites it with the bad layout.

`zig build` alone (fresh cache, no `zig fetch`) writes the correct layout (`<hash>/build.zig`, ...) and verifies the hash.

## Repro (no dependencies beyond the network)

```sh
export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
mkdir proj && cd proj
cat > build.zig <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b.dependency("capnpc_zig", .{});
}
EOF
cat > build.zig.zon <<'EOF'
.{
    .name = .fetchrepro,
    .version = "0.0.0",
    .fingerprint = 0x447b27fc6e61bfdc,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .capnpc_zig = .{
            .url = "https://github.com/nullstyle/capnp-zig/archive/refs/tags/v0.20.0.tar.gz",
            .hash = "capnpc_zig-0.20.0-nUduFXM1RwDO9CsVGFgZowhDNaDZ5V5-10qgILp63pqV",
        },
    },
    .paths = .{""},
}
EOF
zig fetch https://github.com/nullstyle/capnp-zig/archive/refs/tags/v0.20.0.tar.gz
tar tzf "$ZIG_GLOBAL_CACHE_DIR"/p/*.tar.gz | head -1   # <hash>/capnp-zig-0.20.0/LICENSE  (wrong)
zig build                                               # hash mismatch (above)
```

Control, same project: a fresh `ZIG_GLOBAL_CACHE_DIR`, `rm -rf zig-pkg`, then `zig build` alone succeeds, and `tar tzf` shows `<hash>/LICENSE`. Running `zig fetch <url>` after that, then `rm -rf zig-pkg && zig build`, fails again. All three runs reproduced on macOS 27 arm64, Zig 0.17.0, 2026-10-06.

## Likely cause (read, not patched or tested)

`lib/compiler/Maker/Fetch.zig` at 0.17.0 (same code at fork `30d9d1b1b2`):

- `:769-770`: when the archive has one top-level directory, `package_sub_path` is `tmp_directory_path.join(unpack_result.root_dir)`: the hash is computed over that subdirectory (correct).
- `:782-793`: with local storage (`zig build`, `zig-pkg/`) the subdirectory is renamed into place and `f.package_root` points at it. Without local storage (the `zig fetch` CLI), `:792` sets `f.package_root = tmp_directory_path`: the temporary directory **root**, one level above the package.
- `:796-800`: `recompress` tars `f.package_root` into `p/<hash>.tar.gz`, so the tarball gets the extra level.
- `:802-808`: the cleanup then tries to delete the non-empty temporary root: the `DirNotEmpty` warning.

Probable fix: in the no-local-storage branch, set `f.package_root = package_sub_path` (and keep the temporary root alive until `recompress` has read it). Add a test that runs the CLI fetch path on a single-top-level-directory tarball and then the `zig build` unpack path, and checks both hashes agree.
