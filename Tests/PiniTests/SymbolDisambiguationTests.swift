import XCTest
import PiniCore
import Foundation

/// 符号层探针——验证 `<=` 与 `=>` 在引入 B1 语义前，其基础解析/求值行为正确且不互相破坏。
/// #154: `<=` 当前为中缀比较运算符，B1 将叠加前缀 join（<= t），两者须靠位置消歧、互不破坏。
/// #155: `=>` 当前即 async 标记（解析层 isAsync=true），B1 将叠加 `=> T` → `Result<T,Error>` 透明糖，三层一致。
/// 本测试锁定「前置不变量」，B1 落地后这些用例必须仍绿（前缀 `<=` / `=>` 透明糖由 #156/#157 验证）。
final class SymbolDisambiguationTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "sym_test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "sym_test.pini")
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

    private func firstFuncDecl(_ source: String) -> FuncDecl? {
        let lexer = Lexer(source: source, fileName: "sym_test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "sym_test.pini")
        let module = try! parser.parseModule()
        for decl in module.declarations {
            if case .funcDecl(let f) = decl { return f }
        }
        return nil
    }

    // MARK: - #154 `<=` 中缀比较（B1 前缀 join 的前置不变量）

    /// 意图：验证 `<=` 作为中缀比较运算符时 1 <= 2 求值为 true（B1 前缀 join 落地前需锁定的前置不变量）
    func testLessThanOrEqualInfixComparisonTrue() throws {
        let source = """
        main|func() -> ()
            print(1 <= 2)
            return
        """
        XCTAssertEqual(try runProgram(source), "true\n", "<= 应作为中缀比较返回 true")
    }

    /// 意图：验证 `<=` 作为中缀比较运算符时 3 <= 2 求值为 false，输出 "false"
    func testLessThanOrEqualInfixComparisonFalse() throws {
        let source = """
        main|func() -> ()
            print(3 <= 2)
            return
        """
        XCTAssertEqual(try runProgram(source), "false\n", "<= 应作为中缀比较返回 false")
    }

    // MARK: - #155 `=>` 透明性：声明层即 async 标记（B1 透明糖的前置不变量）

    /// 意图：验证 `=>` 在声明层将函数标记为 async：`worker|func() => (I32,)` 解析后 isAsync 为 true
    func testDoubleArrowMarksFuncAsync() {
        let source = """
        worker|func() => (I32,)
            return 1
        main|func() -> ()
            return
        """
        let f = firstFuncDecl(source)
        XCTAssertNotNil(f, "应解析出函数声明")
        XCTAssertTrue(f?.isAsync ?? false, "=> 应标记函数为 async（声明层透明性）")
    }
}
