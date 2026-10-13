#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../../../.." && pwd)
cd "$repo"
swift_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors)
case ${CAPNP_TYPED_RPC_SANITIZER:-} in
    '') ;;
    thread|address) swift_flags+=("-sanitize=$CAPNP_TYPED_RPC_SANITIZER") ;;
    *) echo 'OPEN_RPC_FAIL: unsupported typed RPC sanitizer' >&2; exit 1 ;;
esac
rpc_scratch=$(mktemp -d /tmp/capnp-open-rpc-check.XXXXXX)
trap 'rm -rf "$rpc_scratch"' EXIT
if CAPNP_TYPED_RPC_SANITIZER=unsupported bash "$script_dir/check-rpc.sh" > "$rpc_scratch/sanitizer.stdout" 2> "$rpc_scratch/sanitizer.stderr"; then
    echo 'OPEN_RPC_FAIL: unsupported sanitizer selector rejection' >&2
    exit 1
fi
if [[ -s "$rpc_scratch/sanitizer.stdout" ]] || ! rg -q '^OPEN_RPC_FAIL: unsupported typed RPC sanitizer$' "$rpc_scratch/sanitizer.stderr"; then
    echo 'OPEN_RPC_FAIL: unsupported sanitizer selector diagnostic guard' >&2
    exit 1
fi
echo 'PASS: typed RPC sanitizer selector rejects unsupported values'
core=CapnpCore.xcframework/macos-arm64_x86_64
if [[ ! -f "$core/libcapnp_core.a" ]]; then
    echo 'OPEN_RPC_FAIL: missing macOS core archive' >&2
    exit 1
fi
mode=${1:-}
(cd tools/capnpc-swift && mise exec -- zig build)
generator="$repo/tools/capnpc-swift/zig-out/bin/capnpc-swift"
"$generator" --typed --output-dir="$rpc_scratch/methods" < tools/type-resolver-spike/fixtures/method_generics.request.bin
"$generator" --typed --output-dir="$rpc_scratch/inheritance" < "$script_dir/open_rpc_inheritance.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/external" < "$script_dir/external.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/persistent" < Tests/generated_shape/requests/persistent.request.bin
"$generator" --typed --output-dir="$rpc_scratch/pipeline" < "$script_dir/open_rpc_pipeline.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/producer" < "$script_dir/pipeline_producer.request.bin"
"$generator" --typed --output-dir="$rpc_scratch/consumer" < "$script_dir/pipeline_consumer.request.bin"
mkdir -p "$script_dir/generated"
for pair in methods/method_generics inheritance/open_rpc_inheritance pipeline/open_rpc_pipeline producer/pipeline_producer consumer/pipeline_consumer; do
    generated="$rpc_scratch/$pair.swift"
    golden="$script_dir/generated/${pair##*/}.swift"
    if [[ "$mode" == --update ]]; then cp "$generated" "$golden"; else diff -u "$golden" "$generated"; fi
