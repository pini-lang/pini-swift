import Foundation
import PiniSemantics
import PiniSyntax
import Testing

/// 析构 `deinit`：形状只在对象类型上成立，触发点是最后一个强引用释放时，且早于字段清扫。
/// 两条通道都跑：编译侧在释放胶水里调，解释侧在归零时把字段交割给释放队列、由引擎在语句边界执行。
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

    // MARK: - 解释器通道与两通道一致

    /// 同一份源码分别走 `run` 与 `compile`，两次读数逐字节比对。
    /// 只比 stdout：警告与诊断走 stderr，与析构时机无关。
    private func bothChannels(_ source: String, tag: String) throws -> (run: String, compile: String) {
        guard let cli = cliOrSkip() else { return ("", "") }
        let dir = try makeTemporaryDirectory(tag: tag)
        defer { try? FileManager.default.removeItem(at: dir) }
        try source.write(
            to: dir.appendingPathComponent("case.pini"), atomically: true, encoding: .utf8)
        let interpreted = try runCLI(cli, arguments: ["run", "case.pini"], cwd: dir)
        let compiled = try runCLI(cli, arguments: ["compile", "case.pini"], cwd: dir)
        #expect(interpreted.status == 0, "run 失败：\(interpreted.stderr)")
        #expect(compiled.status == 0, "compile 失败：\(compiled.stderr)")
        return (interpreted.stdout, compiled.stdout)
    }

    @Test("解释器通道也在帧收尾跑一次析构，与编译通道同读数")
    func interpreterRunsDestructorAtFrameEnd() throws {
        let readings = try bothChannels(
            #"""
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
            """#, tag: "deinit-channel")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "主体\n析构\n", "解释通道读数：\(readings.run)")
        #expect(readings.run == readings.compile, "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }

    @Test("解释器通道：析构读到主体改过的字段，别名只触发一次")
    func interpreterDestructorSeesFieldsAndLastAlias() throws {
        let readings = try bothChannels(
            #"""
            {资源}
            句柄: I32 = 0

            {{资源}}

            deinit|self() -> ():
                print(self.句柄,)
                return

            main|func() -> ():
                var 甲 = 资源()
                甲.句柄 = 7
                var 乙 = 甲
                print("甲",)
                return
            """#, tag: "deinit-fields")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "甲\n7\n", "解释通道读数：\(readings.run)")
        #expect(readings.run == readings.compile, "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }

    @Test("解释器通道：外层析构后字段里的内层跟着走，次序与编译通道一致")
    func interpreterDestroysFieldsAfterTheOwner() throws {
        let readings = try bothChannels(
            #"""
            {内}
            名: I32 = 1

            {{内}}

            deinit|self() -> ():
                print("内",)
                return

            {外}
            _子: 内 = 内()

            {{外}}

            deinit|self() -> ():
                print("外",)
                return

            main|func() -> ():
                var 甲 = 外()
                print("甲活着",)
                return
            """#, tag: "deinit-nested")
        guard !readings.run.isEmpty else { return }
        #expect(readings.run == "甲活着\n外\n内\n", "解释通道读数：\(readings.run)")
        #expect(readings.run == readings.compile, "两通道不一致：run=\(readings.run) compile=\(readings.compile)")
    }
}
