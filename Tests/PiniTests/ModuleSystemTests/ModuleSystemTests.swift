import XCTest
import PiniCore
import Foundation

/// 模块系统批 1（G52 R1/R2/R4 + D-1/D-2 裁决，2026-08-31）：
///   块式 import/export 为唯一顶级形态；块头名 = 当前文件名（解析器校验）；
///   `别名.符号` 限定访问只走跨模块通道（D-2 静态互斥）；public 门槛（D8）；
///   R1 物理边界（pini.toml）与 R2 依赖图禁环。
/// 驱动链路：真实文件系统 demo（demo/app 引入 demo/helper）+ CLI 同构 harness。
final class ModuleSystemTests: XCTestCase {

    private var demoRoot: String {
        ((#filePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("demo")
    }

    /// 与 IOTests 同构的运行 harness：真实解释器 + stdout 捕获。
    private func runFile(_ path: String) throws -> String {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let lexer = Lexer(source: source, fileName: path)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: path)
        let module = try parser.parseModule()

        let outPipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

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
        outPipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 与 CLI `pini check` 单文件同构的语义收集 harness。
    private func checkErrors(_ path: String) -> [SemanticError] {
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let lexer = Lexer(source: source, fileName: path)
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: path)
        let module = try! parser.parseModule()
        let analyzer = SemanticAnalyzer()
        return analyzer.analyzeCollecting(module: module)
    }

    // MARK: - 正向

    /// 意图：跨模块限定调用 `helper.加法(1, 2)` → 3（R4 全导入绑定别名 + public 门槛命中）。
    func testCrossModuleCall() throws {
        let out = try runFile(demoRoot + "/app/main.pini")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "3",
                       "跨模块限定调用应命中被引入模块的 public 函数")
    }

    // MARK: - 三层嵌套（G52 R1 / D-4；工单 DoD-2）

