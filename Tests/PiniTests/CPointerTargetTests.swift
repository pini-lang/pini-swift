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

    @Test("宽度表与标量名同源：每个名字都有正的字节宽度，表外的没有")
    func widthsCoverEveryScalar() {
        #expect(Set(CPointerTarget.scalarWidths.keys) == CPointerTarget.scalarNames)
        for (name, width) in CPointerTarget.scalarWidths {
            #expect(CPointerTarget.width(of: name) == width, "\(name) 实际：\(String(describing: CPointerTarget.width(of: name)))")
            #expect(width > 0, "\(name) 的宽度须为正")
        }
        #expect(CPointerTarget.width(of: "I16") == nil)
    }

    @Test("整句与理由同源：句子只是把名字与理由拼起来，标量没有句子")
    func sentenceWrapsTheReason() throws {
        let sentence = try #require(CPointerTarget.sentence(for: "Foo"))
        let reason = try #require(CPointerTarget.rejection(for: "Foo"))
        #expect(sentence == "`Foo` 不能作 `*T` 的目标：\(reason)")
        #expect(CPointerTarget.sentence(for: "U8") == nil)
    }

    @Test("拒绝理由按类别分开：未知、宽度、单字节字符、运行时表示、句柄")
    func rejectionTellsTheCategoriesApart() throws {
        let unknown = try #require(CPointerTarget.rejection(for: "Foo"))
        #expect(unknown.contains("白名单"))

        let width = try #require(CPointerTarget.rejection(for: "I16"))
        #expect(width.contains("IR 没有对应类型"))

        let byte = try #require(CPointerTarget.rejection(for: "CChar"))
        #expect(byte.contains("`U8`"))

        for name in ["String", "Char", "StringHandle"] {
            #expect(CPointerTarget.rejection(for: name) != nil, "\(name) 应有理由")
        }
    }

    @Test("C 面不透明字节指针的定名在表里")
    func opaqueBytePointerIsListed() {
        #expect(CPointerTarget.opaqueBytePointer == "U8")
        #expect(CPointerTarget.scalarNames.contains(CPointerTarget.opaqueBytePointer))
        #expect(CPointerTarget.rejection(for: CPointerTarget.opaqueBytePointer) == nil)
    }
}
