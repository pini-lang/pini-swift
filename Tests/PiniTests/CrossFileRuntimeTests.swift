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

    // MARK: - 枚举 case 的跨文件可见性（H1，2026-08-30）

    /// 意图：枚举声明在 A 文件、使用在 B 文件时，**未限定** case 构造须可用。
    /// 修复前包级符号索引只登记枚举类型名、不登记 case 名，跨文件未限定构造
    /// 报 `undefined function`（外部表现为「枚举 case 是文件作用域」）。
    /// 推进性测量：输出 7（circle 载荷经跨文件 match 解构取出）。
    func testCrossFileUnqualifiedEnumCaseConstruction() throws {
        let out = try runPackage([
            ("shape.pini", "[Shape]\ncircle(r: I32,)\nsquare(s: I32,)\n"),
            ("main.pini", """
area|func(sh: Shape,) -> (I32,)
    match sh:
        case circle(r,):
            return r
        case square(s,):
            return s
    return 0

main|func() -> ()
    print(area(circle(r: 7,)))
    return
"""),
        ])
        XCTAssertTrue(out.contains("7"), "跨文件未限定构造 circle 应可用，实际输出：\(out)")
    }

    /// 意图：**限定** case 构造（形状.圆(...)）跨文件可用——H1 修复不得破坏既有路径。
    /// 推进性测量：输出 1（构造出 1 个 token/元素）。
    func testCrossFileQualifiedEnumCaseConstruction() throws {
        let out = try runPackage([
            ("shape.pini", "[Shape]\ncircle(r: I32,)\n"),
            ("main.pini", """
main|func() -> ()
    var xs = []
    xs = xs.append(Shape.circle(r: 3,))
    print(len(xs))
    return
"""),
        ])
        XCTAssertTrue(out.contains("1"), "跨文件限定构造应可用，实际输出：\(out)")
    }

    /// 意图：同名 case 分属不同枚举（P5-5 HIGH-1 允许共存）时，**未限定**构造
    /// 无期望类型即歧义——ADR-026 D1 静态收敛版要求限定形式（case 由复合类型
    /// 确定，不做运行期猜测；2026-08-30 设计讨论裁决）。
    /// 推进性测量：check 期报错。
    /// 驳回性测量：静默解析到任一父枚举均不合格。
    func testCrossFileAmbiguousCaseRejectsUnqualified() {
        XCTAssertThrowsError(try runPackage([
            ("a.pini", "[Shape]\ndup_case(r: I32,)\n"),
            ("b.pini", "[Other]\ndup_case(x: I32,)\n"),
            ("main.pini", """
main|func() -> ()
    var xs = []
    xs = xs.append(dup_case(r: 1,))
    print(len(xs))
    return
"""),
        ]), "歧义裸名构造应被 check 拒绝并要求限定形式")
    }

    /// 意图：同名 case 分属不同枚举时，**限定**构造仍可用（歧义只影响未限定写法）。
    /// 推进性测量：输出 1。
    func testCrossFileAmbiguousCaseAllowsQualified() throws {
        let out = try runPackage([
            ("a.pini", "[Shape]\ndup_case(r: I32,)\n"),
            ("b.pini", "[Other]\ndup_case(x: I32,)\n"),
            ("main.pini", """
main|func() -> ()
    var xs = []
    xs = xs.append(Other.dup_case(x: 1,))
    print(len(xs))
    return
"""),
        ])
        XCTAssertTrue(out.contains("1"), "同名跨枚举的限定构造应可用，实际输出：\(out)")
    }
}
