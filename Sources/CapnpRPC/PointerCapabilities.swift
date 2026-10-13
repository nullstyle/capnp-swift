@_spi(Generated) import Capnp

/// A capability projected from a typed or erased pointer value. It retains
/// the connection and, for a capability that came home, its local handler.
public struct RPCPointerCapability: Sendable {
    private let token: PointerCapability
    fileprivate let storage: RPCPointerStorage

    public init(_ pointer: PointerReader) throws {
        guard let token = try pointer.capability() else {
            throw RPCError.unimplemented(reason: "null pointer capability")
        }
        guard let storage = token.payload as? RPCPointerStorage else {
            throw RPCError.malformed("unknown pointer capability adapter")
        }
        if storage.projection == nil, case .none = storage.slot {
            throw RPCError.unimplemented(reason: "null pointer capability")
        }
        self.token = token
        self.storage = storage
    }

    public init(cap: CapRef, connection: RPCConnection) throws {
        guard cap.owner == ObjectIdentifier(connection) else { throw RPCError.foreignCapability }
        storage = RPCPointerStorage(connection: connection, slot: .imported(cap))
        token = PointerCapability(storage)
    }

    public init(pipelined: PipelinedCap, connection: RPCConnection) throws {
        guard pipelined.lifetime.owner == ObjectIdentifier(connection) else { throw RPCError.foreignCapability }
        storage = RPCPointerStorage(connection: connection, slot: .pipelined(pipelined))
        token = PointerCapability(storage)
    }

    /// A local handler can be passed in a pointer before it has a wire ID.
    public init(server: any ExportHandler, connection: RPCConnection) {
        storage = RPCPointerStorage(connection: connection, slot: .export(server), local: server)
        token = PointerCapability(storage)
    }

    init(projection: RPCPointerPipeline) {
        let slot: CapSlot = projection.native.map(CapSlot.pipelined) ?? .none
        storage = RPCPointerStorage(connection: projection.pending.connection, slot: slot, projection: projection)
        token = PointerCapability(storage)
    }

    public var connection: RPCConnection { storage.connection }

    /// Generated nullable interface readers treat a null pointer or a
    /// capability-table hole as nil. Explicit projection above stays strict.
    @_spi(Generated)
    public static func read(from pointer: PointerReader) throws -> RPCPointerCapability? {
        guard let token = try pointer.capability() else { return nil }
        guard let storage = token.payload as? RPCPointerStorage else {
            throw RPCError.malformed("unknown pointer capability adapter")
        }
        if storage.projection == nil, case .none = storage.slot { return nil }
        return try RPCPointerCapability(pointer)
    }

    @_spi(Generated)
    public func write(to pointer: PointerBuilder) throws {
        try pointer.setCapability(token)
    }

    /// Uses the same connection seam for imported and locally returned
    /// capabilities. The result retains its bytes and all capability slots.
    public func call(interface: UInt64, method: UInt16, params: PointerReader) async throws -> PointerReader {
        try await storage.connection.callPointer(storage, interface: interface, method: method, params: params)
    }

    /// Send without awaiting the result. Native promised-answer targets are
    /// sent immediately; local projections wait for their local result.
    public func send(interface: UInt64, method: UInt16, params: PointerReader) async throws -> RPCPointerCall {
        try await storage.connection.sendPointer(storage, interface: interface, method: method, params: params)
    }

    /// A stream acknowledgement holds its existing connection window permit
    /// until success, exception, cancellation, or connection closure.
    public func stream(interface: UInt64, method: UInt16, params: PointerReader) async throws {
        let bytes = try params.serialized().bytes.count
        try await connection.streamWindow.acquireThrowing(bytes: bytes)
        defer { connection.streamWindow.release(bytes: bytes) }
        guard !Task.isCancelled else { throw RPCError.canceled }
        _ = try await call(interface: interface, method: method, params: params)
    }
}

final class RPCPointerStorage: Sendable {
    let connection: RPCConnection
    let slot: CapSlot
    let local: (any ExportHandler)?
    let projection: RPCPointerPipeline?

    init(connection: RPCConnection, slot: CapSlot, local: (any ExportHandler)? = nil, projection: RPCPointerPipeline? = nil) {
        self.connection = connection
        self.slot = slot
        self.local = local
        self.projection = projection
    }
}

