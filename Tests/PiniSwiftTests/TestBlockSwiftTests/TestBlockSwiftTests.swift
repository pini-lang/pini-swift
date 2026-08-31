import Testing
import Foundation
@testable import PiniCore

/// #46-E G41（test 块，R5，2026-08-24 拍板）：宿主测试使用 SwiftTesting 驱动 `.pini` `|test` 函数块。
///
/// 本 target（PiniSwiftTests）依赖 Package.swift tools-version 6.2（S0 升级），
/// 与既有 XCTest target（PiniTests）共存；端到端驱动 `Interpreter.runTests`，
/// 验证 `.pini` 语言级测试经 SwiftTesting 宿主可被收集、执行并正确判定。
@Suite("G41 test 块：SwiftTesting 宿主端到端")
struct TestBlockSwiftTests {

 private func runTests(_ source: String) throws -> [Interpreter.TestRunResult] {
 let lexer = Lexer(source: source, fileName: "swift_testing.pini")
 let tokens = try lexer.tokenize()
 let parser = Parser(tokens: tokens, fileName: "swift_testing.pini")
 let module = try parser.parseModule()
 let interpreter = Interpreter()
 return try interpreter.runTests(module: module)
 }

 @Test("收集并执行全部 |test，assert 全通过")
 func allPass() throws {
 let results = try runTests(try! loadPiniFixture("_results", filePath: #filePath) as String)
 #expect(results.count == 2, "应收集到 2 个 |test 函数")
 let allPassed = results.allSatisfy { $0.passed }
 #expect(allPassed, "全部应通过，实际 \(results.map { ($0.name, $0.message) })")
 }

 @Test("断言失败被捕获为测试失败，其余测试不受影响")
 func failureCaptured() throws {
 let results = try runTests(try! loadPiniFixture("_results_2", filePath: #filePath) as String)
 #expect(results.count == 2)
 let failed = results.first { !$0.passed }
 #expect(failed != nil, "应存在失败测试")
 #expect(failed?.name == "应失败")
 #expect(failed?.message.contains("boom") == true)
 let passedCount = results.filter { $0.passed }.count
 #expect(passedCount == 1)
 }

 @Test("R4 参数注入：带参数 |test 注入类型零值后可正常执行")
 func zeroValueParamInjection() throws {
 let results = try runTests(try! loadPiniFixture("_results_3", filePath: #filePath) as String)
 #expect(results.count == 1)
 let msg = results[0].message
    #expect(results[0].passed, "零值注入后应通过，实际 \(msg)")
 }
}
