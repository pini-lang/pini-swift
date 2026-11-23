import Foundation
import Testing
import PiniIR
import PiniSemantics
import PiniSyntax
import PiniHost

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

    @Test("计划跳过的宏名：E4-046，不是未定义名")
    func skippedMacroIsNotUndefined() throws {
        let module = try module(
            """
            main|func() -> (I32,):
                return DOUBLE(1)
            """)
        let package = Package(
            name: "p", fileUnits: [FileUnit(fileName: "inline.pini", module: module)],
            unavailableNames: ["DOUBLE": "函数式宏要实参才能展开，不能取成常量"])
        do {
            try SemanticAnalyzer().analyze(package: package)
            Issue.record("跳过名应报 E4-046")
        } catch let error as SemanticError {
            guard case .untranslatedForeignMacro(let name, let reason, let location) = error else {
                Issue.record("期望 untranslatedForeignMacro，实际 \(error)")
                return
            }
            #expect(name == "DOUBLE")
            #expect(reason.contains("函数式宏"))
            #expect(location.line == 2)
            #expect(error.diagnosticCode == "E4-046")
        }
    }

    @Test("未登记的名字仍是未定义：跳过表不扩大解释面")
    func unknownNameStaysUndefined() throws {
        let module = try module(
            """
            main|func() -> (I32,):
                return NOPE
            """)
        let package = Package(
            name: "p", fileUnits: [FileUnit(fileName: "inline.pini", module: module)],
            unavailableNames: ["DOUBLE": "函数式宏"])
        do {
            try SemanticAnalyzer().analyze(package: package)
            Issue.record("未登记的名字应报未定义")
        } catch let error as SemanticError {
            guard case .undefinedVariable(let name, _) = error else {
                Issue.record("期望 undefinedVariable，实际 \(error)")
                return
            }
            #expect(name == "NOPE")
        }
    }

    @Test("计划宏段与跳过段：渲染后可回读，旧计划缺段读作空表")
    func planRoundTripsResultSections() throws {
        let root = NSTemporaryDirectory() + "/pini-plan-\(UUID().uuidString)"
        let layout = BuildLayout(root: root, profile: "debug")
        try FileManager.default.createDirectory(
            atPath: layout.buildDirectory, withIntermediateDirectories: true)
        let plan = BuildPlan(
            packages: [PlannedPackage(name: "p", root: root, scriptHash: "")],
            steps: [],
            macros: [
                PlannedMacro(package: "p", name: "EOF", type: "I32", value: "-1"),
                PlannedMacro(
                    package: "p", name: "getc", type: "I32", reason: "functionLike"),
            ],
            skips: [PlannedSkip(package: "p", step: "s", name: "DOUBLE", reason: "函数式宏")])
        let text = try plan.render(layout: layout)
        #expect(text.contains("[[macro]]"))
        #expect(text.contains("state = \"value\""))
        #expect(text.contains("reason = \"functionLike\""))
        #expect(text.contains("[[skip]]"))
        try text.write(toFile: layout.planPath, atomically: true, encoding: .utf8)
        let read = try BuildPlan.read(at: layout.planPath, layout: layout)
        #expect(read == plan)

        let oldPath = layout.buildDirectory + "/old-plan.toml"
        try "[plan]\nversion = 1\ntranslator = \"pini-bind/1\"\n"
            .write(toFile: oldPath, atomically: true, encoding: .utf8)
        let old = try BuildPlan.read(at: oldPath, layout: layout)
        #expect(old?.macros.isEmpty == true)
        #expect(old?.skips.isEmpty == true)
    }
}
