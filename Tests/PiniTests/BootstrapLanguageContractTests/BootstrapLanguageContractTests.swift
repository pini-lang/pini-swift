import XCTest
import PiniCore
import Foundation

/// 自举编译器前置的语言能力契约测试（依据 ADR-018）。
/// 覆盖自举 AST 数据模型（AST 节点用递归枚举承载、字段用命名元组可读访问）
/// 所依赖的语言能力：递归枚举 + 命名元组关联值的构造、绑定与字段访问。
/// 该能力若在语言演进中被破坏，自举编译器（用 Pini 写的 Pini 编译器）将无声崩塌。
final class BootstrapLanguageContractTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "bootstrap-contract.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "bootstrap-contract.pini")
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

    /// 意图：递归枚举（`binary(Expr, ...)` 自引用）+ 命名元组关联值的
    /// 构造、嵌套 match 绑定、字段访问（`.value`/`.left`/`.right`）全链路可用。
    /// 推进性测量：输出 "1\n2\n"——依次命中 left/right 两棵子树的字面量值。
    /// 驳回性测量：输出缺失任一子树的 `.value` 即失败。
    func testRecursiveEnumWithNamedTupleAssociatedValues() throws {
        let source = try loadPiniFixture("testRecursiveEnumWithNamedTupleAssociatedValues", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "1\n2\n", "递归枚举 + 命名元组字段访问应依次输出 1、2")
    }
}
