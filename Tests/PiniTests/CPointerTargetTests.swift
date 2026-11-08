import Testing
import PiniSyntax

@testable import PiniIR
@testable import PiniSemantics

/// 白名单与 IR 的标量集合双向对齐：这是导入面、导出面、声明级三处判据的共同底座。
/// 单边增删要在这里红 —— 三处各维护一份，正是「同一个名字三种结论」的来源。
@Suite("指针目标白名单")
struct CPointerTargetTests: Sendable {

    private static let location = SourceLocation(line: 0, column: 0, fileName: "<test>")

    @Test("表里的每个名字都解析得出，拼写与 IR 的标量分支逐字相同")
    func tableMatchesIRScalars() throws {
        #expect(CPointerTarget.scalarNames.count == 7)
        for name in CPointerTarget.scalarNames {
            let resolved = try #require(IRType(from: .simple(name: name, location: Self.location)))
            #expect(resolved.describe() == name, "实际：\(resolved.describe())")
        }
    }

    @Test("IR 的七个标量分支都在表里，没有单边多出来的")
    func everyIRScalarIsListed() {
        let scalars: [IRType] = [.i8, .u8, .i32, .i64, .u64, .f64, .boolean]
        #expect(Set(scalars.map { $0.describe() }) == CPointerTarget.scalarNames)
    }

    @Test("导入面与表同解：表里的名字过 FFIType，宽度例外出宽度错")
    func importFaceAgrees() throws {
        for name in CPointerTarget.scalarNames {
            let resolved = try FFIType.resolve(.simple(name: name, location: Self.location), at: .parameter)
            #expect(resolved.describe() == name, "实际：\(resolved.describe())")
        }
        for name in CPointerTarget.widthsOutsideIR {
            #expect(throws: FFITypeError.widthNotInIR(type: name)) {
                _ = try FFIType.resolve(.simple(name: name, location: Self.location), at: .parameter)
            }
        }
    }

    @Test("拒绝理由点名：未知、宽度、运行时表示、句柄四类各自说清")
    func rejectionNamesTheCulprit() throws {
        let unknown = try #require(CPointerTarget.rejection(for: "Foo"))
        #expect(unknown.contains("Foo"))
        #expect(unknown.contains("白名单"))

        let width = try #require(CPointerTarget.rejection(for: "I16"))
        #expect(width.contains("I16") && width.contains("宽度"))

        for name in ["String", "Char", "StringHandle"] {
            let reason = try #require(CPointerTarget.rejection(for: name))
            #expect(reason.contains(name), "理由要点名，实际：\(reason)")
        }
    }

    @Test("C 面不透明字节指针的定名在表里")
    func opaqueBytePointerIsListed() {
        #expect(CPointerTarget.opaqueBytePointer == "U8")
        #expect(CPointerTarget.scalarNames.contains(CPointerTarget.opaqueBytePointer))
        #expect(CPointerTarget.rejection(for: CPointerTarget.opaqueBytePointer) == nil)
    }
}
