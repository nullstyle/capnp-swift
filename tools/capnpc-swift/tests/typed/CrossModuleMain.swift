@_spi(Generated) import Capnp
import TypedExternal

@main struct CrossModuleMain {
    static func main() throws {
        let value = try UsesExternal.Typed.Value {
            try $0.initBox().setValue("external")
            let nested = $0.initNested()
            try nested.setOuter([1, 2])
            try nested.setInner("inner")
        }
        let reader = try UsesExternal.Typed.read(from: value.pointer)
        let valid = try reader.box().value() == "external" && reader.nested().outer() == [1, 2] && reader.nested().inner() == "inner"
        precondition(valid, "TYPED_IMPORT_FAIL: cross module generic applications")
        print("PASS: cross module generic applications")
    }
}
