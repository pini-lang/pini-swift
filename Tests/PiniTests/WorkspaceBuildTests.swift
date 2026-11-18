import Foundation
import PiniHost
import PiniSemantics
import PiniSyntax
import Testing

@Suite("工作区构建", .serialized)
struct WorkspaceBuildTests {

    @Test("依赖在前的拓扑顺序与 target 产物路径稳定")
    func plansTopologicalBuild() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "plan")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            "[workspace]\nmembers = [\"app\", \"core\", \"base\"]\nprofile = \"debug\"\n")
        try WorkspaceTestSupport.writePackage(root, name: "app", require: ["core"])
        try WorkspaceTestSupport.writePackage(root, name: "core", require: ["base"])
        try WorkspaceTestSupport.writePackage(root, name: "base")

        let plan = try #require(try WorkspaceBuilder.plan(rootDirectory: root.path))
        #expect(plan.packages.map(\.name) == ["base", "core", "app"])
        let app = try #require(plan.packages.first { $0.name == "app" })
        #expect(app.targets.map(\.kind) == [.library])
        #expect(app.targets[0].irPath.hasSuffix("/.build/debug/packages/app/app.ll"))
        #expect(app.targets[0].interfacePath.hasSuffix("/.build/debug/packages/app/interface.txt"))
    }

    @Test("循环依赖在任何构建前被拒绝并给出环链")
    func rejectsDependencyCycle() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "cycle")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"a\", \"b\"]\n")
        try WorkspaceTestSupport.writePackage(root, name: "a", require: ["b"])
        try WorkspaceTestSupport.writePackage(root, name: "b", require: ["a"])

        do {
            _ = try WorkspaceBuilder.plan(rootDirectory: root.path)
            Issue.record("依赖环没有被拒绝")
        } catch {
            #expect(String(describing: error).contains("dependencyCycle"))
            #expect(error.localizedDescription.contains("a"))
            #expect(error.localizedDescription.contains("b"))
        }
    }

    @Test("不同包的可执行产物重名时拒绝覆盖")
    func rejectsDuplicateExecutableNames() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "duplicate-bin")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"a\", \"b\"]\n")
        for name in ["a", "b"] {
            try WorkspaceTestSupport.writePackage(root, name: name)
            let manifest = root.appendingPathComponent("\(name)/pini.toml")
            let text = try String(contentsOf: manifest, encoding: .utf8)
            try text.replacingOccurrences(of: "[lib]", with: "[[bin]]\nname = \"same\"")
                .write(to: manifest, atomically: true, encoding: .utf8)
        }

        do {
            _ = try WorkspaceBuilder.plan(rootDirectory: root.path)
            Issue.record("重名可执行产物没有被拒绝")
        } catch {
            #expect(error.localizedDescription.contains("重名"))
        }
    }

    @Test("普通库不含测试函数，测试 target 同时保留生产接口")
    func isolatesTestTargetSources() throws {
        let plan = try #require(
            try WorkspaceBuilder.plan(
                rootDirectory: WorkspaceTestSupport.bootstrapRoot.path))
        let support = try #require(plan.packages.first { $0.name == "support" })
        let library = try #require(support.targets.first { $0.kind == .library })
        let tests = try #require(support.targets.first { $0.kind == .test })

        let production = try WorkspaceBuilder.load(package: support, target: library)
        let testTarget = try WorkspaceBuilder.load(package: support, target: tests)
        let testNames = WorkspaceTestSupport.testNames(in: testTarget.package)
        #expect(WorkspaceTestSupport.testNames(in: production.package).isEmpty)
        #expect(testNames.contains("负宽度归零"))
        #expect(testNames.contains("字节缓冲按UTF8计数"))
        #expect(production.publicInterface.contains("advance"))
        #expect(production.publicInterface.contains("nonNegativeWidth"))
        #expect(!production.publicInterface.contains("widthFloor"))
    }

    @Test("删除 require 后，磁盘可见的 import 仍被拒绝")
    func rejectsUndeclaredImport() throws {
        let root = try WorkspaceTestSupport.copyBootstrap(tag: "undeclared")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("packages/driver/pini.toml")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.replacingOccurrences(of: "support = \"*\"\n", with: "")
            .write(to: manifest, atomically: true, encoding: .utf8)
        let plan = try #require(try WorkspaceBuilder.plan(rootDirectory: root.path))
        let driver = try #require(plan.packages.first { $0.name == "driver" })
        let target = try #require(driver.targets.first { $0.kind == .executable })

        do {
            _ = try WorkspaceBuilder.load(package: driver, target: target)
            Issue.record("未声明依赖没有被拒绝")
        } catch {
            #expect(error.localizedDescription.contains("support"))
            #expect(error.localizedDescription.contains("未声明"))
        }
    }

    @Test("跨包深层内部函数不可见，多文件 import 逐文件登记")
    func enforcesInternalVisibilityAndMultiFileImports() throws {
        let root = try WorkspaceTestSupport.copyBootstrap(tag: "visibility")
        defer { try? FileManager.default.removeItem(at: root) }
        let secondary = root.appendingPathComponent("packages/driver/src/api/secondary.pini")
        try """
        [secondary|import]
        package = "../../../package"

        secondaryWorkspace|func() -> (Bool,):
            return package.hasWorkspace(".")
        """.write(to: secondary, atomically: true, encoding: .utf8)
        let plan = try #require(try WorkspaceBuilder.plan(rootDirectory: root.path))
        let driver = try #require(plan.packages.first { $0.name == "driver" })
        let target = try #require(driver.targets.first { $0.kind == .executable })
        let loaded = try WorkspaceBuilder.load(package: driver, target: target)
        try SemanticAnalyzer().analyze(package: loaded.package)
        try TypeChecker().check(package: loaded.package)

        try WorkspaceTestSupport.write(
            root, "packages/driver/src/api/main.pini",
            """
            [main|import]
            package = "../../../package"
            _ir = "../../../ir"
            _backend_kit = "../../../backend-kit"
            _backend_dump = "../../../backend-dump"

            main|func() -> ():
                let 结果 = package.normalizeMemberPath("./x")
                print(结果.value)
                return
            """)
        let changed = try WorkspaceBuilder.load(package: driver, target: target)
        do {
            try SemanticAnalyzer().analyze(package: changed.package)
            Issue.record("深层内部函数被跨包接受")
        } catch {
            #expect(String(describing: error).contains("crossModuleAccessDenied"))
        }
    }

    @Test("FFI 规范化保留依赖与 target 字段")
    func preservesManifestFieldsDuringFFINormalization() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            """
            [package]
            name = "sample"
            [require]
            core = "*"
            [lib]
            name = "sample"
            entry = "src/api/sample.pini"
            [ffi]
            search_paths = ["relative"]
            """)
        let manifest = try #require(try FileLoader.loadManifest(directory: root.path))
        #expect(manifest.require["core"] == "*")
        #expect(manifest.targets.map(\.name) == ["sample"])
        #expect(manifest.entryPoints == ["src/api/sample.pini"])
        #expect(manifest.ffi?.searchPaths.first?.hasSuffix("/relative") == true)
    }

    @Test("真实工作区产出接口、IR 与可执行文件")
    func buildsAndRunsWorkspace() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }
        _ = try #require(PiniTestEnvironment.cliPath())
        let root = WorkspaceTestSupport.bootstrapRoot
        let result = try WorkspaceTestSupport.run(
            ".build/debug/pini", ["build", root.path],
            cwd: PiniTestEnvironment.repositoryRoot)
        #expect(result.status == 0, "工作区构建失败：\(result.stderr)")

        let binary = root.appendingPathComponent(".build/debug/bin/pini-bootstrap")
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let execution = try WorkspaceTestSupport.run(binary.path, [], cwd: root)
        #expect(execution.status == 0, "执行失败：\(execution.stderr)")
        #expect(execution.stdout == "workspace-ok 12 true\n", "工作区读数不符：\(execution.stdout)")
        let interface = root.appendingPathComponent(
            ".build/debug/packages/support/interface.txt")
        let text = try String(contentsOf: interface, encoding: .utf8)
        #expect(text.contains("advance"))
        #expect(!text.contains("widthFloor"))
        #expect(!text.contains("负宽度归零"))
    }

    @Test("跨包内部引用在产物生成前失败")
    func rejectsInternalReferenceBeforeEmitting() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())
        let root = try WorkspaceTestSupport.copyBootstrap(tag: "cli-internal")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "packages/driver/src/api/main.pini",
            """
            [main|import]
            package = "../../../package"
            _ir = "../../../ir"
            _backend_kit = "../../../backend-kit"
            _backend_dump = "../../../backend-dump"

            main|func() -> ():
                let 结果 = package.normalizeMemberPath("./x")
                print(结果.value)
                return
            """)

        let result = try WorkspaceTestSupport.run(cli, ["build", root.path], cwd: root)
        #expect(result.status != 0)
        #expect(result.stderr.contains("E3-012"), "诊断不符：\(result.stderr)")
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".build/debug/bin/pini-bootstrap").path))
    }

    @Test("隐式导入的公开类型可按字段与方法使用")
    func usesImplicitlyImportedTypeMembers() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "implicit-types")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"app\", \"base\"]\n")
        try WorkspaceTestSupport.writePackage(root, name: "base")
        try WorkspaceTestSupport.write(
            root, "base/src/api/base.pini",
            """
            (点)
            x: I32 = 0
            y: I32 = 0

            ((点))
            合计|self() -> (I32,):
                return self.x + self.y
            """)
        try WorkspaceTestSupport.write(
            root, "app/pini.toml",
            """
            [package]
            name = "app"

            [require]
            base = "*"

            [[bin]]
            name = "app"
            entry = "src/api/app.pini"
            """)
        try WorkspaceTestSupport.write(
            root, "app/src/api/app.pini",
            """
            [app|import]
            _base = "../../../base"

            main|func() -> ():
                var p = 点()
                p.x = 2
                p.y = 3
                print(p.合计())
                return
            """)

        let build = try WorkspaceTestSupport.run(cli, ["build", root.path], cwd: root)
        #expect(build.status == 0, "工作区构建失败：\(build.stderr)")
        let binary = root.appendingPathComponent(".build/debug/bin/app")
        let run = try WorkspaceTestSupport.run(binary.path, [], cwd: root)
        #expect(run.status == 0, "执行失败：\(run.stderr)")
        #expect(run.stdout == "5\n")
    }
}