extension RPCConnection {
    /// A manually supplied table has no captured local-handler ownership.
    /// Its local IDs must still be live; generated code uses the call/result
    /// overloads, which retain handlers when the native event is received.
    @_spi(Generated)
    public func pointerPayload(bytes: [UInt8], caps: [CapTableEntry]) throws -> PointerReader {
        try pointerPayload(bytes: bytes, caps: caps, localHandlers: [:])
    }

    @_spi(Generated)
    public func pointerPayload(result: CallResult) throws -> PointerReader {
        if let owner = result.pointerOwner, owner !== pointerIdentity { throw RPCError.foreignCapability }
        return try pointerPayload(bytes: result.message, caps: result.caps, localHandlers: result.pointerLocalHandlers)
    }

    @_spi(Generated)
    public func pointerPayload(call: InboundCall) throws -> PointerReader {
        guard call.connection === self else { throw RPCError.foreignCapability }
        return try pointerPayload(bytes: call.params, caps: call.caps, localHandlers: call.pointerLocalHandlers)
    }

    private func pointerPayload(bytes: [UInt8], caps: [CapTableEntry], localHandlers: [UInt32: any ExportHandler]) throws -> PointerReader {
        let tokens = try caps.map { entry -> PointerCapability in
            let storage: RPCPointerStorage
            switch entry {
            case .none:
                storage = RPCPointerStorage(connection: self, slot: .none)
            case .imported(let cap):
                guard cap.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
                storage = RPCPointerStorage(connection: self, slot: .imported(cap))
            case .exported(let id):
                guard let handler = localHandlers[id] ?? localHandler(forExport: id) else {
                    throw RPCError.unimplemented(reason: "unknown local pointer capability")
                }
                storage = RPCPointerStorage(connection: self, slot: .export(handler), local: handler)
            }
            return PointerCapability(storage)
        }
        return try PointerReader(bytes: bytes, capabilities: tokens)
    }

    /// The payload copier has already rewritten indexes into this token
    /// array. Validate every token before passing slots to the existing
    /// send/response seam, which performs the core's ownership checks too.
    @_spi(Generated)
    public nonisolated func pointerSlots(_ tokens: [PointerCapability]) throws -> [CapSlot] {
        try pointerStorages(tokens).map { storage in
            if let projection = storage.projection, projection.native == nil {
                throw RPCError.failed(reason: "pending local capability must be resolved before passing")
            }
            return storage.slot
        }
    }

    private nonisolated func pointerStorages(_ tokens: [PointerCapability]) throws -> [RPCPointerStorage] {
        try tokens.map { token in
            guard let storage = token.payload as? RPCPointerStorage else {
                throw RPCError.malformed("unknown pointer capability adapter")
            }
            guard storage.connection === self else { throw RPCError.foreignCapability }
            return storage
        }
    }

    /// Resolve future arguments/results before passing them. This retains the
    /// native peer's H9 wait-then-pass workaround and also supports returned
    /// local handlers, for which a wire receiverAnswer would be invalid.
    @_spi(Generated)
    public func pointerResolvedSlots(_ tokens: [PointerCapability]) async throws -> [CapSlot] {
        let storages = try pointerStorages(tokens)
        var slots: [CapSlot] = []
        for storage in storages { slots.append(try await resolvedPointerStorage(storage).slot) }
        return slots
    }

    private func pointerPayload(bytes: [UInt8], slots: [CapSlot]) throws -> PointerReader {
        let tokens = try slots.map { slot -> PointerCapability in
            switch slot {
            case .imported(let cap):
                guard cap.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            case .pipelined(let cap):
                guard cap.lifetime.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            case .promise(let cap):
                guard cap.owner == ObjectIdentifier(self) else { throw RPCError.foreignCapability }
            case .none, .export:
                break
            }
            let local: (any ExportHandler)?
            if case .export(let handler) = slot { local = handler } else { local = nil }
            return PointerCapability(RPCPointerStorage(connection: self, slot: slot, local: local))
        }
        return try PointerReader(bytes: bytes, capabilities: tokens)
    }

    fileprivate func callPointer(_ storage: RPCPointerStorage, interface: UInt64, method: UInt16, params: PointerReader) async throws -> PointerReader {
        let pending = try await sendPointer(storage, interface: interface, method: method, params: params)
        return try await pending.value()
    }

