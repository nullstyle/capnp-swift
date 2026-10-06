//! Capability remapping between host payloads and RPC payloads (plan §4,
//! D5; the M0 "cap-remap clone" spike, which decides handoff H6).
//!
//! The host (Swift) builds params/results as a STANDALONE message: its root
//! is the params/results struct, and every capability pointer in it holds an
//! index into a host `caps[]` array of `{kind, id}` (D5).
//!
//! Outbound (`writeHostContent`): validate the host message, clone its root
//! into the Call/Return `payload.content`, then walk the CLONED content and
//! rewrite every capability pointer from "host index i" to an origin-tagged
//! pointer carrying `caps[i]`'s real id space and id
//! (`AnyPointerBuilder.setCapabilityOriginTagged`, Stable). The Peer's own
//! encoder then builds the cap table from those pointers when it sends the
//! frame (`sendCall` runs `encodeCallPayloadCapsWithEffects` after the build
//! callback, `sendReturnResults` runs `encodeReturnPayloadCapsWithEffects`).
//! We never call `initCapTableTyped` or the encoders ourselves: the encoder
//! re-inits the cap table from the cap pointers it finds, and a plain
//! (untagged) pointer would be classified by bare id, which is ambiguous when
//! the export and import id spaces collide (`caps/outbound.zig` resolveCapEntry).
//!
//! Inbound (`copyInbound`): clone the inbound payload content into a new
//! standalone message (its cap pointers keep their inbound cap-table indices)
//! and translate the inbound cap table into `caps[]`, retaining every import
//! so the host owns one wire reference per IMPORT entry until it releases it.

const std = @import("std");
const capnp = @import("capnpc-zig");
const effects = @import("effects.zig");

const message = capnp.message;
const remap = message.capability_remap;
const protocol = capnp.rpc.wire.protocol;
const cap_table = capnp.rpc.caps.table;
const descriptors = capnp.rpc.caps.descriptors;

pub const Cap = effects.Cap;

pub const RemapError = error{
    /// A capability pointer's index is outside `caps[]`.
    CapIndexOutOfRange,
    /// An IMPORT id with no live wire reference, or an EXPORT id that is not
    /// exported (stale or forged host handle).
    BadCapId,
    /// `caps[i].kind == .promised` (pipelined caps in payloads land in M2).
    UnsupportedCapKind,
};

/// Clone the host message `host_msg` (validated with default limits) into
/// `payload.content` and remap its capability pointers through `caps`.
/// `table` is the sending Peer's cap table (`peer.caps`); it is read only.
pub fn writeHostContent(
    allocator: std.mem.Allocator,
    table: *const cap_table.CapTable,
    payload: *protocol.PayloadBuilder,
    host_msg: []const u8,
    caps: []const Cap,
) !void {
    var src = try message.Message.init(allocator, host_msg, .{});
    defer src.deinit();
    const root = try src.getRootAnyPointer();
    const content = try payload.initContent();
    // cloneAnyPointer copies capability pointers as plain indices (it rejects
    // origin-tagged ones, so a host cannot smuggle a pre-tagged pointer).
    try message.cloneAnyPointer(root, content);
    try remapContentCaps(allocator, table, content, caps);
}

/// Rewrite every capability pointer reachable from `content` (in place, in
/// `content.builder`) from a host index into an origin-tagged pointer.
pub fn remapContentCaps(
    allocator: std.mem.Allocator,
    table: *const cap_table.CapTable,
    content: message.AnyPointerBuilder,
    caps: []const Cap,
) !void {
    const builder = content.builder;
    // A read view over the builder's own segments: walking it with the
    // reader's resolve functions follows far pointers and list encodings
    // exactly as the Peer's encoder will. Writes go to the same bytes; each
    // capability pointer is read once, before it is rewritten.
    const view = try remap.buildMessageView(allocator, builder);
    defer allocator.free(view.segments);
    if (content.segment_id >= view.msg.segments.len) return error.InvalidSegmentId;
    const seg = view.msg.segments[content.segment_id];
    if (content.pointer_pos + 8 > seg.len) return error.OutOfBounds;
    const word = std.mem.readInt(u64, seg[content.pointer_pos..][0..8], .little);
    try walk(&view.msg, builder, table, caps, content.segment_id, content.pointer_pos, word, remap.max_traversal_depth);
}