struct WorkspaceProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum WorkspaceTestSupport {
    static let bootstrapRoot = PiniTestEnvironment.repositoryRoot.appendingPathComponent("bootstrap")

    /// 报告末尾带总耗时，golden 只钉稳定部分：把「（N.NN 秒）」统一换成占位。
    static func withoutTiming(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"（[0-9]+\.[0-9]+ 秒）"#, with: "（用时）", options: .regularExpression)
    }

    static func temporaryDirectory(tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pini-workspace-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func copyBootstrap(tag: String) throws -> URL {
        let root = try temporaryDirectory(tag: tag)
        try FileManager.default.copyItem(
            at: bootstrapRoot.appendingPathComponent("pini.toml"),
            to: root.appendingPathComponent("pini.toml"))
        try FileManager.default.copyItem(
            at: bootstrapRoot.appendingPathComponent("packages"),
            to: root.appendingPathComponent("packages"))
        return root
    }

    static func write(_ root: URL, _ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writePackage(_ root: URL, name: String, require: [String] = []) throws {
        let requirements =
            require.isEmpty
            ? ""
            : "[require]\n"
                + require.map { "\($0) = \"*\"" }
                .joined(separator: "\n") + "\n"
        try write(
            root, "\(name)/pini.toml",
            "[package]\nname = \"\(name)\"\n\(requirements)[lib]\nentry = \"src/api/\(name).pini\"\n")
    }

    static func testNames(in package: Package) -> [String] {
        package.fileUnits.flatMap { unit in
            unit.module.declarations.compactMap { decl in
                guard case .funcDecl(let function) = decl,
                    function.modifiers.contains("test")
                else { return nil }
                return function.name
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], cwd: URL) throws -> WorkspaceProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = PiniTestEnvironment.childEnvironment()
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return WorkspaceProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
