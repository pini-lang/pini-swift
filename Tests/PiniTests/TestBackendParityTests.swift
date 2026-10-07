import Foundation
@testable import PiniCore
import Testing

/// `|test` 在**两条后端**上行为一致。
///
/// 参照物是**手写期望**，⛔ 不是「另一条后端」——理由与 `ContractReferenceTests` 逐字相同：
/// 两条通道同时错就会互相认证，判据恒真。故每条语料都写死「程序输出 + 报告 + 退出码」，
/// 两条通道**各自**与这份期望比；两通道彼此相等是推论，不是判据。
///
/// ⚠️ 本套件存在的理由是一条实测过的缺口：`|test` 此前**只有解释器一条通道** ——
/// 发射层的 `isTest` 读取次数为 `0`，纯测试档（无 `main`）在 `emit` 上直接报 `E6-004`
/// （「没找到 main」），而有 `main` 的档虽能发射，测试函数却被 `define` 出来、**一次都没被调用**。
/// 于是「同一份测试、两条后端」这件事此前**没有载体**，也就没有任何东西在守它。
///
/// 三条语义要点（`test-llvm` 与 `test` 必须同判，⛔ 不是「大致相当」）：
/// ① **`main` 不执行** —— 测试入口与程序入口互斥；
/// ② **失败断言中止本测试、但不中止这一轮** —— 一个失败不得隐藏它后面的测试；
/// ③ **输出顺序** —— 程序输出全部在前、报告收尾（解释器那条路的既有形态）。
@Suite("测试两通道锁步")
struct TestBackendParityTests {

    /// 一条语料 + 它的**手写期望**。
    ///
    /// `expectedBody` 是**去掉报告首行之后**的全部输出 —— 首行含临时文件绝对路径，
    /// 会随每次运行变化，故不写进期望值（它由「两通道彼此相等」那半边覆盖）。
    ///
    /// ⚠️ 访问级**不是 private**：它出现在 `@Test` 参数的签名里，Swift 要求「参数用到的类型
    /// 不得比方法更私密」（否则方法也得降成 private，而测试方法必须是 internal 才被收集）。
    struct Corpus: Sendable, CustomStringConvertible {
        let label: String
        /// 内联 Pini 语料（`C4`：raw 字符串写在用例体上，由调用方给出）。
        let source: String
        let expectedStatus: Int32
        let expectedBody: String
        /// 驳回性测量：这些串**不得出现**在任一通道的输出里。
        let forbidden: [String]

        var description: String { label }
    }

    // MARK: - 语料与手写期望

