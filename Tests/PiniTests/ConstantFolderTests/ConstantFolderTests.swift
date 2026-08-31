import XCTest
import PiniCore
import Foundation

/// 常量折叠 AST pass 结构化测试：直接断言折叠后的 AST 节点，
/// 不依赖解释器执行（最快、最精确的验证）。
final class ConstantFolderTests: XCTestCase {

    private func parse(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "<cf-test>")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "<cf-test>")
        return ConstantFolder.foldConstants(in: parser.parseModuleCollectingErrors().module)
    }

    /// 取首个顶层 varDecl 的 initializer 表达式（兼容 .varDecl 与 .statement 两种包裹）
    private func firstVarInit(_ module: Module) -> PiniCore.Expression? {
        for d in module.declarations {
            switch d {
            case .varDecl(let stmt):
                if case .varDecl(_, _, let init_, _, _) = stmt { return init_ }
            case .statement(let stmt):
                if case .varDecl(_, _, let init_, _, _) = stmt { return init_ }
            default:
                break
            }
        }
        return nil
    }

    /// 取首个函数体内首个 return 的 value 表达式
    private func firstFuncReturn(_ module: Module) -> PiniCore.Expression? {
        for d in module.declarations {
            if case .funcDecl(let f) = d, let body = f.body {
                for s in body.statements {
                    if case .returnStatement(let v, _) = s { return v }
                }
            }
        }
        return nil
    }

    /// 意图：验证整型字面量相加 `1 + 2` 被常量折叠为 integerLiteral(3)。
    func testIntAdditionFolded() throws {
        let m = try parse("let x = 1 + 2\n")
        guard case .integerLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected integerLiteral"); return }
        XCTAssertEqual(v, 3)
    }

    /// 意图：验证字符串常量拼接 `"a" + "b"` 折叠为 stringLiteral("ab")。
    func testStringConcatFolded() throws {
        let m = try parse("let s = \"a\" + \"b\"\n")
        guard case .stringLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected stringLiteral"); return }
        XCTAssertEqual(v, "ab")
    }

    /// 意图：验证嵌套括号表达式 `(3 * 4) + 5` 整体折叠为 integerLiteral(17)。
    func testNestedParenFolded() throws {
        let m = try parse("let y = (3 * 4) + 5\n")
        guard case .integerLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected integerLiteral"); return }
        XCTAssertEqual(v, 17)
    }

    /// 意图：验证除零表达式 `10 / 0` 保持不折叠（避免折叠出非法常量），且 initializer 仍存在。
    func testDivideByZeroNotFolded() throws {
        let init_ = firstVarInit(try parse("let z = 10 / 0\n"))
        if case .integerLiteral(_, _) = init_ { XCTFail("should NOT fold divide-by-zero") }
        XCTAssertNotNil(init_)
    }

    /// 意图：验证含标识符操作数的表达式 `a + 1` 不折叠（其值需运行时确定）。
    func testIdentifierOperandNotFolded() throws {
        let init_ = firstVarInit(try parse("let w = a + 1\n"))
        if case .integerLiteral(_, _) = init_ { XCTFail("should NOT fold with identifier operand") }
    }

    /// 意图：验证 `true && false` 因短路/副作用语义不折叠为 boolLiteral。
    func testLogicalAndNotFolded() throws {
        let init_ = firstVarInit(try parse("let f = true && false\n"))
        if case .boolLiteral(_, _) = init_ { XCTFail("should NOT fold && (short-circuit/side-effect)") }
    }

    /// 意图：验证一元负号作用于整型字面量 `-5` 折叠为 integerLiteral(-5)。
    func testUnaryMinusFolded() throws {
        let m = try parse("let n = -5\n")
        guard case .integerLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected integerLiteral"); return }
        XCTAssertEqual(v, -5)
    }

    /// 意图：验证浮点常量相加 `1.0 + 2.0` 折叠为 floatLiteral(3.0)。
    func testFloatAdditionFolded() throws {
        let m = try parse("let d = 1.0 + 2.0\n")
        guard case .floatLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected floatLiteral"); return }
        XCTAssertEqual(v, 3.0)
    }

    /// 意图：验证整型比较 `3 > 2` 折叠为 boolLiteral(true)。
    func testIntComparisonFolded() throws {
        let m = try parse("let c = 3 > 2\n")
        guard case .boolLiteral(let v, _) = firstVarInit(m) else { XCTFail("expected boolLiteral"); return }
        XCTAssertEqual(v, true)
    }

    /// 意图：验证函数体内 return 表达式参与折叠，`return 2 + 3` 折叠为 integerLiteral(5)。
    func testFuncBodyReturnFolded() throws {
        let m = try parse("g|func() -> (I32,):\n    return 2 + 3\n")
        guard case .integerLiteral(let v, _) = firstFuncReturn(m) else { XCTFail("expected integerLiteral in return"); return }
        XCTAssertEqual(v, 5)
    }

    /// 取首个函数体内 match 的 `case _:` 通配块里首个 varDecl 的 initializer（D3①：通配=case _:）。
    private func firstWildcardVarInit(_ module: Module) -> PiniCore.Expression? {
        for d in module.declarations {
            if case .funcDecl(let f) = d, let body = f.body {
                for s in body.statements {
                    if case .matchStatement(_, let cases, _) = s,
                       let wc = cases.first(where: { if case .wildcard = $0.pattern { true } else { false } }) {
                        for ws in wc.block.statements {
                            if case .varDecl(_, _, let init_, _, _) = ws { return init_ }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// P4（D3①）：`case _:` 通配块的语句应参与常量折叠（与 case 块一致）。
    /// 意图：验证 `case _:` 通配块内 `var x = 1 + 2` 折叠为 integerLiteral(3)，与 case 块行为一致。
    func testWildcardBlockConstantFolded() throws {
        let src = try loadPiniFixture("testWildcardBlockConstantFolded", filePath: #filePath)
        let m = try parse(src)
        guard case .integerLiteral(let v, _) = firstWildcardVarInit(m) else {
            XCTFail("case _: 块内 var x = 1 + 2 应折叠为 integerLiteral(3)")
            return
        }
        XCTAssertEqual(v, 3)
    }
}
