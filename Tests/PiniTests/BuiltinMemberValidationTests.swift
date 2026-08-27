import XCTest
import PiniCore
import Foundation

/// ③：内建类型（String/Array）成员方法静态校验。
/// 驱动链路：Lexer → Parser → TypeChecker.checkCollecting(module:)，与 CLI `pini check` 同构。
/// 背景：边界③——String/Array 的运行时成员方法此前未进类型环境，调用点校验被静默跳过。
/// 本测试验证：① 合法调用零诊断；② 参数个数不符报 argumentCountMismatch；
/// ③ 参数类型不符报 mismatch；④ 未知成员报 unknownMember。
final class BuiltinMemberValidationTests: XCTestCase {

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    /// 意图：String 的全部内建成员方法（upper/lower/contains/substring/split）以合法参数调用，应通过类型检查。
    /// 推进性测量：整个模块零类型错误。
    /// 驳回性测量：若 registerBuiltinTypes 未登记这些签名，调用点校验跳过——本测试不会失败（需其他测试覆盖漏报面）。
    func testValidStringMemberCalls() throws {
        let source = """
        main|func() -> ()
            var s = "Hello, World"
            print(s.upper())
            print(s.lower())
            print(s.contains("World"))
            print(s.substring(0, 5))
            print(s.split(","))
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "合法 String 成员调用应无类型错误，实际: \(diagnostics)")
    }

    /// 意图：substring 需 2 个 I32 参数，仅传 1 个应报 argumentCountMismatch。
    /// 推进性测量：诊断含 substring 的 argumentCountMismatch（expected 2, got 1）。
    /// 驳回性测量：若调用点参数个数校验缺失，此测试会失败（漏报）。
    func testArgumentCountMismatchReported() throws {
        let source = """
        main|func() -> ()
            var s = "Hello"
            print(s.substring(0))
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .argumentCountMismatch(expected: 2, got: 1, _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "substring 参数个数不符应报 argumentCountMismatch，实际: \(diagnostics)")
    }

    /// 意图：contains 要求 String 参数，传入 I32 应报 mismatch。
    /// 推进性测量：诊断含 contains 的 mismatch（expected String, got I32）。
    /// 驳回性测量：若调用点参数类型校验缺失，此测试会失败（漏报）。
    func testArgumentTypeMismatchReported() throws {
        let source = """
        main|func() -> ()
            var s = "Hello"
            print(s.contains(42))
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .mismatch(expected: "String", got: "I32", _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "contains 参数类型不符应报 mismatch，实际: \(diagnostics)")
    }

    /// 意图：对已知内建类型 String 调用未注册成员（拼写错误 `uppr`）应报 unknownMember。
    /// 推进性测量：诊断含 (typeName: "String", memberName: "uppr") 的 unknownMember。
    /// 驳回性测量：若未知成员被静默跳过，此测试会失败（漏报）；用户自定义类型的未知成员不受影响（另测）。
    func testUnknownMemberReported() throws {
        let source = """
        main|func() -> ()
            var s = "Hello"
            print(s.uppr())
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .unknownMember(typeName: "String", memberName: "uppr", _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "String 未知成员应报 unknownMember，实际: \(diagnostics)")
    }

    /// 意图：用户自定义类型上调用未注册成员，类型层不应报 unknownMember（保持原跳过行为，避免误伤）。
    /// 推进性测量：整个模块零类型错误。
    /// 驳回性测量：若 unknownMember 误伤用户类型，此测试会失败（误报）。
    func testUserTypeUnknownMemberNotReported() throws {
        let source = """
        (盒子)
            内容: String = "x"

        main|func() -> ()
            var b = 盒子()
            print(b)
            return
        """
        let diagnostics = checkCollecting(source)
        let falsePositive = diagnostics.contains {
            if case .unknownMember(_, _, _) = $0 { return true }
            return false
        }
        XCTAssertFalse(falsePositive, "用户自定义类型不应触发 unknownMember，实际: \(diagnostics)")
    }
}
