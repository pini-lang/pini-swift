import XCTest
import PiniCore
import Foundation

/// 数组元素标注 `[T]` 语义检查测试（proposal-array-element-annotation D-β）
/// 设计裁决：标注仅做检查（期望类型下推逐元素校验），ADR-020 签名契约不动
/// （append 返回新数组、内建签名 `[any]` 不特化）；通配 `_`/`Any` 放行；
/// 无标注累积器 `var ys = []` 语义零变更。
final class ArrayElementAnnotationTests: XCTestCase {

    /// 意图：标注位字面量初始化逐元素校验——混型元素静态拒绝
    /// 推进性测量：check 期报 mismatch（expected I32, got String）
    /// 驳回性测量：静默通过（实施前实测 [1, "a"] 可运行）均不合格
    func testArrayLiteralElementTypeChecked() throws {
        let source = try loadPiniFixture("testArrayLiteralElementTypeChecked", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "混型字面量应被标注拒绝")
    }

    /// 意图：同型字面量通过标注检查（零回归守卫）
    /// 推进性测量：构造成功并输出
    /// 驳回性测量：同型被误报均不合格
    func testArrayLiteralElementTypeAccepted() throws {
        let source = try loadPiniFixture("testArrayLiteralElementTypeAccepted", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("3"), out)
    }

    /// 意图：append 实参按接收者声明元素类型检查——类型不符静态拒绝
    /// 推进性测量：check 期报 mismatch
    /// 驳回性测量：append("a") 静默入列均不合格
    func testAppendArgumentElementTypeChecked() throws {
        let source = try loadPiniFixture("testAppendArgumentElementTypeChecked", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "append 类型不符实参应被拒绝")
    }

    /// 意图：append 合规实参通过（ADR-020 契约不变守卫：返回新数组须接收）
    /// 推进性测量：构造成功并输出 [7]
    /// 驳回性测量：合规 append 被误报均不合格
    func testAppendArgumentAccepted() throws {
        let source = try loadPiniFixture("testAppendArgumentAccepted", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("7"), out)
    }

    /// 意图：赋值位字面量右值按声明元素类型逐项校验
    /// 推进性测量：check 期报 mismatch
    /// 驳回性测量：字面量赋值绕过元素检查均不合格
    func testAssignLiteralElementTypeChecked() throws {
        let source = try loadPiniFixture("testAssignLiteralElementTypeChecked", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source), "混型字面量赋值应被拒绝")
    }

    /// 意图：通配元素类型放行（`[Any]` 不拦）+ 无标注累积器语义零变更
    /// （D-β：标注仅做检查；`var ys = []` 契约惯用法保持，回归保护）
    /// 推进性测量：两个累积器混型 append 均通过
    /// 驳回性测量：`[Any]` 被拦 / 无标注累积器被新检查波及均不合格
    func testWildcardAndUnannotatedUnchanged() throws {
        let source = try loadPiniFixture("testWildcardAndUnannotatedUnchanged", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("a"), out)
        XCTAssertTrue(out.contains("b"), out)
    }

    private func runSource(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "arrayannot.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "arrayannot.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error? = nil
        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let e = thrown {
            throw e
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
