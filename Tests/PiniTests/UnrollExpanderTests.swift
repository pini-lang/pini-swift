import Foundation
import PiniSemantics
import PiniSyntax
import Testing

/// 展开器判据：一轮一变多、模式名换字面量、产物不再含 `unrollStatement`、五条诊断各就各位。
@Suite("展开器")
struct UnrollExpanderTests {

    @Test("展开：每轮一份、模式名换字面量、产物里没有 unroll")
    func expandsIntoRounds() throws {
        let source = """
            登记|func(码: I32, 名: String,) -> ():
                print(码)
                print(名)
                return

            main|func() -> ():
                unroll (码, 名) in [(1, "开始"), (2, "进行")]:
                    登记(码, 名)
                return
            """
        let module = try Self.expanded(source)
        let printed = Printer.print(module: module)
        #expect(!printed.contains("unroll"), "展开产物里还留着 unroll：\n\(printed)")
        #expect(printed.contains("登记(1, \"开始\")"), "第一轮没换成字面量：\n\(printed)")
        #expect(printed.contains("登记(2, \"进行\")"), "第二轮没换成字面量：\n\(printed)")
        // 展开后仍是同一棵可打印、可回读的树。
        let second = try Self.expanded(printed)
        #expect(PrinterRoundTripTests.firstMismatch(module, second, "Module") == nil)
    }

    @Test("嵌套：内层 unroll 在每份副本里各自展开")
    func expandsNested() throws {
        let source = """
            登记|func(组: String, 序: I32,) -> ():
                print(组)
                print(序)
                return

            main|func() -> ():
                unroll (组) in ["甲", "乙"]:
                    unroll (序) in [1, 2]:
                        登记(组, 序)
                return
            """
        let printed = Printer.print(module: try Self.expanded(source))
        #expect(printed.contains("登记(\"甲\", 1)") && printed.contains("登记(\"乙\", 2)"))
        #expect(printed.components(separatedBy: "登记(").count - 1 == 4, "四轮应当各一份：\n\(printed)")
    }

    @Test("函数字面量体内的 unroll 也会被展开")
    func expandsInsideFunctionLiteral() throws {
        let source = """
            main|func() -> ():
                var 落 = func () -> ():
                    unroll (序) in [1, 2]:
                        print(序)
                    return
                落()
                return
            """
        let printed = Printer.print(module: try Self.expanded(source))
        #expect(!printed.contains("unroll"), "函数字面量里的 unroll 没被展开：\n\(printed)")
    }

    @Test("表不是字面量集合：绑定到变量的表被拒")
    func rejectsNonLiteralTable() {
        Self.expectFailure(
            """
            main|func() -> ():
                var 表 = [1, 2]
                unroll (码) in 表:
                    print(码)
                return
            """,
            matching: { if case .tableNotLiteral = $0 { return true }; return false })
    }

    @Test("元素不是标量：数组套数组被拒")
    func rejectsNonScalarRow() {
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码) in [[1], [2]]:
                    print(码)
                return
            """,
            matching: { if case .tableNotLiteral = $0 { return true }; return false })
    }

    @Test("行分量数与模式不符")
    func rejectsArityMismatch() {
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码, 名) in [(1,)]:
                    print(码)
                return
            """,
            matching: {
                if case .rowMismatch(let row, let expected, let actual, _) = $0 {
                    return row == 1 && expected == 2 && actual == 1
                }
                return false
            })
    }

    @Test("空表：展开零轮")
    func rejectsEmptyTable() {
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码) in []:
                    print(码)
                return
            """,
            matching: { if case .emptyTable = $0 { return true }; return false })
    }

    @Test("超过二百五十六行")
    func rejectsTooManyRows() {
        let rows = (1...257).map { "\($0)" }.joined(separator: ", ")
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码) in [\(rows)]:
                    print(码)
                return
            """,
            matching: {
                if case .tooManyRows(let count, let limit, _) = $0 { return count == 257 && limit == 256 }
                return false
            })
    }

    @Test("体内声明与模式同名的变量：挡的是静默覆盖")
    func rejectsPatternNamedDeclaration() {
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码) in [1, 2]:
                    let 码 = 5
                    print(码)
                return
            """,
            matching: {
                if case .bodyNameConflict(let name, _, _) = $0 { return name == "码" }
                return false
            })
    }

    @Test("体顶层声明局部变量：各轮共用一条语句列表，必然重名")
    func rejectsTopLevelLocal() {
        Self.expectFailure(
            """
            main|func() -> ():
                unroll (码) in [1, 2]:
                    let 标签 = 码
                    print(标签)
                return
            """,
            matching: {
                if case .bodyNameConflict(let name, _, _) = $0 { return name == "标签" }
                return false
            })
    }

    @Test("嵌套块里声明同名局部量不算冲突")
    func allowsLocalInNestedBlock() throws {
        // 每条 `if` 体在每轮各得一份，作用域天然分开 —— 这类写法不该被挡。
        let source = """
            main|func() -> ():
                unroll (码) in [1, 2]:
                    if true:
                        let 标签 = 码
                        print(标签)
                return
            """
        let printed = Printer.print(module: try Self.expanded(source))
        #expect(printed.components(separatedBy: "let 标签").count - 1 == 2, "两轮各一份：\n\(printed)")
    }

    @Test("解释器与 LLVM 两条通道输出一致")
    func bothChannelsAgree() throws {
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
            withKnownIssue("未提供 PINI_CLI_BIN / PINI_LLVM_BIN ⇒ 双通道读数本次未取（跳过 +1）") {
                Issue.record("双通道判据未取")
            }
            return
        }
        let source = """
            登记|func(码: I32, 名: String,) -> ():
                print(码)
                print(名)
                return

            main|func() -> ():
                unroll (码, 名) in [(1, "开始"), (2, "进行"), (3, "结束")]:
                    登记(码, 名)
                return
            """
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unroll-parity-\(UUID().uuidString).pini")
        try source.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let interpreted = try Self.launch(cli, ["run", path.path])
        let compiled = try Self.launch(cli, ["run-llvm", path.path])
        #expect(interpreted.status == 0, "解释器未跑通：\(interpreted.stderr)")
        #expect(compiled.status == 0, "LLVM 未跑通：\(compiled.stderr)")
        #expect(interpreted.stdout == compiled.stdout, "两条通道输出不一致")
        #expect(
            interpreted.stdout == ["1", "开始", "2", "进行", "3", "结束"].joined(separator: "\n") + "\n",
            "展开顺序或取值不对：\(interpreted.stdout)")
    }

    // MARK: - 助手

    static func expanded(_ source: String, fileName: String = "unroll-test.pini") throws -> Module {
        switch FrontEnd.collect(source: source, fileName: fileName) {
        case .parsed(let module): return module
        case .lexFailed(let error): throw error
        case .parseFailed(_, let errors): throw errors[0]
        case .expandFailed(let errors): throw errors[0]
        }
    }

    static func expectFailure(_ source: String, matching predicate: (UnrollError) -> Bool) {
        switch FrontEnd.collect(source: source, fileName: "unroll-test.pini") {
        case .expandFailed(let errors):
            let matched = errors.contains(where: predicate)
            #expect(matched, "错误不对：\(errors)")
        default:
            Issue.record("应当展开失败，实际通过了")
        }
    }

    static func launch(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }
}