    /// 三层嵌套夹具 `app ⊃ frontend ⊃ syntax`（各层一份 `pini.toml`）。
    private var demo3Root: String {
        ((#filePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("demo3")
    }

    /// 意图：三层嵌套切成 3 个模块，命名空间各自独立。
    ///
    /// 夹具刻意让 `frontend` 与 `syntax` 各自定义**同名** public 符号 `取值`（100 / 10）：
    /// ① 只要任一层被父模块扫入，父包就会出现两个 `取值` ⇒ 重复声明；
    /// ② 只要跨模块裸名串味，结果就不是 110。两条一起把「命名空间独立」钉死。
    func testThreeLevelNestedModulesStaySeparate() throws {
        let app = demo3Root + "/app"
        let fm = FileManager.default
        for p in ["", "/frontend", "/frontend/syntax"] {
            XCTAssertTrue(fm.fileExists(atPath: app + p + "/pini.toml"), "三层各须一份清单，缺：\(p)")
        }

        // D-4 父扫描侧：嵌套模块源码不进父包——三层**逐层**剔除。
        // `syntax/lex/lex.pini` 距其清单两层：回溯必须是递归的，否则会被误扫进 app 包。
        let appPkg = try FileLoader.loadDirectory(path: app,
                                                  manifest: FileLoader.loadManifest(directory: app))
        XCTAssertEqual(appPkg.fileUnits.map { ($0.fileName as NSString).lastPathComponent },
                       ["main.pini"],
                       "app 包只含根级 main.pini；frontend/ 与其下的 syntax/ 都须被剔除")

        let fePkg = try FileLoader.loadDirectory(
            path: app + "/frontend", manifest: FileLoader.loadManifest(directory: app + "/frontend"))
        XCTAssertEqual(fePkg.fileUnits.count, 1, "frontend 包只含 frontend.pini（syntax/ 已剔除）")

        let synPkg = try FileLoader.loadDirectory(
            path: app + "/frontend/syntax",
            manifest: FileLoader.loadManifest(directory: app + "/frontend/syntax"))
        XCTAssertEqual(Set(synPkg.fileUnits.map { ($0.fileName as NSString).lastPathComponent }),
                       ["syntax.pini", "lex.pini"],
                       "syntax 包含 syntax.pini 与深层 lex/lex.pini——lex/ 无清单，不切出新模块")

        // 命名空间独立：frontend 的裸 `取值`(100) + syntax 的 `syntax.取值`(10) = 110。
        let out = try runFile(app + "/main.pini")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "110",
                       "三层各持同名符号 取值 而不相撞：100 + 10")
    }

    // MARK: - D-1 块头校验

    /// 意图：块头名与当前文件名不一致 → E2-005（D-1 自识性标签）。
    func testHeaderMustMatchFileName() {
        let source = "[wrong|import]\nfoo = \"./foo\"\n"
        let lexer = Lexer(source: source, fileName: "right.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "right.pini")
        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidDeclaration(let reason, _) = error else {
                XCTFail("应为 invalidDeclaration，实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("当前文件名"), "应提示当前文件名要求，实际: \(reason)")
        }
    }

    /// 意图：顶级裸 import 语句已移除 → E2-005 迁移提示。
    func testBareImportRemoved() {
        let source = "import foo\n"
        let lexer = Lexer(source: source, fileName: "x.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "x.pini")
        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidDeclaration(let reason, _) = error else {
                XCTFail("应为 invalidDeclaration，实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("块形式"), "应提示块形式迁移，实际: \(reason)")
        }
    }

    // MARK: - D-2 静态互斥

    private func writeTempModule(name: String, source: String) throws -> String {
        let dir = NSTemporaryDirectory() + "/pini_modtest_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "[package]\nname = \"\(name)\"\n".write(toFile: dir + "/pini.toml", atomically: true, encoding: .utf8)
        try source.write(toFile: dir + "/\(name).pini", atomically: true, encoding: .utf8)
        return dir + "/\(name).pini"
    }

    /// 意图：局部变量与 import 别名同名 → E3-004 redeclaredSymbol（D-2 静态互斥）。
    func testAliasNameConflictRejected() throws {
        let helperDir = demoRoot + "/helper"
        let mainDir = NSTemporaryDirectory() + "/pini_modtest_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: mainDir, withIntermediateDirectories: true)
        try "[package]\nname = \"app\"\n".write(toFile: mainDir + "/pini.toml", atomically: true, encoding: .utf8)
        try "[app|import]\nhelper = \"\(helperDir)\"\n\nmain|func() -> ():\n    var helper = 1\n    return\n"
            .write(toFile: mainDir + "/app.pini", atomically: true, encoding: .utf8)
        let errors = checkErrors(mainDir + "/app.pini")
        XCTAssertTrue(errors.contains { error in
            if case SemanticError.redeclaredSymbol(let name, _) = error { return name == "helper" }
            return false
        }, "别名同名局部声明应报 redeclaredSymbol，实际: \(errors)")
    }

    // MARK: - D8 public 门槛

    /// 意图：非 public（`_` 前缀）符号经 `别名.` 访问 → E3-012。
    func testNonPublicAccessDenied() throws {
        let mainDir = demoRoot + "/app"
        let source = try String(contentsOfFile: mainDir + "/main.pini", encoding: .utf8)
            + "\n触碰私有|func() -> ():\n    print(helper._内部校验(1))\n    return\n"
        let lexer = Lexer(source: source, fileName: mainDir + "/main.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: mainDir + "/main.pini")
        let module = try parser.parseModule()
        let errors = SemanticAnalyzer().analyzeCollecting(module: module)
        XCTAssertTrue(errors.contains { error in
            if case SemanticError.crossModuleAccessDenied(let symbol, _) = error {
                return symbol.contains("_内部校验")
            }
            return false
        }, "非 public 符号跨模块访问应报 E3-012，实际: \(errors)")
    }

    // MARK: - R1 物理边界

    /// 意图：被引入目录缺 pini.toml → E3-011。
    func testModuleRootMissingManifest() throws {
        let dir = NSTemporaryDirectory() + "/pini_modtest_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/orphan", withIntermediateDirectories: true)
        try "x|func() -> (I32,):\n    return 1\n".write(toFile: dir + "/orphan/orphan.pini", atomically: true, encoding: .utf8)
        let mainPath = try writeTempModule(name: "main", source: "")
        let mainDir = (mainPath as NSString).deletingLastPathComponent
        let source = "[main|import]\nnm = \"\(dir)/orphan\"\n\nmain|func() -> ():\n    return\n"
        try source.write(toFile: mainPath, atomically: true, encoding: .utf8)
        let errors = checkErrors(mainPath)
        XCTAssertTrue(errors.contains { error in
            if case SemanticError.moduleRootMissing = error { return true }
            return false
        }, "缺清单的模块根应报 E3-011，实际: \(errors)")
        _ = mainDir
    }

    // MARK: - R2 禁环

    /// 意图：A → B → A 依赖环 → E3-010（加载期全图校验）。
    func testDependencyCycleRejected() throws {
        let root = NSTemporaryDirectory() + "/pini_modtest_\(UUID().uuidString)"
        for m in ["ca", "cb"] {
            try FileManager.default.createDirectory(atPath: root + "/\(m)", withIntermediateDirectories: true)
            try "[package]\nname = \"\(m)\"\n".write(toFile: root + "/\(m)/pini.toml", atomically: true, encoding: .utf8)
        }
        try "[ca|import]\ncb = \"../cb\"\n\n入口|func() -> (I32,):\n    return cb.入口()\n"
            .write(toFile: root + "/ca/ca.pini", atomically: true, encoding: .utf8)
        try "[cb|import]\nca = \"../ca\"\n\n入口|func() -> (I32,):\n    return ca.入口()\n"
            .write(toFile: root + "/cb/cb.pini", atomically: true, encoding: .utf8)
        let mainPath = try writeTempModule(name: "main", source: "")
        let source = "[main|import]\nca = \"\(root)/ca\"\n\nmain|func() -> ():\n    return\n"
        try source.write(toFile: mainPath, atomically: true, encoding: .utf8)
        let errors = checkErrors(mainPath)
        XCTAssertTrue(errors.contains { error in
            if case SemanticError.moduleDependencyCycle = error { return true }
            return false
        }, "依赖环应报 E3-010，实际: \(errors)")
        _ = mainPath
    }
}
