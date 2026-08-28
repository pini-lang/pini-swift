import XCTest
import PiniCore
import Foundation

/// CLI 集成测试。
///
/// `PiniCLI` 是可执行目标（不可被测试直接 import），故本测试**直接驱动 CLI 目录处理所用到的
/// 同一组公共 API**——`FileLoader.loadManifest` / `loadDirectory` + 包级
/// `SemanticAnalyzer.analyze(package:)` / `TypeChecker.check(package:)` / `Interpreter.run(package:)`——
/// 覆盖两种目录语义：
/// 1. 含 `pini.toml` 的目录 = 显式多文件模块（跨文件符号解析 + 运行时链接）；
/// 2. 无 `pini.toml` 的目录 = 一组独立程序（逐文件 check，不合并命名空间）。
/// 这与 `main.swift` 的 `runCheckPath` / `runRunPath` 行为完全一致，可作为 CLI 目录路由的回归屏障。
final class CLIDirectoryTests: XCTestCase {

    private func packageRoot() -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    /// 将 stdout 重定向到 pipe 并捕获 block 内的全部输出（与 IntegrationTests.runProgram 同法）。
    private func captureStdout(_ block: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try block()
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    // MARK: - 模块模式（含 pini.toml）

    /// 验收：examples/multifile 作为多文件模块，check 通过且 run 完成跨文件运行时链接。
    /// 意图：验证 examples/multifile 作为显式多文件模块可加载（manifest 名 demo、聚合 2 个 .pini 单元），模块级 analyze/check 不抛错，run 完成跨文件链接并输出 5/25/0。
    func testMultiFileModuleCheckAndRun() throws {
        let dir = (packageRoot() as NSString).appendingPathComponent("examples/multifile")
        let manifest = try FileLoader.loadManifest(directory: dir)
        XCTAssertNotNil(manifest, "examples/multifile 应含 pini.toml")
        XCTAssertEqual(manifest?.name, "demo")

        let pkg = try FileLoader.loadDirectory(path: dir, manifest: manifest)
        XCTAssertEqual(pkg.fileUnits.count, 2, "应聚合 utils.pini + main.pini 两个单元")

        // 模块级静态检查：跨文件引用对 demo 模块合法，不应抛错。
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(package: pkg),
                         "模块级语义分析不应报错")
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(package: pkg),
                         "模块级类型检查不应报错")

