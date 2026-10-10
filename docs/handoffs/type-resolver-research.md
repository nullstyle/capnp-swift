# `type_resolver` adoption research

Date: 2026-10-10. Evidence: primary source inspection and Git object comparison, with the executed consumer and compatibility probes recorded in [the probe README](../../tools/type-resolver-spike/README.md). No production dependency pins, shipping generated Swift files, upstream checkout, or package-cache files were changed. The isolated concrete-specialization prototype now emits typed Swift; open generic declarations remain unimplemented.

## Finding

The Swift generator already receives the metadata needed for schema-node generics, but ignores it. Its independent **v0.21.0** generator dependency has the lossless schema model and internal resolver, without a public `type_resolver` export. **v0.23.0** adds an Experimental facade over that same implementation. The separately pinned v0.23.0 RPC core does not make that facade available to the v0.21.0 generator. [Swift pins][swift-pin], [core pin][core-pin], [v0.21 root][root21], [v0.23 facade][facade]

### Exact snapshots

| Source | Immutable commit | Observed identity |
|---|---|---|
| capnp-swift inspected HEAD | `25869c20a2ebd45d35cb1ccaa914b487956ac9e6` | Generator pins `capnpc_zig-0.21.0-nUduFa7PRwBrWc9CyzM8u052LMqBhHzvA52R1s407iCg`; core pins `capnpc_zig-0.23.0-nUduFUsRTgCn5wyHqoKC0ZXgBemZlU7y6bWBmH3RpW9U`. |
| capnp-zig v0.21.0 | `3490a77e1296dfd5adce6b15f60d12a37abce4d9` | Annotated tag object `7cb8e47795a1f56fe66a6ec483cf56abba7e78a9`; commit date 2026-10-06. |
| capnp-zig v0.23.0 | `aca9824a30c2f362b9257cb9a38ad0816ce29743` | Annotated tag object `1bb9157cec16be50a2fca5d6072db297c357ffc5`; commit date 2026-10-08. |
| Remote capnp-zig main | `f093ac43d65198e1402f5128ab511a743e2efbd6` | Retrieved 2026-10-10; commit timestamp `2026-10-10T13:21:19-08:00`. |

`git ls-tree` proves `schema.zig` (blob `633e8b6dacac4e2f967d636baa585362d0889f56`), `request_reader.zig` (`741e513eec8e123bf9cc042d42bc0f682298aedb`), and internal `type_resolver.zig` (`80d114fa816fcad627a483de0e3b1ceaf5434a29`) are identical at all three capnp-zig snapshots. The facade is absent at v0.21.0 and identical at v0.23.0/main (blob `c48a4f898fd7e9ccf5c79da52b6b68334ed7fa1e`). `cmp` also confirmed the specified local v0.23 package's facade/schema/request reader match the remote snapshot. [v0.21 schema][schema21], [v0.23 schema][schema], [main schema][schema-main], [main facade][facade-main]

## Public surface

v0.21.0 exports no `type_resolver` from `lib.zig`, `lib_core.zig`, or `lib_quic.zig`. v0.23.0/main export the facade from all three. The Swift generator imports the `capnpc-zig-core` module under the name `capnp`, so a deliberate generator pin change would expose `capnp.type_resolver`. [Roots][roots], [Swift build][swift-build]

The exact facade is:

```zig
Error = error{InvalidSchema}
max_depth: usize = 64
LookupFn = *const fn (?*anyopaque, schema.Id) ?*const schema.Node
Type { expression: schema.TypeExpression, unbound: bool, context_depth: u8 }
Type.parameter() ?schema.TypeMetadata.AnyPointer.Parameter
Context.init(nodes, node, brand) Error!Context
Context.initWithLookup(node, brand, lookup, lookup_context) Error!Context
Context.resolve(expression) Error!Type
Context.listElement(resolved_list) Error!Type
Context.enter(resolved_named_type) Error!Context
Context.validate(expression) Error!void
```

`Context` also exposes a `resolver: internal.Resolver` field in the Experimental API snapshot; this is an implementation leak, not a reason to depend on the internal API. The facade's intended contract says the internal resolver may change. [Facade][facade], [API snapshot][snapshot], [stability policy][stability]

## Metadata and Swift seam

The existing `schema.Type` union intentionally erases parameter references to `any_pointer` and named applications to their node ID. Preserve it **together with** its parallel metadata, never infer brands from display names. The metadata is already parsed at v0.21.0; there is no missing frontend/request-reader feature to implement here. [Schema model][schema], [request parser][request]

