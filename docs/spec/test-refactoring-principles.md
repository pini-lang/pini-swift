# Test Refactoring Principles

> **框架**：本标准的断言语汇为 **Swift Testing**（`import Testing`；`@Test` / `#expect` /
> `try #require` / `Issue.record` / `withKnownIssue`）。2026-09-19 前本标准写作 XCTest
> 语汇，随测试树重建一并迁移；**三要素与目录约定不变**，变的只是承载它们的 API。

## Overview

This document records the principles established during the Pini compiler test refactoring, serving as a reference for engineering practice when organizing and writing tests.

## Three Elements of Good Tests

Every test should contain three core elements:

### 1. Intent Case（意图用例）

A clear description of what behavior the test is verifying. The intent is carried by the
display name (and by the first comment line of the body), so it is visible in the test report
itself — not only in the source.

```swift
@Test("类型体带 trait 约束被拒")
func testParserRejectsConstraintOnStructBody() throws {
    /// 意图：`(盒<T>:显示)` 被拒 —— 约束写在扩展块位，不写在类型体位。
}
```

**Naming Convention:** `test[Module][Behavior]`

- Module: AST, Lexer, Parser, TypeChecker, HIRExecutor, etc.
- Behavior: What specific behavior is being tested
- The display name carries the same intent in one sentence; the function name keeps the
  `test` prefix and the module/behavior shape, so both the report and a text search agree.

### 2. Advancing Measures（推进性测量）

Assertions that verify the **expected behavior occurs**.

```swift
#expect(elements.count == 2)                 // Expected count
#expect(mutable)                             // Expected condition
#expect(output == ["0", "1", "2"])           // Expected value
let value = try #require(module.declarations.first)   // Expected non-nil
```

**Guidelines:**

- Be specific about expected values
- Test actual behavior, not implementation details
- Use descriptive messages for failures

### 3. Dismissing Measures（驳回性测量）

Assertions that verify **unexpected behavior does NOT occur**.

```swift
#expect(a != b)                       // Different values should be unequal
Issue.record("应为函数声明 f")           // Unexpected code path should not execute
#expect(throws: ParserError.self) { … }  // Expected error should be thrown
```

**Guidelines:**

- Test boundary cases
- Verify error handling paths
- Explicitly check for incorrect results

## Test Organization Pattern

### By Module

Each major module should have its own suite:

| Module | Suite | Responsibility |
|--------|------------|----------------|
| AST | `ASTTests` | Test AST node creation, equality, and properties |
| Lexer | `LexerTests` | Test tokenization of all token types |
| IndentTracker | `IndentTrackerTests` | Test indent/dedent logic |
| Parser | `ParserTests` | Test parsing of all syntax constructs |
| Environment | `EnvironmentTests` | Test scope management and variable binding |
| Errors | `ErrorTests` | Test error types and control signals |
| Program execution | `ProgramExecutionTests` | Test end-to-end program execution |

### By Behavior Within Module

Within each suite, organize tests by behavior categories:

```swift
struct LexerTests {
    // Token types
    @Test("标识符") func testTokenizeSimpleIdentifier()
    @Test("中文标识符") func testTokenizeChineseIdentifier()
    @Test("字符串字面量") func testTokenizeStringLiteral()
    @Test("整数字面量") func testTokenizeIntegerLiteral()

    // Special cases
    @Test("注释") func testTokenizeComment()
    @Test("缩进与反缩进") func testTokenizeIndentDedent()
    @Test("运算符最长匹配") func testTokenizeLongestMatchOperator()

    // Error cases
    @Test("非法字符") func testTokenizeInvalidCharacter()
}
```

## Test Directory Layout

### The Directory Unit (codified 2026-09-03 — the convention practice already settled on)

Every suite lives in its own directory, named after the suite. Fixtures read
by that suite live beside it, named after the test function that consumes them.

```
Tests/PiniTests/
    PiniFixtureLoader.swift            <- shared loader; stays at the top level
    <SuiteName>/
        <SuiteName>.swift              <- the suite
        testXxxBehavior.pini           <- fixture, named after the consuming test func
        testYyyBehavior.pini
```

