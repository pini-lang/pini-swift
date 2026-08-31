import XCTest
@testable import PiniCore

/// P5-5 HIGH-1 + MED-2：枚举 case 命名空间化。
///
/// 核心语义（评审 4 路线 5）：
/// - 跨枚举同名 case（形状.圆 与 几何.圆）允许共存，case 名按枚举隔离；
/// - 构造按「枚举限定名」寻址：唯一名时未限定 `圆(5.0)` 仍可用，歧义时强制 `形状.圆(5.0)`；
/// - match 模式按被匹配值自带的 parentEnum 解析（运行期天然正确，跨枚举同名不串味）。
///
/// 本文件覆盖解释器运行期行为（构造解析 + 限定构造）；类型检查 / IR 路径分别在 B3 / B4 补充。
final class EnumNamespaceTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "enumns.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "enumns.pini")
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

    // MARK: - P5-5 B2 解释器：限定构造解析父枚举

    /// 两个枚举共享 case 名 圆；限定构造 `形状.圆(2.0)` 与 `几何.圆(0.0, 3.0)` 须各自解析到正确父枚举。
    /// 意图：验证两个共享 case 名「圆」的枚举经限定构造 `形状.圆(2.0)` / `几何.圆(0.0, 3.0)` 运行时各自解析到正确父枚举并输出各自关联值。
    func testQualifiedConstructionResolvesParentEnum() throws {
        let source = try loadPiniFixture("testQualifiedConstructionResolvesParentEnum", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("圆(2.0)"), "形状.圆 应解析到 形状 父枚举，实际输出: \(out)")
        XCTAssertTrue(out.contains("圆(0.0, 3.0)"), "几何.圆 应解析到 几何 父枚举，实际输出: \(out)")
    }

    /// 反向（零回归）：case 名全局唯一时，未限定构造 `圆(5.0)` 仍可直接使用。
    /// 意图：零回归——case 名全局唯一时未限定构造 `圆(5.0)` 仍可直接使用并正确输出 `圆(5.0)`。
    func testUniqueUnqualifiedConstructionStillWorks() throws {
        let source = try loadPiniFixture("testUniqueUnqualifiedConstructionStillWorks", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("圆(5.0)"), "唯一名未限定构造应可用，实际输出: \(out)")
    }

    /// 歧义（两个枚举共享 圆）：无期望类型 → check 期拒绝并要求限定形式
    /// （ADR-026 D1 静态收敛版：运行期动态消歧已移除，2026-08-30 裁决）
    /// 意图：歧义路径——两个枚举共享 case 名「圆」时，未限定构造 `圆(2.0)` 必须被
    /// check 拒绝，迫使改用限定写法 `形状.圆 / 几何.圆`（case 由复合类型确定）。
    func testAmbiguousUnqualifiedConstructionRequiresQualification() throws {
        let source = try loadPiniFixture("testAmbiguousUnqualifiedConstructionRequiresQualification", filePath: #filePath)
        XCTAssertThrowsError(try runProgram(source), "歧义裸名构造应被 check 拒绝，迫使改用 形状.圆 / 几何.圆")
    }

    /// 限定构造出的跨枚举同名值，match 时按值自带 parentEnum 正确匹配（不串味）：
    /// 形状.圆 匹配 `case 圆(r)` 取到半径 2.0，证明构造未串到几何.圆。
    /// 意图：验证限定构造出的值 match 时按自带 parentEnum 解析——`形状.圆(2.0)` 匹配 `case 圆(r)` 取到半径 2.0，不串到 几何.圆。
    func testCrossEnumSameCaseMatchByValueParent() throws {
        let source = try loadPiniFixture("testCrossEnumSameCaseMatchByValueParent", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("2.0"), "match 应按值 parentEnum 解析 形状.圆 取到半径 2.0，实际: \(out)")
    }

    // MARK: - P5-5 B3 类型检查 / 语义：限定构造 arity + MED-2 严谨穷尽性

    private func collectTypeErrors(_ source: String) throws -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "b3tc.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "b3tc.pini")
        let module = try parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    private func analyzeProgram(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "b3sa.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "b3sa.pini")
        let module = try parser.parseModule()
        try SemanticAnalyzer().analyze(module: module)
    }

    /// B3：限定构造 `形状.圆(2.0, 3.0)` 多传参 → 类型检查报 `argumentCountMismatch`
    /// （按 (父, case) 校验，不受跨枚举同名 case 干扰）。
    /// 意图：限定构造 `形状.圆(2.0, 3.0)` 多传参时类型检查须报 argumentCountMismatch（按 (父, case) 校验，不受跨枚举同名干扰）。
    func testQualifiedConstructionArityViolationReported() throws {
        let source = try loadPiniFixture("testQualifiedConstructionArityViolationReported", filePath: #filePath)
        let errors = try collectTypeErrors(source)
        XCTAssertTrue(
            errors.contains { if case .argumentCountMismatch = $0 { return true } else { return false } },
            "限定构造多传参应报 argumentCountMismatch，实际: \(errors)"
        )
    }

    /// B3（零回归）：限定构造 `形状.圆(2.0)` arity 正确 → 无类型错误。
    /// 意图：零回归——限定构造 `形状.圆(2.0)` arity 正确时类型检查不应产生任何错误。
    func testQualifiedConstructionCorrectArityNoError() throws {
        let source = try loadPiniFixture("testQualifiedConstructionCorrectArityNoError", filePath: #filePath)
        let errors = try collectTypeErrors(source)
        XCTAssertTrue(errors.isEmpty, "限定构造 arity 正确应无类型错误，实际: \(errors)")
    }

    /// B3 MED-2：两枚举共享 case 圆 时，限定值 `形状.圆(1.0)` 锁定父枚举 → 仅覆盖 圆 缺 矩形
    /// 须抛 `nonExhaustiveMatch`（无锁定时 parentUnion 跨两父退化、不会报，故此测试隔离 MED-2 行为）。
    /// 意图：MED-2——限定值 `形状.圆(1.0)` 锁定父枚举后，match 缺 `矩形` case 须抛 nonExhaustiveMatch。
    func testMED2PinnedExhaustivenessThrowsOnMissingCase() throws {
        let source = try loadPiniFixture("testMED2PinnedExhaustivenessThrowsOnMissingCase", filePath: #filePath)
        XCTAssertThrowsError(try analyzeProgram(source), "限定值锁定穷尽性后缺 case 应抛 nonExhaustiveMatch") { error in
            guard case SemanticError.nonExhaustiveMatch(_, _) = error else {
                XCTFail("应为 nonExhaustiveMatch，实际: \(error)")
                return
            }
        }
    }

    /// B3 MED-2（零回归）：两枚举共享 case 圆 时，限定值 `形状.圆(1.0)` 且覆盖 形状 全部 case → 通过。
    /// 意图：MED-2 零回归——限定值 `形状.圆(1.0)` 且覆盖 形状 全部 case（圆/矩形）时穷尽性校验应通过。
    func testMED2PinnedExhaustivenessPassesOnFullCoverage() throws {
        let source = try loadPiniFixture("testMED2PinnedExhaustivenessPassesOnFullCoverage", filePath: #filePath)
        XCTAssertNoThrow(try analyzeProgram(source), "限定值且完整覆盖应通过穷尽性校验")
    }

    // MARK: - P5-5 B5 端到端：跨枚举同名 case 运行期全链路

    /// 端到端：跨枚举同名 case（形状.圆 / 几何.圆）经限定构造 + 按值类型匹配，
    /// 输出正确且互不串味；与 examples/enum-namespacing.pini 同源验证。
    /// 意图：端到端——跨枚举同名 case（形状.圆 / 几何.圆）经限定构造 + 按值类型匹配全链路输出正确且互不串味。
    func testCrossEnumEndToEndOutput() throws {
        let source = try loadPiniFixture("testCrossEnumEndToEndOutput", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("2.0"), "取形状半径(形状.圆(2.0)) 应得 2.0，实际: \(out)")
        XCTAssertTrue(out.contains("3.0"), "取形状半径(形状.矩形(3.0, 4.0)) 应得 3.0，实际: \(out)")
        XCTAssertTrue(out.contains("圆(2.0)"), "形状.圆 应打印 圆(2.0)，实际: \(out)")
        XCTAssertTrue(out.contains("圆(0.0, 3.0)"),
                      "几何.圆 应打印 圆(0.0, 3.0)，实际: \(out)")
    }
}
