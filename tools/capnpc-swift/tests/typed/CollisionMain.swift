@_spi(Generated) import Capnp

@main struct CollisionMain {
    static func main() throws {
        let first = try UsesA.Typed.Value { try $0.initBox().setValue("first") }
        let second = try UsesB.Typed.Value { try $0.initBox().setValue([9]) }
        let valid = try UsesA.Typed.read(from: first.pointer).box().value() == "first" && UsesB.Typed.read(from: second.pointer).box().value() == [9]
        precondition(valid, "TYPED_COLLISION_FAIL: stable branded collisions")
        print("PASS: stable branded collisions")
    }
}