Rules:

- **One directory per suite**; directory name == suite name == file name.
- **Fixture name == the test function that consumes it.** `testReadFile.pini` is read
  by `testReadFile()`. This is what makes a dead fixture detectable by inspection:
  a `.pini` with no matching `func` is orphaned. （语料类套件可以再补一条机械判据，
  把「夹具名 ↔ 用例名」逐条断言，不必只靠肉眼。）
- **Fixtures are located by path, not by bundle resource.** `PiniFixtureLoader` derives
  the fixture directory from `#filePath`, so a directory can be relocated without
  touching a single call site.
- **Shared helpers stay at the `Tests/PiniTests/` top level** (today: `PiniFixtureLoader.swift`).
  Per-suite helpers belong inside the suite.
- **Fixture trees are not groups.** `ModuleSystemTests/demo/` is fixture data, not a
  subject grouping.

### Subject Groups (optional; precedent: `CodeGen/`)

A directory may hold subject-related suites instead of exactly one. The
existing precedent:

```
Tests/PiniTests/CodeGen/                <- subject group (IR / LLVM)
    IRGeneratorTests/
    IRExecutionTests/
    IRPrintGoldenTests/
```

Grouping is **by subject, not by compiler pass**. Measured 2026-09-03: 61 of 111 test
files (55%) drive the whole Lexer → Parser → interpreter pipeline and only 8 (7%) touch
a single pass, so pass-based buckets collapse into one oversized bucket. See
`docs/spec/test-dir-taxonomy-2026-09-03.md`（载体已删） for the measured proposal.

## Coverage Strategy

### Every Module Must Have At Least One Test

No module should be untested. Even simple utilities like `IndentTracker` need tests.

### Test Both Success and Failure Paths

For every feature, test:
1. **Normal case**: The feature works as expected
2. **Edge case**: Boundary conditions
3. **Error case**: Invalid input is handled correctly

```swift
// Normal case
@Test("定义并读取")
func testEnvironmentDefineAndGet() throws {
    let env = Environment()
    env.define(name: "x", value: .int(42), isMutable: true)
    let result = try env.get(name: "x")
    // advancing measure
    if case .int(42) = result {} else { Issue.record("变量值应为 42") }  // dismissing measure
}

// Error case
@Test("未定义变量")
func testEnvironmentUndefinedVariable() {
    let env = Environment()
    #expect(throws: RuntimeError.self) { try env.get(name: "nonexistent") }
}
```

### Test External Behavior, Not Implementation

Focus on what the code does, not how it does it.

**Good:**
```swift
// Tests behavior: struct assignment creates independent instances
@Test("结构体赋值产生独立实例")
func testStructCopySemantics() throws {
    let output = try runProgram(source)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "10")
}
```

**Bad:**
```swift
// Tests implementation: checks internal class structure
@Test("结构体实例是类实例")
func testStructInstanceIsClass() {
    let si = StructInstance(typeName: "Point", fields: [:])
    #expect(type(of: si) is AnyClass)
}
```

## Test Isolation

### Each Test Should Be Independent

Tests should not depend on each other. Each test should:
- Create its own fixtures
- Not modify shared state
- Clean up after itself

```swift
@Test("嵌套作用域")
func testEnvironmentNestedScope() {
    // Each test creates its own environment
    let outer = Environment()
    outer.define(name: "outer", value: .int(1), isMutable: true)

    let inner = Environment(enclosing: outer)
    inner.define(name: "inner", value: .int(2), isMutable: true)

    // Test assertions
}
```

### Use Helper Methods for Common Setup

Extract repetitive setup into private helper methods:

```swift
struct ProgramExecutionTests {
    private func runProgram(_ source: String) throws -> String {
        // Common setup: lex, parse, execute, capture output
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        // Capture the program's output through the executor's sink, not by
        // redirecting the process's stdout…
        let runner = ProgramRunner()
        var lines: [String] = []
        runner.outputSink = { lines.append($0) }
        try runner.run(module: module)

        return lines.joined(separator: "\n")
    }
}
```

