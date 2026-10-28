import Foundation
import PiniCore
import Testing

/// `()` 出现在**值位**时的判据：无返回值调用没有值可给。
///
/// 语言面把它与「推不出类型」分开：推断侧对 void 调用返 `nil`，而 `nil` 在初值位 / 实参位
/// 一律按「未知」放行 ⇒ 静默把 `Any` 绑定给 `var`。本套件钉住两侧：语句位**仍合法**，
/// 值位**必须报 `E4-001`**（`got` 为 `()`）。
struct VoidValuePositionTests {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 前端四道门：词法 → 语法 → 语义 → 类型。任一拒绝即抛出首条诊断。
    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        return (module, checker)
    }

    /// 完整跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    // MARK: - 语句位：合法

    @Test("无返回值调用作表达式语句合法，输出照旧")
    func voidCallAsExpressionStatementIsLegal() throws {
        /// 意图：值位收紧不得波及语句位 —— `print(...)` 单独成句是最常见的写法。
        let source = #"""
        main|func() -> ():
            print("a")
            return
        """#
        #expect(try runOutput(source) == ["a"])
    }

    // MARK: - 值位：拒绝

    @Test("无返回值调用作无标注变量初值被拒")
    func voidCallAsUnannotatedInitializerIsRejected() throws {
        /// 意图：无标注初值位此前把 nil 推断落成 `Any` ⇒ `x` 被静默绑定。
        let source = #"""
        main|func() -> ():
            var x = print("a")
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("无返回值调用作有标注变量初值被拒，报出标注类型")
    func voidCallAsAnnotatedInitializerIsRejected() throws {
        /// 意图：有标注时 `expected` 取标注本身 —— 报文须指 `I32`，不是笼统的「值」。
        let source = #"""
        main|func() -> ():
            var x: I32 = print("a")
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("expected: \"I32\"") == true,
            "该按标注报期望类型，实际：\(String(describing: observed?.message))"
        )
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("无返回值调用作实参被拒 —— `Any` 形参同样不接受")
    func voidCallAsAnyArgumentIsRejected() throws {
        /// 意图：`print` 的形参是 `Any`，实参校验整段被跳过；形参宽松不等于值位宽松。
        let source = #"""
        main|func() -> ():
            print(print("a"))
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("无返回值用户函数作初值同样被拒")
    func voidUserFunctionAsInitializerIsRejected() throws {
        /// 意图：判定面覆盖函数类型登记，不只是内建 —— `g` 的返回类型来自 `-> ()` 声明。
        let source = #"""
        g|func() -> ():
            print("g")

        main|func() -> ():
            var v = g()
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("writeFile 的返回值已不可用：拿它绑变量被拒")
    func writeFileResultCannotBeBound() throws {
        /// 意图：本节点已收窄为 `()`，`var c = writeFile(...)` 必须被拒（`c` 里没有结果码）。
        let source = #"""
        main|func() -> ():
            var c = writeFile("/tmp/pini-void-probe.txt", "x")
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("非 void 函数里 return 无返回值调用被拒")
    func voidCallAsReturnValueOfNonVoidFunctionIsRejected() throws {
        /// 意图：`return expr` 的类型取自推断，void 调用返 nil ⇒ 下方结构比对整段跳过。
        let source = #"""
        f|func() -> (I32):
            return print("a")

        main|func() -> ():
            var y = f()
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"()\"") == true,
            "该报「实际得到 ()」，实际：\(String(describing: observed?.message))"
        )
    }

    @Test("void 函数体内 return 无返回值调用不被类型层拒绝")
    func voidCallAsReturnValueOfVoidFunctionIsNotATypeError() throws {
        /// 意图：`-> ()` 函数体内 return 的值不参与返回类型比对（既有规则）⇒ 不得收紧成误报。
        /// ⚠️ 本用例只判类型层：降载对「返回值类型不可静态解析」另有拒绝（与 void 无关）。
        let source = #"""
        g|func() -> ():
            return print("g")

        main|func() -> ():
            g()
            return
        """#
        _ = try typeChecked(source)
    }
}
