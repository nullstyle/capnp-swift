@_spi(Generated) import Capnp
import TypedCollisions

@main struct CollisionImportMain {
    static func main() throws {
        let value = try UsesOneCollision.Typed.Value { try $0.setBox(CollisionProducer.makeB()) }
        let reader = try UsesOneCollision.Typed.read(from: value.pointer).box()
        let valid = try reader.value() == [7, 8, 9] && reader.marker == 202
        precondition(valid, "TYPED_COLLISION_IMPORT_FAIL: one imported declaration from colliding module")
        print("PASS: one imported declaration from colliding module")
    }
}
