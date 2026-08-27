import XCTest
import PiniCore
import Foundation

/// if/elif/else 同级块匹配契约（草稿 A4，2026-08-23 批次 2）：
/// elif/else 必须与 if 处于同一缩进级别；深级/浅级均须被拦截（不静默错误消费）。
/// 实现上由缩进 token（dedent）机制天然保证——本套件固化该契约，防未来缩进模型回归。
final class IfElifElseLevelTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "if-level.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "if-level.pini")
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

    private func checkModule(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "check.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "check.pini")
        let module = try parser.parseModule()

        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)

        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 同级合法

    /// 意图：if/elif/else 同级链正常解析执行，输出 A/B/C。
    func testSameLevelIfElifElseValid() throws {
        let source = """
        main|func() -> ()
            var x = 2
            if x == 1:
                print("A",)
            elif x == 2:
                print("B",)
            else:
                print("C",)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "B")
    }

    /// 意图：多 elif 链 + else 兜底，同级合法。
    func testLongElifChainValid() throws {
        let source = """
        main|func() -> ()
            var x = 5
            if x == 1:
                print("A",)
            elif x == 2:
                print("B",)
            elif x == 3:
                print("C",)
            elif x == 4:
                print("D",)
            else:
                print("E",)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "E")
    }

    /// 意图：嵌套 if/else 各自同级，内层 else 不被外层消费。
    func testNestedSameLevelIfElseValid() throws {
        let source = """
        main|func() -> ()
            var x = 1
            if x == 1:
                print("外A",)
                if x == 1:
                    print("内A",)
                else:
                    print("内B",)
            else:
                print("外B",)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "外A\n内A")
    }

    /// 意图：单行体 if 后同级 elif 合法。
    func testSingleLineBodyElifValid() throws {
        let source = """
        main|func() -> ()
            var x = 2
            if x == 1: print("A",)
            elif x == 2: print("B",)
            else: print("C",)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "B")
    }

    // MARK: - 跨级拦截

    /// 意图：elif 缩进深于 if（进入 then 块内部）应报解析错误，不得静默并入 then 块。
    func testElifDeeperThanIfRejected() {
        let source = """
        main|func() -> ()
            if true:
                print("A",)
                elif false:
                    print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "elif 深于 if 应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    /// 意图：elif 缩进浅于 if（跨出外层块）应报解析错误，不得挂到更外层上下文。
    func testElifShallowerThanIfRejected() {
        let source = """
        main|func() -> ()
            while true:
                if true:
                    print("A",)
            elif false:
                print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "elif 浅于 if 应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    /// 意图：else 缩进浅于 if 应报解析错误。
    func testElseShallowerThanIfRejected() {
        let source = """
        main|func() -> ()
            if true:
                print("A",)
        else:
            print("B",)
        return
        """
        XCTAssertThrowsError(try checkModule(source), "else 浅于 if 应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    /// 意图：else 缩进深于 if（进入 then 块内部）应报解析错误。
    func testElseDeeperThanIfRejected() {
        let source = """
        main|func() -> ()
            if true:
                print("A",)
                else:
                    print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "else 深于 if 应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    // MARK: - 孤儿 elif/else（无 if 上下文，不匹配其他关键字）

    /// 意图：孤儿 elif（无对应 if）必须报「前无同级 if」专属错误，而非笼统的「无效的表达式」。
    func testOrphanElifRejected() {
        let source = """
        main|func() -> ()
            elif false:
                print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "孤儿 elif 应报错") { error in
            guard case ParserError.invalidStatement(let reason, _) = error else {
                XCTFail("应为 invalidStatement（专属诊断），实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("同级 if"), "诊断应指明 if 同级契约，实际: \(reason)")
        }
    }

    /// 意图：孤儿 else（无对应 if）必须报「前无同级 if」专属错误。
    func testOrphanElseRejected() {
        let source = """
        main|func() -> ()
            else:
                print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "孤儿 else 应报错") { error in
            guard case ParserError.invalidStatement(let reason, _) = error else {
                XCTFail("应为 invalidStatement（专属诊断），实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("同级 if"), "诊断应指明 if 同级契约，实际: \(reason)")
        }
    }

    /// 意图：else 与 while 同级但 while 无 else——else 不得匹配 while（其他关键字），必须报错。
    func testElseDoesNotMatchWhile() {
        let source = """
        main|func() -> ()
            while true:
                print("A",)
            else:
                print("B",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "else 不得匹配 while 应报错") { error in
            guard case ParserError.invalidStatement(let reason, _) = error else {
                XCTFail("应为 invalidStatement（专属诊断），实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("同级 if"), "诊断应指明 if 同级契约，实际: \(reason)")
        }
    }

    /// 意图：else 之后的 elif 不被消费（elif 只能出现在 if/elif 链内），应报错。
    func testElifAfterElseRejected() {
        let source = """
        main|func() -> ()
            var x = 1
            if x == 1:
                print("A",)
            else:
                print("B",)
            elif x == 2:
                print("C",)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "else 后的 elif 应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }
}