| Existing metadata | Current Swift omission / adoption point |
|---|---|
| `FieldSlot.type_metadata`: `.none`, recursive `.list`, `.named` Brand, or `.any_pointer` details | `emitFieldReader`/`emitFieldBuilder` switch only on `slot.type`; list emitters accept only `*schema.Type`. Construct `TypeExpression{ .type = slot.type, .metadata = slot.type_metadata }`, retain the resolved context while emitting, and traverse list metadata with `listElement`. |
| `Node.parameters`, `Node.is_generic`, parameter `{scope_id, parameter_index}` | Declarations have no Swift generic parameter list. `is_generic` currently causes interface dispatch closure exclusions. A resolved declaration with an empty brand still reports its own parameters as unbound; resolution alone does not emit a Swift generic declaration. |
| `Method.param_brand`, `result_brand`, `implicit_parameters` | Method payload structs are emitted by ID alone. Enter each payload using a struct expression plus its method brand in the interface's current context. |
| Parallel `InterfaceNode.superclass_brands` | Server protocol inheritance, client ancestor properties, and dispatch closure use superclass IDs alone. Enter each superclass application with its parallel brand in the child's current context. |
| `ConstNode`/`AnnotationNode.type_metadata`, `AnnotationUse.brand` | Preserve when these generator surfaces are implemented; they are not required for a field/RPC-payload probe. |

Sources: [metadata definitions][schema], [method/superclass parsing][request], [Swift readers][swift-fields], [Swift builders][swift-builders], [Swift lists][swift-lists], [Swift method payloads][swift-methods], [Swift inheritance][swift-inheritance]. `rg` found no use of `type_metadata`, `superclass_brands`, `param_brand`, `result_brand`, `implicit_parameters`, or `.parameters` in the current Swift generator.

Current erased `AnyPointer` field readers expose only `…IsNull`; builders emit no setter. Typed generics therefore need a Swift pointer-value/codec design as well as resolver adoption. Text, Data, lists, structs, and capabilities are all legal type arguments, so assuming every parameter has a struct-style `.Reader`/`.Builder` would be insufficient. [Swift readers][swift-fields], [Swift builders][swift-builders], [official generic rules][language]

## Behavior that affects the design

- **Ownership:** the facade allocates nothing and copies a bounded stack of brand frames. Nodes, brand slices, binding expressions, metadata pointers, and lookup context remain borrowed. The parsed request must outlive all contexts and returned types; `freeCodeGeneratorRequest` frees this metadata. A returned `Type` must be passed only to the `Context` that produced it. [Facade][facade], [resolver][resolver], [request cleanup][cleanup]
- **Brand scope:** absent bindings and explicit `.unbound` retain erasure. `.inherit` searches the caller environment; a `.bind` expression is interpreted in its caller's frame, not the newly entered target. An unrelated scope, duplicate scope, wrong binding count, non-pointer binding, invalid parameter index, cycle, or excessive depth produces `InvalidSchema`. Pointer-only arguments and omitted-argument erasure agree with the official language/spec. [Resolver][resolver], [official Brand schema][official-brand], [language][language]
- **Validation:** `resolve` substitutes parameter chains and checks metadata shape; it does not recursively validate every named expression. Call `validate` to check reachable list/brand-binding expressions and referenced named-node kinds. It does not walk all fields of every referenced declaration. `enter` accepts only struct/interface expressions; enum entry and entry on unbound AnyPointer fail. [Resolver][resolver], [facade][facade]
- **Anonymous method structs:** their wire `scopeId` is zero, although they inherit the interface's generic scopes. The internal resolver reconstructs the parent through method IDs by scanning the complete node slice; lookup-only mode can recover an owner only when it is the queried expected scope. A directly owning generic interface can be found this way. **Proven consumer reproduction:** the executed test uses `Outer(T).Inner.echo(value :T)` through `Outer(Text).Inner`. The slice context enters the branded Inner and anonymous params, resolving `value` as Text. The lookup-only context reaches the branded Inner, then params validation fails with `InvalidSchema`: the reference to Outer cannot discover the owning nested interface through `LookupFn` alone. See the [fixture](../../tools/type-resolver-spike/fixtures/lexical_rpc.capnp) and [consumer probe](../../tools/type-resolver-spike/src/probe.zig). Retain `request.nodes` for adoption, and request an owner-lookup or known-owner entry helper before freezing lookup-only support. [Lexical-parent implementation][lexical], [official method schema][official-method]
- **Method generics:** `implicit_method_parameter` intentionally resolves as `unbound = true`; `Type.parameter()` recognizes only schema-node parameters. The executed probe confirms two compiler representations: anonymous payloads declare their own scoped parameter, while named `Box(U)` payloads bind to an implicit-method reference. Both remain unbound. The facade has no method-call binding context or inference API. Typed method generics require an additional Swift design and/or an upstream handoff, not merely a pin bump. [Resolver][resolver]
- **Inheritance:** the facade has no ancestor enumeration or application-equality helper. Upstream codegen treats equal branded diamonds as one application and preserves conflicting applications of the same ancestor ID as distinct. Swift's current ID-only closure both drops generic ancestors and cannot represent that distinction. Retain caller contexts and brand applications, with cycle/depth and application-count budgets; do not simply remove the `is_generic` guard. [Upstream ancestor traversal][ancestors], [Swift closure][swift-closure]

## Probe outcome and adoption recommendation

