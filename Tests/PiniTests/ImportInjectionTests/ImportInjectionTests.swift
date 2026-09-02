import XCTest
import PiniCore
import Foundation

/// 批 6 D-4：隐式别名注入（`_别名 = path` = 全导入 + 裸调用；冲突即 E3-013；#1 弱警告）。
/// 用户裁决 2026-09-02：#1 别名不必等于目标名（弱警告）/ #2 注入文件级 / #3 三类冲突全报 /
/// #4 仅 `_` 别名可裸调用或 `_别名.符号` 限定，非 `_` 别名必须限定。
/// Def-1 已消化（2026-09-02）：端到端用例改用**子进程跑 pini CLI**（Def-1 工单指的方向），
/// 不再进程内 dup2——与 XCTest 的输出机制无冲突。
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

 /// Def-1 基建：子进程跑 pini CLI（fixture 落盘后以 CLI 全管线执行——
 /// 与用户真实路径一致，且不触碰进程自身的 stdout）。
 private static func piniBinary() -> String {
 var dir = URL(fileURLWithPath: #filePath)
 for _ in 0..<4 { dir = dir.deletingLastPathComponent() }
 return dir.appendingPathComponent(".build/debug/pini").path
 }

 @discardableResult
 private func runCLI(_ args: [String], cwd: String) throws
 -> (out: String, err: String, code: Int32) {
 let p = Process()
 p.executableURL = URL(fileURLWithPath: Self.piniBinary())
 p.arguments = args
 p.currentDirectoryURL = URL(fileURLWithPath: cwd)
 let out = Pipe(); let err = Pipe()
 p.standardOutput = out; p.standardError = err
 try p.run()
 p.waitUntilExit()
 return (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
 String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
 p.terminationStatus)
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

 // MARK: Def-1 消化后的端到端用例（子进程 CLI）

 /// 意图：注入裸调用 + `_别名.符号` 限定，两形态经真实 CLI 输出。
 func testInjectionEndToEndViaCLI() throws {
 let (root, cleanup) = try makeFixture(mainImport: "_text = \"./deps/text\"",
 mainBody: "    print(hello())\n    print(_text.hello())\n")
 defer { cleanup() }
 let r = try runCLI(["run", root], cwd: NSTemporaryDirectory())
 XCTAssertEqual(r.code, 0)
 XCTAssertEqual(r.out, "hi\nhi\n", "裸调用与限定调用都应输出 hi")
 }

 /// 意图：非 `_` 别名裸调用在语义层拒绝（exit != 0，E3-002）。
 func testNonUnderscoreBareCallRejectedViaCLI() throws {
 let (root, cleanup) = try makeFixture(mainImport: "text = \"./deps/text\"",
 mainBody: "    print(hello())\n")
 defer { cleanup() }
 let r = try runCLI(["run", root], cwd: NSTemporaryDirectory())
 XCTAssertNotEqual(r.code, 0)
 XCTAssertTrue(r.err.contains("E3-002"), "应报语义未定义，实际：\(r.err)")
 }

 /// 意图：E7-002 弱警告走 stderr 且不阻断（exit 0）。
 func testWeakWarningOnStderrViaCLI() throws {
 let (root, cleanup) = try makeFixture(mainImport: "_text = \"./deps/text\"")
 defer { cleanup() }
 let r = try runCLI(["check", root], cwd: NSTemporaryDirectory())
 XCTAssertEqual(r.code, 0, "弱警告不阻断")
 XCTAssertTrue(r.err.contains("E7-002"), "弱警告应上 stderr")
 XCTAssertFalse(r.out.contains("E7-002"), "警告不得污染 stdout")
 }

 /// 意图：F6——argv 透传（单文件 + 模块两种运行形态 + 无参）。
 func testArgvPassthroughViaCLI() throws {
 let base = NSTemporaryDirectory() + "pini_f6_\(UUID().uuidString)"
 try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(atPath: base) }
 // 单文件与模块分目录放（两个 main 同包会触发重声明——Def-3 门禁的正确行为）
 let singleBase = NSTemporaryDirectory() + "pini_f6s_\(UUID().uuidString)"
 try FileManager.default.createDirectory(atPath: singleBase, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(atPath: singleBase) }
 try "main|func() -> ():\n    print(argv())\n    return\n"
 .write(toFile: singleBase + "/s.pini", atomically: true, encoding: .utf8)

 let single = try runCLI(["run", singleBase + "/s.pini", "甲", "乙"], cwd: singleBase)
 XCTAssertEqual(single.out, "[甲, 乙]\n")

 try "[package]\nname = \"m\"\n".write(toFile: base + "/pini.toml", atomically: true, encoding: .utf8)
 try "main|func() -> ():\n    print(argv())\n    return\n"
 .write(toFile: base + "/m.pini", atomically: true, encoding: .utf8)
 let module = try runCLI(["run", base, "X"], cwd: base)
 XCTAssertEqual(module.out, "[X]\n")

 let empty = try runCLI(["run", singleBase + "/s.pini"], cwd: singleBase)
 XCTAssertEqual(empty.out, "[]\n")
 }

 /// 意图：Def-2——被引入模块内部的注入导入可跨模块解析
 ///（uni 内部注入 text 并裸调 greet；app 经 uni.hello() 触发）。
 func testCrossModuleInjectionPropagation() throws {
 let base = NSTemporaryDirectory() + "pini_d4c_\(UUID().uuidString)"
 let fm = FileManager.default
 try fm.createDirectory(atPath: base + "/app/deps/uni", withIntermediateDirectories: true)
 try fm.createDirectory(atPath: base + "/app/deps/text", withIntermediateDirectories: true)
 defer { try? fm.removeItem(atPath: base) }

 try "[main|import]\nuni = \"./deps/uni\"\n\nmain|func() -> ():\n    print(uni.hello())\n    return\n"
 .write(toFile: base + "/app/main.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"app\"\n"
 .write(toFile: base + "/app/pini.toml", atomically: true, encoding: .utf8)
 try "[package]\nname = \"uni\"\nversion = \"1.0\"\n\n[tap]\ndefault = \"file:../text\"\n\n[require]\ntext = \"^1.0\"\n"
 .write(toFile: base + "/app/deps/uni/pini.toml", atomically: true, encoding: .utf8)
 try "[lib|import]\n_text = \"../text\"\n\n[lib|export]\nhello = hello\n\nhello|func() -> (String,):\n    return greet()\n"
 .write(toFile: base + "/app/deps/uni/lib.pini", atomically: true, encoding: .utf8)
 try "[lib|export]\ngreet = greet\n\ngreet|func() -> (String,):\n    return \"来自注入\"\n"
 .write(toFile: base + "/app/deps/text/lib.pini", atomically: true, encoding: .utf8)
 try "[package]\nname = \"texttool\"\n".write(toFile: base + "/app/deps/text/pini.toml", atomically: true, encoding: .utf8)

 let r = try runCLI(["run", base + "/app"], cwd: base)
 XCTAssertEqual(r.out, "来自注入\n", "被引入模块内部的注入裸名应可解析")
 }
}
