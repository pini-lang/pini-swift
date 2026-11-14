import Foundation
import PiniHost
import PiniSemantics
import Testing

/// 构建面的判据：`build.pini` 读成计划、计划是纯数据、生成物只落构建目录、
/// 缺产物与过期计划都给得出「先跑 build」。四条各管一段，任一段静默通过都会让
/// 「外部符号不见了」表现成一串未定义调用。
@Suite("FFI 构建面")
struct BuildSurfaceTests {

    // MARK: - 夹具

    private struct Fixture {
        let root: URL
        var path: String { root.path }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makePackage(script: String?, header: String = defaultHeader) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("include"), withIntermediateDirectories: true)
        try "[package]\nname = \"builde2e\"\nversion = \"0.1.0\"\n".write(
            to: root.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try header.write(
            to: root.appendingPathComponent("include/cstr.h"), atomically: true, encoding: .utf8)
        try "main|func() -> (I32,):\n    return 0\n".write(
            to: root.appendingPathComponent("main.pini"), atomically: true, encoding: .utf8)
        if let script = script {
            try script.write(
                to: root.appendingPathComponent(BuildScript.fileName), atomically: true,
                encoding: .utf8)
        }
        return Fixture(root: root)
    }

    private static let defaultHeader = """
        #define LIMIT 512
        unsigned long strlen(const char *s);
        int atoi(const char *s);
        """

