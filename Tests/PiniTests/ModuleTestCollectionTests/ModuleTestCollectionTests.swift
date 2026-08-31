import XCTest
import PiniCore
import Foundation

/// G49（issue-tdd-module-blockers-2026-08-28）：模块清单 `[build] exclude` + `pini test [path]`
/// 模块化收集的回归屏障。
///
/// `PiniCLI` 是可执行目标（不可被测试直接 import），故本测试**直接驱动 CLI 所用到的
/// 同一组公共 API**——`FileLoader.locateModuleRoot` / `loadManifest` / `loadDirectory` /
/// `loadFile` + 包级 `Interpreter.runTests(package:fileScope:)`——覆盖：
/// 1. `[build] exclude` 解析与包加载排除（目录前缀匹配，全目标统一生效）；
/// 2. 模块根向上定位（文件 / 目录入口，模块外返回 nil）；
/// 3. 包级测试收集：全量（无参语义）与 `fileScope` 限定（显式路径语义），
///    跨文件符号可见；显式路径加回被排除目录（`loadFile` 补载）由 CLI 侧组装后走同一 API。
final class ModuleTestCollectionTests: XCTestCase {

    /// 建立临时模块夹具：
    /// - pini.toml：`[package] name=smoke` + `[build] exclude=["examples"]`；
    /// - src/lib.pini：`加` 助手函数（跨文件符号）；
    /// - tests/t1.pini：`|test` 调用 `加`（跨文件可见性验证点）；
    /// - examples/garbage.pini：**非法** Pini 文本（exclude 生效性验证点——进包即炸）。
    private func makeFixtureModule() throws -> (root: String, cleanup: () -> Void) {
        let root = NSTemporaryDirectory() + "g49-smoke-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/tests", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/examples", withIntermediateDirectories: true)

        let manifest = try! loadPiniFixture("_manifest", filePath: #filePath)
        let lib = try! loadPiniFixture("_lib", filePath: #filePath)
        let test1 = try! loadPiniFixture("_test1", filePath: #filePath)
        let garbage = "this is not valid pini !!! ==="

        try manifest.write(toFile: root + "/pini.toml", atomically: true, encoding: .utf8)
        try lib.write(toFile: root + "/src/lib.pini", atomically: true, encoding: .utf8)
        try test1.write(toFile: root + "/tests/t1.pini", atomically: true, encoding: .utf8)
        try garbage.write(toFile: root + "/examples/garbage.pini", atomically: true, encoding: .utf8)
        return (root, { try? fm.removeItem(atPath: root) })
    }

    // MARK: - 清单解析与包加载排除

    /// 意图：`[build] exclude` 内联数组被解析进 `ModuleManifest.buildExclude`。
    func testManifestParsesBuildExclude() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        let manifest = try FileLoader.loadManifest(directory: root)
        XCTAssertEqual(manifest?.buildExclude, ["examples"], "[build] exclude 应解析进清单")
    }

    /// 意图：`loadDirectory` 跳过被排除目录（目录前缀匹配）——非法语料不进包，
    /// 包级语义/类型检查因此通过（exclude 全目标统一生效）。
    func testLoadDirectoryExcludesPaths() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        let manifest = try FileLoader.loadManifest(directory: root)
        let pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
        XCTAssertEqual(pkg.fileUnits.count, 2, "exclude 后应只剩 src/lib.pini 与 tests/t1.pini，实际 \(pkg.fileUnits.map(\.fileName))")
        XCTAssertFalse(pkg.fileUnits.contains { $0.fileName.contains("garbage") },
                       "被排除目录下的文件不应进包")

        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(package: pkg), "排除语料后包级语义检查不应报错")
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(package: pkg), "排除语料后包级类型检查不应报错")
    }

    // MARK: - 模块根定位

    /// 意图：自文件 / 子目录向上均定位到模块根；模块外位置返回 nil（独立文件语义）。
    func testLocateModuleRoot() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        XCTAssertEqual(try FileLoader.locateModuleRoot(for: root + "/tests/t1.pini"), root,
                       "自文件入口应定位到模块根")
        XCTAssertEqual(try FileLoader.locateModuleRoot(for: root + "/tests"), root,
                       "自子目录入口应定位到模块根")
        XCTAssertEqual(try FileLoader.locateModuleRoot(for: root), root,
                       "模块根自身应命中自身清单")

        let outside = NSTemporaryDirectory()
        XCTAssertNil(try FileLoader.locateModuleRoot(for: outside + "/definitely-not-a-module.pini"),
                     "模块外位置应返回 nil")
    }

    // MARK: - 包级测试收集

    /// 意图：全量收集（无参语义）——tests/ 下的 `|test` 全部收集，跨文件符号 `加` 可见。
    func testRunTestsPackageFullCollection() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        let manifest = try FileLoader.loadManifest(directory: root)
        let pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
        let interpreter = Interpreter()
        let results = try interpreter.runTests(package: pkg)
        XCTAssertEqual(results.count, 2, "全量收集应命中 tests/t1.pini 的 2 个测试")
        XCTAssertTrue(results.allSatisfy(\.passed),
                      "跨文件调用 加 的测试应全部通过，实际 \(results.map { ($0.name, $0.message) })")
        XCTAssertEqual(results.map(\.name), ["加法正确性", "字符串长度"])
    }

    /// 意图：`fileScope` 限定收集（显式路径语义）——仅命中文件的 `|test` 被执行。
    func testRunTestsPackageFileScope() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        let manifest = try FileLoader.loadManifest(directory: root)
        let pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
        let target = root + "/tests/t1.pini"
        let interpreter = Interpreter()
        let results = try interpreter.runTests(package: pkg, fileScope: { $0 == target })
        XCTAssertEqual(results.count, 2, "显式文件范围应命中该文件的 2 个测试")

        let narrowed = try interpreter.runTests(package: pkg, fileScope: { _ in false })
        XCTAssertTrue(narrowed.isEmpty, "无命中范围应收集为空")
    }

    /// 意图：显式路径加回被排除目录——`loadFile` 补载（CLI 侧组装方式）后，
    /// 同一 `runTests(package:fileScope:)` 通道可执行排除区内测试（跨文件符号仍可见）。
    func testExcludedDirAddBackViaLoadFile() throws {
        let (root, cleanup) = try makeFixtureModule()
        defer { cleanup() }

        let extra = try loadPiniFixture("testExcludedDirAddBackViaLoadFile", filePath: #filePath)
        try extra.write(toFile: root + "/examples/excluded_test.pini",
                        atomically: true, encoding: .utf8)

        let manifest = try FileLoader.loadManifest(directory: root)
        var pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
        let target = root + "/examples/excluded_test.pini"
        // CLI 侧加回方式：路径未进包 → loadFile 补载后拼接
        let added = try FileLoader.loadFile(path: target)
        pkg = Package(name: pkg.name, fileUnits: pkg.fileUnits + added.fileUnits)

        let interpreter = Interpreter()
        let results = try interpreter.runTests(package: pkg, fileScope: { $0 == target })
        XCTAssertEqual(results.count, 1, "加回后应命中排除区内的 1 个测试")
        XCTAssertTrue(results[0].passed, "排除区内测试应可跨文件调用 加，实际 \(results[0].message)")
    }
}