done
xcrun swiftc "${swift_flags[@]}" \
    -module-name Capnp -emit-library -emit-module -module-cache-path "$rpc_scratch/module-cache" \
    Sources/Capnp/*.swift -o "$rpc_scratch/libCapnp.dylib" -emit-module-path "$rpc_scratch/Capnp.swiftmodule"
xcrun swiftc "${swift_flags[@]}" \
    -enable-testing -Xcc -Wno-comment -module-name CapnpRPC -I "$rpc_scratch" -I "$core/Headers" -L "$rpc_scratch" -lCapnp \
    -emit-library -emit-module -module-cache-path "$rpc_scratch/module-cache" \
    Sources/CapnpRPC/*.swift "$core/libcapnp_core.a" -o "$rpc_scratch/libCapnpRPC.dylib" \
    -emit-module-path "$rpc_scratch/CapnpRPC.swiftmodule" -Xlinker -rpath -Xlinker "$rpc_scratch"
compile() {
    xcrun swiftc "${swift_flags[@]}" \
        -Xcc -Wno-comment -module-cache-path "$rpc_scratch/module-cache" -I "$rpc_scratch" -I "$core/Headers" \
        -L "$rpc_scratch" -lCapnp -lCapnpRPC -Xlinker -rpath -Xlinker "$rpc_scratch" "$@"
}
compile -emit-library -emit-module -module-name TypedExternal "$rpc_scratch/external/external.swift" \
    -o "$rpc_scratch/libTypedExternal.dylib" -emit-module-path "$rpc_scratch/TypedExternal.swiftmodule"
if ! compile -emit-library -module-name TypedPersistent "$rpc_scratch/persistent/persistent.swift" \
    -o "$rpc_scratch/libTypedPersistent.dylib"; then
    echo 'OPEN_RPC_FAIL: named method payload reuses nested declaration' >&2
    exit 1
fi
echo 'PASS: named method payload reuses nested declaration'
if ! compile -emit-library -module-name TypedInheritance "$rpc_scratch/inheritance/open_rpc_inheritance.swift" \
    -o "$rpc_scratch/libTypedInheritance.dylib"; then
    echo 'OPEN_RPC_FAIL: generated clients reserve members and omit unbound conveniences' >&2
    exit 1
fi
echo 'PASS: generated clients reserve members and omit unbound conveniences'
compile -lTypedExternal "$rpc_scratch/methods/method_generics.swift" \
    "$rpc_scratch/inheritance/open_rpc_inheritance.swift" "$script_dir/VerifyOpenRPC.swift" -o "$rpc_scratch/verify"
"$rpc_scratch/verify"
if ! compile -lTypedExternal "$rpc_scratch/pipeline/open_rpc_pipeline.swift" \
    "$script_dir/VerifyTypedPipelines.swift" -o "$rpc_scratch/verify-pipelines"; then
    echo 'OPEN_RPC_FAIL: typed pipelines preserve generated method and schema names' >&2
    exit 1
fi
echo 'PASS: typed pipelines preserve generated method and schema names'
"$rpc_scratch/verify-pipelines"

# A producer built with Capnp alone must stay usable by an RPC consumer.
mkdir -p "$rpc_scratch/pure-producer" "$rpc_scratch/rpc-producer"
cp "$rpc_scratch/Capnp.swiftmodule" "$rpc_scratch/pure-producer/Capnp.swiftmodule"
cp "$rpc_scratch/libCapnp.dylib" "$rpc_scratch/pure-producer/libCapnp.dylib"
xcrun swiftc "${swift_flags[@]}" \
    -module-cache-path "$rpc_scratch/pure-producer/module-cache" -I "$rpc_scratch/pure-producer" \
    -L "$rpc_scratch/pure-producer" -lCapnp -emit-library -emit-module -module-name PipelineProducer \
    "$rpc_scratch/producer/pipeline_producer.swift" -o "$rpc_scratch/pure-producer/libPipelineProducer.dylib" \
    -emit-module-path "$rpc_scratch/pure-producer/PipelineProducer.swiftmodule"
if ! compile -I "$rpc_scratch/pure-producer" -L "$rpc_scratch/pure-producer" -lPipelineProducer \
    -Xlinker -rpath -Xlinker "$rpc_scratch/pure-producer" "$rpc_scratch/consumer/pipeline_consumer.swift" \
    "$script_dir/VerifyMixedPipeline.swift" -o "$rpc_scratch/verify-mixed-pure"; then
    echo 'OPEN_RPC_FAIL: RPC consumers accept Capnp-only struct producers' >&2
    exit 1
fi
"$rpc_scratch/verify-mixed-pure"
compile -emit-library -emit-module -module-name PipelineProducer "$rpc_scratch/producer/pipeline_producer.swift" \
    -o "$rpc_scratch/rpc-producer/libPipelineProducer.dylib" -emit-module-path "$rpc_scratch/rpc-producer/PipelineProducer.swiftmodule"
compile -D PIPELINE_PRODUCER_RPC -I "$rpc_scratch/rpc-producer" -L "$rpc_scratch/rpc-producer" -lPipelineProducer \
    -Xlinker -rpath -Xlinker "$rpc_scratch/rpc-producer" "$rpc_scratch/consumer/pipeline_consumer.swift" \
    "$script_dir/VerifyMixedPipeline.swift" -o "$rpc_scratch/verify-mixed-rpc"
"$rpc_scratch/verify-mixed-rpc"

cat > "$rpc_scratch/list-projection.swift" <<'SWIFT'
import Capnp
import CapnpRPC
func invalid(_ call: PFactory.Typed.Client.ShapesCall) { _ = call.pipeline.list }
SWIFT
if compile -typecheck "$rpc_scratch/pipeline/open_rpc_pipeline.swift" "$rpc_scratch/list-projection.swift" > "$rpc_scratch/list-projection.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: list pipeline projection typecheck' >&2; exit 1
fi
if ! rg -q "has no member 'list'" "$rpc_scratch/list-projection.log"; then
    cat "$rpc_scratch/list-projection.log" >&2
    echo 'OPEN_RPC_FAIL: list pipeline projection diagnostic guard' >&2; exit 1
fi
echo 'PASS: list-index pipelines require an awaited typed result'
cat > "$rpc_scratch/union-projection.swift" <<'SWIFT'
import Capnp
import CapnpRPC
func invalid(_ call: PFactory.Typed.Client.ShapesCall) { _ = call.pipeline.choice.cap }
SWIFT
if compile -typecheck "$rpc_scratch/pipeline/open_rpc_pipeline.swift" "$rpc_scratch/union-projection.swift" > "$rpc_scratch/union-projection.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: union pipeline projection typecheck' >&2; exit 1
fi
if ! rg -q "has no member 'cap'" "$rpc_scratch/union-projection.log"; then
    cat "$rpc_scratch/union-projection.log" >&2
    echo 'OPEN_RPC_FAIL: union pipeline projection diagnostic guard' >&2; exit 1
fi
echo 'PASS: union pipelines require an awaited discriminant'
cat > "$rpc_scratch/scalar-projection.swift" <<'SWIFT'
import Capnp
import CapnpRPC
func invalid(_ call: PFactory.Typed.Client.EchoCall<CapnpText>) { _ = call.pipeline.value() }
SWIFT
if compile -typecheck "$rpc_scratch/pipeline/open_rpc_pipeline.swift" "$rpc_scratch/scalar-projection.swift" > "$rpc_scratch/scalar-projection.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: scalar pipeline projection typecheck' >&2; exit 1
fi
if ! rg -q "requires that 'CapnpText' conform to 'CapnpPipelineSchema'" "$rpc_scratch/scalar-projection.log"; then
    cat "$rpc_scratch/scalar-projection.log" >&2
    echo 'OPEN_RPC_FAIL: scalar pipeline projection diagnostic guard' >&2; exit 1
fi
echo 'PASS: scalar generic arguments retain awaited reads without capability projections'
cat > "$rpc_scratch/pure-projection.swift" <<'SWIFT'
import Capnp
import CapnpRPC
import PipelineProducer
func invalid(_ call: PConsumer.Typed.Client.EchoCall<PBridgeSink.Typed>) { _ = call.pipeline.value.typed() }
SWIFT
if compile -I "$rpc_scratch/pure-producer" -typecheck "$rpc_scratch/consumer/pipeline_consumer.swift" "$rpc_scratch/pure-projection.swift" > "$rpc_scratch/pure-projection.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: Capnp-only producer typed projection typecheck' >&2; exit 1
fi
if ! rg -q "requires that .* conform to 'CapnpPipelineSchema'" "$rpc_scratch/pure-projection.log"; then
    cat "$rpc_scratch/pure-projection.log" >&2
    echo 'OPEN_RPC_FAIL: Capnp-only producer typed projection diagnostic guard' >&2; exit 1
fi
echo 'PASS: Capnp-only producers expose awaited fallback without promising native typed projections'

cat > "$rpc_scratch/wrong.swift" <<'SWIFT'
import Capnp
import CapnpRPC
func invalid(_ client: Child.Typed.Client) async throws {
    _ = try await client.parent.echo(as: CapnpText.self) { try $0.setValue([UInt8](arrayLiteral: 1)) }
}
SWIFT
if compile -typecheck "$rpc_scratch/methods/method_generics.swift" "$rpc_scratch/wrong.swift" > "$rpc_scratch/wrong.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: wrong method binding typecheck' >&2
    exit 1
fi
if ! rg -q 'cannot convert value of type.*UInt8.*expected argument type.*String' "$rpc_scratch/wrong.log"; then
    cat "$rpc_scratch/wrong.log" >&2
    echo 'OPEN_RPC_FAIL: wrong method binding diagnostic guard' >&2
    exit 1
fi
echo 'PASS: open method Text binding rejects Data at Swift typecheck'
cat > "$rpc_scratch/missing.swift" <<'SWIFT'
import Capnp
import CapnpRPC
struct Missing: Child.TypedServer {}
SWIFT
if compile -typecheck "$rpc_scratch/methods/method_generics.swift" "$rpc_scratch/missing.swift" > "$rpc_scratch/missing.log" 2>&1; then
    echo 'OPEN_RPC_FAIL: missing ancestor witness typecheck' >&2
    exit 1
fi
if ! rg -q "does not conform to protocol.*TypedServer" "$rpc_scratch/missing.log" || ! rg -q 'echo' "$rpc_scratch/missing.log"; then
    cat "$rpc_scratch/missing.log" >&2
    echo 'OPEN_RPC_FAIL: missing ancestor witness diagnostic guard' >&2
    exit 1
fi
echo 'PASS: typed inheritance requires ancestor server witnesses'
if "$generator" --typed --output-dir="$rpc_scratch/rejected" < "$script_dir/open_rpc_conflict.request.bin" > "$rpc_scratch/rejected.stdout" 2> "$rpc_scratch/rejected.stderr"; then
    echo 'OPEN_RPC_FAIL: conflicting inherited applications atomic rejection' >&2
    exit 1
fi
if [[ -s "$rpc_scratch/rejected.stdout" ]] || ! rg -q ConflictingInheritedApplication "$rpc_scratch/rejected.stderr" || [[ -n $(find "$rpc_scratch/rejected" -type f -print) ]]; then
    echo 'OPEN_RPC_FAIL: conflicting inherited applications rejection evidence' >&2
    exit 1
fi
echo 'PASS: conflicting inherited applications fail before source is written'
