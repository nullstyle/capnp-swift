# Public type resolver consumer probe

Run from the repository root:

```sh
just type-resolver-spike
```

This separate test package pins capnp-zig v0.23.0, whose Experimental
`type_resolver` facade is exported by `capnpc-zig-core`. The shipping Swift
generator still pins v0.21.0; the RPC core's v0.23.0 pin is independent.
The probe imports only `capnp.schema`, `capnp.request`, and the public
`capnp.type_resolver` facade. It reads the repository's existing request
fixtures plus the synthetic lexical, struct and RPC fixtures below. Keep the whole checkout
available when running it.

Every request outlives its contexts and resolved types. Fields carry
`schema.Type` together with `type_metadata`; list traversal uses
`listElement`, named applications use `enter`, and graph checks use
`validate` before shallow `resolve`. Results go back to the context that
produced them. The test allocator verifies request cleanup.

## Eight executed cases

| Case | Observed result |
|---|---|
| `List(Box(Text))` and the unbound `Box(T)` declaration | The application resolves `value` to Text; the declaration retains its scoped parameter identity. |
| `Link(Text).next` and `List(Link(T))` | Entering recursive applications retains Text. |
| `Outer(Text).Inner(Data)` and `Box(Box(Text))` | Lexical parameters and nested caller contexts remain distinct. |
| Lists, capabilities and AnyStruct | Nested UInt16 lists and interface bindings retain their shape; unconstrained AnyStruct is distinguished from an unbound parameter. |
| `TextChild → Middle(Text) → Parent(Text)` | Superclass brands and anonymous params/result payloads resolve to Text. |
| Generic methods with anonymous and named payloads | Both stay unbound. Anonymous payloads declare their own scoped parameter; named `Box(U)` payloads carry an implicit-method reference. |
| Malformed `Box` binding arity | `resolve` leaves the named expression shallow; `validate` and `enter` reject it. |
| Nested generic RPC with a lookup callback | Slice-backed contexts resolve Text; lookup-only payload validation fails with `InvalidSchema` (H12). |

The final case records an existing upstream defect. A future pin with its
fix should change the callback expectation to Text, while preserving the
slice result. [H12](../../docs/handoffs/H12-type-resolver-lexical-lookup.md)
contains the reproduction and the proposed public contract.

## Concrete Swift specialization prototype

```sh
just type-resolver-specializations
```

This runs the 22-case Zig suite, builds the separate specialization
executable, checks its committed Swift output for drift, and compiles it
with the current pure Swift `Capnp` sources in a fresh temporary directory.
Five Swift cases cover distinct/nested Box applications, integer and
struct lists, recursive Link applications, both lexical bindings, and
null/missing field defaults. A negative Swift typecheck proves Box(Text)
rejects Data. If `capnp` is installed, the C++ encoder independently
produces the same fixture values, the Swift reader checks them, and the
C++ decoder compares the Swift builder's values against that fixture.
C++ 1.5.0 was used in the recorded run. A missing C++ tool produces an
explicit skip; the other checks still run.
The core CI job runs `just type-resolver-methods`, which includes this gate,
on every push and pull request.

The planner keys named applications by node ID **and effective bindings
of every lexical parameter**. This separates Box(Text) from Box(Data),
deduplicates Box(Text) reached through different paths, and terminates
recursive Link(Text) traversal. It uses only public Context operations.
Generated `AppN` names are local to the output; they are not a proposed
public naming scheme. [The design note](../../docs/generic-specializations.md)
defines the supported subset and remaining Swift interface decisions.

The four new Zig cases reject erased parameters, unsupported AnyPointer,
nonempty schema defaults, and expanding applications over the consumer's
budget. Generation finishes before the executable writes any output.
The default application budget is 256, with resolver depth and key-size
bounds as additional limits.

Regenerate the synthetic request with the same pinned compiler command
as the lexical fixture below, replacing both `lexical_rpc` names with
`specializations`. Its SHA-256 is
`dcbe14551bbfeca369f1919e90ea32dddffde31ca81bd843f7658edadb6e881f`;
regeneration was compared byte-identically. Then regenerate and execute
the Swift gate with:

```sh
bash scripts/type-resolver-specializations.sh --update
```

The independent C++ input is `fixtures/specializations.value.txt`.
`swift/GeneratedSpecializations.swift` is generated, never hand-edited.

All 11 new checks were ablated through `scripts/ablate.py`: four Zig error
expectations, the five named Swift value checks, C++ decoded-value parity
(change child1's Swift value), and the wrong-binding gate (substitute a
valid Text setter call). Each produced its intended named failure, rather
than an unrelated compile error. All three mutated files were restored
byte-for-byte; the restored suite and Swift gate passed. Logs:
`/tmp/capnp-swift-specialization-ablations.log` and
`/tmp/capnp-swift-specialization-ablation-{1..11}.log`.

## Concrete generic RPC and inheritance prototype

```sh
just type-resolver-rpc
```

