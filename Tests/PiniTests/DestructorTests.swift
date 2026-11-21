import Foundation
import PiniSemantics
import PiniSyntax
import Testing

/// 析构 `deinit`：形状只在对象类型上成立，触发点是最后一个强引用释放时，且早于字段清扫。
/// 行为判据走 LLVM 通道；解释器的对象寿命由宿主 ARC 承担，没有可安全重入的归零点（见计划件）。
@Suite("析构", .serialized)
struct DestructorTests: PiniSourceLowering {

    private func diagnosticCode(_ source: String) -> String? {
        do {
            _ = try typeChecked(source)
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    @Test("结构体上声明析构被拒")
    func destructorOnStructIsRejected() {
        let source = #"""
        (箱)
        值: I32 = 0

        {{箱}}

        deinit|self() -> ():
            return
        """#
        #expect(diagnosticCode(source) == "E4-040")
    }

    @Test("析构带形参被拒")
    func destructorWithParameterIsRejected() {
        let source = #"""
        {箱}
        值: I32 = 0

        {{箱}}

        deinit|self(_多余: I32,) -> ():
            return
        """#
        #expect(diagnosticCode(source) == "E4-040")
    }

    @Test("同一类型声明两次析构被拒")
    func secondDestructorOnSameTypeIsRejected() {
        let source = #"""
        {箱}
        值: I32 = 0

        {{箱}}

        deinit|self() -> ():
            return

        {{箱}}

        deinit|self() -> ():
            return
        """#
        #expect(diagnosticCode(source) == "E4-040")
    }

    // MARK: - 触发时机（LLVM 通道）

    private func cliOrSkip() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    private func makeTemporaryDirectory(tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runCLI(
        _ cli: String, arguments: [String], cwd: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = PiniTestEnvironment.childEnvironment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readAllData(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readAllData(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    @Test("作用域退出的最后一次释放触发一次析构，晚于主体输出")
    func destructorRunsOnceAtScopeExit() throws {
        guard let cli = cliOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "deinit-once")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"""
        {资源}
        句柄: I32 = 0

        {{资源}}

        deinit|self() -> ():
            print("析构",)
            return

        main|func() -> ():
            var 甲 = 资源()
            甲.句柄 = 1
            print("主体",)
            return
        """#.write(
            to: dir.appendingPathComponent("life.pini"), atomically: true, encoding: .utf8)
        let result = try runCLI(cli, arguments: ["compile", "life.pini"], cwd: dir)
        #expect(result.status == 0, "compile 失败：\(result.stderr)")
        #expect(result.stdout == "主体\n析构\n", "读数：\(result.stdout)")
    }

    @Test("别名不重复触发：析构等到最后一个持有者释放")
    func destructorWaitsForTheLastAlias() throws {
        guard let cli = cliOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "deinit-alias")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"""
        {资源}
        句柄: I32 = 0

        {{资源}}

        deinit|self() -> ():
            print("析构",)
            return

        main|func() -> ():
            var 甲 = 资源()
            甲.句柄 = 7
            var 乙 = 甲
            print("甲",)
            return
        """#.write(
            to: dir.appendingPathComponent("alias.pini"), atomically: true, encoding: .utf8)
        let result = try runCLI(cli, arguments: ["compile", "alias.pini"], cwd: dir)
        #expect(result.status == 0, "compile 失败：\(result.stderr)")
        #expect(result.stdout == "甲\n析构\n", "读数：\(result.stdout)")
    }
}
