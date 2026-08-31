import XCTest
@testable import PiniCore

/// G-P10 收口：类型构造实参拒绝 + 调用点标签校验
final class LabelValidationTests: XCTestCase {

    /// 意图：类型构造不接受实参（字段经初始化器/赋值设置）——此前位置实参被静默丢弃
    /// 推进性测量：运行期元数报错
    /// 驳回性测量：静默接受（无错）均不合格
    func testTypeConstructorRejectsArguments() throws {
        let source = try loadPiniFixture("testTypeConstructorRejectsArguments", filePath: #filePath)
        XCTAssertThrowsError(try buildAndRun(source), "类型构造传参应报元数错误")
    }

    /// 意图：带标签实参须命中形参名——此前 check 静默通过、运行期才报
    /// 推进性测量：check 期 E4 报错
    /// 驳回性测量：check 通过均不合格
    func testMismatchedArgLabelFailsCheck() throws {
        let source = try loadPiniFixture("testMismatchedArgLabelFailsCheck", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "lv.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "lv.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        XCTAssertThrowsError(try checker.check(module: module), "标签不匹配应被 check 拒绝")
    }

    /// 意图：匹配的标签仍通过（回归护栏）
    /// 推进性测量：运行输出 3
    /// 驳回性测量：误报均不合格
    func testMatchedLabelStillWorks() throws {
        let source = try loadPiniFixture("testMatchedLabelStillWorks", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("3"), out)
    }

    // MARK: - 助手

    private func buildAndRun(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "lv.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "lv.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        return ""
    }

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "lv.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "lv.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let analyzer = SemanticAnalyzer()
            try analyzer.analyze(module: module)
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
