#!/usr/bin/env bash
# The Stable Swift API gate (docs/stability.md, M9 G4): no breaking change
# in the Capnp, CapnpRPC and CapnpNW modules since the last release.
#
# The baseline is the release that the COMMITTED Package.swift downloads
# (its CapnpCore URL .../releases/download/<version>/...), so each release
# commit moves it. CI swaps Package.swift to the local core first; reading
# the committed file keeps the baseline right.
#
# How: for the baseline and for the working tree, a derived package holds the three
# library targets and the CapnpCore binary target, with a manifest built
# from that revision's own (`swift package dump-package`). Each one builds
# on its own, `swift-api-digester -dump-sdk` dumps each module with explicit
# search paths, and `-diagnose-sdk` compares the dumps. `swift package
# diagnose-api-breaking-changes` cannot do this here: with SwiftPM's native
# build system (Xcode 26.x) its baseline dump got the WasmKit module twice
# and lost the CapnpCore module (CI 39203933176).
#
# Experimental API (typed generation, QUIC; stability.md) may change. Allow
# such a breakage by the exact line this script prints, one per line, in
# scripts/api-breakage-allowlist.txt ('#' lines are comments).
#
#   scripts/check-api-breakage.sh [baseline-tag]
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
LIBS=(Capnp CapnpRPC CapnpNW)

baseline=${1:-$(git show HEAD:Package.swift |
  sed -n 's#.*releases/download/\([^/"]*\)/CapnpCore.xcframework.zip.*#\1#p' | head -1)}
if [ -z "$baseline" ]; then
  echo "check-api-breakage: the committed Package.swift names no release core URL" >&2
  exit 2
fi
# A shallow CI checkout has no tags: fetch the baseline tag alone.
if ! git rev-parse -q --verify "refs/tags/$baseline^{commit}" >/dev/null; then
  git fetch --quiet --depth=1 origin "refs/tags/$baseline:refs/tags/$baseline"
fi

work=$(mktemp -d /tmp/capnp-api-XXXXXX)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)

