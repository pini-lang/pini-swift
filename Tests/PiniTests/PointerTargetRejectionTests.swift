import Testing
import PiniSyntax

@testable import PiniSemantics

/// `*T` 的 ARC 隔离不随声明位置改变：签名位拒绝的目标，局部声明与匿名函数形参同样拒绝。
/// 三条负例配一条阳性对照 —— 只有拒绝、没有「标量指针照常可用」那一半，过度收紧也会绿。
@Suite("指针目标的声明位判据")
struct PointerTargetRejectionTests: Sendable, PiniSourceLowering {

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let code = (error as? any DiagnosticProviding)?.diagnosticCode ?? ""
            return (code, String(describing: error))
        }
    }

    @Test("函数体局部声明写 *计数对象 被拒")
    func localDeclarationIsRejected() throws {
        let failed = failure {
            _ = try typeChecked(
                """
                {计数对象}
                数值: I32 = 0

                main|func() -> ():
                    var p: *计数对象
                    return
                """)
        }
        let message = try #require(failed?.message)
        #expect(message.contains("ARC 隔离"), "实际：\(message)")
    }

    @Test("匿名函数形参写 *计数对象 被拒")
    func lambdaParameterIsRejected() throws {
        let failed = failure {
            _ = try typeChecked(
                """
                {计数对象}
                数值: I32 = 0

                main|func() -> ():
                    var f = func(a: *计数对象,) -> ():
                        return
                    return
                """)
        }
        let message = try #require(failed?.message)
        #expect(message.contains("ARC 隔离"), "实际：\(message)")
    }

    @Test("泛型参数里套 *计数对象 一样被拒")
    func genericNestingIsRejected() throws {
        let failed = failure {
            _ = try typeChecked(
                """
                {计数对象}
                数值: I32 = 0

                main|func() -> ():
                    var xs: [*计数对象] = []
                    return
                """)
        }
        let message = try #require(failed?.message)
        #expect(message.contains("ARC 隔离"), "实际：\(message)")
    }

    /// 一条形参写 `*target` 的函数。只声明不调用：判据要的是签名位本身成立与否。
    private func declaring(_ target: String) -> String {
        """
        吃(p: *\(target),) -> ():
            return

        main|func() -> ():
            return
        """
    }

    @Test("未登记的名字作目标被拒，理由点它不在白名单")
    func unknownNameIsRejected() throws {
        let failed = failure { _ = try typeChecked(declaring("Foo")) }
        let message = try #require(failed?.message)
        #expect(message.contains("`Foo`"), "实际：\(message)")
        #expect(message.contains("白名单"), "实际：\(message)")
    }

    @Test("String 作目标在检查期就被拒，不再漂到执行期")
    func stringTargetIsRejected() throws {
        let failed = failure { _ = try typeChecked(declaring("String")) }
        let message = try #require(failed?.message)
        #expect(message.contains("运行时表示"), "实际：\(message)")
    }

    @Test("语言层有、IR 没有的宽度作目标，检查期即拒")
    func widthOutsideIRIsRejected() throws {
        for width in ["I16", "U16", "U32", "F32"] {
            let failed = failure { _ = try typeChecked(declaring(width)) }
            let message = try #require(failed?.message)
            #expect(message.contains("IR 没有对应类型"), "\(width) 实际：\(message)")
        }
    }

    @Test("CChar 作目标被拒，理由指向 U8")
    func ccharTargetIsRejected() throws {
        let failed = failure { _ = try typeChecked(declaring("CChar")) }
        let message = try #require(failed?.message)
        #expect(message.contains("`U8`"), "实际：\(message)")
    }

    @Test("白名单内的标量指针照常成立")
    func whitelistedScalarTargetStillWorks() throws {
        _ = try typeChecked(declaring("U8"))
        _ = try typeChecked(declaring("F64"))
    }

    @Test("标量指针照常成立：收紧没有把合法的 *I64 一起挡掉")
    func scalarPointerStillWorks() throws {
        _ = try typeChecked(
            """
            main|func() -> ():
                var x: I64 = 7
                var p: *I64 = unsafe (&x)
                print(unsafe load(p))
                return
            """)
    }

    @Test("指针参与二元运算时报出拼写，不再是空 expected")
    func pointerOperandShowsItsSpelling() throws {
        let failed = failure {
            _ = try typeChecked(
                """
                main|func() -> ():
                    var x: I64 = 7
                    var p: *I64 = unsafe (&x)
                    var q = unsafe (p + 1)
                    return
                """)
        }
        let message = try #require(failed?.message)
        #expect(message.contains("*I64"), "实际：\(message)")
    }
}