## Error Handling Tests

### Explicitly Verify Error Types

Use `#expect(throws:)` for the type, and pattern matching for the payload:

```swift
@Test("非法字符")
func testLexerErrorInvalidCharacter() {
    let lexer = Lexer(source: "@", fileName: "test.pini")
    #expect(throws: LexerError.self) { try lexer.tokenize() }
}
```

### Test Error Properties

Verify error payloads contain correct information:

```swift
@Test("类型不匹配的载荷")
func testRuntimeErrorTypeMismatch() throws {
    let loc = SourceLocation(line: 1, column: 5, fileName: "test.pini")
    let error = RuntimeError.typeMismatch(expected: "int", got: "string", location: loc)

    guard case .typeMismatch(let expected, let got, let errorLoc) = error else {
        Issue.record("应为 typeMismatch"); return
    }
    #expect(expected == "int")       // advancing
    #expect(got == "string")         // advancing
    #expect(errorLoc == loc)         // advancing
}
```

### 门控类用例：跳过要显式、要计数

环境未配置（例如 LLVM 工具链缺失）时，用 `withKnownIssue` 记一笔**可见**的跳过，并让
读数带上条数；环境**已**配置但工具缺失属配置错误，用 `try #require` 直接判红。

```swift
@Test("某特性经 LLI 真实执行")
func testFeatureViaLLI() throws {
    guard LLVMToolchain.lliPath != nil else {
        withKnownIssue("未配置 LLVM 工具链 ⇒ 本臂本次未测") {
            Issue.record("LLVM 臂未参与核对")
        }
        return
    }
    try #require(LLVMToolchain.lliPath != nil, "已配置 LLVM 环境却找不到 lli")
    // …真实执行断言
}
```

⚠️ 没有「静默跳过」这一档：`swift test` 的汇总行会把已知问题数一并打出
（`… with 1 known issue`），因此「没跑」与「通过」在读数上必须分得开。

## Regression Testing

### Every Bug Fix Gets a Test

When fixing a bug, write a test that:
1. Reproduces the bug
2. Fails before the fix
3. Passes after the fix

This prevents the bug from reappearing.

### Cross-Module Integration Tests

Test the full pipeline (lexer → parser → execution) for critical features:

```swift
@Test("match 用例")
func testMatchCase() throws {
    let source = """
[形状]
圆
矩形

main|func() -> ():
    var s = 圆
    match s:
        case 圆:
            print("圆形",)
        case _:
            print("未知",)
    return
"""
    let output = try runProgram(source)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "圆形")
}
```

## Verification Checklist

Before marking test refactoring complete:

- [ ] Every module has at least one suite
- [ ] Every test contains intent, advancing measures, and dismissing measures
- [ ] Assertions use `#expect` / `try #require` / `Issue.record`（不用 XCTest 断言）
- [ ] Tests are organized by module and behavior
- [ ] Error paths are tested alongside success paths
- [ ] Tests are independent and isolated
- [ ] All tests pass
- [ ] No regressions in existing tests

## 参考实现样板

以下样板直接复用到新测试文件，含模块专属 helper。

### 执行产物（runProgram 模式）

```swift
struct MyFeatureTests {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "test.pini")
        let module = try parser.parseModule()
        // 输出走执行器的汇接口取回，不重定向进程 stdout
        let runner = ProgramRunner()
        var lines: [String] = []
        runner.outputSink = { lines.append($0) }
        try runner.run(module: module)
        return lines.joined(separator: "\n")
    }

    /// 意图：正常输入产生预期输出
    @Test("正常输入")
    func testNormalCase() throws {
        let source = """
main|func() -> ():
    print(预期值,)
    return
"""
        #expect(try runProgram(source) == "预期值")
    }

    /// 意图：错误路径抛出正确异常
    @Test("错误输入")
    func testErrorCase() throws {
        let source = "…"
        #expect(throws: RuntimeError.self) { try runProgram(source) }
    }
}
```

