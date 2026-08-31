import XCTest
import PiniCore
import Foundation

/// #46-E G40（LazyRef，2026-08-24 拍板 D1-D4）：懒加载引用语义测试。
///
/// 覆盖：显式 `LazyRef<T>(闭包)`（D1 显式优先）与推断糖 `LazyRef(闭包)`（D1 语法糖）；
/// `.value` once 求值缓存（D2/D4：首访执行一次、后续返回缓存、多线程仅一次）；
/// 引用语义承载（G42：复制共享同一 box/缓存）。
final class LazyRefTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

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
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 意图：显式 `LazyRef<I32>(闭包)` 构造 + `.value` 访问返回初始化结果（D1 显式优先）。
    func testLazyRefExplicitConstructValue() throws {
        let source = try loadPiniFixture("testLazyRefExplicitConstructValue", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42", "显式构造后 .value 应返回初始化结果")
    }

    /// 意图：`.value` 首访执行初始化闭包一次并缓存（D2）——副作用只打印一次，后续访问返回缓存。
    func testLazyRefValueCachesAfterFirstAccess() throws {
        let source = try loadPiniFixture("testLazyRefValueCachesAfterFirstAccess", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["init", "42", "42", "42"], "初始化闭包只应执行一次（init 恰一次），后续 .value 返回缓存")
    }

    /// 意图：推断糖 `LazyRef(闭包)`（D1 语法糖）与显式构造同语义。
    func testLazyRefInferredSugar() throws {
        let source = try loadPiniFixture("testLazyRefInferredSugar", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "7", "推断糖构造后 .value 应返回初始化结果")
    }

    /// 意图：引用语义承载（G42）——`var b = a` 复制共享同一 box；初始化一次，b.value 与 a.value 一致。
    func testLazyRefAliasSharesCache() throws {
        let source = try loadPiniFixture("testLazyRefAliasSharesCache", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["init", "5", "5"], "复制共享同一 box：初始化一次，a/b 读到同一缓存")
    }

    /// 意图：LazyRef 参数非闭包时报错（类型守卫）。
    func testLazyRefNonFunctionArgFails() throws {
        let source = try loadPiniFixture("testLazyRefNonFunctionArgFails", filePath: #filePath)
        XCTAssertThrowsError(try runProgram(source), "LazyRef 参数非闭包应报错") { error in
            XCTAssertTrue(error is RuntimeError, "应为 RuntimeError")
        }
    }

    // MARK: - Swift 级（box 语义）

    /// 意图：LazyRefBox 引用语义——复制共享同一 box（===）；compute 只执行一次（once）。
    func testLazyRefBoxSharesAndOnce() {
        let fv = FunctionValue(name: "init", params: [], returnTypes: [], body: nil, decl: nil,
                               closure: Environment())
        let box = LazyRefBox(initializer: fv)
        let shared = box
        XCTAssertTrue(box === shared, "复制应共享同一 LazyRefBox（引用语义）")

        var calls = 0
        let v1 = box.value { _ in calls += 1; return .int(42) }
        let v2 = shared.value { _ in calls += 1; return .int(99) }
        guard case .int(let i1) = v1, case .int(let i2) = v2 else {
            return XCTFail("应返回 int 值")
        }
        XCTAssertEqual(i1, 42)
        XCTAssertEqual(i2, 42, "共享 box 已初始化 → 返回缓存而非重新求值")
        XCTAssertEqual(calls, 1, "初始化 compute 只应执行一次（once）")
    }
}
