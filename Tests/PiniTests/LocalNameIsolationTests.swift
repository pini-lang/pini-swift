import Foundation
import Testing
import PiniSyntax
@testable import PiniHost

/// 同名局部变量跨函数互不顶替：降载阶段重推类型时，用的必须是**本函数**的声明。
/// 语料把宽类型排在后面 —— 检查按声明顺序写入持久表，后写者胜，故修复前先声明的那个函数会被顶替。
/// 另有一组块作用域判据：内层声明独立，退出后外层绑定恢复，两条执行通道读数相同。
@Suite("局部名隔离")
struct LocalNameIsolationTests: Sendable {

    private static let corpus = #"""
    narrow|func(q: I32,) -> (I32,):
        var n = q
        var i = n - 1
        return i

    wide|func(p: U64,) -> (U64,):
        var n = p
        return n

    main|func() -> ():
        print(narrow(7))
        print(wide(9))
        return
    """#

    private static let expected = #"""
    6
    9
    """#

    /// 块内同名声明：if / while / else / 嵌套四形，含条件为假、块内写外层变量与类型顶替。
    private static let shadowCorpus = #"""
    thenBranch|func() -> (I32,):
        var n = 1
        if true:
            var n = 99
            print(n)
        return n

    falseBranch|func() -> (I32,):
        var n = 1
        if false:
            var n = 99
            print(n)
        return n

    loops|func() -> (I32,):
        var n = 1
        var i = 0
        while i < 1:
            var n = 50
            print(n)
            i = i + 1
        if false:
            print(0)
        else:
            var n = 60
            print(n)
        return n

    nested|func() -> (I32,):
        var n = 1
        if true:
            if true:
                var n = 70
                print(n)
        return n

    typed|func() -> (I32,):
        var n = 1
        if true:
            var n = "shadow"
            print(n)
        return n

    main|func() -> ():
        print(thenBranch())
        print(falseBranch())
        print(loops())
        print(nested())
        print(typed())
        return
    """#

    /// 手写期望：块内打印内层值，函数返回外层值；类型顶替一例返回 I32。
    private static let shadowExpected = #"""
    99
    1
    1
    50
    60
    1
    70
    1
    shadow
    1
    """#

    /// 块后读块内绑定：语义期与 IR 校验都该拒，不应有运行期兜底。
    private static let invisibleCorpus = #"""
    probe|func() -> (I32,):
        if true:
            var n = 99
        return n

    main|func() -> ():
        print(probe())
        return
    """#

    /// 隔离不等于放行：块内标注与初值真不符时仍要报类型不匹配。
    private static let typeMismatchCorpus = #"""
    probe|func() -> (I32,):
        if true:
            var n: String = 2
            return n
        return 1

    main|func() -> ():
        print(probe())
        return
    """#

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    private static func attempt(_ source: String) -> Outcome {
        let name = "局部名隔离探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(fileName: name, module: try FrontEnd.passes(module: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "局部名隔离", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    /// 意图：先声明的窄类型不被后声明的同名宽类型顶替；被拒时的报文也要说清是哪一边。
    @Test("先声明的窄类型不被同名宽类型顶替")
    func narrowDeclarationSurvivesLaterWideOne() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：隔离不等于放行 —— 名字对上但类型真不符时仍要拒。
    /// 没有这条，上一条的「跑通了」也可以由「根本不检查」造成。
    @Test("同名在场时真正的类型不符仍被拒")
    func genuineMismatchIsStillRejected() throws {
        let source = #"""
        narrow|func(q: I32,) -> (I32,):
            var n = q
            var i: U64 = n - 1
            return i

        main|func() -> ():
            print(narrow(7))
            return
        """#
        guard case .refused(let message) = Self.attempt(source) else {
            Issue.record("类型不符应被拒")
            return
        }
        #expect(message.contains("type mismatch"), "应报类型不匹配，实际：\(message)")
        #expect(message.contains("U64"), "报文应指出期望的类型，实际：\(message)")
    }

    /// 意图：块内同名声明退出后外层绑定恢复，解释器腿逐行等于手写期望。
    @Test("解释器腿：块内遮蔽退出后外层绑定恢复")
    func interpreterRestoresOuterBinding() throws {
        let outcome = Self.attempt(Self.shadowCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("遮蔽语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.shadowExpected)
    }

    /// 意图：命令行 run 腿与进程内同一份期望，语义层不因块作用域放行而漏判。
    @Test("命令行 run 腿：块内遮蔽退出后外层绑定恢复")
    func cliRunRestoresOuterBinding() throws {
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "shadow-run.pini", contents: Self.shadowCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.shadowExpected + "\n")
    }

    /// 意图：发射腿逐行相同 —— 内层独立、退出恢复在两条通道上是同一条规则。
    @Test("命令行 run-llvm 腿：块内遮蔽退出后外层绑定恢复")
    func cliLLVMRestoresOuterBinding() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "shadow-llvm.pini", contents: Self.shadowCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.shadowExpected + "\n")
    }

    /// 意图：块后读块内绑定在两条通道都被拒，不靠运行期兜底。
    @Test("块内声明在块后不可见")
    func blockBindingsStayInvisible() throws {
        guard case .refused = Self.attempt(Self.invisibleCorpus) else {
            Issue.record("块后读块内绑定应被拒")
            return
        }
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "invisible.pini", contents: Self.invisibleCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["run", file.path])
        #expect(result.status != 0)
    }

    /// 意图：隔离不等于放行，块内标注与初值真不符时仍报类型不匹配。
    @Test("块内真类型不符仍被拒")
    func genuineBlockMismatchIsStillRejected() throws {
        guard case .refused(let message) = Self.attempt(Self.typeMismatchCorpus) else {
            Issue.record("块内类型不符应被拒")
            return
        }
        #expect(message.contains("type mismatch"), "实际：\(message)")
    }

    // MARK: - 命令行装置

    /// 取被测命令行：优先环境变量，其次自寻构建产物；取不到由调用方响亮跳过。
    private func cliPath() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    /// 解析 LLVM 工具链目录；取不到则由调用方响亮跳过发射腿。
    private func llvmToolchainDir() -> String? {
        let fromEnv = PiniTestEnvironment.llvmBinDirectory() ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv + "/lli") {
            return fromEnv
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["lli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readAllData()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let text = String(decoding: data, as: UTF8.self).split(separator: "\n").first
        else { return nil }
        return URL(fileURLWithPath: String(text)).deletingLastPathComponent().path
    }

    /// 同步跑一次子进程，回收 stdout / stderr 与退出码。
    private func launch(
        _ binary: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

    /// 每次用独立临时目录，避免同名言料在并行测试间互相覆盖。
    private func scratchFile(named name: String, contents: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-block-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
