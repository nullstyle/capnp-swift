// The M4 serialization bench (plan §8): the same ping-pong shape as
// capnp-zig's bench/ping_pong.zig — build a ping (u64 id + u32 len + Text
// payload), serialize, re-read, build a pong (id + 1, payload echoed),
// serialize, re-read, checksum — over the pure-Swift Capnp runtime.
//
//   bench-ping-pong [--iters N] [--payload N] [--warmup N]

import Capnp
import Foundation

var iters = 10_000
var payloadBytes = 1024
var warmup = 100
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--iters": iters = Int(args.removeFirst()) ?? iters
    case "--payload": payloadBytes = Int(args.removeFirst()) ?? payloadBytes
    case "--warmup": warmup = Int(args.removeFirst()) ?? warmup
    default: break
    }
}

let payload = String(repeating: "a", count: payloadBytes)

func buildPing(_ id: UInt64, _ mb: MessageBuilder) {
    let root = mb.initRoot(dataWords: 1, pointerWords: 1)
    root.setUInt64(at: 0, id)
    root.setText(0, payload)
}

func run(_ iterations: Int) -> (UInt64, Double) {
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<iterations {
        let pingMB = MessageBuilder()
        buildPing(UInt64(i), pingMB)
        let pingBytes = pingMB.toBytes()
        let pingRoot = try! Message(bytes: pingBytes).rootStruct()
        let text = try! pingRoot.readText(0)
        let pongMB = MessageBuilder()
        let pong = pongMB.initRoot(dataWords: 1, pointerWords: 1)
        pong.setUInt64(at: 0, pingRoot.readUInt64(at: 0) + 1)
        pong.setText(0, text)
        let pongBytes = pongMB.toBytes()
        let pongRoot = try! Message(bytes: pongBytes).rootStruct()
        checksum &+= pongRoot.readUInt64(at: 0) &+ UInt64(pongBytes.count) &+ UInt64(pongRoot.readUInt32(at: 0))
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
    return (checksum, elapsed / Double(iterations))
}

_ = run(warmup)
let (checksum, nsPerOp) = run(iters)
let opsPerSec = 1e9 / nsPerOp
print("iterations: \(iters)")
print("payload: \(payloadBytes)")
print("ns/op: \(String(format: "%.2f", nsPerOp))")
print("ops/s: \(String(format: "%.0f", opsPerSec))")
print("checksum: \(checksum)")