    private static let defaultScript = """
        ; 构建配置：每个给定块是一条 C 头文件翻译步，块名即步骤名。
        [cstr|given]
            头文件: String = "include/cstr.h"
            包含路径: [String,] = ["include",]
            定义: [String,] = []
        """

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let cli = try #require(PiniTestEnvironment.cliPath())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: out.fileHandleForReading.readAllData(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readAllData(), as: UTF8.self)
        )
    }

    /// 包内源码文件名（排除 `.build`）：生成物是否漏进源码树，只看这一份清单。
    private func sourceTree(of root: URL) throws -> [String] {
        let listing = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return listing.filter { !$0.hasPrefix(".build/") && $0 != ".build" }.sorted()
    }

    // MARK: - 配置期

    @Test("每个给定块读成一条翻译步，字段缺省即空数组")
    func readsTranslateSteps() throws {
        let fixture = try makePackage(
            script: """
                [cstr|given]
                    头文件: String = "include/cstr.h"
                    包含路径: [String,] = ["include",]
                [math|given]
                    头文件: String = "include/cstr.h"
                """)
        defer { fixture.remove() }
        let steps = try #require(try BuildScript.steps(packageRoot: fixture.path))
        #expect(steps.map(\.name) == ["cstr", "math"])
        #expect(steps[0].includePaths == ["include"])
        #expect(steps[1].includePaths.isEmpty)
        #expect(steps[1].defines.isEmpty)
    }

    @Test("无 build.pini 表示没有翻译步，不是错误")
    func absentScriptMeansNoSteps() throws {
        let fixture = try makePackage(script: nil)
        defer { fixture.remove() }
        #expect(try BuildScript.steps(packageRoot: fixture.path) == nil)
    }

    @Test("认不得的字段、缺头文件、重复步骤名都在读取期拒绝")
    func rejectsMalformedScripts() throws {
        let unknownField = try makePackage(
            script: """
                [cstr|given]
                    头文件: String = "include/cstr.h"
                    目标: String = "cstr"
                """)
        defer { unknownField.remove() }
        #expect(throws: BuildScriptError.self) {
            _ = try BuildScript.steps(packageRoot: unknownField.path)
        }

        let missingHeader = try makePackage(
            script: """
                [cstr|given]
                    包含路径: [String,] = ["include",]
                """)
        defer { missingHeader.remove() }
        #expect(throws: BuildScriptError.self) {
            _ = try BuildScript.steps(packageRoot: missingHeader.path)
        }

        let duplicate = try makePackage(
            script: """
                [cstr|given]
                    头文件: String = "include/cstr.h"
                [cstr|given]
                    头文件: String = "include/cstr.h"
                """)
        defer { duplicate.remove() }
        #expect(throws: BuildScriptError.self) {
            _ = try BuildScript.steps(packageRoot: duplicate.path)
        }
    }

    @Test("计划是纯数据：输出路径由布局给出，渲染两次逐字节相同")
    func planIsPureData() throws {
        let fixture = try makePackage(script: Self.defaultScript)
        defer { fixture.remove() }
        let configured = try #require(try BuildRunner.configure(rootDirectory: fixture.path))
        let first = try configured.plan.render(layout: configured.layout)
        let second = try configured.plan.render(layout: configured.layout)
        #expect(first == second, "计划渲染不确定")
        #expect(first.contains(".build/debug/packages/builde2e/generated/cstr.pini"), "输出没落构建目录：\(first)")
        #expect(first.contains("header = \"include/cstr.h\""), "头文件没写根相对路径：\(first)")

        /// 落在包根下的普通文件即可：读回只经布局换算路径，不要求非在 `.build` 里。
        let planPath = fixture.root.appendingPathComponent("plan.toml").path
        try first.write(toFile: planPath, atomically: true, encoding: .utf8)
        let read = try #require(try BuildPlan.read(at: planPath, layout: configured.layout))
        #expect(read.steps == configured.plan.steps, "计划读回后步骤不一致")
        #expect(read.packages.map(\.name) == ["builde2e"])
    }

    @Test("工作区成员的计划落到工作区根，而不是成员目录")
    func memberLayoutUsesWorkspaceRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-build-ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        try "[workspace]\nmembers = [\"app\"]\nprofile = \"debug\"\n".write(
            to: root.appendingPathComponent("pini.toml"), atomically: true, encoding: .utf8)
        try "[package]\nname = \"app\"\nversion = \"0.1.0\"\n".write(
            to: root.appendingPathComponent("app/pini.toml"), atomically: true, encoding: .utf8)
        let layout = try BuildLayout.locate(
            packageRoot: root.appendingPathComponent("app").path)
        let canonical = ModuleDependencyLoader.shared.canonicalPath(
            packagePath: root.path, relativeTo: "/")
        #expect(layout.root == canonical, "成员没认到工作区根：\(layout.root)")
    }

    // MARK: - 执行期

    @Test("--print-plan 打出计划且不写任何产物")
    func printPlanWritesNothing() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let fixture = try makePackage(script: Self.defaultScript)
        defer { fixture.remove() }
        let result = try runCLI(["build", fixture.path, "--print-plan"])
        #expect(result.status == 0, "stderr：\(result.err)")
        #expect(result.out.contains("generated/cstr.pini"), "计划里没有输出路径：\(result.out)")
        #expect(result.out.contains("input_hash = \"\""), "配置期不该算指纹：\(result.out)")
        #expect(
            !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".build").path),
            "配置期写了构建目录")
    }

    @Test("build 产出生成模块，check 看得见符号，源码树不多一个文件")
    func buildFeedsCheck() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let fixture = try makePackage(
            script: Self.defaultScript,
            header: "#define LIMIT 512\nunsigned long strlen(const char *s);\n")
        defer { fixture.remove() }
        try """
            main|func() -> (I32,):
                print(unsafe strlen("abcd"))
                print(LIMIT)
                return 0
            """.write(
                to: fixture.root.appendingPathComponent("main.pini"), atomically: true,
                encoding: .utf8)
        let before = try sourceTree(of: fixture.root)

        let build = try runCLI(["build", fixture.path])
        #expect(build.status == 0, "stderr：\(build.err)")
        #expect(build.out.contains("已翻译"), "构建没报告翻译：\(build.out)")

        let check = try runCLI(["check", fixture.path])
        #expect(check.status == 0, "stderr：\(check.err)")
        #expect(try sourceTree(of: fixture.root) == before, "构建往源码树写了文件")

        let run = try runCLI(["run", fixture.path])
        #expect(run.status == 0, "stderr：\(run.err)")
        #expect(run.out.split(separator: "\n").prefix(2) == ["4", "512"], "运行输出：\(run.out)")
    }

    @Test("删掉构建目录后 check 报「先跑 build」，不静默通过")
    func checkRequiresBuild() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let fixture = try makePackage(script: Self.defaultScript)
        defer { fixture.remove() }
        let build = try runCLI(["build", fixture.path])
        #expect(build.status == 0, "stderr：\(build.err)")
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent(".build"))

        let check = try runCLI(["check", fixture.path])
        #expect(check.status != 0, "缺产物却检查通过")
        #expect(check.err.contains("pini build"), "诊断没指向 build：\(check.err)")
    }

    @Test("build.pini 一改，旧计划即判过期")
    func staleScriptIsReported() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let fixture = try makePackage(script: Self.defaultScript)
        defer { fixture.remove() }
        #expect(try runCLI(["build", fixture.path]).status == 0)
        try (Self.defaultScript + "\n; 注释也算改动\n").write(
            to: fixture.root.appendingPathComponent(BuildScript.fileName), atomically: true,
            encoding: .utf8)
        let check = try runCLI(["check", fixture.path])
        #expect(check.status != 0, "过期计划没被拦下")
        #expect(check.err.contains("pini build"), "诊断没指向 build：\(check.err)")
    }

    @Test("输入不变则复用，头文件一改就重翻，计划逐字节稳定")
    func reusesUntilInputChanges() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let fixture = try makePackage(script: Self.defaultScript)
        defer { fixture.remove() }
        #expect(try runCLI(["build", fixture.path]).status == 0)
        let planPath = fixture.root.appendingPathComponent(".build/debug/plan.toml")
        let firstPlan = try String(contentsOf: planPath, encoding: .utf8)

        let again = try runCLI(["build", fixture.path])
        #expect(again.out.contains("未变"), "同一输入又翻了一遍：\(again.out)")
        #expect(try String(contentsOf: planPath, encoding: .utf8) == firstPlan, "计划不稳定")

        try """
            #define LIMIT 1024
            unsigned long strlen(const char *s);
            """.write(
                to: fixture.root.appendingPathComponent("include/cstr.h"), atomically: true,
                encoding: .utf8)
        let changed = try runCLI(["build", fixture.path])
        #expect(changed.out.contains("已翻译"), "改了头文件却没重翻：\(changed.out)")
        #expect(try String(contentsOf: planPath, encoding: .utf8) != firstPlan, "计划没跟上输入")
    }
}
