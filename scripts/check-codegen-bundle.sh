#!/usr/bin/env bash
# Verify an artifact's tool directory without a development-tree tool lookup.
# Usage: scripts/check-codegen-bundle.sh <directory-containing-capnpc-driver>
set -euo pipefail
fail() { echo "BUNDLE_SMOKE_FAIL: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail 'expected one bundled tool directory'
repo=$(cd "$(dirname "$0")/.." && pwd)
tool_dir=$(cd "$1" && pwd) || fail 'bundled tool directory is unavailable'
driver="$tool_dir/capnpc-driver"
[[ -x "$driver" ]] || fail 'bundled driver is not executable'
smoke_dir=$(mktemp -d /tmp/capnp-codegen-bundle.XXXXXX)
trap 'rm -rf "$smoke_dir"' EXIT
cd "$smoke_dir"
# Exercise adjacent artifact discovery, independent of development overrides.
unset CAPNPC_SWIFT_PLUGIN CAPNP_WASM

if ! "$driver" --output-dir "$smoke_dir/mvp" "$repo/interop/schemas/mvp.capnp"; then
    fail 'MVP generation'
fi
if ! diff -u "$repo/interop/mvp-swift-gen/mvp.swift" "$smoke_dir/mvp/mvp.swift"; then
    fail 'MVP regeneration comparison'
fi
echo 'PASS: bundled compiler preserves MVP generation'

mkdir "$smoke_dir/schemas"
cat > "$smoke_dir/schemas/producer.capnp" <<'CAPNP'
@0xb02d387699c43007;
using Swift = import "/swift.capnp";
$Swift.module("BundleProducer");
struct Box(T) { value @0 :T; }
CAPNP
cat > "$smoke_dir/schemas/consumer.capnp" <<'CAPNP'
@0xa8177a5d8c5a8b19;
using Swift = import "/swift.capnp";
$Swift.module("BundleConsumer");
using Producer = import "producer.capnp";
struct Envelope(T) { box @0 :Producer.Box(T); }
CAPNP
# Each invocation belongs to one Swift module, as with separate Swift targets.
for module in producer consumer; do
    if ! "$driver" --typed --output-dir "$smoke_dir/typed/$module" \
        "$smoke_dir/schemas/$module.capnp"; then
        fail "standalone typed $module generation"
    fi
    if ! "$driver" --typed --check --output-dir "$smoke_dir/typed/$module" \
        "$smoke_dir/schemas/$module.capnp"; then
        fail "standalone typed $module check"
    fi
done
grep -Eq 'public enum Typed<.*: CapnpPointerSchema>: CapnpStructSchema' \
    "$smoke_dir/typed/producer/producer.swift" || fail 'producer typed facade'
grep -Eq 'public enum Typed<.*: CapnpPointerSchema>: CapnpStructSchema' \
    "$smoke_dir/typed/consumer/consumer.swift" || fail 'consumer typed facade'
grep -q '^import BundleProducer$' "$smoke_dir/typed/consumer/consumer.swift" \
    || fail 'consumer producer-module import'
grep -Eq 'BundleProducer\.Box_Node[[:xdigit:]]+\.Typed<' "$smoke_dir/typed/consumer/consumer.swift" \
    || fail 'consumer generic producer binding'
echo 'PASS: bundled Swift annotations support checked typed module imports'
