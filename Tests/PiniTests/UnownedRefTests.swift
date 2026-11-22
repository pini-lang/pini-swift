import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax
import Testing

/// 无主引用：`UnownedRef(对象)` 只在对象上成立、只在 unsafe 上下文构造；成员访问同样要 unsafe。
/// 运行期“不留份”由语料 `unowned-ref-no-retain` 两条通道各判一遍。
@Suite("无主引用", .serialized)
struct UnownedRefTests: PiniSourceLowering {

    private func diagnosticCode(_ source: String) -> String? {
        do {
            _ = try typeChecked(source)
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    @Test("构造、字段读、方法调用与字段写都能过检查与降载")
    func unownedRefLowers() throws {
        let source = #"""
        {节点}
        值: I32 = 0

        {{节点}}
        加|self(_量: I32,) -> (I32,):
            return self.值 + _量

        写|unsafe(_目标: UnownedRef<节点>, _新值: I32,) -> ():
            _目标.值 = _新值
            return

        main|func() -> ():
            var 强 = 节点()
            let 无主 = unsafe UnownedRef(强)
            print(unsafe 无主.值)
            print(unsafe 无主.加(1))
            写(无主, 9)
            return
        """#
        _ = try lowered(source)
    }

    @Test("结构取无主引用报 E4-043")
    func structUnownedRefIsRejected() {
        let source = #"""
        (点)
        x: I32 = 0

        取|func() -> ():
            let p = 点()
            let u = unsafe UnownedRef(p)
            return
        """#
        #expect(diagnosticCode(source) == "E4-043")
    }

    @Test("成员访问缺 unsafe 报 E4-001")
    func accessOutsideUnsafeIsRejected() {
        let source = #"""
        {节点}
        值: I32 = 0

        main|func() -> ():
            let 强 = 节点()
            let 无主 = unsafe UnownedRef(强)
            print(无主.值)
            return
        """#
        #expect(diagnosticCode(source) == "E4-001")
    }

    @Test("构造缺 unsafe 报 E4-001")
    func constructionOutsideUnsafeIsRejected() {
        let source = #"""
        {节点}
        值: I32 = 0

        main|func() -> ():
            let 强 = 节点()
            let 无主 = UnownedRef(强)
            return
        """#
        #expect(diagnosticCode(source) == "E4-001")
    }

    @Test("显式类型实参形态与省略形态同型")
    func explicitTypeArgumentLowers() throws {
        let source = #"""
        {节点}
        值: I32 = 0

        main|func() -> (I32,):
            let 强 = 节点()
            强.值 = 3
            let 无主 = unsafe UnownedRef<节点>(强)
            return unsafe 无主.值
        """#
        _ = try lowered(source)
    }

    @Test("显式 UnownedRef 标注与构造同型")
    func unownedRefAnnotationAgrees() throws {
        let source = #"""
        {节点}
        值: I32 = 0

        main|func() -> (I32,):
            let 强 = 节点()
            let 无主: UnownedRef<节点> = unsafe UnownedRef(强)
            return unsafe 无主.值
        """#
        _ = try typeChecked(source)
    }
}
