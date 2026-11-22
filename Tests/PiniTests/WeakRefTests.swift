import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax
import Testing

/// 弱引用：`weak 对象` 只在对象上成立，结果类型 `WeakRef<T>`；`.value` 读成 `Optional<T>`。
/// 运行期“对象销毁后读到 nil”由语料 `weak-ref-lifecycle` 两条通道各判一遍。
@Suite("弱引用", .serialized)
struct WeakRefTests: PiniSourceLowering {

    private func diagnosticCode(_ source: String) -> String? {
        do {
            _ = try typeChecked(source)
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    @Test("对象取弱引用与值读都能过检查与降载")
    func objectWeakRefLowers() throws {
        let source = #"""
        {节点}
        值: I32 = 0

        main|func() -> ():
            let 强 = 节点()
            let 弱 = weak 强
            match 弱.value:
                case some(目标,):
                    print(目标.值)
                case nil:
                    print("空")
            return
        """#
        _ = try lowered(source)
    }

    @Test("结构取弱引用报 E4-042")
    func structWeakRefIsRejected() {
        let source = #"""
        (点)
        x: I32 = 0

        取|func() -> ():
            let p = 点()
            let w = weak p
            return
        """#
        #expect(diagnosticCode(source) == "E4-042")
    }

    @Test("显式 WeakRef 标注与 weak 前缀同型")
    func weakRefAnnotationAgrees() throws {
        let source = #"""
        {节点}
        值: I32 = 0

        取|func() -> (I32,):
            let 强 = 节点()
            let 弱: WeakRef<节点> = weak 强
            match 弱.value:
                case some(目标,):
                    return 目标.值
                case nil:
                    return 0
        """#
        _ = try typeChecked(source)
    }
}
