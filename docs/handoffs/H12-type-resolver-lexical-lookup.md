# H12: make lookup-backed resolver contexts preserve nested RPC lexical scopes

Status: **REPRODUCED 2026-10-10** against capnp-zig v0.23.0's public
Experimental facade. Consumer workaround: use `Context.init(request.nodes,
node, brand)`. Upstream changes remain an owner coordination item.

## Failure

`Context.initWithLookup` rejects a valid anonymous RPC params struct whose
field refers to a generic scope enclosing its interface. The equivalent
slice-backed context resolves that field to Text.

```capnp
@0xd8d53a771adf5a1d;
struct Outer(T) {
  interface Inner {
    echo @0 (value :T) -> (value :T);
  }
}
struct Root { service @0 :Outer(Text).Inner; }
```

Both modes find Root, resolve its branded `service`, and enter Inner.
Slice mode then validates/enters the method's params type with its
`param_brand` and resolves `value` to Text. Lookup-only mode fails that
same valid payload validation with `InvalidSchema`. The lookup callback
can return every request node by ID; missing nodes are not the cause.

Anonymous payloads have wire `scope_id = 0`. The resolver reconstructs
their owning interface by scanning the node slice. Lookup-only mode has
no slice and tries the queried expected scope as the possible owner.
For a direct interface parameter this can work; here the expected scope
is Outer, while the actual owning interface is Inner. A forward node-ID
lookup cannot discover that reverse edge.

Primary sources: [public facade](https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/type_resolver_api.zig),
[lexical-parent resolution](https://github.com/nullstyle/capnp-zig/blob/aca9824a30c2f362b9257cb9a38ad0816ce29743/src/serialization/type_resolver.zig#L330-L355).
The facade and implementation are unchanged at inspected remote main
`f093ac43d65198e1402f5128ab511a743e2efbd6` (2026-10-10); see the immutable
comparisons in [the research](type-resolver-research.md).

## Reproduce

In the capnp-swift checkout:

```sh
just type-resolver-spike
```

The final case in
`tools/type-resolver-spike/src/probe.zig` uses only the public facade. It
asserts the successful slice result and the current callback-mode error.
Both operate on the same parsed request and keep it alive until teardown.
The request and source schema are in `tools/type-resolver-spike/fixtures/`;
[the probe README](../../tools/type-resolver-spike/README.md) records the
pinned compiler, exact hashes, generation command, and runtime ablation.

This case was ablated by expecting a different callback error; its named
runtime assertion failed, and byte-restored source returned to 8/8 passing.
After an upstream fix, the callback expectation should become the same
Text result as the slice-backed context. Add both params and results to
the upstream regression coverage.

## Contract needed before freezing

The public callback form should have a documented way to recover logical
method ownership, so replacing a full node slice with lookups preserves
valid-schema behavior. Two possible approaches:

1. Accept a logical-owner lookup alongside node lookup. Consumers can
   index `param_struct_type`/`result_struct_type → interface ID` once while
   parsing their complete request; the resolver follows the owner's
   lexical scopes through the existing node lookup.
2. Offer entry into a method payload with its known owning interface,
   and explicitly document which direct lookup-only initializations need
   that ownership information. Active caller frames can also help this
   specific entry path, but do not discover arbitrary reverse ownership
   when a payload is initialized directly.

Keep the ownership interpretation inside the resolver. The consumer should
not fabricate schema nodes, rewrite the wire scope ID, or import the
internal resolver to repair the public facade. This issue is independent
of method-local generic inference, which remains intentionally unbound.
