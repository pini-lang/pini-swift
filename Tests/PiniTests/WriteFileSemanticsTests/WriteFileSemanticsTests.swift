import Foundation
import PiniCore
import Testing

/// `writeFile` 的**写语义**判据：就地截断（与 `fopen("w")` 同义），⛔ 不是原子替换。
///
/// 组织：一夹具一条用例，夹具在本文件同目录的 `Fixtures/` 下、文件名即消费它的用例名。
///
/// ⚠️ 本套件测的是**盘上发生了什么**，⛔ 不是返回值 —— 三条用例各钉一个只在该语义下成立的事实：
/// 截断（旧尾巴消失）· 不可打开时抛错（⛔ 不绕过权限）· 符号链接被跟随（⛔ 不替换链接）。
/// 原子替换（临时文件 + 改名）在**三条全部给出相反答案**：旧文件被换成新 inode、权限被绕过、链接被替换。
///
/// ⚠️ 每条用例自建临时基准目录；只读文件在清理前要恢复权限，否则删除会失败。
struct WriteFileSemanticsTests {

    // MARK: - 私有 helper

    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-write-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

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

    // MARK: - 判据

    @Test("写已有文件是就地截断：旧内容不留尾巴")
    func testWriteFileTruncatesInPlace() throws {
        /// 意图：新内容比旧内容短时，旧尾巴必须消失 —— 这是「就地截断」与「追加」的分界。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let target = sandbox.appendingPathComponent("target.txt")
        try Data("a-much-longer-old-content".utf8).write(to: target)

        let lines = try run("testWriteFileTruncatesInPlace", programBase: sandbox)

        #expect(lines == ["0"], "成功写的返回码应为 0，实际：\(lines)")
        let after = try String(contentsOf: target, encoding: .utf8)
        #expect(after == "short", "旧内容未被截断，实际：\(after)")
    }

    @Test("写只读文件走错误通道，不绕过权限")
    func testWriteFileRejectsReadOnlyFile() throws {
        /// 意图：目标**不可打开**必须响亮失败。
        /// ⚠️ 原子替换在这条会**通过写入**（临时文件 + 改名只需目录权限）⇒ 真值是「静默改写只读文件」。
        let sandbox = try makeSandbox()
        let target = sandbox.appendingPathComponent("readonly.txt")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: target.path)
            try? FileManager.default.removeItem(at: sandbox)
        }
        try Data("guarded".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: target.path)

        do {
            let lines = try run("testWriteFileRejectsReadOnlyFile", programBase: sandbox)
            Issue.record("只读文件应抛错，实际跑通并输出：\(lines)")
        } catch let RuntimeError.invalidOperation(reason, _) {
            #expect(reason.contains("无法写入"), "错误原因应指向写入失败，实际：\(reason)")
        }

        let content = try String(contentsOf: target, encoding: .utf8)
        #expect(content == "guarded", "只读文件的内容被改动了：\(content)")
    }

    @Test("写符号链接是跟随链接，不是替换链接")
    func testWriteFileFollowsSymlink() throws {
        /// 意图：写 `link.txt` 应改到它**指向**的 `target.txt`，而 `link.txt` 仍是链接。
        /// ⚠️ 原子替换在这条会把链接换成普通文件、且目标文件**一字未动**。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let target = sandbox.appendingPathComponent("target.txt")
        let link = sandbox.appendingPathComponent("link.txt")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

        let lines = try run("testWriteFileFollowsSymlink", programBase: sandbox)

        #expect(lines == ["0"], "成功写的返回码应为 0，实际：\(lines)")
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written == "through-link", "链接指向的文件未被写入，实际：\(written)")
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        #expect(isLink, "符号链接被替换成了普通文件")
    }
}