1. Production pins stayed unchanged. The separate v0.23.0 consumer imports the existing `capnpc-zig-core` module through `mise exec -- zig`, without package-cache edits. Scratch builds of the same generator source passed unit/golden tests on v0.21.0 and v0.23.0 and emitted byte-identical Swift for 26/26 committed requests. The RPC core pin remains a separate integration decision. [Swift build][swift-build], [pins][swift-pin]
2. The eight executed consumer cases parse real compiler requests, retain `request.nodes`, validate and resolve `{slot.type, slot.type_metadata}`, traverse list layers with `listElement`, and enter branded applications. Lists, recursion, lexical/nested brands, pointer shapes, inherited method payloads and method-local erasure pass; malformed named arity is rejected. Lookup-only nested RPC entry reproduces H12. Every case was ablated at runtime and restored byte-for-byte. [The probe](../../tools/type-resolver-spike/README.md) records the exact cases, fixture provenance and logs; [upstream facade tests][tests] provide additional source-backed expectations.
3. Before adopting a typed Swift surface, add coverage for the chosen policy on branded diamonds, conflicting ancestor applications, explicit self-binding versus inheritance, and negative index/scope/depth limits. These were inspected in upstream source but are outside this eight-case probe. Ablate every new gate, as this repo requires. [Resolver][resolver], [official Brand schema][official-brand], [repo rules][rules]
4. Keep resolver/context tokens internal to the generator. The [concrete-specialization prototype](../generic-specializations.md) now proves typed Swift struct reads/writes and application identity through the public facade, including independent C++ encode/decode checks. Before freezing Swift APIs, choose how open pointer parameters are represented, how generic nested declarations are named across files, how branded interface ancestors are selected, and what support is promised for implicit method generics. The prototype is **not a complete public generic interface design**. Preserve erased compatibility while proving the typed surface.

The facade is explicitly **Experimental**, despite Stable `request`/`schema`; stability policy allows changes at a 0.x minor bump. Exact version pinning and compatibility gates are necessary, and no facade internals or lifetime-bearing context should become part of a frozen Swift public API. [Stability policy][stability]

## Compact source map

| Concern | Primary source |
|---|---|
| Swift input lifetime and node map | [main.zig:58–66][swift-main], [generator.zig:151–164][swift-init] |
| Public facade and freeze classification | [type_resolver_api.zig][facade], [docs/stability.md][stability] |
| Lossless metadata and cleanup | [schema.zig][schema], [request_reader.zig][request], [request cleanup][cleanup] |
| Binding, validation, method lexical parent | [type_resolver.zig][resolver], [lexical parent][lexical] |
| Branded interface identity | [generic_application.zig:108–149][ancestors] |
| Real-request and synthetic facade expectations | [type_resolver_api_test.zig][tests] |
| Official generic semantics | [Cap'n Proto language][language], [immutable schema.capnp][official-brand] (upstream commit `3a82de9b39736a2625f03c93b2b7c50642dd5b25`, retrieved 2026-10-10) |

[swift-pin]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/build.zig.zon#L7-L14
[core-pin]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/core/build.zig.zon#L10-L19
[swift-build]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/build.zig#L20-L30
[swift-main]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/main.zig#L58-L66
[swift-init]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L151-L164
[swift-fields]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L698-L784
[swift-builders]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L932-L1024
[swift-lists]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L890-L930
[swift-methods]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L460-L481
[swift-inheritance]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L485-L553
[swift-closure]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/tools/capnpc-swift/src/generator.zig#L399-L420
[rules]: https://github.com/nullstyle/capnp-swift/blob/25869c20a2ebd45d35cb1ccaa914b487956ac9e6/CLAUDE.md#L45-L55
[root21]: https://github.com/nullstyle/capnp-zig/blob/3490a77e1296dfd5adce6b15f60d12a37abce4d9/src/lib.zig
[roots]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/lib_core.zig#L18
[schema21]: https://github.com/nullstyle/capnp-zig/blob/3490a77e1296dfd5adce6b15f60d12a37abce4d9/src/serialization/schema.zig
[schema]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/schema.zig
[schema-main]: https://github.com/nullstyle/capnp-zig/blob/f093ac43d65198e1402f5128ab511a743e2efbd6/src/serialization/schema.zig
[facade]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/type_resolver_api.zig
[facade-main]: https://github.com/nullstyle/capnp-zig/blob/f093ac43d65198e1402f5128ab511a743e2efbd6/src/serialization/type_resolver_api.zig
[resolver]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/type_resolver.zig#L97-L325
[lexical]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/type_resolver.zig#L327-L361
[request]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/request_reader.zig#L348-L416
[cleanup]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/request_reader.zig#L928-L1010
[snapshot]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/docs/api-snapshot-experimental.txt
[stability]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/docs/stability.md#L297-L307
[ancestors]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/capnpc-zig/generic_application.zig#L108-L149
[tests]: https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/tests/serialization/type_resolver_api_test.zig
[language]: https://capnproto.org/language.html#generic-types
[official-method]: https://github.com/capnproto/capnproto/blob/3a82de9b39736a2625f03c93b2b7c50642dd5b25/c%2B%2B/src/capnp/schema.capnp#L293-L309
[official-brand]: https://github.com/capnproto/capnproto/blob/3a82de9b39736a2625f03c93b2b7c50642dd5b25/c%2B%2B/src/capnp/schema.capnp#L367-L430
