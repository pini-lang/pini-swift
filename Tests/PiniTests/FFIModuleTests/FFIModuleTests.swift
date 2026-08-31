import XCTest
@testable import PiniCore

/// ffi_module 示例门禁（ADR-015 / ADR-017）：以测试工程师视角端到端门禁
/// `examples/ffi_module/` 这个「配置 + 调用外部接口」的完整模块示例。
///
/// 覆盖：
/// · 目录级多文件模块运行（loadDirectory 经 pini.toml 的 `[ffi]` 配置 → Interpreter.run(package:)），
/// 断言 `pini run examples/ffi_module/` 的 golden 输出逐字节一致；
/// · 语言级 `|test` 块收集执行（runTests，等价于 `pini test examples/ffi_module/cstring.pini`）；
/// · 类型/语义门禁（check 零错误）；
/// · 三类拒绝用例（推进性 + 驳回性测量）：未注册 foreign 符号 E5-017、*object C 兼容性、
/// `&` 非 unsafe 上下文拒绝。
///
/// 全部遵循测试规范的三要素（意图 / 推进性测量 / 驳回性测量）。
final class FFIModuleTests: XCTestCase {

 // MARK: - Helpers

 private func packageRoot() -> String {
 var url = URL(fileURLWithPath: #file)
 while url.path != "/" {
 let pkg = url.appendingPathComponent("Package.swift").path
 if FileManager.default.fileExists(atPath: pkg) {
 return url.path
 }
 url = url.deletingLastPathComponent()
 }
 return url.path
 }

 private var ffiModuleDir: String {
 (packageRoot() as NSString).appendingPathComponent("examples/ffi_module")
 }

 /// 目录级多文件模块运行：loadDirectory（自动解析 pini.toml 的 `[ffi]`）→
 /// Interpreter.run(package:)，stdout 经 outputSink 重定向为字符串。
 /// 复刻 CLI `pini run examples/ffi_module/` 的进程内等价路径。
 /// `[ffi].search_paths` 已由 FileLoader.loadManifest 规一为相对模块目录的绝对路径，
 /// 故此处 Interpreter 传入同一 ffiConfig，使 vendored lib 在任意 cwd 下均可被加载。
 private func runModule(at dir: String) throws -> String {
 let manifest = try FileLoader.loadManifest(directory: dir)
 let pkg = try FileLoader.loadDirectory(path: dir, manifest: manifest)
 let interpreter = Interpreter(ffiConfig: manifest?.ffi ?? .default)
 var segments: [String] = []
 interpreter.outputSink = { segments.append($0 + "\n") }
 try interpreter.run(package: pkg)
 return segments.joined(separator: "")
 }

 /// 单文件解释执行并捕获 stdout（Pipe 重定向，复刻 FFITests.runProgram）。
 private func runProgram(_ source: String) throws -> String {
 let module = try parse(source)
 let pipe = Pipe()
 let originalStdout = dup(STDOUT_FILENO)
 setvbuf(stdout, nil, _IONBF, 0)
 dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
 do {
 let interpreter = Interpreter()
 try interpreter.run(module: module)
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
 return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
 .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
 }

 private func parse(_ source: String) throws -> Module {
 let lexer = Lexer(source: source, fileName: "test.pini")
 let tokens = try lexer.tokenize()
 let parser = Parser(tokens: tokens, fileName: "test.pini")
 return try parser.parseModule()
 }

 /// 语义 + 类型全链路检查；返回首个错误（nil = 通过）。
 private func analyzeErrors(_ source: String) -> Error? {
 do {
 let module = try parse(source)
 try SemanticAnalyzer().analyze(module: module)
 let errors = TypeChecker().checkCollecting(module: module)
 return errors.first
 } catch {
 return error
 }
 }

 private func assertParseError(_ source: String, contains fragment: String,
 file: StaticString = #filePath, line: UInt = #line) {
 do {
 _ = try parse(source)
 XCTFail("应解析失败", file: file, line: line)
 } catch {
 let text = String(describing: error)
 XCTAssertTrue(text.contains(fragment), "报错应含 `\(fragment)`，实际: \(text)", file: file, line: line)
 }
 }

 // MARK: - 推进性测量：golden 运行 + 语言级测试 + 门禁

 /// 意图：整个 ffi_module 目录经 `pini run` 等价路径的执行输出与 golden 串逐字节一致。
 /// 推进性测量：断言输出等于精确 golden（含每行尾换行）。
 /// 驳回性测量：断言输出不等于一个被故意改动的串（防止「永远相等」式假阳性）。
 /// 注：golden 不含 `puts("hello, FFI")` 那一行——`puts` 是 C 库函数，直写**真实 stdout**，
 /// 绕过解释器的 `outputSink` 重定向；故进程内捕获不含此行，但 `pini run` 的终端可见。
 func testModuleGoldenRun() throws {
 let golden = "长度 = 8\natoi = 4096\n填充字节 = 7\n堆字节 = 100\n拷贝字节 = 7\n"
 let got = try runModule(at: ffiModuleDir)
 XCTAssertEqual(got, golden, "ffi_module 运行输出应与 golden 一致（示例语义退化？）\n 期望：\(golden)\n 实际：\(got)")
 XCTAssertNotEqual(got, "长度 = 0\n", "不应等于错误 golden（防假阳性）")
 }

 /// 意图：`examples/ffi_module/cstring.pini` 内的 `|test` 块被收集并全部通过，
 /// 等价于 `pini test examples/ffi_module/cstring.pini`（裸绑定 atoi、strcmp 两个用例）。
 /// 推进性测量：收集数 == 2 且全部 passed。
 /// 驳回性测量：不应存在 failed 用例。
 func testModuleLanguageTestsAllPass() throws {
 let source = try String(contentsOfFile: (ffiModuleDir as NSString).appendingPathComponent("cstring.pini"),
 encoding: .utf8)
 let module = try parse(source)
 // 单文件 |test 收集执行同样需加载所在模块的 `[ffi]` 配置（复刻 `pini test` 的行为），
 // 否则 foreign 块（ffilib）无法经 search_paths 解析到项目内 vendored lib。
 let manifest = try? FileLoader.loadManifest(directory: ffiModuleDir)
 let interpreter = Interpreter(ffiConfig: manifest?.ffi ?? .default)
 let results = try interpreter.runTests(module: module)
 XCTAssertEqual(results.count, 2, "应收集到 2 个 |test 块（裸绑定测试 / 比较测试）")
 let allPassed = results.allSatisfy { $0.passed }
 XCTAssertTrue(allPassed, "全部应通过，实际：\(results.map { ($0.name, $0.message) })")
 let failed = results.filter { !$0.passed }
 XCTAssertTrue(failed.isEmpty, "不应有失败用例，实际：\(failed)")
 }

 /// 意图：ffi_module 目录通过 `pini check`（解析 + 语义 + 类型三阶段零错误）。
 /// 推进性测量：聚合诊断为空。
 func testModuleConformsToCheck() throws {
 let source = try String(contentsOfFile: (ffiModuleDir as NSString).appendingPathComponent("cstring.pini"),
 encoding: .utf8)
 let diags = try collectCheckDiagnostics(source)
 XCTAssertTrue(diags.isEmpty, "ffi_module 应零错误通过 check，实际：\(diags)")
 }

 /// 意图：示例的 FFI 依赖已「项目内 vendoring」（lib/libffilib.{dylib,so} 随仓库提交），
 /// 不依赖宿主机的 libc 隐式解析或硬编码 search_paths——这是示例独立性的硬证据。
 /// 推进性测量：项目内存在该 vendored 库文件。
 /// 驳回性测量：库缺失时应立即失败，提醒「示例不再自包含」。
 func testVendoredLibraryPresent() throws {
 let libDir = (ffiModuleDir as NSString).appendingPathComponent("lib")
 let dylib = (libDir as NSString).appendingPathComponent("libffilib.dylib")
 let so = (libDir as NSString).appendingPathComponent("libffilib.so")
 let exists = FileManager.default.fileExists(atPath: dylib)
 || FileManager.default.fileExists(atPath: so)
 XCTAssertTrue(exists,
 "示例依赖应 vendored 于项目内（lib/libffilib.dylib 或 .so），否则示例失去独立性：\(libDir)")
 }

 private func collectCheckDiagnostics(_ source: String) throws -> [String] {
 let tokens = try Lexer(source: source, fileName: "cstring.pini").tokenize()
 let parser = Parser(tokens: tokens, fileName: "cstring.pini")
 let parseResult = parser.parseModuleCollectingErrors()
 if !parseResult.errors.isEmpty { return parseResult.errors.map { "Parse: \($0)" } }
 let module = parseResult.module
 let semantic = SemanticAnalyzer().analyzeCollecting(module: module)
 if !semantic.isEmpty { return semantic.map { "Semantic: \($0)" } }
 return TypeChecker().checkCollecting(module: module).map { "Type: \($0)" }
 }

 // MARK: - 驳回性测量：拒绝面

 /// 意图：声明于 `[libc|foreign]` 的 C 符号在 libc 中不存在 → 注册期 fail-fast E5-017。
 /// 推进性测量：运行抛错且报错含「未找到符号」/「symbol」。
 /// 驳回性测量：不应静默成功。
 func testUndefinedForeignSymbolRejected() throws {
 let source = try loadPiniFixture("testUndefinedForeignSymbolRejected", filePath: #filePath)
 XCTAssertThrowsError(try runProgram(source)) { error in
 let msg = "\(error)"
 XCTAssertTrue(msg.contains("未找到符号") || msg.contains("symbol") || msg.contains("E5-017"),
 "期望 E5-017 符号未找到，实际：\(msg)")
 }
 }

 /// 意图：`*T` 元素禁 object（ARC 隔离）——`*计数器` 声明被类型检查拒绝。
 /// 推进性测量：analyzeErrors 返回非空且报错含「C 兼容」。
 func testPointerToObjectRejected() throws {
 let source = try loadPiniFixture("testPointerToObjectRejected", filePath: #filePath)
 let err = analyzeErrors(source)
 guard let err else {
 XCTFail("`*object` 应被 C 兼容性校验拒绝"); return
 }
 XCTAssertTrue("\(err)".contains("C 兼容"), "报错应提及 C 兼容性，实际: \(err)")
 }

 /// 意图：`&` 取地址在非 unsafe 上下文（普通函数体）→ 类型检查拒绝。
 /// 推进性测量：analyzeErrors 返回非空且报错含「unsafe」。
 func testAddressOfOutsideUnsafeRejected() throws {
 let source = try loadPiniFixture("testAddressOfOutsideUnsafeRejected", filePath: #filePath)
 let err = analyzeErrors(source)
 guard let err else {
 XCTFail("非 unsafe 上下文取地址应报错"); return
 }
 XCTAssertTrue("\(err)".contains("unsafe"), "报错应提及 unsafe 上下文，实际: \(err)")
 }
}
