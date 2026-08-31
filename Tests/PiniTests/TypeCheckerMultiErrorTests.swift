import XCTest
import PiniCore

/// 收尾：TypeChecker 收集模式——单文件一次性报出多个类型错误
/// （呼应 P2-4.3 解析层 / 语义层多错同报；类型检查层此前仅报第一个）。
/// 驱动链路：Lexer → Parser → TypeChecker.checkCollecting(module:)，与 CLI `pini check` 同构。
final class TypeCheckerMultiErrorTests: XCTestCase {

    private let checker = TypeChecker()

    private func parse(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 解析并以收集模式执行类型检查，返回模块内全部类型错误（不抛出）。
    private func collectErrors(_ source: String) throws -> [TypeError] {
        checker.checkCollecting(module: try parse(source))
    }

    // MARK: - 提取辅助（推进性 / 驳回性测量共用）

    /// mismatch 错误的 (expected, got) 载荷；用具名结构体以满足 Equatable（Swift 元组不遵从 Equatable）。
    private struct MismatchPayload: Equatable {
        let expected: String
        let got: String
    }

    /// 仅保留 mismatch 错误并抽取 (expected, got)，便于精确比对「收集到的错误集合」。
    private func mismatchPayloads(_ errors: [TypeError]) -> [MismatchPayload] {
        errors.compactMap { error in
            if case .mismatch(let expected, let got, _) = error {
                return MismatchPayload(expected: expected, got: got)
            }
            return nil
        }
    }

    /// 抽取 mismatch 错误所在的源码行号，用于验证「跨函数 / 函数体内逐语句」恢复位置。
    private func mismatchLines(_ errors: [TypeError]) -> [Int] {
        errors.compactMap { error in
            if case .mismatch(_, _, let loc) = error { return loc.line }
            return nil
        }
    }

    // MARK: - 跨多个顶级函数：各自非 void 函数裸 return → 多返回类型错误同报

    /// 意图：验证收集模式对「跨多个顶级函数」的返回类型错误能一次性同报（而非遇第一个即退出）。
    func testCollectsMultipleReturnTypeErrorsAcrossFunctions() throws {
        let source = try loadPiniFixture("testCollectsMultipleReturnTypeErrorsAcrossFunctions", filePath: #filePath)
        let errors = try collectErrors(source)

        // 推进性测量：应精确收集到 2 个错误，且均为裸 return 进入 I32 函数的 mismatch(expected: "I32", got: "()")。
        XCTAssertEqual(errors.count, 2, "跨函数应一次性收集 2 个返回类型错误，实际: \(errors)")
        let payloads = mismatchPayloads(errors)
        XCTAssertEqual(payloads, [MismatchPayload(expected: "I32", got: "()"), MismatchPayload(expected: "I32", got: "()")], "错误载荷应为两处裸 return 的 (I32, ())，实际: \(payloads)")

        // 驳回性测量：收集到的错误必须全部为 mismatch——不得混入 argumentCountMismatch 等其它类别；
        // 且两处错误须分处不同函数体（行号不同），证明是「跨函数」收集而非塌缩进单个作用域。
        XCTAssertEqual(payloads.count, errors.count, "不应混入非 mismatch 类别的错误，实际: \(errors)")
        let lines = mismatchLines(errors)
        XCTAssertEqual(Set(lines).count, 2, "两处返回错误应落在不同行（不同函数），实际行号: \(lines)")
        XCTAssertTrue(lines.allSatisfy { $0 >= 2 }, "错误应落在函数体内（行号 ≥ 2），而非声明行，实际: \(lines)")
    }

    // MARK: - 同一函数体内：多个赋值类型不符 → 逐语句恢复并同报

    /// 意图：验证函数体内连续多条类型错误能被逐语句恢复并一次性收集（panic-mode），不中途退出。
    func testCollectsMultipleTypeErrorsWithinSingleFunction() throws {
        let source = try loadPiniFixture("testCollectsMultipleTypeErrorsWithinSingleFunction", filePath: #filePath)
        let errors = try collectErrors(source)

        // 推进性测量：应精确收集到 2 个赋值类型错误，依次为 (I32, String) 与 (I32, F64)。
        XCTAssertEqual(errors.count, 2, "同一函数体内应逐语句收集 2 个类型错误，实际: \(errors)")
        let payloads = mismatchPayloads(errors)
        XCTAssertEqual(payloads, [MismatchPayload(expected: "I32", got: "String"), MismatchPayload(expected: "I32", got: "F64")], "错误载荷应依次为 (I32,String) 与 (I32,F64)，实际: \(payloads)")

        // 驳回性测量：收集到的错误必须全部为 mismatch；且两处错误应落在同一 main 函数体内（行号 > 声明行）。
        XCTAssertEqual(payloads.count, errors.count, "不应混入非 mismatch 类别的错误，实际: \(errors)")
        let lines = mismatchLines(errors)
        XCTAssertTrue(lines.allSatisfy { $0 > 1 }, "错误应落在 main 函数体内（行号 > 1 声明行），实际: \(lines)")
    }

    // MARK: - 多个调用点实参类型不符 → 同报

    /// 意图：验证多个调用点的实参类型错误能被一次性收集（呼应 P2-1.2 调用点类型校验）。
    func testCollectsMultipleCallSiteErrors() throws {
        let source = try loadPiniFixture("testCollectsMultipleCallSiteErrors", filePath: #filePath)
        let errors = try collectErrors(source)

        // 推进性测量：应精确收集到 2 个调用点类型错误，依次为 (I32, String) 与 (I32, F64)。
        XCTAssertEqual(errors.count, 2, "多个调用点错误应一次性收集，实际: \(errors)")
        let payloads = mismatchPayloads(errors)
        XCTAssertEqual(payloads, [MismatchPayload(expected: "I32", got: "String"), MismatchPayload(expected: "I32", got: "F64")], "错误载荷应依次为 (I32,String) 与 (I32,F64)，实际: \(payloads)")

        // 驳回性测量：收集到的错误必须全部为 mismatch；且两处错误须落在不同调用点（行号不同，均 ≥ 4）。
        XCTAssertEqual(payloads.count, errors.count, "不应混入非 mismatch 类别的错误，实际: \(errors)")
        let lines = mismatchLines(errors)
        XCTAssertEqual(Set(lines).count, 2, "两处调用点错误应落在不同行，实际行号: \(lines)")
        XCTAssertTrue(lines.allSatisfy { $0 >= 4 }, "错误应落在 main 函数体内的调用点（行号 ≥ 4），实际: \(lines)")
    }

    // MARK: - 合法源：零类型错误

    /// 意图：验证合法源在收集模式下不产生任何类型错误（无假阳性）。
    func testNoTypeErrorsWhenValid() throws {
        let source = try loadPiniFixture("testNoTypeErrorsWhenValid", filePath: #filePath)
        let errors = try collectErrors(source)

        // 推进性测量：合法源不应有任何类型错误。
        XCTAssertEqual(errors.count, 0, "合法源不应有类型错误，实际: \(errors)")

        // 驳回性测量：错误集合必须为空，确认无 mismatch / argumentCountMismatch 等假阳性。
        XCTAssertTrue(errors.isEmpty, "合法源的错误集合必须为空，确认无假阳性")
    }
}