# derive REV CORE DIR: the library sources of REV (a git revision, or
# "worktree" for the files on disk) and a manifest for them in DIR. CORE is
# "url" (the release binary the manifest names) or "local" (this checkout's
# CapnpCore.xcframework: new sources may use a header newer than the
# release).
derive() {
  local rev=$1 core=$2 dir=$3
  mkdir -p "$dir/manifest" "$dir/pkg"
  if [ "$rev" = worktree ]; then
    (swift package dump-package) >"$dir/manifest.json"
    tar -C "$repo" -cf - "${LIBS[@]/#/Sources/}" | tar -x -C "$dir/pkg"
  else
    git show "$rev:Package.swift" >"$dir/manifest/Package.swift"
    (cd "$dir/manifest" && swift package dump-package) >"$dir/manifest.json"
    git archive "$rev" "${LIBS[@]/#/Sources/}" | tar -x -C "$dir/pkg"
  fi
  if [ "$core" = local ]; then
    cp -cR "$repo/CapnpCore.xcframework" "$dir/pkg/" 2>/dev/null || cp -R "$repo/CapnpCore.xcframework" "$dir/pkg/"
  fi
  python3 - "$dir/manifest.json" "$core" "${LIBS[@]}" >"$dir/pkg/Package.swift" <<'PY'
import json, sys

manifest = json.load(open(sys.argv[1]))
core, libs = sys.argv[2], sys.argv[3:]
targets = {t["name"]: t for t in manifest["targets"]}

def fail(message):
    sys.exit(f"check-api-breakage: {message}; extend scripts/check-api-breakage.sh")

order = []
def visit(name):
    if name in order:
        return
    target = targets.get(name) or fail(f"no target {name}")
    for dep in target.get("dependencies", []):
        if "byName" not in dep:
            fail(f"{name}: only by-name dependencies are supported")
        visit(dep["byName"][0])
    order.append(name)
for lib in libs:
    visit(lib)

lines = []
for name in order:
    target = targets[name]
    if target["type"] == "binary":
        if core == "local":
            lines.append(f'.binaryTarget(name: "{name}", path: "{name}.xcframework")')
        else:
            lines.append(f'.binaryTarget(name: "{name}", url: "{target["url"]}", checksum: "{target["checksum"]}")')
        continue
    if target["type"] != "regular":
        fail(f"{name}: target type {target['type']}")
    for key in ("path", "sources", "exclude", "resources", "settings", "pluginUsages"):
        if target.get(key):
            fail(f"{name}: {key}")
    deps = ", ".join(f'"{d["byName"][0]}"' for d in target.get("dependencies", []))
    lines.append(f'.target(name: "{name}", dependencies: [{deps}])')

names = {"macos": "macOS", "ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "visionos": "visionOS"}
platforms = ", ".join(f'.{names[p["platformName"]]}("{p["version"]}")' for p in manifest["platforms"])
modes = ", ".join(f".v{m}" for m in manifest.get("swiftLanguageModes") or ["6"])
products = ", ".join(f'.library(name: "{lib}", targets: ["{lib}"])' for lib in libs)
print("// swift-tools-version: 6.0")
print("// Derived by scripts/check-api-breakage.sh: the library targets only.")
print("import PackageDescription")
print("let package = Package(")
print('    name: "capnp-swift-api",')
print(f"    platforms: [{platforms}],")
print(f"    products: [{products}],")
print("    targets: [")
for line in lines:
    print(f"        {line},")
print("    ],")
print(f"    swiftLanguageModes: [{modes}]")
print(")")
PY
}

# dump DIR: build DIR/pkg and write DIR/<module>.json for every library.
dump() {
  local dir=$1 modules core
  if ! swift build --package-path "$dir/pkg" >"$dir/build.log" 2>&1; then
    tail -20 "$dir/build.log" >&2
    echo "check-api-breakage: the derived package in $dir did not build" >&2
    exit 2
  fi
  # The folder that holds every library's module (the native and the Swift
  # Build layouts differ, and both also keep per-target copies).
  modules=""
  while IFS= read -r candidate; do
    candidate=$(dirname "$candidate")
    local all=1 lib
    for lib in "${LIBS[@]}"; do [ -e "$candidate/$lib.swiftmodule" ] || all=0; done
    if [ "$all" = 1 ]; then modules=$candidate; break; fi
  done < <(find "$dir/pkg/.build" -name "${LIBS[0]}.swiftmodule")
  core=$(dirname "$(find "$dir/pkg" -name module.modulemap -path '*CapnpCore.xcframework/macos-*' -print -quit)")
  if [ -z "$modules" ] || [ "$core" = . ]; then
    echo "check-api-breakage: no module folder or CapnpCore headers in $dir/pkg/.build" >&2
    exit 2
  fi
  for lib in "${LIBS[@]}"; do
    xcrun swift-api-digester -dump-sdk -module "$lib" -o "$dir/$lib.json" -I "$modules" -I "$core" \
      -sdk "$sdk" -target "$(uname -m)-apple-macos15.0" -abort-on-module-fail -avoid-location
  done
}

derive "refs/tags/$baseline" url "$work/base"
if [ -d "$repo/CapnpCore.xcframework" ]; then
  derive worktree local "$work/head"
else
  derive worktree url "$work/head"
fi
dump "$work/base"
dump "$work/head"

allow="$work/allowlist"
grep -v -e '^#' -e '^[[:space:]]*$' scripts/api-breakage-allowlist.txt >"$allow" || true
echo "check-api-breakage: ${LIBS[*]} against $baseline ($(wc -l <"$allow" | tr -d ' ') allowed)"
broken=0
for lib in "${LIBS[@]}"; do
  xcrun swift-api-digester -diagnose-sdk -input-paths "$work/base/$lib.json" -input-paths "$work/head/$lib.json" \
    -breakage-allowlist-path "$allow" -o "$work/$lib.diag"
  # The report is section comments plus one line per breakage; the exit code
  # is 0 either way.
  if grep -v -e '^/\*' -e '^[[:space:]]*$' "$work/$lib.diag" >"$work/$lib.breaks"; then
    echo "$lib: $(wc -l <"$work/$lib.breaks" | tr -d ' ') breaking change(s):"
    sed 's/^/  /' "$work/$lib.breaks"
    broken=1
  else
    echo "$lib: no breaking change"
  fi
done
exit $broken