    fileprivate func sendPointer(_ storage: RPCPointerStorage, interface: UInt64, method: UInt16, params: PointerReader) async throws -> RPCPointerCall {
        try pointerCheckOpen()
        let payload = try params.serialized()
        let slots = try await pointerResolvedSlots(payload.capabilities)
        let ready = try await readyPointerTarget(storage)
        if let handler = ready.local {
            let task = Task { try await self.invokeLocalPointer(handler, interface: interface, method: method, bytes: payload.bytes, slots: slots) }
            return RPCPointerCall(RPCPointerPending(local: task, connection: self, timeoutMilliseconds: pointerCallTimeoutMilliseconds, retained: [storage, payload.capabilities]))
        }
        let target: CallTarget
        switch ready.slot {
        case .imported(let cap): target = .cap(cap)
        case .pipelined(let cap): target = .pipelined(cap)
        case .none: throw RPCError.unimplemented(reason: "null pointer capability")
        case .export, .promise: throw RPCError.unimplemented(reason: "unresolved local pointer capability")
        }
        let promise = try await send(target, interface: interface, method: method, params: payload.bytes, caps: slots)
        return RPCPointerCall(RPCPointerPending(remote: promise, retained: [storage, payload.capabilities]))
    }

    private func readyPointerTarget(_ storage: RPCPointerStorage) async throws -> RPCPointerStorage {
        if let projection = storage.projection {
            guard projection.path.count <= 64 else { throw RPCError.failed(reason: "pipeline path too deep") }
            if let native = projection.native, try pointerPipelinedResult(native) == nil { return storage }
            return try await resolvedPointerStorage(storage)
        }
        if case .pipelined(let native) = storage.slot, try pointerPipelinedResult(native) != nil {
            return try await resolvedPointerStorage(storage)
        }
        return storage
    }

    private func resolvedPointerStorage(_ storage: RPCPointerStorage, depth: Int = 0) async throws -> RPCPointerStorage {
        guard depth < 64 else { throw RPCError.failed(reason: "pipeline resolution too deep") }
        let pointer: PointerReader
        if let projection = storage.projection {
            pointer = try await projection.value()
        } else if case .pipelined(let native) = storage.slot {
            let result = try await pointerAwaitPipelinedResult(native)
            var selected = try pointerPayload(result: result)
            guard native.path.count <= 64 else { throw RPCError.failed(reason: "pipeline path too deep") }
            for index in native.path { selected = try selected.field(Int(index)) }
            pointer = selected
        } else {
            return storage
        }
        guard let capability = try RPCPointerCapability.read(from: pointer) else {
            throw RPCError.failed(reason: "pipelined capability is null")
        }
        guard capability.connection === self else { throw RPCError.foreignCapability }
        return try await resolvedPointerStorage(capability.storage, depth: depth + 1)
    }

    private func invokeLocalPointer(_ handler: any ExportHandler, interface: UInt64, method: UInt16, bytes: [UInt8], slots: [CapSlot]) async throws -> PointerReader {
        try pointerCheckOpen()
        try Task.checkCancellation()
        var aliases: [UInt32] = []
        defer { pointerRemoveLocal(aliases) }
        let caps = try localPointerEntries(slots, aliases: &aliases)
        let call = InboundCall(interfaceID: interface, methodID: method, params: bytes, caps: caps, connection: self, pointerLocalHandlers: pointerLocalSnapshot(caps))
        let response = try await handler.handle(call, on: self)
        return try pointerPayload(bytes: response.message, slots: response.caps)
    }

    private func localPointerEntries(_ slots: [CapSlot], aliases: inout [UInt32]) throws -> [CapTableEntry] {
        try slots.map { slot in
            switch slot {
            case .none: return .none
            case .imported(let cap): return .imported(cap)
            case .export(let handler):
                // A scoped alias keeps ordinary handlers usable without
                // creating a wire export for a purely local invocation.
                let id = try pointerRegisterLocal(handler)
                aliases.append(id)
                return .exported(id)
            case .pipelined, .promise:
                throw RPCError.unimplemented(reason: "unresolved capability in local pointer call")
            }
        }
    }
}
