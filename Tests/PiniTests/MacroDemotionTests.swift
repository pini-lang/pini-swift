import Testing
import PiniIR
import PiniSemantics
import PiniSyntax

/// 宏常量降级：未求值只在读点报，声明处只挡非标量，降载不再逐条预检。
/// 需要 C 头文件的真实求值另由命令行夹具覆盖；这里钉住判定面与诊断面。
struct MacroDemotionTests: Sendable {

    private func module(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return try FrontEnd.passes(module: parsed.module)
    }

    private func checked(
        _ source: String, failures: [String: ForeignConstantFailure] = [:]
    ) throws -> [TypeError] {
        let module = try module(source)
        try SemanticAnalyzer().analyze(module: module)
        return TypeChecker().checkCollecting(
            module: module, foreignConstantFailures: failures)
    }

    @Test("未求值的宏没被读到时零诊断：未使用不算错误")
    func unusedFailureIsSilent() throws {
        let errors = try checked(
            """
            [libc|foreign]
            EOF|macro: I32

            main|func() -> (I32,):
                return 0
            """,
            failures: ["EOF": .noHeaders])
        #expect(errors.isEmpty)
    }

    @Test("读到未求值的宏：E4-044 落在读点，理由带声明位置")
    func readReportsAtUseSite() throws {
        let errors = try checked(
            """
            [libc|foreign]
            EOF|macro: I32

            main|func() -> (I32,):
                return EOF
            """,
            failures: ["EOF": .noHeaders])
        #expect(errors.count == 1)
        guard case .foreignMacroUnavailable(let name, let reason, let location) = errors[0] else {
            Issue.record("期望 foreignMacroUnavailable，实际 \(errors[0])")
            return
        }
        #expect(name == "EOF")
        #expect(reason.contains("声明在"))
        #expect(location.line == 5)
        #expect(errors[0].diagnosticCode == "E4-044")
    }

    @Test("取址只报地址禁令，不叠加未求值：一条表达式一条诊断")
    func addressOfReportsOnlyAddressRule() throws {
        let errors = try checked(
            """
            [libc|foreign]
            EOF|macro: I32

            main|func() -> (I32,):
                let p = unsafe &EOF
                return 0
            """,
            failures: ["EOF": .noHeaders])
        #expect(!errors.contains { $0.diagnosticCode == "E4-044" })
        #expect(errors.contains { $0.diagnosticCode == "E4-001" })
    }

    @Test("非标量宏在声明处报 E4-045：与头文件无关，不降级")
    func nonScalarMacroIsDeclarationError() throws {
        let errors = try checked(
            """
            [libc|foreign]
            P|macro: *U8

            main|func() -> (I32,):
                return 0
            """)
        #expect(errors.count == 1)
        #expect(errors[0].diagnosticCode == "E4-045")
    }

    @Test("声明了失败宏但没用：降载不再逐条预检，照常出 main")
    func loweringToleratesUnresolvedMacro() throws {
        let module = try module(
            """
            [libc|foreign]
            EOF|macro: I32

            main|func() -> (I32,):
                return 0
            """)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let errors = checker.checkCollecting(
            module: module, foreignConstantFailures: ["EOF": .noHeaders])
        #expect(errors.isEmpty)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let ir = try IRLowerer.lower(
            module: module, typeInference: checker.typeInference, foreignConstants: [])
        #expect(ir.functions.contains { $0.name == "main" })
    }
}
