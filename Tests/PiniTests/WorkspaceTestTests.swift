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
            result.stdout
                == """
                测试目标: 工作区 .（2 个测试 target）
                包 alpha / alpha-tests（3 个测试）
                 ✓ 加法成立
                 ✓ 负数可用
                 ✓ 减法成立
                包 beta / beta-tests（1 个测试）
                 ✓ 字符串长度
                结果: 4 通过, 0 失败

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
            result.stdout
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 gamma / gamma-tests（3 个测试）
                 ✓ 甲
                 ✗ 乙: 必失
                 ✓ 丙
                结果: 2 通过, 1 失败

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
            narrowed.stdout
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 alpha / alpha-tests（1 个测试）
                 ✓ 减法成立
                结果: 1 通过, 0 失败

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
            result.stdout
                == """
                保留-执行
                测试目标: 工作区 .（1 个测试 target）
                包 delta / delta-tests（1 个测试）
                 ✓ 保留
                结果: 1 通过, 0 失败

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
        #expect(
            result.stdout
                == """
                测试目标: 工作区 .（4 个测试 target）
                包 package / package-tests（1 个测试）
                 ✓ 工作区标记可识别
                包 support / support-tests（7 个测试）
                 ✓ 字节缓冲按UTF8计数
                 ✓ 切片共享存储
                 ✓ 构建器写UTF8
                 ✓ 源文本行表
                 ✓ 符号表按首次出现驻留
                 ✓ 负宽度归零
                 ✓ 位移使用归一宽度
                包 driver / driver-tests（1 个测试）
                 ✓ 公开调用可用
                包 unicode / unicode-tests（33 个测试）
                 ✓ 骨架折叠形近字母
                 ✓ 骨架跨脚本折叠
                 ✓ 骨架多标量目标
                 ✓ 骨架先分解
                 ✓ 骨架不折叠大小写
                 ✓ 骨架数字零
                 ✓ 骨架未映射保持
                 ✓ 骨架幂等
                 ✓ 骨架非法输入原样
                 ✓ 分解预组合字符
                 ✓ 组合基字与附标
                 ✓ 已组合保持
                 ✓ 组合阻断
                 ✓ 规范重排
                 ✓ 组合排除
                 ✓ 韩文算术
                 ✓ 不做兼容等价
                 ✓ 等价写法归一
                 ✓ 非法输入原样
                 ✓ 宽度与偏移
                 ✓ 拒绝截断
                 ✓ 拒绝游离续字节
                 ✓ 拒绝续字节错位
                 ✓ 拒绝过长编码
                 ✓ 拒绝代理区
                 ✓ 拒绝超出上限
                 ✓ 错误前保留标量
                 ✓ 编码往返
                 ✓ 编码宽度边界
                 ✓ 分类字母数字
                 ✓ 分类空白
                 ✓ 标识符判据
                 ✓ 版本与特殊标量
                结果: 42 通过, 0 失败

                """)
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
                    assert(add(3, 0 - 1) == 2, "3-1")
                    return
                """,
                "tests/alpha_test.pini": """
                加法成立|test() -> ():
                    assert(add(1, 1) == 2, "1+1")
                    return

                负数可用|test() -> ():
                    assert(add(0 - 2, 1) == 0 - 1, "负数")
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
