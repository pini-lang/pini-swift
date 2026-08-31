import XCTest
import PiniCore
import Foundation

/// 用户扩展方法覆盖内建成员方法（H-3，2026-08-31 落地）：
///   内建类型（String/Array）值的成员派发为三级——**用户扩展 > 语言内标准库 > 宿主原生**。
///   用户扩展按名匹配（非按签名），既可覆盖同名内建成员，也可新增内建表没有的方法。
///   IR 后端对内建类型用户扩展维持不支持（既有 Experimental 边界，E6-002，回归锁）。
/// 驱动链路与 CLI `pini run` 同构：stdout 捕获（确定性环境，dup2 接管）。
final class BuiltinOverrideTests: XCTestCase {

    /// 与 IOTests 同构的运行 harness：真实解释器 + stdout 捕获。
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
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

    private func runFixture(_ name: String) throws -> String {
        try runProgram(try loadPiniFixture(name, filePath: #filePath) as String)
    }

    /// 意图：用户 String.contains 扩展覆盖内建成员——返回用户实现结果 false（原为内建 true）。
    func testStringContainsOverride() throws {
        let out = try runFixture("testStringContainsOverride")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "false",
                       "用户扩展应覆盖同名内建成员方法（H-3 用户优先）")
    }

    /// 意图：用户 Array.len 扩展（内建表没有的名字）作为新方法可用。
    func testArrayNewMethodOverride() throws {
        let out = try runFixture("testArrayNewMethodOverride")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "999",
                       "用户扩展可为内建类型新增方法（原被内建表 guard 拒绝）")
    }

    /// 意图：用户新增方法体内调用未覆盖的内建成员（self.upper()）正常派发。
    func testStringNewMethodAddition() throws {
        let out = try runFixture("testStringNewMethodAddition")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ABC!",
                       "用户新增方法应可用，且体内未覆盖成员仍走内建")
    }

    /// 意图：覆盖与非覆盖共存——contains 命中用户实现，upper 仍命中内建。
    func testUnoverriddenStillBuiltin() throws {
        let out = try runFixture("testUnoverriddenStillBuiltin")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "false\nHELLO",
                       "仅同名成员被覆盖，其余成员派发不变")
    }

    /// 意图：R-c 回归锁——与内建成员同名的自由函数按名调用命中用户函数（true），
    /// 无覆盖场景下成员调用命中内建（true），两条通道互不干扰。
    func testFreeFunctionSameNameRegression() throws {
        let out = try runFixture("testFreeFunctionSameNameRegression")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "true\ntrue",
                       "自由函数通道与成员通道互不影响")
    }

    /// 意图：IR 后端对内建类型用户扩展维持不支持（E6-002，既有 Experimental 边界——回归锁）。
    func testIRUnsupportedForBuiltinExtension() throws {
        let source = try loadPiniFixture("testIRUnsupportedForBuiltinExtension", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        XCTAssertThrowsError(try IRGenerator().generate(module: module)) { error in
            guard case IRGenError.unsupportedExpression = error else {
                XCTFail("应为 unsupportedExpression（E6-002），实际: \(error)")
                return
            }
        }
    }
}