The recipe depends on the serialization gate, then generates the RPC fixture
and compares the committed output. A fresh temporary directory compiles the
current `Capnp` and `CapnpRPC` sources and links the existing macOS core archive.
Run `just xcframework` first if that archive is missing; do not rebuild it
concurrently with Swift compilation. No package manifest or release artifact
is changed by the gate. The Swift 6 harness uses real LoopbackTransport pairs,
five-second call deadlines, and an independent 45-second process watchdog.

Twelve runtime checks cover a branded diamond with one Base(Text)
implementation, separate Base(Text)/Base(Data) payload applications, same-name
ancestor methods, named Box(Text) payloads, Outer(Text).Inner lexical lookup,
callbacks, returned capability lifetime, shared nested capability indexes,
struct-list capability entries, foreign connection rejection, and unknown
interface/method rejection. Two negative Swift typechecks reject Data in an
inherited Text payload and a server missing its inherited echo method.
Three Zig checks reject conflicting brands for one inherited wire ID,
method-local generics, and an inheritance cycle in an owned request graph.
The complete Zig suite passes 15/15.

The graph keys anonymous method payloads with their logical owner's effective
bindings, obtained through the public resolver. Equal ancestors deduplicate
by application; conflicting applications of one wire ID in a single export
are rejected because calls carry no brand discriminator. Separate exports
may use different applications. Typed parent views are `super0`, `super1`, etc.;
field aliases are `<Field>Capability`. These names, like AppN, are experimental.
Nested builders and readers share the payload capability table. Method-local
generics, streaming, local returned-export views, and typed result pipelines
remain outside this prototype; see the design note for its adoption boundary.

Regenerate `fixtures/rpc_specializations.request.bin` with the pinned WasmKit
command in the provenance section below, replacing `lexical_rpc` with
`rpc_specializations`. Then run:

```sh
bash scripts/type-resolver-rpc.sh --update
```

The request is synthetic and generated with the same compiler SHA-256 recorded
below; regeneration compares byte-identically. Request SHA-256:
`dbc99b17e64f9047c84f3ec5f0eae26c959262ac6bfdf2953636281baa29f0f9`.
`swift/GeneratedRPCSpecializations.swift` is generated, never hand-edited.

All 17 new checks were individually ablated through `scripts/ablate.py`, with
an intended named failure required for every run: three Zig error expectations,
twelve runtime checks, and two negative typechecks changed into valid programs.
Every mutated source was restored byte-for-byte; the restored combined gate
passes. Logs: `/tmp/capnp-swift-rpc-ablations.log`,
`/tmp/capnp-swift-rpc-ablation-{1..16}.log`,
`/tmp/capnp-swift-rpc-ablation-17.log` (struct-list capability check), and
`/tmp/capnp-swift-rpc-final-gate.log`.

The struct-list case also uncovered an existing serialization bug: the Swift
builder included the tag in the list pointer's declared word count. The native
clone rejected the list at the segment boundary. The runtime now emits the
spec's count excluding the tag; a shipping unit regression compares exact
independent C++ 1.5.0 bytes. Its assertion was ablated separately. Reintroducing
the old builder formula reproduces the native refusal in the RPC gate, with
source restoration verified. Logs:
`/tmp/capnp-swift-list-count-unit-ablation.log` and
`/tmp/capnp-swift-rpc-list-count-regression-ablation.log`.

## Explicit method-local applications (2026-10-12)

```sh
just type-resolver-methods
```

This includes the original serialization and concrete RPC gates, then generates
`swift/GeneratedMethodSpecializations.swift` with:

```sh
tools/type-resolver-spike/zig-out/bin/capnpc-swift-specialize \
  tools/type-resolver-spike/fixtures/method_generics.request.bin :Root \
  --methods tools/type-resolver-spike/fixtures/method_generics.profiles.json
```

Profiles select interface/method declarations and call-site arguments from root
fields. The generator closes the root's effective argument brands using the
public resolver, creates concrete payload brands, and keeps an erased server
view for each method. Case names produce `echoAsText`, `echoAsData`, etc.; calls
still use one standard wire ID and ordinal on the same capability. There is no
wire discriminator or type inference. Without a profile, method generics retain
the default rejection. The design note explains the two compiler representations
and scope/arity validation. Graph/request metadata is borrowed and never edited.

The Swift gate compiles `swift/ProbePointer.swift` only into a fresh temporary
Capnp module, alongside the current runtime. This private experiment copies
opaque pointer values across payload slots without guessing their type, with
bounds/depth/budget checks and capability-index remapping. The package's shipped
runtime has no added pointer-codec interface. Local exported-capability copying,
open Swift generic declarations, streaming, typed pipelines and public naming
remain adoption work. Explicit method cases support the same reachable concrete
subset as the rest of this tool.

The 14 named runtime checks cover an inherited generic method on one capability
for Text/Data, enclosing interface bindings and changed field positions, null
values, integer/struct lists, nested Box arguments, named method brands, two
reversed arguments, and values inside List(Box(T)). The compiler rejects bare
List(T) as List(AnyPointer); the fixture uses the legal Box wrapper. Five checks
exercise the private copier's budget, malformed extent, cyclic depth, nested
capability remapping/data preservation, and double-far traversal. One negative
Swift typecheck rejects Data for a Text method argument, and one CLI gate proves
invalid profiles produce no partial source. Seven new Zig checks reject invalid
profiles or distinguish a named payload's unrelated unbound declaration parameter.
The complete Zig suite passes 22/22.

