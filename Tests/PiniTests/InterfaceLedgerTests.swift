import Foundation
import PiniHost
import Testing

@Suite("工作区接口记录", .serialized)
struct InterfaceLedgerTests {

    @Test("记录渲染后可逐字段读回")
    func roundTripsLedger() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "ledger-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = WorkspaceInterfaceLedger(
            profile: "debug",
            entries: [
                WorkspaceInterfaceEntry(
                    name: "app", path: ".build/debug/packages/app/interface.txt",
                    hash: "aa", source: "ss",
                    deps: [WorkspaceInterfaceDep(name: "base", hash: "bb")]),
                WorkspaceInterfaceEntry(
                    name: "base", path: ".build/debug/packages/base/interface.txt",
                    hash: "bb", source: "tt"),
            ])
        try WorkspaceTestSupport.write(
            root, ".build/debug/interfaces.host.toml", ledger.render())
        let path = WorkspaceInterfaceLedger.path(root: root.path, profile: "debug")
        let read = try #require(WorkspaceInterfaceLedger.read(at: path))
        #expect(read == ledger, "读回与写入不一致：\(read.render())")
        #expect(read.entries.map(\.name) == ["app", "base"])
    }

    @Test("版本不符或缺版本时按无记录处理")
    func rejectsWrongVersion() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "ledger-version")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, ".build/debug/interfaces.host.toml",
            "[interfaces]\nversion = 1\nprofile = \"debug\"\n")
        #expect(
            WorkspaceInterfaceLedger.read(
                at: WorkspaceInterfaceLedger.path(root: root.path, profile: "debug")) == nil)
        try WorkspaceTestSupport.write(
            root, ".build/debug/no-version.toml", "[interfaces]\nprofile = \"debug\"\n")
        #expect(
            WorkspaceInterfaceLedger.read(
                at: root.appendingPathComponent(".build/debug/no-version.toml").path) == nil)
    }

    @Test("行级差异指出首个不同行与增删行数")
    func reportsLineDrift() throws {
        #expect(WorkspaceInterfaceLedger.diffDetail(recorded: "a\nb\n", current: "a\nb\n") == nil)
        #expect(
            WorkspaceInterfaceLedger.diffDetail(recorded: "a\nb\n", current: "b\na\n")
                == "第 1 行不同")
        let added = WorkspaceInterfaceLedger.diffDetail(
            recorded: "a\nb\n", current: "a\nb\nc\n")
        #expect(added == "第 3 行起不同（少 0 行，多 1 行）", "文案不符：\(String(describing: added))")
        let removed = WorkspaceInterfaceLedger.diffDetail(recorded: "a\nb\n", current: "a\n")
        #expect(removed == "第 2 行起不同（少 1 行，多 0 行）", "文案不符：\(String(describing: removed))")
    }

    @Test("宿主构建写记录，检查按记录判漂移")
    func flagsDriftThroughCLI() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "host-ledger")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"app\", \"base\"]\n")
        try WorkspaceTestSupport.writePackage(root, name: "base")
        try WorkspaceTestSupport.writePackage(root, name: "app", require: ["base"])
        try WorkspaceTestSupport.write(
            root, "base/src/api/base.pini",
            """
            公开|func(x: I32,) -> (I32,):
                return x + 1
            """)
        try WorkspaceTestSupport.write(
            root, "app/src/api/app.pini",
            """
            [app|import]
            _base = "../../../base"

            调用|func(x: I32,) -> (I32,):
                return 公开(x = x)
            """)

        let build = try WorkspaceTestSupport.run(cli, ["build", root.path], cwd: root)
        #expect(build.status == 0, "构建失败：\(build.stderr)")
        let ledgerPath = WorkspaceInterfaceLedger.path(root: root.path, profile: "debug")
        let ledger = try #require(WorkspaceInterfaceLedger.read(at: ledgerPath))
        #expect(ledger.entries.map(\.name) == ["app", "base"])
        let appEntry = try #require(ledger.entries.first { $0.name == "app" })
        let baseEntry = try #require(ledger.entries.first { $0.name == "base" })
        #expect(appEntry.deps.map(\.name) == ["base"])
        #expect(appEntry.deps.first?.hash == baseEntry.hash)
        #expect(!appEntry.source.isEmpty, "本包源码摘要为空")
        #expect(!baseEntry.source.isEmpty, "本包源码摘要为空")

        let clean = try WorkspaceTestSupport.run(cli, ["check", root.path], cwd: root)
        #expect(clean.status == 0, "检查失败：\(clean.stderr)")
        #expect(clean.stdout.contains("工作区检查通过（2 个包）"), "读数不符：\(clean.stdout)")

        try WorkspaceTestSupport.write(
            root, "base/src/api/base.pini",
            """
            公开|func(x: I32,) -> (I32,):
                return x + 1

            公开二|func(x: I32,) -> (I32,):
                return x + 2
            """)
        let drifted = try WorkspaceTestSupport.run(cli, ["check", root.path], cwd: root)
        #expect(drifted.status != 0, "公开面变化没有报漂移")
        #expect(drifted.stderr.contains("E3-021"), "诊断不符：\(drifted.stderr)")

        let rebuilt = try WorkspaceTestSupport.run(cli, ["build", root.path], cwd: root)
        #expect(rebuilt.status == 0, "重建失败：\(rebuilt.stderr)")
        let settled = try WorkspaceTestSupport.run(cli, ["check", root.path], cwd: root)
        #expect(settled.status == 0, "回写记录后仍报漂移：\(settled.stderr)")

        try WorkspaceTestSupport.write(
            root, "base/src/_internal/helper.pini",
            """
            辅助|func(x: I32,) -> (I32,):
                return x + 3
            """)
        let internalOnly = try WorkspaceTestSupport.run(cli, ["check", root.path], cwd: root)
        #expect(internalOnly.status == 0, "仅内部改动不该报漂移：\(internalOnly.stderr)")
    }
}