### 结构断言（IRGeneratorTests，**已于 M6 翻转退役**）

> M6 翻转（2026-09-12）删除了旧生成器，本节所示套件随之退役（88 例 + 83 夹具）。
> 本节保留作**反例**：断言 IR 文本形状与实现强耦合 —— 换一条管线，整批断言即失效，
> 且失效方式是「测试对象消失」而非「行为回归」，无法迁移。
> 能力与行为的覆盖改由执行层、差分与运行时契约三类承担（见本节后续各段）。

```swift
struct IRGeneratorTests {
    private func generateIR(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "test.pini")
        let module = try parser.parseModule()
        return try IRGenerator().generate(module: module)
    }

    /// 意图：验证某特性生成的 IR 包含预期指令
    @Test("IR 含预期指令")
    func testFeatureIREmitted() throws {
        let ir = try generateIR("…")
        #expect(ir.contains("expected_ir_instruction"), "应生成预期 IR 指令，实际:\n\(ir)")
    }
}
```

### 真实执行（LLI）

```swift
struct IRExecutionTests {
    private var lliAvailable: Bool { LLVMToolchain.lliPath != nil }

    private func runViaLLI(_ source: String) throws -> String {
        guard let lli = LLVMToolchain.lliPath else {
            withKnownIssue("未配置 LLVM 工具链 ⇒ 本臂本次未测") { Issue.record("LLVM 臂未参与核对") }
            return ""
        }
        let ir = try generateIR(source)
        let tmp = FileManager.default.temporaryDirectory.path + "/pini_\(UUID()).ll"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try ir.write(toFile: tmp, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: lli)
        proc.arguments = [tmp]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 意图：某特性经 LLI 真实执行产生预期输出
    @Test("经 LLI 执行")
    func testFeatureViaLLI() throws {
        let output = try runViaLLI("…")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "预期值")
    }
}
```

### 类型检查（TypeCheckerTests）

```swift
struct TypeCheckerTests {
    private func check(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "test.pini")
        let module = try parser.parseModule()
        try SemanticAnalyzer().analyze(module: module)
        try TypeChecker().check(module: module)
    }

    @Test("合法程序放行")
    func testValidProgram() throws {
        try check("main|func() -> (): \n    return\n")
    }

    @Test("类型不符被拒")
    func testTypeMismatchDetected() throws {
        #expect(throws: TypeError.self) {
            try check("main|func() -> (): \n    var x: I32 = \"hi\"\n    return\n")
        }
    }
}
```

### 错误 payload 断言（通用）

```swift
@Test("错误载荷")
func testErrorPayload() {
    let loc = SourceLocation(line: 1, column: 5, fileName: "test.pini")
    let error = SomeError.caseX(param: "v", location: loc)
    guard case .caseX(let p, let l) = error else {
        Issue.record("应为 caseX"); return
    }
    #expect(p == "v")     // advancing
    #expect(l == loc)     // advancing
}
```

## 注释风格（与代码注释指南协和）

本规范的「意图 / 推进性 / 驳回性」三要素**保持不变**；代码注释的通用风格见姊妹指南 `pini-comment-style-guide.md`（受 spec v0 §7 治理，本规范受 §6 治理），二者关系如下：

- **意图注释（每条测试首行）** 即该指南「自包含行为陈述」在测试代码上的具体实例 → 保留并鼓励。一句话说清验证什么行为，不额外嵌入行号 / 跨文件章节号 / 代码片段。
- **显示名与意图注释同义**：显示名进测试报告的读数面，意图注释留在源码里；两者都用一句话，不叙事。
- 推进性 / 驳回性注释中若提到错误码，用稳定码 `E#-###`，不用行号。
- 测试里引用外部决策（如某边界为何被拒）走单行指针：`// 见 标签语法反转`，理由在 ADR，不在注释叙事。

两者不冲突：本规范要求「写意图」，指南要求「意图之外不叙事、不引易变外部」——互补共存。
