import Foundation
import PiniCore
import Testing

/// `listDir` 内建的判据（自举仓 M8 的前置：`.pini` 源码此前**写不出**「列出目录」）。
///
/// 组织：一夹具一条用例，夹具在本文件同目录的 `Fixtures/` 下、文件名即消费它的用例名 ——
/// 「有夹具而无用例」与「有用例而无夹具」都能一眼看出（同 `GrammarAcceptanceTests` 的约定）。
///
/// ⚠️ **与其它套件的一处结构性不同**：本套件的被测对象是**文件系统**。
/// ⇒ 每条用例**自建一个临时目录**当程序基准，⛔ 不在仓库里建任何文件，
///   ⛔ 也不把基准指向夹具目录 —— 后者会让用例互相看见对方的产物，
///   于是「列出的条目数」这类断言会随夹具增减而漂，**而漂的那一刻不会有判据变红**。
///
/// ⚠️ 本套件**不断言**「列不全时截断」，因为实现**不截断**：判据是「无上限」本身
///   （`testListDirHasNoEntryCountCap`）。要证明一条**不存在**的行为只能靠规模，
///   这也是那条用例取 300 个文件的原因。
struct ListDirBuiltinTests {

    // MARK: - 私有 helper

    /// 建一个受控的临时基准目录；调用方负责在结束时删除。
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-listdir-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 解析（含常量折叠）→ 语义门禁 → 类型检查 → 降载 → 在指定基准上执行，返回标准输出逐行。
    ///
    /// 与 `GrammarAcceptanceTests.runFixture` 的差别只有一处：`programBase` 由调用方给定。
    /// 那正是本套件需要的自由度 —— IO 相对路径按**程序基准**解析（不是进程 CWD），
    /// 故基准指向哪里，`listDir` 就列哪里。
    private func run(_ fixture: String, programBase: URL) throws -> [String] {
        let source = try loadPiniFixture(fixture + ".pini", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: fixture + ".pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fixture + ".pini")
            .parseModuleCollectingErrors()
        let module = ConstantFolder.foldConstants(in: parsed.module)
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: programBase.path)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 在基准目录下造条目；`names` 里以 `/` 结尾的当成目录。
    private func seed(_ base: URL, subdirectory: String, names: [String]) throws {
        let dir = base.appendingPathComponent(subdirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let target = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try Data().write(to: target)
            }
        }
    }

    // MARK: - 正向

    @Test("条目是名字（不含目录部分），且按 UTF-8 字节序升序")
    func testListDirReturnsEntryNamesInByteOrder() throws {
        /// 意图：`listDir(path)` 返回**名字**；顺序**确定**（字节序），不是文件系统的返回序。
        /// 语料刻意混入三类边界：大写（`B` = 0x42）、下划线（`_` = 0x5F）、中文（首字节 ≥ 0xE4）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seed(sandbox, subdirectory: "entries",
                 names: ["apple.txt", "zebra.txt", "中文字符.txt", "B.txt", "a.txt", "_under.txt", "subdir/"])

        let lines = try run("testListDirReturnsEntryNamesInByteOrder", programBase: sandbox)

        let expected = ["B.txt", "_under.txt", "a.txt", "apple.txt", "subdir", "zebra.txt", "中文字符.txt"]
        #expect(lines == expected,
                "条目与顺序都不符。实际：\(lines)")

        /// ⭐ 位置断言（不依赖上面那张人写的期望表）—— 期望表本身可能被改错，
        /// 而这三条各钉住一个**字节序事实**，改错时会单独红。
        #expect(lines.firstIndex(of: "B.txt")! < lines.firstIndex(of: "a.txt")!,
                "大写 B(0x42) 应排在 a(0x61) 之前 —— 这不是大小写不敏感排序")
        #expect(lines.firstIndex(of: "_under.txt")! < lines.firstIndex(of: "a.txt")!,
                "_ (0x5F) 应排在 a(0x61) 之前")
        #expect(lines.last == "中文字符.txt",
                "非 ASCII 应排在全部 ASCII 之后。实际末条：\(lines.last ?? "（空）")")
    }

    // MARK: - 负向（两条必须都在，见各夹具头注）

    @Test("目录不存在时响亮拒绝，不是静默返回空数组")
    func testListDirRejectsMissingDirectory() throws {
        /// 意图：走**错误通道**（`RuntimeError.invalidOperation`），且原因里点明是哪种失败。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let lines = try run("testListDirRejectsMissingDirectory", programBase: sandbox)
            Issue.record("目录不存在时应抛错，实际跑通并输出：\(lines)")
        } catch let RuntimeError.invalidOperation(reason, _) {
            #expect(reason.contains("不是目录或不存在"),
                    "错误原因应指明目录不存在，实际：\(reason)")
        }
    }

    @Test("路径是文件而非目录时同样响亮拒绝")
    func testListDirRejectsFilePath() throws {
        /// 意图：钉住「检查的是**是目录**，不只是**存在**」。
        /// ⚠️ 这是本套件最容易被写漏的一条：只查 `fileExists` 的实现在这里**静默返回空数组**。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Data().write(to: sandbox.appendingPathComponent("a-file.txt"))

        do {
            let lines = try run("testListDirRejectsFilePath", programBase: sandbox)
            Issue.record("路径是文件时应抛错，实际跑通并输出：\(lines)")
        } catch let RuntimeError.invalidOperation(reason, _) {
            #expect(reason.contains("不是目录或不存在"),
                    "错误原因应指明不是目录，实际：\(reason)")
        }
    }

    // MARK: - 边界

    @Test("空目录是合法输入，返回空数组")
    func testListDirOnEmptyDirectoryReturnsEmptyArray() throws {
        /// 意图：与上面两条构成一对 —— **空目录**（合法，返空）与**错误路径**（拒绝）
        /// 必须给出**不同**结果，否则「永远返回空数组」的实现两条都能过。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seed(sandbox, subdirectory: "empty", names: [])

        let lines = try run("testListDirOnEmptyDirectoryReturnsEmptyArray", programBase: sandbox)
        #expect(lines == ["0"], "空目录应返回长度 0 的数组，实际：\(lines)")
    }

    @Test("无条目数上限：300 个条目全部返回")
    func testListDirHasNoEntryCountCap() throws {
        /// 意图：钉住**语义决定**（见规范内建清单那段）——`listDir` 刻意不设上限。
        /// ⚠️ 本条原先以 `readFile` 的 64 KiB 上限作**对照**，那个对照已于 2026-10-01 失效：
        /// 该上限被删除（与本条同一条理由 —— 它继承自发射器栈缓冲、不是语言选的，
        /// 见 `Sources/PiniCore/Common/IOLimits.swift` 头注）⇒ 本仓**两个**目录/文件读入内建
        /// 现在都不设上限。`readFile` 那一侧有自己的判据：`ReadFileBuiltinTests`。
        /// ⇒ 将来若有人给任一侧加上限，这条（或那条）红得**正确**：那是语义变更，不是优化。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let names = (0..<300).map { String(format: "f%03d.txt", $0) }
        try seed(sandbox, subdirectory: "many", names: names)

        let lines = try run("testListDirHasNoEntryCountCap", programBase: sandbox)
        #expect(lines == ["300"], "300 个条目应全部返回，实际长度：\(lines)")
    }
}
