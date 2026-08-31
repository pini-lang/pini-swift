import XCTest
import Foundation
@testable import PiniCore

/// 内嵌组合：结构块内嵌父类型简写
///
/// 验证 `(容器) 父类型` 内嵌组合能被正确解析为
/// `composedType = "父类型"` 以及一个同名字段
final class StructTests: XCTestCase {

    // MARK: - Parser Tests

    /// Intent: `(容器) 父类型` 内嵌组合 → composedType + 同名字段
    func testComposedFieldShorthandParser() throws {
        let source = try loadPiniFixture("testComposedFieldShorthandParser", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .structDecl(let sd) = module.declarations.first else {
            XCTFail("Expected structDecl, got \(String(describing: module.declarations.first))")
            return
        }
        XCTAssertEqual(sd.name, "容器")
        XCTAssertEqual(sd.composedType, "元素类型")
        XCTAssertEqual(sd.fields.count, 1)
        XCTAssertEqual(sd.fields[0].name, "元素类型")
        if case .simple(let tn, _) = sd.fields[0].typeAnnotation {
            XCTAssertEqual(tn, "元素类型")
        } else {
            XCTFail("Expected .simple type annotation, got \(sd.fields[0].typeAnnotation)")
        }
    }

    /// Intent: 普通带类型标注和默认值的字段仍然正常解析（与简写不冲突）
    func testNormalStructFieldsStillWork() throws {
        let source = try loadPiniFixture("testNormalStructFieldsStillWork", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .structDecl(let sd) = module.declarations.first else {
            XCTFail("Expected structDecl, got \(String(describing: module.declarations.first))")
            return
        }
        XCTAssertEqual(sd.name, "计数器")
        XCTAssertNil(sd.composedType, "普通字段形式不应产生 composedType")
        XCTAssertEqual(sd.fields.count, 2)
        XCTAssertEqual(sd.fields[0].name, "名称")
        XCTAssertEqual(sd.fields[1].name, "数值")
    }

    /// 意图：管道组合 `(容器|父类型)` 已被移除，解析应抛错
    func testInlinePipeCompositionRemoved() throws {
        let source = try loadPiniFixture("testInlinePipeCompositionRemoved", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        XCTAssertThrowsError(try parser.parseModule(), "行内管道组合应被移除并抛解析错误")
    }

    // MARK: - Runtime Tests（由 DraftV5AlignmentTests Task A3 迁入）

    /// 捕获 stdout 的端到端运行辅助函数
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

    /// Intent: 组合字段运行时可访问 — 父类型字段经组合后可用
    func testComposedFieldRuntimeAccess() throws {
        let source = try loadPiniFixture("testComposedFieldRuntimeAccess", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertTrue(lines.contains("0"), "应能访问父类型字段 x，包含 0；实际: \(lines)")
        XCTAssertTrue(lines.contains("1"), "应能访问自身字段 额外，包含 1；实际: \(lines)")
    }
}
