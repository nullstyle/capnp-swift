/// The byte-stream framing of one connection (plan §2): TCP, Unix and TLS
/// carry standalone segment-table messages; the QUIC baseline wraps each in
/// a u32 little-endian length prefix.
public enum RPCFraming: Sendable, Equatable {
    case segmentTable
    case u32LE
}
