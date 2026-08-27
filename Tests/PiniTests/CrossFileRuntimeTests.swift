import XCTest
import PiniCore
import Foundation

/// 解释器跨文件运行时链接（同模块多文件包）。
///
/// 设计锚点：
/// - 单文件包委托旧 `run(module:)`，零回归。
/// - 多文件包：所有文件的声明（类型 + 函数）注册进同一全局环境，跨文件调用在运行时可解析；
///   可见性 enforce 已在 Phase 3 静态期完成，运行时同模块共享命名空间；`main` 恒全局可见。
final class CrossFileRuntimeTests: XCTestCase {

    private func buildPackage(_ units: [(fileName: String, source: String)]) throws -> Package {
        let fileUnits = try units.map { (fn, src) -> FileUnit in
            let lexer = Lexer(source: src, fileName: fn)
            let tokens = try lexer.tokenize()
            let parser = Parser(tokens: tokens, fileName: fn)
            let module = try parser.parseModule()
            return FileUnit(fileName: fn, module: module)
        }
        return Package(name: "testpkg", fileUnits: fileUnits)
    }

    /// 运行包并捕获 stdout（复用 IntegrationTests 的 pipe 重定向模式）。
    private func runPackage(_ units: [(fileName: String, source: String)]) throws -> String {
        let package = try buildPackage(units)
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            let interpreter = Interpreter()
            try interpreter.run(package: package)
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
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// A 定义函数，B 的 main 跨文件调用 → 两端输出都应出现（验证运行时链接）。
    /// 意图：验证跨文件函数调用在运行时链接成功，lib.pini 的 helper 与 app.pini 的 main 输出均出现。
    func testCrossFileCallRuns() throws {
        let out = try runPackage([
            ("lib.pini", "helper() -> ()\n    print(\"from-helper\")\n    return\n"),
            ("app.pini", "main() -> ()\n    helper()\n    print(\"from-main\")\n    return\n"),
        ])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.contains("from-helper"), "跨文件 helper 应在运行时被执行：\(trimmed)")
        XCTAssertTrue(trimmed.contains("from-main"), "main 应在运行时被执行：\(trimmed)")
    }

    /// 跨文件调用携带实参（验证参数跨文件传递）。
    /// 意图：验证跨文件调用可携带实参，`greet("hi")` 参数跨文件传递后输出恰为 "hi"。
    func testCrossFileCallWithArgument() throws {
        let out = try runPackage([
            ("lib.pini", "greet(name,) -> ()\n    print(name)\n    return\n"),
            ("app.pini", "main() -> ()\n    greet(\"hi\")\n    return\n"),
        ])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    /// package 级符号（`_` 目录）跨文件调用 → 运行时同样链接成功。
    /// 意图：验证 `_` 目录下 package 级函数跨文件调用在运行时同样链接成功，输出含 "pkg-helper"。
    func testPackageLevelSymbolVisibleAtRuntime() throws {
        let out = try runPackage([
            ("_pkg/lib.pini", "helper() -> ()\n    print(\"pkg-helper\")\n    return\n"),
            ("app.pini", "main() -> ()\n    helper()\n    return\n"),
        ])
        XCTAssertTrue(out.contains("pkg-helper"), "package 级跨文件函数应在运行时链接：\(out)")
    }

    /// 单文件包委托旧 run(module:)，零回归。
    /// 意图：验证单文件包委托旧 run(module:) 路径零回归，main 正常执行输出 "ok"。
    func testSingleFilePackageDelegates() throws {
        let out = try runPackage([
            ("app.pini", "main() -> ()\n    print(\"ok\")\n    return\n"),
        ])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    /// 包内无 main → 运行时报 mainNotFound。
    /// 意图：验证无 main 的包运行时抛 RuntimeError（mainNotFound 错误路径）。
    func testMainNotFoundThrows() throws {
        let package = try buildPackage([
            ("lib.pini", "helper() -> ()\n    return\n"),
        ])
        XCTAssertThrowsError(try Interpreter().run(package: package)) { error in
            XCTAssertTrue(error is RuntimeError, "无 main 应抛 RuntimeError（mainNotFound），实际 \(error)")
        }
    }
}
