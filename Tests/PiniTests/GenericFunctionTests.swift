import XCTest
@testable import PiniCore

/// 泛型函数调用点端到端比对（T 占位通配）：实参类型按 T 绑定后做结构等价比对，
/// 不再是「按精确名比较 T」。驱动链路：Lexer → Parser → TypeChecker.check(module:)。
final class GenericFunctionTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    /// 意图：泛型函数 identity<T>(x: T) 在 identity<I32>(x: 5) 调用点，T 绑定 I32 后形参 I32 与实参 I32 结构等价。
    /// 推进性测量：check 不应抛错。
    func testGenericFunctionCallWithMatchingType() {
        let source = """
        identity|func<T>(x: T) -> (T,)
            return x
        main|func() -> ()
            var y = identity<I32>(x: 5)
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "identity<I32>(x: 5) 应通过类型检查（T 绑定 I32）")
    }

    /// 意图：调用点实参类型与特化后形参不符时，必须报 mismatch（T 占位通配后做精确比对）。
    /// 推进性测量：抛出 TypeError.mismatch。
    /// 驳回性测量：T 按精确名比较时（修复前语义）会误判为「通过」，本测试作为回归护栏。
    func testGenericFunctionCallWithMismatchedType() {
        let source = """
        identity|func<T>(x: T) -> (T,)
            return x
        main|func() -> ()
            var y = identity<I32>(x: "a")
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "identity<I32>(x: \"a\") 应报类型不匹配") { error in
            guard case TypeError.mismatch = error else {
                XCTFail("应为 TypeError.mismatch，实际: \(error)")
                return
            }
        }
    }

    /// 意图：泛型函数类型实参个数与声明不符时，报错（genericArgumentCountMismatch）。
    /// 推进性测量：抛出 TypeError.genericArgumentCountMismatch(typeName: "identity", expected: 1, got: 2)。
    func testGenericFunctionTypeArgumentCountMismatch() {
        let source = """
        identity|func<T>(x: T) -> (T,)
            return x
        main|func() -> ()
            var y = identity<I32, I32>(x: 5)
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "泛型函数类型实参个数不符应抛错") { error in
            guard case TypeError.genericArgumentCountMismatch(typeName: "identity", expected: 1, got: 2, _) = error else {
                XCTFail("应为 genericArgumentCountMismatch(typeName: \"identity\", expected: 1, got: 2)，实际: \(error)")
                return
            }
        }
    }
}
