import XCTest
@testable import PiniCore

/// match 穷尽性检查（R1 总是开启，D3①/G28 更新，2026-08-23）的 best-effort 校验测试。
/// validated pass 开关与 default 已移除（R2=删除）：穷尽性检查是 match 内建契约，
/// `case _:` 通配兜底豁免。仅跑 SemanticAnalyzer，不进入 TypeChecker/Interpreter。
final class ValidatedMatchTests: XCTestCase {

    private func analyze(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "validated.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "validated.pini")
        let module = try parser.parseModule()
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
    }

    /// 与已知 case 并存的未知 case 名视为拼写错误。
    /// 意图：match 中与已知 case 并存的未知 case 名（紫）应触发 unknownMatchCase 错误并携带该名字。
    func testUnknownCaseThrows() throws {
        let source = try loadPiniFixture("testUnknownCaseThrows", filePath: #filePath)
        XCTAssertThrowsError(try analyze(source)) { error in
            guard case SemanticError.unknownMatchCase(let name, _) = error else {
                XCTFail("应为 unknownMatchCase，实际 \(error)")
                return
            }
            XCTAssertEqual(name, "紫")
        }
    }

    /// 覆盖全枚举 → 不报错（成功路径）。
    /// 意图：case 覆盖全枚举时应通过校验不报错。
    func testValidExhaustiveNoError() throws {
        let source = try loadPiniFixture("testValidExhaustiveNoError", filePath: #filePath)
        XCTAssertNoThrow(try analyze(source))
    }

    /// 覆盖不全且无 `case _:` 兜底 → nonExhaustiveMatch（R1：总是开启，无需 validated pass 标记）。
    /// 意图：覆盖不全且无兜底时应抛 nonExhaustiveMatch 错误，missing 列表含「蓝」。
    func testNonExhaustiveThrows() throws {
        let source = try loadPiniFixture("testNonExhaustiveThrows", filePath: #filePath)
        XCTAssertThrowsError(try analyze(source)) { error in
            guard case SemanticError.nonExhaustiveMatch(let missing, _) = error else {
                XCTFail("应为 nonExhaustiveMatch，实际 \(error)")
                return
            }
            XCTAssertEqual(missing, ["蓝"])
        }
    }

    /// 覆盖不全但 `case _:` 兜底 → 不报错（R1 豁免；`case _:` 等价旧 default/pass 通配）。
    /// 意图：覆盖不全但有 `case _:` 兜底时应通过校验不报错（成功路径）。
    func testNonExhaustiveWithWildcardNoError() throws {
        let source = try loadPiniFixture("testNonExhaustiveWithWildcardNoError", filePath: #filePath)
        XCTAssertNoThrow(try analyze(source))
    }

    /// R1：lenient 模式概念移除——旧「无通配子块则不校验」行为被取代，缺 case 无兜底一律报错。
    /// 意图：即使没有 pass/validated 标记，覆盖不全也报 nonExhaustiveMatch（穷尽性总是开启）。
    func testLenientModeConceptRemoved() throws {
        let source = try loadPiniFixture("testLenientModeConceptRemoved", filePath: #filePath)
        XCTAssertThrowsError(try analyze(source)) { error in
            guard case SemanticError.nonExhaustiveMatch(let missing, _) = error else {
                XCTFail("应为 nonExhaustiveMatch，实际 \(error)")
                return
            }
            XCTAssertEqual(missing, ["蓝"])
        }
    }

    /// best-effort：全部 case 均无法解析到本模块已知枚举（如未登记枚举）→ 跳过校验，不误报。
    /// 意图：match 目标无法解析到已知枚举时应跳过穷尽性校验不误报（best-effort）。
    func testUnresolvedEnumSkipsValidation() throws {
        let source = try loadPiniFixture("testUnresolvedEnumSkipsValidation", filePath: #filePath)
        XCTAssertNoThrow(try analyze(source))
    }
}