    /// ⚠️ 语料一律 raw 字符串（`#"""`）；内容行与闭合符同一缩进基准即可。
    private static let corpora: [Corpus] = [
        Corpus(
            label: "全通过",
            source: #"""
            甲|test() -> ():
                assert(1 + 1 == 2, "算术")
                return

            乙|test() -> ():
                assert(len("abc") == 3, "len")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
             ✓ 甲
             ✓ 乙
            结果: 2 通过, 0 失败
            """#,
            forbidden: ["✗"]
        ),
        Corpus(
            label: "单条失败",
            source: #"""
            甲|test() -> ():
                assert(1 > 2, "必失")
                return
            """#,
            expectedStatus: 1,
            expectedBody: #"""
             ✗ 甲: 必失
            结果: 0 通过, 1 失败
            """#,
            forbidden: ["✓"]
        ),
        Corpus(
            label: "无测试函数",
            source: #"""
            main() -> ():
                print("只有 main")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
             （未找到 |test 测试函数）
            结果: 0 通过, 0 失败
            """#,
            forbidden: ["只有 main", "✓"]
        ),
        Corpus(
            label: "参数零值注入",
            source: #"""
            参数测试|test(n: I32, s: String, b: Bool,) -> ():
                assert(n == 0, "I32 零值")
                assert(len(s) == 0, "String 空串")
                assert(b == false, "Bool 假")
                print("参数测试-通过")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
            参数测试-通过
             ✓ 参数测试
            结果: 1 通过, 0 失败
            """#,
            forbidden: ["✗"]
        ),
        Corpus(
            label: "断言无消息用默认串",
            source: #"""
            无言断言|test() -> ():
                assert(1 > 2)
                return
            """#,
            expectedStatus: 1,
            expectedBody: #"""
             ✗ 无言断言: assert failed
            结果: 0 通过, 1 失败
            """#,
            forbidden: ["✓"]
        ),
        Corpus(
            label: "测试体调普通函数",
            source: #"""
            helper(x: I32,) -> (I32,):
                return x * 2

            调助手|test() -> ():
                assert(helper(21,) == 42, "helper 应返回 42")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
             ✓ 调助手
            结果: 1 通过, 0 失败
            """#,
            forbidden: ["✗"]
        ),
        Corpus(
            label: "测试体带控制流",
            source: #"""
            循环求和|test() -> ():
                var 合计: I32 = 0
                for (i,) in [1, 2, 3, 4, 5,]:
                    合计 = 合计 + i
                assert(合计 == 15, "1..5 之和应为 15")
                if 合计 > 10:
                    assert(true, "大于 10")
                else:
                    assert(false, "不该走这里")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
             ✓ 循环求和
            结果: 1 通过, 0 失败
            """#,
            forbidden: ["✗", "不该走这里"]
        ),
        Corpus(
            label: "有 main 时不执行 main",
            source: #"""
            应跑|test() -> ():
                assert(true, "ok")
                return

            main() -> ():
                print("main-绝不应出现")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
             ✓ 应跑
            结果: 1 通过, 0 失败
            """#,
            forbidden: ["main-绝不应出现"]
        ),
        Corpus(
            label: "顺序即声明序",
            source: #"""
            第一个|test() -> ():
                print("第一")
                return
            第二个|test() -> ():
                print("第二")
                return
            第三个|test() -> ():
                print("第三")
                return
            """#,
            expectedStatus: 0,
            expectedBody: #"""
            第一
            第二
            第三
             ✓ 第一个
             ✓ 第二个
             ✓ 第三个
            结果: 3 通过, 0 失败
            """#,
            forbidden: ["✗"]
        ),
        Corpus(
            label: "失败中止本测试但不中止这一轮",
            source: #"""
            甲|test() -> ():
                print("甲-前")
                assert(1 > 2, "甲失败")
                print("甲-后-不应出现")
                return

            乙|test() -> ():
                print("乙-照跑")
                return
            """#,
            expectedStatus: 1,
            expectedBody: #"""
            甲-前
            乙-照跑
             ✗ 甲: 甲失败
             ✓ 乙
            结果: 1 通过, 1 失败
            """#,
            forbidden: ["甲-后-不应出现"]
        ),
        Corpus(
            label: "两条都失败",
            source: #"""
            甲|test() -> ():
                assert(1 > 2, "甲失")
                return
            乙|test() -> ():
                assert(2 > 3, "乙失")
                return
            """#,
            expectedStatus: 1,
            expectedBody: #"""
             ✗ 甲: 甲失
             ✗ 乙: 乙失
            结果: 0 通过, 2 失败
            """#,
            forbidden: ["✓"]
        ),
    ]

    // MARK: - 装置

    /// 取被测命令行，**优先环境变量，其次自寻构建产物**。
    ///
    /// ⚠️⭐ 为什么要自寻：本仓既有的七处判据都只在 `PINI_CLI_BIN` 存在时才跑，而**常规跑法是裸
    /// `swift test`**（不设该变量）⇒ 那一族判据在默认读数里**全部被跳过** —— 本批实测到一条既有
    /// 失败（`@strdup` 那条）正是被这个门藏住的。本套件因此**不走那条老路**：环境变量缺席时，
    /// 从 `#filePath` 反推仓根、再找构建产物，使它在默认跑法下**真的跑**。
    ///
    /// 仍保留「响亮跳过」这一支：两者都取不到时记一条已知问题，⛔ 不让用例静默通过。
    private func cliPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }
        // `#filePath` → <仓根>/Tests/PiniTests/TestBackendParityTests.swift ⇒ 上溯三层取仓根。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let candidates = ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
            .map { repoRoot + $0 }
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 本套件本次未取（跳过 +1）") {
            Issue.record("测试两通道锁步未取：本批判据本次没有跑")
        }
        return nil
    }

    private func launch(
        _ binary: String, _ arguments: [String], workingDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-test-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 去掉报告首行。
    ///
    /// 首行含**临时文件的绝对路径**，逐次运行都不同，故不写进手写期望；它由「两条通道输出
    /// 逐字节相等」那半边覆盖。两种形态都要削：单档起首是「测试文件:」，模块起首是「测试目标:」。
    private func strippingReportHeader(_ text: String) -> String {
        var body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("测试文件: ") && !$0.hasPrefix("测试目标: ") }
            .joined(separator: "\n")
        // ⚠️ 切分保留末尾空段 ⇒ `joined` 会补回一个尾换行，而手写期望（raw 字符串）**不含**它
        //（多行字符串的末尾换行被闭合符吃掉）。不对齐这一格，每条用例都会差一个字节。
        if body.hasSuffix("\n") { body.removeLast() }
        return body
    }

    /// 目录里写一份语料，返回它的绝对路径。
    private func write(_ source: String, named name: String, into dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - 判据

    /// 意图：同一份语料，`test` 与 `test-llvm` 两条通道各自与**同一份手写期望**相符。
    ///
    /// 推进性测量：两条通道的输出与退出码都等于期望值。
    /// 驳回性测量：`forbidden` 里的串在**两条**通道的输出里都不出现（`C5` 的否定形态）；
    /// 另有一条总否定 —— 两条通道的输出不得彼此不同（不等即报，且报出首处差异）。
    @Test(
        "同一份语料：两条通道各自与手写期望相符",
        arguments: TestBackendParityTests.corpora)
    func bothChannelsMatchWrittenExpectation(_ corpus: Corpus) throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = try write(corpus.source, named: "\(corpus.label).pini", into: scratch)

        let a = try launch(cli, ["test", path])
        let b = try launch(cli, ["test-llvm", path])

        let aBody = strippingReportHeader(a.stdout)
        let bBody = strippingReportHeader(b.stdout)

        // 推进性测量：两条通道**各自**与手写期望比（⛔ 不是互相比 —— 同时错会互相认证）。
        #expect(aBody == corpus.expectedBody, "解释器通道的输出与期望不符")
        #expect(bBody == corpus.expectedBody, "LLVM 通道的输出与期望不符")
        #expect(a.status == corpus.expectedStatus, "解释器通道退出码 \(a.status) ≠ 期望 \(corpus.expectedStatus)")
        #expect(b.status == corpus.expectedStatus, "LLVM 通道退出码 \(b.status) ≠ 期望 \(corpus.expectedStatus)")

        // 驳回性测量：不该出现的确实没出现（两通道都查）。
        for needle in corpus.forbidden {
            #expect(!aBody.contains(needle), "解释器通道不该出现「\(needle)」")
            #expect(!bBody.contains(needle), "LLVM 通道不该出现「\(needle)」")
        }

        // 总否定：报告首行（含路径）也必须两通道同形 —— 它不进期望值，故单列一条。
        #expect(
            a.stdout == b.stdout,
            "两条通道的标准输出不一致（含报告首行）—— LLVM 侧 stderr：\(b.stderr.prefix(400))")
    }

    /// 意图：按路径**收窄范围**时，两条通道收窄到**同一批**测试（模块根 / 单文件 / 子目录三形态）。
    ///
    /// 推进性测量：三种收窄形态下，两条通道各自与手写期望相符。
    /// 驳回性测量：收窄到 `a.pini` 时，子目录那条测试的名字**不得出现**（收窄没生效就会漏出来）。
    ///
    /// ⚠️ 语料用「路径 → 内容」字典在**运行时**写入临时目录（多文件不是落文件的理由）。
    @Test("按路径收窄范围：两条通道收窄到同一批")
    func bothChannelsNarrowIdentically() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let files: [String: String] = [
            "pini.toml": #"""
            [package]
            name = "tmod"
            """#,
            "a.pini": #"""
            甲测试|test() -> ():
                print("甲跑")
                assert(1 + 1 == 2, "甲")
                return
            """#,
            "sub/b.pini": #"""
            乙测试|test() -> ():
                print("乙跑")
                assert(1 > 2, "乙必失")
                return
            """#,
        ]
        for (relative, content) in files {
            let url = scratch.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        // 三种收窄形态：无参（模块根全量）· 显式文件 · 显式子目录。
        let shapes: [(label: String, argument: String?, status: Int32, body: String, forbidden: [String])] = [
            (
                "模块根全量", nil, 1,
                #"""
                甲跑
                乙跑
                 ✓ 甲测试
                 ✗ 乙测试: 乙必失
                结果: 1 通过, 1 失败
                """#,
                []
            ),
            (
                "显式文件", "a.pini", 0,
                #"""
                甲跑
                 ✓ 甲测试
                结果: 1 通过, 0 失败
                """#,
                ["乙跑", "乙测试"]
            ),
            (
                "显式子目录", "sub", 1,
                #"""
                乙跑
                 ✗ 乙测试: 乙必失
                结果: 0 通过, 1 失败
                """#,
                ["甲跑", "甲测试"]
            ),
        ]

        for shape in shapes {
            var argsA = ["test"]
            var argsB = ["test-llvm"]
            if let argument = shape.argument {
                argsA.append(argument)
                argsB.append(argument)
            }
            let a = try launch(cli, argsA, workingDirectory: scratch)
            let b = try launch(cli, argsB, workingDirectory: scratch)
            let aBody = strippingReportHeader(a.stdout)
            let bBody = strippingReportHeader(b.stdout)

            #expect(aBody == shape.body, "\(shape.label)：解释器通道输出与期望不符")
            #expect(bBody == shape.body, "\(shape.label)：LLVM 通道输出与期望不符")
            #expect(a.status == shape.status, "\(shape.label)：解释器退出码 \(a.status) ≠ \(shape.status)")
            #expect(b.status == shape.status, "\(shape.label)：LLVM 退出码 \(b.status) ≠ \(shape.status)")
            for needle in shape.forbidden {
                #expect(!aBody.contains(needle), "\(shape.label)：解释器通道不该出现「\(needle)」")
                #expect(!bBody.contains(needle), "\(shape.label)：LLVM 通道不该出现「\(needle)」")
            }
            #expect(a.stdout == b.stdout, "\(shape.label)：两条通道标准输出不一致")
        }
    }
}

/// 测试模式的**发射层**不变量。
///
/// ⭐ 与上面那套的分工：这套**不需要工具链**（不调 clang、不起子进程），故在任何环境都跑；
/// 它守的是「发射器有没有按测试模式合成该合成的东西」。端到端那套守的是「行为一致」。
/// 两套都在，是因为前者能定位（错在哪一处合成），后者能定论（真跑起来一致不一致）。
@Suite("测试模式发射")
struct TestModeEmissionTests {

    private func emitTestMode(_ source: String, mode: Bool) throws -> String {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        _ = checker.checkCollecting(module: module)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        // 测试模式**必须**按 `requiresMain: false` 降载 —— 纯测试档没有 `main` 是合法形态。
        let lowered = try IRLowerer.lower(
            module: module, typeInference: checker.typeInference, requiresMain: false)
        let emitter = IREmitter()
        if mode { emitter.testReportHeader = "测试文件: inline.pini" }
        return emitter.emit(module: lowered)
    }

    private static let corpus = #"""
    甲|test() -> ():
        assert(1 > 2, "甲失")
        return
    """#

    /// 意图：测试模式下断言失败**不陷阱**，而是记标志 + 跳出本函数（与解释器的 panic 中止同形）。
    ///
    /// 推进性测量：驱动器、入口、两个插槽都在产物里；失败断言写成「置标志」。
    /// 驳回性测量：`bk_panic` 那条陷阱调用**不得出现**（出现了就意味着失败会带走整轮测试）。
    @Test("测试模式下断言失败不陷阱：标志 + 出口，而非 bk_panic")
    func failingAssertDoesNotTrapInTestMode() throws {
        let ir = try emitTestMode(Self.corpus, mode: true)

        #expect(ir.contains("define i32 @\(IREmitter.testDriverName)()"), "驱动器未合成")
        #expect(ir.contains("define i32 @main()"), "进程入口未合成")
        #expect(
            ir.contains("@\(IREmitter.testFailedGlobal) = internal global i32 0"),
            "失败标志插槽未发出")
        #expect(
            ir.contains("store i32 1, ptr @\(IREmitter.testFailedGlobal)"),
            "失败断言没有置标志")
        #expect(
            ir.contains("call void @\(IRName.mangle("甲"))()"),
            "驱动器没有调用测试函数")
        // 驳回性：陷阱路必须消失。
        #expect(!ir.contains("call ptr @bk_panic"), "测试模式下仍发出陷阱调用")
    }

    /// 意图：**阳性对照** —— 测试模式关闭时，同一份语料的断言失败仍走陷阱（生产语义一字未改）。
    ///
    /// 推进性测量：`bk_panic` 在产物里，驱动器**不**在。
    /// 驳回性测量：测试模式的两个插槽**不得**出现（默认态不该带上测试模式的东西）。
    ///
    /// ⚠️ 这条与上一条成对：只有「测试模式下不陷阱」那半时，「凡断言都不陷阱」也能过判据 ——
    /// 那正是把生产语义一并改掉的形态。
    @Test("测试模式关闭时：陷阱照旧，且不带任何测试模式插槽")
    func productionSemanticsUnchangedWhenModeOff() throws {
        let ir = try emitTestMode(Self.corpus, mode: false)

        #expect(ir.contains("call ptr @bk_panic"), "生产语义的陷阱调用不见了")
        // 驳回性：测试模式的产物特征一个都不许露头。
        #expect(!ir.contains("define i32 @\(IREmitter.testDriverName)()"), "关闭时仍合成了驱动器")
        #expect(!ir.contains("@\(IREmitter.testFailedGlobal)"), "关闭时仍带失败标志插槽")
        #expect(!ir.contains("@\(IREmitter.testMsgGlobal)"), "关闭时仍带消息插槽")
    }

    /// 意图：测试模式下**用户 `main` 不被发射**（测试入口与程序入口互斥）。
    ///
    /// 推进性测量：驱动器在，且测试函数被调用。
    /// 驳回性测量：`main` 体里那句 `print` 的**字符串常量不得进产物** ——
    /// 用常量内容当靶，而不是「`@main` 出现次数」：测试模式的入口本身就叫 `main`，数名字数不出来。
    ///
    /// ⚠️⭐ 靶串**必须是只出现在 main 体里的 CJK 串**，⛔ 不能用拉丁串：产物里的常量按字节转义
    ///（`c"\E4\B8\BB…"`），而**报告首行本身就带着临时文件的绝对路径** —— 拉丁串会与文件名撞，
    /// 于是「main 没被发射」这条断言会被路径里那几个字母误判成通过。这条是我写完第一版、
    /// 实测发现 `main-` 撞上了文件名之后改的。
    @Test("测试模式不发射用户 main")
    func userMainIsNotEmittedInTestMode() throws {
        let source = #"""
        应跑|test() -> ():
            assert(true, "ok")
            return

        main() -> ():
            print("主入口不该被发射")
            return
        """#
        let ir = try emitTestMode(source, mode: true)
        #expect(ir.contains("define i32 @\(IREmitter.testDriverName)()"), "驱动器未合成")
        #expect(
            !ir.contains(#"\E4\B8\BB\E5\85\A5\E5\8F\A3"#),
            "用户 main 的字符串常量进了产物 ⇒ 那个 main 被发射了")
    }
}