fn walk(
    msg: *const message.Message,
    builder: *message.MessageBuilder,
    table: *const cap_table.CapTable,
    caps: []const Cap,
    segment_id: u32,
    pointer_pos: usize,
    pointer_word: u64,
    depth: u32,
) !void {
    if (depth == 0) return error.RecursionLimitExceeded;
    if (pointer_word == 0) return;
    const resolved = try msg.resolvePointer(segment_id, pointer_pos, pointer_word, 8);
    if (resolved.pointer_word == 0) return;
    switch (@as(u2, @truncate(resolved.pointer_word & 0x3))) {
        // Struct: visit its pointer section.
        0 => {
            const s = try msg.resolveStructPointer(resolved.segment_id, resolved.pointer_pos, resolved.pointer_word);
            const base = s.offset + @as(usize, s.data_size) * 8;
            var i: usize = 0;
            while (i < s.pointer_count) : (i += 1) {
                const pos = base + i * 8;
                try walk(msg, builder, table, caps, s.segment_id, pos, try slotWord(msg, s.segment_id, pos), depth - 1);
            }
        },
        // List: only pointer lists and struct lists can hold capabilities.
        1 => {
            const list = try msg.resolveListPointer(resolved.segment_id, resolved.pointer_pos, resolved.pointer_word);
            if (list.element_size == 6) {
                var i: u32 = 0;
                while (i < list.element_count) : (i += 1) {
                    const pos = list.content_offset + @as(usize, i) * 8;
                    try walk(msg, builder, table, caps, list.segment_id, pos, try slotWord(msg, list.segment_id, pos), depth - 1);
                }
            } else if (list.element_size == 7) {
                const ic = try msg.resolveInlineCompositeList(resolved.segment_id, resolved.pointer_pos, resolved.pointer_word);
                const stride = (@as(usize, ic.data_words) + @as(usize, ic.pointer_words)) * 8;
                var e: u32 = 0;
                while (e < ic.element_count) : (e += 1) {
                    const base = ic.elements_offset + @as(usize, e) * stride + @as(usize, ic.data_words) * 8;
                    var p: usize = 0;
                    while (p < ic.pointer_words) : (p += 1) {
                        const pos = base + p * 8;
                        try walk(msg, builder, table, caps, ic.segment_id, pos, try slotWord(msg, ic.segment_id, pos), depth - 1);
                    }
                }
            }
        },
        // Capability: host index -> origin-tagged real id.
        3 => try rewriteCap(builder, table, caps, resolved.segment_id, resolved.pointer_pos, resolved.pointer_word),
        else => return error.InvalidPointer,
    }
}

/// The pointer word stored at `pos` (bounds-checked).
fn slotWord(msg: *const message.Message, segment_id: u32, pos: usize) error{ InvalidSegmentId, OutOfBounds }!u64 {
    if (segment_id >= msg.segments.len) return error.InvalidSegmentId;
    const seg = msg.segments[segment_id];
    if (pos + 8 > seg.len) return error.OutOfBounds;
    return std.mem.readInt(u64, seg[pos..][0..8], .little);
}

fn rewriteCap(
    builder: *message.MessageBuilder,
    table: *const cap_table.CapTable,
    caps: []const Cap,
    segment_id: u32,
    pointer_pos: usize,
    pointer_word: u64,
) !void {
    const index = try remap.decodeCapabilityPointer(pointer_word);
    if (index >= caps.len) return error.CapIndexOutOfRange;
    const dest = message.AnyPointerBuilder{
        .builder = builder,
        .segment_id = segment_id,
        .pointer_pos = pointer_pos,
    };
    const cap = caps[index];
    switch (cap.kind) {
        .none => try dest.setNull(),
        .import => {
            if (importRefCount(table, cap.id) == 0) return error.BadCapId;
            try dest.setCapabilityOriginTagged(descriptors.originCodeForTag(.receiverHosted), cap.id);
        },
        .@"export" => {
            if (!table.hasExport(cap.id)) return error.BadCapId;
            const tag: protocol.CapDescriptorTag = if (table.isExportPromise(cap.id)) .senderPromise else .senderHosted;
            try dest.setCapabilityOriginTagged(descriptors.originCodeForTag(tag), cap.id);
        },
        .promised => return error.UnsupportedCapKind,
    }
}

/// Wire references the peer holds on `import_id` (0 when unknown).
pub fn importRefCount(table: *const cap_table.CapTable, import_id: u32) u32 {
    const entry = table.imports.get(import_id) orelse return 0;
    return entry.ref_count;
}

pub const Inbound = struct {
    /// Standalone message (segment table + segments) whose root is a clone
    /// of the payload content. Owned; free with the same allocator.
    msg: []const u8,
    /// One entry per inbound cap-table entry. Owned.
    caps: []Cap,

    pub fn deinit(self: Inbound, allocator: std.mem.Allocator) void {
        allocator.free(self.msg);
        allocator.free(self.caps);
    }
};

/// Copy an inbound payload out as a standalone message plus `caps[]`.
///
/// On success every `.imported` entry of `inbound` is marked retained, so the
/// Peer's post-dispatch release pass leaves those wire references to the
/// host. Retention is the last step and cannot fail, so on error the host
/// owns nothing and the Peer releases the imports as usual.
///
/// `inbound` is `*const` because that is how the Peer hands it to question
/// callbacks and call handlers; its `retained` flags are written through a
/// by-value copy whose slice aliases the Peer's storage (the pattern capnp-zig's
/// own generated code and HostPeer use).
pub fn copyInbound(
    allocator: std.mem.Allocator,
    content: message.AnyPointerReader,
    inbound: *const cap_table.InboundCapTable,
) !Inbound {
    var mb = message.MessageBuilder.init(allocator);
    defer mb.deinit();
    const root = try mb.initRootAnyPointer();
    try message.cloneAnyPointer(content, root);
    const bytes = try mb.toBytes();
    errdefer allocator.free(bytes);

    const n = inbound.len();
    const caps = try allocator.alloc(Cap, n);
    errdefer allocator.free(caps);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        caps[i] = switch (try inbound.get(i)) {
            .none => .{ .kind = .none },
            .imported => |imp| .{ .kind = .import, .id = imp.id },
            .exported => |exp| .{ .kind = .@"export", .id = exp.id },
            // A remote reference to one of OUR answers (receiverAnswer). The
            // host cannot use it as a value until promise pipelining lands
            // (M2); it reads as a null capability for now.
            .promised => .{ .kind = .none },
        };
    }

    var mutable = inbound.*;
    i = 0;
    while (i < n) : (i += 1) {
        if (caps[i].kind == .import) mutable.retainIndex(i) catch unreachable; // i < len
    }
    return .{ .msg = bytes, .caps = caps };
}