All 23 new checks were ablated individually, each with its intended named failure,
and every mutated source was restored byte-for-byte. The restored combined gate
passes. Evidence: `/tmp/capnp-swift-methods-ablations.log`,
`/tmp/capnp-swift-methods-ablation-{1..23}.log`,
`/tmp/capnp-swift-methods-final-gate.log`. Production generate-check and the
full Swift suite (40/40 plus 9/9 conformance/import/fuzz checks) also pass; logs
are `/tmp/capnp-swift-methods-production-generate-check.log` and
`/tmp/capnp-swift-methods-swift-tests.log`.

Regenerate the request with the pinned WasmKit command in the provenance section,
replacing `lexical_rpc` with `method_generics`, then run:

```sh
bash scripts/type-resolver-methods.sh --update
```

The request regenerates byte-identically; its SHA-256 is
`11ff15863ffb7f4090a72c2365274fed94993f5c64ec8fe6f18bf44a9e991414`.
Profile SHA-256:
`58dac7ba59575e3601a1bc0f3876888a87ee5885573136a52e49f4665558b070`.
The compiler SHA-256 is recorded below. Both inputs are synthetic.
Generated Swift is regenerated, never hand-edited. Independent C++ 1.5.0
code generation shows the named server's Box(AnyPointer) context:

```sh
mkdir -p /tmp/capnp-swift-method-cpp
capnp compile -oc++:/tmp/capnp-swift-method-cpp \
  --src-prefix=tools/type-resolver-spike/fixtures \
  tools/type-resolver-spike/fixtures/method_generics.capnp
```

This confirms the erased server convention; the new RPC transport evidence is
Swift loopback, not a C++ RPC pairing. Production pins, Package.swift and release
0.1.1 stay unchanged. The old committed specialization/RPC outputs have no drift.

## Generator compatibility (2026-10-10)

A scratch copy of the shipping generator source was built separately with
v0.21.0 and v0.23.0. Unit and golden tests passed for both, and fresh
plugin binaries emitted byte-identical Swift for all 26 committed request
fixtures. Production `just generate-check` also passed its four outputs.
The shipping generator's dependency URL and hash remain unchanged. Logs:
`/tmp/capnp-swift-resolver-compat.log` and
`/tmp/capnp-swift-resolver-generate-check.log`.

## Local fixture provenance

`fixtures/lexical_rpc.capnp` is a synthetic schema created for this probe.
The committed request is generated by the repository's pinned compiler,
under the existing WasmKit driver, forwarding the plugin input to stdout:

```sh
swift build --product capnpc-driver
.build/debug/capnpc-driver --plugin /bin/cat \
  --wasm tools/capnpc-swift/wasm/capnp.wasm \
  --src-prefix tools/type-resolver-spike/fixtures \
  tools/type-resolver-spike/fixtures/lexical_rpc.capnp \
  > tools/type-resolver-spike/fixtures/lexical_rpc.request.bin
```

Compiler SHA-256:
`5429b7277b18b6e3f65430068ac41ac327ef8dd359603955f16ec576e0c3a14a`.
Request SHA-256:
`bb6016e9eabdb99473671d30429c7e3b2bfdf4bda687c792d4a7115e7d01d402`.
Regeneration is byte-identical. Existing corpus inputs retain their
original provenance; no generated Swift sources are hand-edited.

## Ablation evidence (2026-10-10)

Every case was broken individually with `scripts/ablate.py`, using an
explicit command for this package:

```sh
python3 scripts/ablate.py tools/type-resolver-spike/src/probe.zig \
  '<exact assertion>' '<wrong assertion>' -- \
  mise exec -- zig build --build-file tools/type-resolver-spike/build.zig \
  test --summary all
```

| Case in the table above | Mutation caught by that test at runtime |
|---|---|
| 1 | Expect Data for `Box(Text).value`. |
| 2 | Expect Data for the recursive next node's value. |
| 3 | Expect Data for the lexical outer Text parameter. |
| 4 | Expect UInt32 for the nested UInt16 list element. |
| 5 | Expect Data for inherited Text params. |
| 6 | Expect the anonymous method's parameter to be bound. |
| 7 | Expect a different error from malformed-brand validation. |
| 8 | Expect a different error from lookup-only payload validation. |

Each run must report its named runtime assertion failure, rather than a
compile failure or an empty selection. Source restoration is byte-verified;
the restored suite passes 8/8. Logs:
`/tmp/capnp-swift-resolver-ablations.log` and
`/tmp/capnp-swift-resolver-ablation-{1..8}.log`.

See [the research](../../docs/handoffs/type-resolver-research.md) for the
public surface, immutable source comparisons, branded-inheritance hazards,
and the remaining Swift pointer-value design decisions.
