import XCTest
@testable import PiniCore

final class BlockLabelTests: XCTestCase {
    
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // TR-A4.2: break outer jumps outermost
    /// 意图：验证内层循环中 break outer 直接跳出最外层循环
    /// 推进性测量：跳过 scope outer 内其余语句，最终无输出
    func testBreakOuterJumpsOutermost() throws {
        let source = try loadPiniFixture("testBreakOuterJumpsOutermost", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "")
    }
    
    // TR-A4.3: break inner stays at inner
    /// 意图：验证带标签 break inner 仅跳出内层循环、外层继续执行
    /// 推进性测量：break inner 后执行 print(i)，输出 "1"
    func testBreakInnerStaysInner() throws {
        let source = try loadPiniFixture("testBreakInnerStaysInner", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "1")
    }
    
    // TR-A4 variant: continue with label
    /// 意图：验证 continue outer 跳回外层循环继续迭代
    /// 推进性测量：内层 print 被跳过，外层到 count=3 时 break，输出 "3"
    func testContinueOuter() throws {
        let source = try loadPiniFixture("testContinueOuter", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "3")
    }

    // MARK: - 由 DraftV5AlignmentTests (Task A4) 迁入：带标签 break/continue 的边界行为

    /// 带标签 break 应从内层跳出外层循环（仅打印 j=0,1 后终止）
    /// 意图：验证内层循环中 break outer 直接终止整个双层循环
    /// 推进性测量：仅打印 j=0,1 后循环终止，输出行与 ["0", "1"] 相等
    func testLabeledBreakExitsOuterLoopFromInner() throws {
        let source = try loadPiniFixture("testLabeledBreakExitsOuterLoopFromInner", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["0", "1"], "break outer 应跳出双层循环，只打印 j=0,1 后终止")
    }

    /// break 不存在的标签应导致运行期错误
    /// 意图：验证 break 引用不存在的标签时解释器抛运行期错误
    /// 推进性测量：XCTAssertThrowsError 捕获 interpreter.run 抛出的错误
    func testBreakNonexistentLabelThrows() throws {
        let source = try loadPiniFixture("testBreakNonexistentLabelThrows", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let interpreter = Interpreter()
        XCTAssertThrowsError(try interpreter.run(module: module))
    }

    /// continue 不存在的标签应导致运行期错误
    /// 意图：验证 continue 引用不存在的标签时解释器抛运行期错误
    /// 推进性测量：XCTAssertThrowsError 捕获 interpreter.run 抛出的错误
    func testContinueNonexistentLabelThrows() throws {
        let source = try loadPiniFixture("testContinueNonexistentLabelThrows", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let interpreter = Interpreter()
        XCTAssertThrowsError(try interpreter.run(module: module))
    }

    /// Parser 层 — break/continue 标签正确解析到 AST
    /// 意图：验证解析器把 outer|while 与 break outer 的标签 "outer" 存入 AST（ADR-014：标签落在控制流语句上）
    /// 推进性测量：whileStatement.label 与 breakStatement 的 label 均为 "outer"
    func testParserBreakContinueLabelInAST() throws {
        let source = try loadPiniFixture("testParserBreakContinueLabelInAST", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .funcDecl(let fd) = module.declarations[0],
              let body = fd.body else {
            XCTFail("应为 .funcDecl 且有 body")
            return
        }

        XCTAssertEqual(body.statements.count, 2, "应有 labeled while + return 两条语句")

        guard case .whileStatement(_, let whileBody, _, let label, _) = body.statements[0] else {
            XCTFail("第一条应为带标签的 whileStatement")
            return
        }
        XCTAssertEqual(label, "outer", "while 标签应为 outer")

        XCTAssertEqual(whileBody.statements.count, 1, "while 体应有一条语句")
        guard case .breakStatement(let breakLabel, _) = whileBody.statements[0] else {
            XCTFail("while 体内应为 breakStatement")
            return
        }
        XCTAssertEqual(breakLabel, "outer", "break 标签应为 outer")
    }

    /// Parser 层 — 无标签 break/continue 解析为 nil（向后兼容）
    /// 意图：验证无标签 while 与 break 在 AST 中的 label 均为 nil
    /// 推进性测量：whileStatement.label 与 breakStatement 的 label 断言为 nil
    func testParserUnlabeledBreakContinueNilLabel() throws {
        let source = try loadPiniFixture("testParserUnlabeledBreakContinueNilLabel", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .funcDecl(let fd) = module.declarations[0],
              let body = fd.body else {
            XCTFail("应为 .funcDecl")
            return
        }

        guard case .whileStatement(_, let whileBody, _, let label, _) = body.statements[0] else {
            XCTFail("第一条应为 whileStatement")
            return
        }
        XCTAssertNil(label, "无标签 while 的 label 应为 nil")

        guard case .breakStatement(let breakLabel, _) = whileBody.statements[0] else {
            XCTFail("应为 breakStatement")
            return
        }
        XCTAssertNil(breakLabel, "无标签 break 的 label 应为 nil")
    }
}
