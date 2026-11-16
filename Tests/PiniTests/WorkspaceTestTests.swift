import Foundation
import PiniHost
import Testing

@Suite("工作区测试闭环", .serialized)
struct WorkspaceTestTests {

    @Test("通过用例输出固定报告并以 0 退出")
    func reportsPassingWorkspace() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "pass")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 0, "工作区测试失败：\(result.stderr)")
        #expect(result.stderr.isEmpty)
        #expect(
            WorkspaceTestSupport.withoutTiming(result.stdout)
                == """
                测试目标: 工作区 .（2 个测试 target）
                包 alpha / alpha-tests（3 个测试，3 通过）
                包 beta / beta-tests（1 个测试，1 通过）
                结果: 4 通过, 0 失败（用时）

                """)
    }

    @Test("失败断言中止本测试但后续测试继续，退出码为 1")
    func keepsRunningAfterFailure() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.failingWorkspace(tag: "fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 1)
        #expect(result.stderr.isEmpty)
        #expect(
            WorkspaceTestSupport.withoutTiming(result.stdout)
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 gamma / gamma-tests（3 个测试，2 通过）
                 ✗ 乙: 必失
                结果: 2 通过, 1 失败（用时）

                """)
    }

    @Test("筛选只收窄执行面，不改变判定与顺序")
    func filtersWithoutReordering() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "filter")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let narrowed = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter", "减法"], cwd: root)
        #expect(narrowed.status == 0, "筛选运行失败：\(narrowed.stderr)")
        #expect(
            WorkspaceTestSupport.withoutTiming(narrowed.stdout)
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 alpha / alpha-tests（1 个测试，1 通过）
                结果: 1 通过, 0 失败（用时）

                """)

        let missing = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter=不存在"], cwd: root)
        #expect(missing.status == 2)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr.contains("没有测试名匹配筛选条件 '不存在'"), "实际 stderr：\(missing.stderr)")
    }

    @Test("被筛掉的用例不执行，其输出与失败都不得出现")
    func filterSkipsExecution() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.filterWorkspace(tag: "filter-exec")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter", "保留"], cwd: root)
        #expect(result.status == 0, "筛选运行失败：\(result.stderr)")
        #expect(result.stdout.contains("保留-执行"))
        #expect(!result.stdout.contains("排除-执行"))
        #expect(
            WorkspaceTestSupport.withoutTiming(result.stdout)
                == """
                保留-执行
                测试目标: 工作区 .（1 个测试 target）
                包 delta / delta-tests（1 个测试，1 通过）
                结果: 1 通过, 0 失败（用时）

                """)
    }

    @Test("跳过只排除名单内的用例，其余照常执行且顺序不变")
    func skipsNamedTests() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "skip")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--skip", "减法"], cwd: root)
        #expect(result.status == 0, "跳过运行失败：\(result.stderr)")
        #expect(
            WorkspaceTestSupport.withoutTiming(result.stdout)
                == """
                测试目标: 工作区 .（2 个测试 target）
                包 alpha / alpha-tests（2 个测试，2 通过）
                包 beta / beta-tests（1 个测试，1 通过）
                结果: 3 通过, 0 失败（用时）

                """)

        let equalsForm = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--skip=减法"], cwd: root)
        #expect(
            WorkspaceTestSupport.withoutTiming(equalsForm.stdout)
                == WorkspaceTestSupport.withoutTiming(result.stdout),
            "--skip 与 --skip= 应等价")
    }

    @Test("跳过名单零命中按框架错报出，不静默当成跳过")
    func rejectsSkipWithoutMatch() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "skip-miss")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--skip", "不存在"], cwd: root)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(
            result.stderr.contains("没有测试名匹配 --skip '不存在'"),
            "实际 stderr：\(result.stderr)")
    }

    @Test("筛选命中又被跳过排空时不得读成通过")
    func rejectsEmptyAfterSkip() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "skip-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter", "减法", "--skip", "减法"], cwd: root)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(
            result.stderr.contains("筛选与跳过之后没有测试可跑"),
            "实际 stderr：\(result.stderr)")
    }

    @Test("整个 target 被跳过时不出测试，但报告说明原因")
    func marksFullySkippedTarget() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "skip-target")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--skip", "字符串"], cwd: root)
        #expect(result.status == 0, "跳过运行失败：\(result.stderr)")
        #expect(
            WorkspaceTestSupport.withoutTiming(result.stdout)
                == """
                测试目标: 工作区 .（2 个测试 target）
                包 alpha / alpha-tests（3 个测试，3 通过）
                包 beta / beta-tests（0 个测试，--skip 全数排除）
                结果: 3 通过, 0 失败（用时）

                """)
    }

    @Test("声明的测试 target 收集不到 |test 时门禁转红")
    func rejectsDeclaredTargetWithoutTests() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "unregistered")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestFixtures.writePackage(
            root, name: "gamma",
            targets: """
                [[test]]
                name = "gamma-tests"
                entry = "tests"
                """, files: ["tests/helper.pini": "旁路|func() -> ():\n    return\n"])
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/gamma\"]\n")
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("未收集到任何 |test 测试函数"), "实际 stderr：\(result.stderr)")
    }

    @Test("重复运行得到逐字节相同的报告")
    func repeatsDeterministically() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "repeat")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let first = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        let second = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(first.status == 0, "首次运行失败：\(first.stderr)")
        #expect(first.status == second.status)
        #expect(first.stdout == second.stdout)
        #expect(first.stderr == second.stderr)
    }

    @Test("bootstrap 工作区的测试由同一条链执行")
    func runsBootstrapWorkspaceTests() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", "."], cwd: WorkspaceTestSupport.bootstrapRoot)
        #expect(result.status == 0, "工作区测试失败：\(result.stderr)")
        #expect(result.stderr.isEmpty)
        let fixture = PiniTestEnvironment.repositoryRoot
            .appendingPathComponent("Tests/PiniTests/bootstrap-workspace-tests.txt")
        let expected = try String(contentsOf: fixture, encoding: .utf8)
        #expect(WorkspaceTestSupport.withoutTiming(result.stdout) == expected)
    }

    @Test("测试 target 按包依赖拓扑序展开")
    func ordersSuitesByDependency() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "test-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            "[workspace]\nmembers = [\"packages/app\", \"packages/core\"]\n")
        try WorkspaceTestFixtures.writePackage(
            root, name: "app", requires: ["core"],
            targets: """
                [[test]]
                name = "app-tests"
                entry = "tests"
                """, files: ["tests/app_test.pini": "应用|test() -> ():\n    assert(true, \"app\")\n"])
        try WorkspaceTestFixtures.writePackage(
            root, name: "core",
            targets: """
                [[test]]
                name = "core-tests"
                entry = "tests"
                """, files: ["tests/core_test.pini": "核心|test() -> ():\n    assert(true, \"core\")\n"])

        let plan = try #require(try WorkspaceBuilder.plan(rootDirectory: root.path))
        let suites = WorkspaceTestRunner.suites(in: plan)
        #expect(suites.map(\.packageName) == ["core", "app"])
        #expect(suites.map(\.targetName) == ["core-tests", "app-tests"])
    }
}

