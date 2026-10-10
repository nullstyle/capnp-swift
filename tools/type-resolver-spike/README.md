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
fixtures plus the small lexical RPC fixture below. Keep the whole checkout
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

This runs the 12-case Zig suite, builds the separate specialization
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
The core CI job runs this combined gate on every push and pull request.

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
