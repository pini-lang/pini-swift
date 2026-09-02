import XCTest
import PiniCore
import Foundation

/// 批 6 D-4：隐式别名注入（`_别名 = path` = 全导入 + 裸调用；冲突即 E3-013；#1 弱警告）。
/// 用户裁决 2026-09-02：#1 别名不必等于目标名（弱警告）/ #2 注入文件级 / #3 三类冲突全报 /
/// #4 仅 `_` 别名可裸调用或 `_别名.符号` 限定，非 `_` 别名必须限定。
/// 范围注记：端到端（stdout 捕获）用例因 Def-1（见 issue-d4-deferred-defects-2026-09-02）
/// 暂缓——裸调用行为由 CLI 六场景实测覆盖；本文件只保留纯分析器用例。
final class ImportInjectionTests: XCTestCase {

 private var warnings: [SemanticWarning] = []

 /// 夹具：app（import 注入/显式）→ deps/text（导出 hello）；\n 单行书写（H-4 布局）。
 private func makeFixture(mainImport: String, mainBody: String = "    return\n",
 extraMainBody: String = "") throws
 -> (root: String, cleanup: () -> Void) {
 let base = NSTemporaryDirectory() + "pini_d4_\(UUID().uuidString)"
 let fm = FileManager.default
 try fm.createDirectory(atPath: base + "/app/deps/text", withIntermediateDirectories: true)

 let mainSrc = "[main|import]\n" + mainImport + "\nmain|func() -> ():\n" + mainBody + extraMainBody
 try mainSrc.write(toFile: base + "/app/main.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"app\"\n"
 .write(toFile: base + "/app/pini.toml", atomically: true, encoding: .utf8)
 try "[lib|export]\nhello = hello\n\nhello|func() -> (String,):\n    return \"hi\"\n"
 .write(toFile: base + "/app/deps/text/lib.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"texttool\"\nversion = \"1.0\"\n"
 .write(toFile: base + "/app/deps/text/pini.toml", atomically: true, encoding: .utf8)

 return (base + "/app", { try? fm.removeItem(atPath: base) })
 }

 /// 解析 + 语义分析（含警告捕获）。
 private func analyzeFixture(root: String) throws {
 let manifest = try FileLoader.loadManifest(directory: root)
 let pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
 let analyzer = SemanticAnalyzer()
 try analyzer.analyze(package: pkg)
 warnings = analyzer.warnings
 }

 // MARK: #4 通道模型（语义层）

 /// 意图：非 `_` 别名（显式限定通道）裸调用被语义层拒绝（#4 通道不混）。
 func testNonUnderscoreAliasRequiresQualification() throws {
 let (root, cleanup) = try makeFixture(mainImport: "text = \"./deps/text\"",
 mainBody: "    print(hello())\n")
 defer { cleanup() }
 XCTAssertThrowsError(try analyzeFixture(root: root), "非 `_` 别名的裸调用应被语义层拒绝")
 }

 // MARK: #3 三类冲突（E3-013）

 /// 意图：注入符号 vs 本地顶级声明 → E3-013。
 func testInjectionConflictsWithLocalDeclaration() throws {
 let (root, cleanup) = try makeFixture(
 mainImport: "_text = \"./deps/text\"",
 extraMainBody: "\nhello|func() -> (String,):\n    return \"local\"\n")
 defer { cleanup() }
 XCTAssertThrowsError(try analyzeFixture(root: root)) { error in
 guard case SemanticError.injectedSymbolConflict(let sym, _, _) = error else {
 return XCTFail("应为 injectedSymbolConflict，实际：\(error)")
 }
 XCTAssertEqual(sym, "hello")
 }
 }

 /// 意图：注入 vs 注入（两个模块裸导出同名符号）→ E3-013（多项 import 块，批 1 单项限制已解除）。
 func testInjectionConflictsWithInjection() throws {
 let base = NSTemporaryDirectory() + "pini_d4b_\(UUID().uuidString)"
 let fm = FileManager.default
 try fm.createDirectory(atPath: base + "/app/deps/a", withIntermediateDirectories: true)
 try fm.createDirectory(atPath: base + "/app/deps/b", withIntermediateDirectories: true)
 defer { try? fm.removeItem(atPath: base) }

 try "[main|import]\n_a = \"./deps/a\"\n_b = \"./deps/b\"\n\nmain|func() -> ():\n    return\n"
 .write(toFile: base + "/app/main.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"app\"\n"
 .write(toFile: base + "/app/pini.toml", atomically: true, encoding: .utf8)
 let lib = "[lib|export]\nhello = hello\n\nhello|func() -> (String,):\n    return \"hi\"\n"
 try lib.write(toFile: base + "/app/deps/a/lib.pini", atomically: true, encoding: .utf8)
 try lib.write(toFile: base + "/app/deps/b/lib.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"ma\"\n".write(toFile: base + "/app/deps/a/pini.toml", atomically: true, encoding: .utf8)
 try "[package]\nname = \"mb\"\n".write(toFile: base + "/app/deps/b/pini.toml", atomically: true, encoding: .utf8)

 XCTAssertThrowsError(try analyzeFixture(root: base + "/app")) { error in
 guard case SemanticError.injectedSymbolConflict(let sym, let holder, _) = error else {
 return XCTFail("应为 injectedSymbolConflict，实际：\(error)")
 }
 XCTAssertEqual(sym, "hello")
 XCTAssertTrue(holder.contains("_a") && holder.contains("_b"), "错误应点名两个注入方")
 }
 }

 // MARK: #1 弱警告

 /// 意图：`_别名` 与目标模块名不一致 → E7-002 弱警告（不阻断）；一致 → 无该警告。
 func testWeakWarningOnNameMismatch() throws {
 // 目标模块名 texttool ≠ text → 警告
 let (root, cleanup) = try makeFixture(mainImport: "_text = \"./deps/text\"")
 defer { cleanup() }
 try analyzeFixture(root: root)
 XCTAssertTrue(warnings.contains {
 if case .implicitAliasNameMismatch(let a, let t, _) = $0 { return a == "_text" && t == "texttool" }
 return false
 }, "名字不一致应发 E7-002 弱警告")
 XCTAssertEqual(warnings.count, 1)

 // 目标名一致（导入别名 _texttool）→ 无警告
 let (root2, cleanup2) = try makeFixture(mainImport: "_texttool = \"./deps/text\"")
 defer { cleanup2() }
 try analyzeFixture(root: root2)
 XCTAssertFalse(warnings.contains {
 if case .implicitAliasNameMismatch = $0 { return true }
 return false
 }, "名字一致不应发警告")
 }
}