private enum WorkspaceTestFixtures {

    static func passingWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        // 成员清单逆序写入，执行序仍由计划器的确定性排序决定。
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            "[workspace]\nmembers = [\"packages/beta\", \"packages/alpha\"]\nprofile = \"debug\"\n")
        try writePackage(
            root, name: "alpha",
            targets: """
                [lib]
                name = "alpha"
                entry = "src/api/math.pini"

                [[test]]
                name = "alpha-tests"
                entry = "tests"
                """,
            files: [
                "src/api/math.pini": """
                add|func(a: I32, b: I32,) -> (I32,):
                    return a + b
                """,
                "tests/zeta_test.pini": """
                减法成立|test() -> ():
                    assert(add(a = 3, b = 0 - 1) == 2, "3-1")
                    return
                """,
                "tests/alpha_test.pini": """
                加法成立|test() -> ():
                    assert(add(a = 1, b = 1) == 2, "1+1")
                    return

                负数可用|test() -> ():
                    assert(add(a = 0 - 2, b = 1) == 0 - 1, "负数")
                    return
                """,
            ])
        try writePackage(
            root, name: "beta",
            targets: """
                [[test]]
                name = "beta-tests"
                entry = "tests"
                """,
            files: [
                "tests/string_test.pini": """
                字符串长度|test() -> ():
                    assert(len("abc") == 3, "len")
                    return
                """
            ])
        return root
    }

    static func failingWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/gamma\"]\n")
        try writePackage(
            root, name: "gamma",
            targets: """
                [[test]]
                name = "gamma-tests"
                entry = "tests"
                """,
            files: [
                "tests/run_test.pini": """
                甲|test() -> ():
                    assert(1 == 1, "甲")
                    return

                乙|test() -> ():
                    assert(1 == 2, "必失")
                    return

                丙|test() -> ():
                    assert(2 == 2, "丙")
                    return
                """
            ])
        return root
    }

    static func filterWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/delta\"]\n")
        try writePackage(
            root, name: "delta",
            targets: """
                [[test]]
                name = "delta-tests"
                entry = "tests"
                """,
            files: [
                "tests/filter_test.pini": """
                保留|test() -> ():
                    print("保留-执行")
                    assert(true, "保留")
                    return

                排除|test() -> ():
                    print("排除-执行")
                    assert(true, "排除")
                    return
                """
            ])
        return root
    }

    static func writePackage(
        _ root: URL, name: String, requires: [String] = [], targets: String,
        files: [String: String]
    ) throws {
        let requirements =
            requires.isEmpty
            ? ""
            : "[require]\n" + requires.map { "\($0) = \"*\"" }.joined(separator: "\n") + "\n"
        try WorkspaceTestSupport.write(
            root, "packages/\(name)/pini.toml",
            "[package]\nname = \"\(name)\"\n\(requirements)\(targets)\n")
        for (relative, text) in files {
            try WorkspaceTestSupport.write(root, "packages/\(name)/\(relative)", text)
        }
    }
}