        // 模块级运行：跨文件链接后输出应为 5 / 25 / 0。
        let out = try captureStdout {
            let interpreter = Interpreter()
            try interpreter.run(package: pkg)
        }
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["5", "25", "0"],
                       "跨文件调用 add/square 与 向量 构造的输出应为 5/25/0，实际：\(lines)")
    }

    /// 验收：examples/package-demo 演示 spec 2.5 约定制可见性的全部边缘情况——
    /// 用 `;` 注释（本语言注释符）以「（合法）print」与「（非法）注释」标注；
    /// 非法访问（hard-private 函数/类型、internal 文件符号、跨文件 `_` 字段）仅在源码中以注释演示，
    /// 模块本身可编译运行，作为可见性规则的「活文档」。覆盖：
    /// ① public（公开API）② package（_internals/ 目录）③ package 类型 + 公开字段（{账户}.余额）
    /// ④ public 类型自身方法访问 `_` 字段（{金库}.验证）⑤ hard-private 函数（_私有助手）
    /// ⑥ internal 文件（_私密文件.pini）⑦ hard-private 类型（{_私密仓}，在 secrettypes.pini）
    /// ⑧⑨ 字段级 type-private（P4.5 已 enforce：同文件非方法函数 / 跨文件访问 `_` 字段均被拦截，
    ///       详情见 FieldVisibilityTests）。
    /// 意图：验证 examples/package-demo 作为可见性规则「活文档」可整体编译运行——聚合 5 个单元（含 _internals/helpers 与 _私密文件）后 analyze/check 不抛错，run 输出 107/42/0/1/0/1234 覆盖 public/package/字段级可见性各场景。
    func testPackageDemoConventionVisibility() throws {
        let dir = (packageRoot() as NSString).appendingPathComponent("examples/package-demo")
        let manifest = try FileLoader.loadManifest(directory: dir)
        XCTAssertNotNil(manifest, "examples/package-demo 应含 pini.toml")
        XCTAssertEqual(manifest?.name, "packagedemo")

        let pkg = try FileLoader.loadDirectory(path: dir, manifest: manifest)
        // 递归扫描含 `_` 目录与 `_` 文件：main.pini + api.pini + secrettypes.pini + _internals/helpers.pini + _私密文件.pini = 5 个单元。
        XCTAssertEqual(pkg.fileUnits.count, 5,
                       "应聚合 main/api/secrettypes/_internals/helpers/_私密文件 5 个 .pini，实际：\(pkg.fileUnits.map { $0.fileName })")

        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(package: pkg),
                         "包级语义分析不应报错")
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(package: pkg),
                         "包级类型检查不应报错")

        let out = try captureStdout {
            let interpreter = Interpreter()
            try interpreter.run(package: pkg)
        }
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["107", "42", "0", "1", "0", "1234"],
                       "公开API(7+100)=107、包内辅助=42、账户.余额=0、账户.查主人()=_owner=1、金库.查余额()=0、金库.验证()=_密码=1234，实际：\(lines)")
    }

    /// 回归（P4 复审 HIGH 修复）：模块 run 路径现在执行可见性 enforce——
    /// 跨文件调用 hard-private（`_` 符号）函数会在 analyze/check 阶段被拒，
    /// run 不再静默执行。复刻修复后的 runRunPath 模块分支（analyze → check → run）。
    /// 意图：回归 P4 复审 HIGH 修复——模块 run 路径必须 enforce 可见性：跨文件调用 hard-private `_secret` 时 analyze/check 阶段抛 inaccessibleSymbol，run 不再静默执行。
    func testModuleRunEnforcesVisibility() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_runvis_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // pini.toml 标记本目录为显式多文件模块。
        try "[package]\nname = \"demo\"\n".write(
            toFile: (tmp as NSString).appendingPathComponent("pini.toml"),
            atomically: true, encoding: .utf8)
        // lib.pini 声明 hard-private 函数；main.pini 跨文件调用它。
        try "_secret() -> ()\n    return\n".write(
            toFile: (tmp as NSString).appendingPathComponent("lib.pini"),
            atomically: true, encoding: .utf8)
        try "main() -> ()\n    _secret()\n    return\n".write(
            toFile: (tmp as NSString).appendingPathComponent("main.pini"),
            atomically: true, encoding: .utf8)

        let manifest = try FileLoader.loadManifest(directory: tmp)
        let pkg = try FileLoader.loadDirectory(path: tmp, manifest: manifest)

        // 复刻修复后的 runRunPath 模块分支：analyze → check → run。
        // 跨文件调用 hard-private 应在 analyze/check 阶段抛 inaccessibleSymbol，
        // 故整体流程必须抛错（run 不会执行到）。
        var thrown: Error?
        do {
            let analyzer = SemanticAnalyzer()
            try analyzer.analyze(package: pkg)
            let checker = TypeChecker()
            try checker.check(package: pkg)
            let interpreter = Interpreter()
            try interpreter.run(package: pkg)
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "模块 run 路径必须 enforce 可见性，跨文件调 hard-private 应被拒")
        let isVisibilityError: Bool
        if let e = thrown as? SemanticError {
            if case .inaccessibleSymbol = e { isVisibilityError = true } else { isVisibilityError = false }
        } else if let e = thrown as? TypeError {
            if case .inaccessibleSymbol = e { isVisibilityError = true } else { isVisibilityError = false }
        } else {
            isVisibilityError = false
        }
        XCTAssertTrue(isVisibilityError, "应报 inaccessibleSymbol，实际：\(String(describing: thrown))")
    }

    // MARK: - 独立程序模式（无 pini.toml）

    /// 验收：无 pini.toml 的目录在 CLI 层被当作独立程序逐文件 check（不合并命名空间）。
    /// 用临时目录放两个互不依赖的单文件程序验证该分支不被误合并。
    /// 意图：验证无 pini.toml 的目录在 CLI 层按独立程序逐文件 check（不合并命名空间）——临时目录两个互不依赖的单文件程序各自语义/类型检查均无错误。
    func testDirectoryWithoutManifestChecksEachFileIndependently() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_cli_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try "main|func() -> ()\n    print(1)\n    return\n".write(
            toFile: (tmp as NSString).appendingPathComponent("a.pini"),
            atomically: true, encoding: .utf8)
        try "main|func() -> ()\n    print(2)\n    return\n".write(
            toFile: (tmp as NSString).appendingPathComponent("b.pini"),
            atomically: true, encoding: .utf8)

        // 无 manifest → loadDirectory 回退目录名；逐文件独立 check（与 CLI 无清单分支一致）。
        let pkg = try FileLoader.loadDirectory(path: tmp)
        XCTAssertEqual(pkg.fileUnits.count, 2)
        for unit in pkg.fileUnits {
            let sem = SemanticAnalyzer().analyzeCollecting(module: unit.module)
            XCTAssertTrue(sem.isEmpty, "独立文件不应有语义错误：\(sem)")
            let type = TypeChecker().checkCollecting(module: unit.module)
            XCTAssertTrue(type.isEmpty, "独立文件不应有类型错误：\(type)")
        }
    }

    /// 驳回性测量（护栏非形同虚设）：若将「本应作为模块」的 main.pini 当作独立文件 check，
    /// 其跨文件引用（add/square/向量）必暴露为未定义——证明模块模式确有跨文件解析价值，
    /// 且独立模式不会误合并相邻文件的符号。
    /// 意图：驳回性护栏——把本应作为模块的 examples/multifile 的 main.pini 独立 check 时，跨文件引用（add/square/向量）必报未定义符号，证明模块模式确有跨文件解析价值且独立模式不误合并符号。
    func testMultiFileModuleFilesFailWhenCheckedIndependently() throws {
        let dir = (packageRoot() as NSString).appendingPathComponent("examples/multifile")
        let pkg = try FileLoader.loadDirectory(path: dir)
        let mainUnit = pkg.fileUnits.first {
            ($0.fileName as NSString).lastPathComponent == "main.pini"
        }
        XCTAssertNotNil(mainUnit, "应含 main.pini")

        let diags = SemanticAnalyzer().analyzeCollecting(
            module: mainUnit!.module)
        XCTAssertFalse(diags.isEmpty,
                       "main.pini 独立 check 应报跨文件未定义符号（add/square/向量）")
    }

    // MARK: - R8 清单改名护栏（module.toml → pini.toml）

    /// 旧名 `module.toml` 必须抛错，**不得**静默当作「无清单」。
    /// 意图：R8（issue-pini-dir-namespace-2026-08-29）护栏——清单文件名是 R1 判定模块边界的哨兵；
    /// 硬切后若旧名被静默忽略，该目录会从「模块边界」退化为「普通文件」，其下源码被父模块扫入
    /// 且全程不报错（症状离原因很远）。故命中旧名必须抛 `legacyManifestName`。
    func testLegacyManifestNameThrowsInsteadOfDegradingSilently() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_legacy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // 仅放旧名清单，不放 pini.toml。
        try "[package]\nname = \"legacy\"\n".write(
            toFile: (tmp as NSString).appendingPathComponent("module.toml"),
            atomically: true, encoding: .utf8)

        var thrown: Error?
        do { _ = try FileLoader.loadManifest(directory: tmp) } catch { thrown = error }
        guard let err = thrown else {
            return XCTFail("命中旧名 module.toml 应抛错，不得静默返回 nil")
        }
        guard case LoaderError.legacyManifestName = err else {
            return XCTFail("应抛 legacyManifestName，实际：\(err)")
        }
    }

    /// 对照：新名 `pini.toml` 存在时正常加载。
    /// 意图：R8 正向护栏——新名清单应被正常识别为模块（防止上一测试的「必抛错」分支被写成恒真）。
    func testNewManifestNameLoadsNormally() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pini_newname_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try "[package]\nname = \"renamed\"\n".write(
            toFile: (tmp as NSString).appendingPathComponent("pini.toml"),
            atomically: true, encoding: .utf8)

        let manifest = try FileLoader.loadManifest(directory: tmp)
        XCTAssertEqual(manifest?.name, "renamed")
    }
}
