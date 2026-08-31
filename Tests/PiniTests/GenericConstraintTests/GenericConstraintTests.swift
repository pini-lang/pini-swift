import XCTest
import PiniCore

/// 泛型约束分隔符（H-2/A9 裁决落地，2026-08-31）：
///   `<T: 约束,>`——`:` 与扩展块特征约束 `((块:特征))` 同形；旧 `|` 分隔废除。
///   注意：约束的语义求解（trait 约束求解）属 G8（未定义），本套件只验证**语法位**。
/// 驱动链路：Lexer → Parser.parseModule（语法层）。
final class GenericConstraintTests: XCTestCase {

    private func parse(_ fixture: String) throws -> Module {
        let source = try loadPiniFixture(fixture, filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 收集模块内全部泛型形参（名字, 约束标注描述）。
    private func collectGenericParams(_ module: Module) -> [(name: String, constraint: String?)] {
        var out: [(String, String?)] = []
        for decl in module.declarations {
            switch decl {
            case .funcDecl(let f):
                for gp in f.genericParams { out.append((gp.name, gp.constraint?.describe())) }
            case .structDecl(let s):
                for gp in s.genericParams { out.append((gp.name, gp.constraint?.describe())) }
            default:
                break
            }
        }
        return out
    }

    /// 意图：泛型函数 `<T: 可比较>` 的 `:` 约束被解析进 GenericParam.constraint。
    func testGenericFuncColonConstraint() throws {
        let module = try parse("testGenericFuncColonConstraint")
        let gps = collectGenericParams(module)
        XCTAssertEqual(gps.count, 1, "应恰有一个泛型形参")
        XCTAssertEqual(gps.first?.name, "T")
        XCTAssertNotNil(gps.first?.constraint, "`:` 约束应被解析为非空 constraint")
        XCTAssertTrue(gps.first?.constraint?.contains("可比较") == true, "约束名应保留，实际: \(gps.first?.constraint ?? "nil")")
    }

    /// 意图：泛型结构体 `(盒<T: 可比较>)` 同样接受 `:` 约束。
    func testGenericStructColonConstraint() throws {
        let module = try parse("testGenericStructColonConstraint")
        let gps = collectGenericParams(module)
        XCTAssertEqual(gps.count, 1)
        XCTAssertEqual(gps.first?.name, "T")
        XCTAssertNotNil(gps.first?.constraint)
    }

    /// 意图：废除的 `|` 分隔 → 解析错误（E2-008 invalidType，附迁移提示）。
    func testOldPipeConstraintRejected() {
        XCTAssertThrowsError(try parse("testOldPipeConstraintRejected")) { error in
            guard case ParserError.invalidType(let reason, _) = error else {
                XCTFail("应为 invalidType，实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("`:`"), "错误消息应提示新分隔符，实际: \(reason)")
        }
    }

    /// 意图：无约束泛型 `<T>` 不受影响（回归 generic.pini / generic-func.pini 形态）。
    func testGenericNoConstraintUnaffected() throws {
        let module = try parse("testGenericNoConstraintUnaffected")
        let gps = collectGenericParams(module)
        XCTAssertEqual(gps.count, 1)
        XCTAssertEqual(gps.first?.name, "T")
        XCTAssertNil(gps.first?.constraint, "无约束泛型的 constraint 应为 nil")
    }
}
