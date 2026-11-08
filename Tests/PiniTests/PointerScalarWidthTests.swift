import Foundation
import Testing
import PiniSyntax

@testable import PiniHost
@testable import PiniSemantics

/// 标量表与运行时的宽度必须逐项对齐：`p + n` 的步长、`load` / `store` 的编解码宽度是同一个数。
/// 表外名字在运行时没有编解码分支 —— 这条钉住「检查期拒掉的名字不会从运行时漏进来」。
@Suite("指针标量宽度")
struct PointerScalarWidthTests: Sendable {

    private static let location = SourceLocation(line: 0, column: 0, fileName: "<test>")

    private static func annotation(_ name: String) -> TypeAnnotation {
        .simple(name: name, location: location)
    }

    @Test("表里每个标量的 stride 等于登记的字节宽度")
    func strideMatchesTheTable() {
        for (name, width) in CPointerTarget.scalarWidths {
            let stride = RawPointerValue.stride(of: Self.annotation(name))
            #expect(stride == width, "\(name) 实际：\(String(describing: stride))")
        }
        #expect(RawPointerValue.stride(of: Self.annotation("I16")) == nil)
    }

    @Test("写入后用同一元素类型读回，七个标量各自同值")
    func encodeDecodeRoundTrips() throws {
        for (name, width) in CPointerTarget.scalarWidths {
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: width, alignment: 1)
            defer { ptr.deallocate() }
            let value: Value
            switch name {
            case "F64": value = .float(1.5)
            case "Bool": value = .bool(true)
            default: value = .int(7)
            }
            try RuntimeOps.encode(value, to: ptr, type: Self.annotation(name))
            let readBack = try RuntimeOps.decodePointer(
                RawPointerValue(pointer: ptr, elemType: Self.annotation(name), freesMemory: false))
            #expect(readBack == value, "\(name) 实际：\(readBack)")
        }
    }

    @Test("表外名字没有编解码：写入与读出都报运行时错，不按错宽度静默处理")
    func namesOutsideTheTableAreRejected() throws {
        for name in ["I16", "U16", "U32", "F32", "CChar", "String"] {
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
            defer { ptr.deallocate() }
            #expect(throws: RuntimeError.self, "\(name) 写入应被拒") {
                try RuntimeOps.encode(.int(1), to: ptr, type: Self.annotation(name))
            }
            #expect(throws: RuntimeError.self, "\(name) 读出应被拒") {
                _ = try RuntimeOps.decodePointer(
                    RawPointerValue(pointer: ptr, elemType: Self.annotation(name), freesMemory: false))
            }
        }
    }
}
