# Test Refactoring Principles

## Overview

This document records the principles established during the Pini compiler test refactoring, serving as a reference for engineering practice when organizing and writing tests.

## Three Elements of Good Tests

Every test should contain three core elements:

### 1. Intent Case（意图用例）

A clear description of what behavior the test is verifying. The test name should immediately convey the purpose.

```swift
func testStructCopySemantics() throws {
    // Intent: Verify that structs have value semantics - copying creates independent instances
}
```

**Naming Convention:** `test[Module][Behavior]`
- Module: AST, Lexer, Parser, Interpreter, Environment, etc.
- Behavior: What specific behavior is being tested

### 2. Advancing Measures（推进性测量）

Assertions that verify the **expected behavior occurs**.

```swift
XCTAssertEqual(output, "10")        // Expected value
XCTAssertTrue(foundIndent)          // Expected condition
XCTAssertNotNil(result)             // Expected non-nil
XCTAssertEqual(tokens.count, 2)     // Expected count
```

**Guidelines:**
- Be specific about expected values
- Test actual behavior, not implementation details
- Use descriptive messages for failures

### 3. Dismissing Measures（驳回性测量）

Assertions that verify **unexpected behavior does NOT occur**.

```swift
XCTAssertNotEqual(loc1, loc3)      // Different values should be unequal
XCTFail("Expected identifier")      // Unexpected code path should not execute
XCTAssertThrowsError(...)           // Expected error should be thrown
```

**Guidelines:**
- Test boundary cases
- Verify error handling paths
- Explicitly check for incorrect results

## Test Organization Pattern

### By Module

Each major module should have its own test class:

| Module | Test Class | Responsibility |
|--------|------------|----------------|
| AST | `ASTTests` | Test AST node creation, equality, and properties |
| Lexer | `LexerTests` | Test tokenization of all token types |
| IndentTracker | `IndentTrackerTests` | Test indent/dedent logic |
| Parser | `ParserTests` | Test parsing of all syntax constructs |
| Environment | `EnvironmentTests` | Test scope management and variable binding |
| Errors | `ErrorTests` | Test error types and control signals |
| Interpreter | `InterpreterTests` | Test end-to-end program execution |

### By Behavior Within Module

Within each test class, organize tests by behavior categories:

```swift
final class LexerTests: XCTestCase {
    // Token types
    func testTokenizeSimpleIdentifier()
    func testTokenizeChineseIdentifier()
    func testTokenizeStringLiteral()
    func testTokenizeIntegerLiteral()
    
    // Special cases
    func testTokenizeComment()
    func testTokenizeIndentDedent()
    func testTokenizeLongestMatchOperator()
    
    // Error cases
    func testTokenizeInvalidCharacter()
}
```

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
func testEnvironmentDefineAndGet() {
    env.define(name: "x", value: .int(42), isMutable: true)
    let result = try env.get(name: "x")
    // advancing measure
    if case .int(42) = result { }
    else { XCTFail("变量值应为 42") } // dismissing measure
}

// Error case
func testEnvironmentUndefinedVariable() {
    XCTAssertThrowsError(try env.get(name: "nonexistent")) { error in
        guard case RuntimeError.undefinedVariable(name: "nonexistent", _) = error else {
            XCTFail("应为 undefinedVariable 错误") // dismissing measure
            return
        }
    }
}
```

### Test External Behavior, Not Implementation

Focus on what the code does, not how it does it.

**Good:**
```swift
// Tests behavior: struct assignment creates independent instances
func testStructCopySemantics() throws {
    let output = try runProgram(source)
    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10")
}
```

**Bad:**
```swift
// Tests implementation: checks internal class structure
func testStructInstanceIsClass() {
    let si = StructInstance(typeName: "Point", fields: [:])
    XCTAssertTrue(type(of: si) is AnyClass)
}
```

## Test Isolation

### Each Test Should Be Independent

Tests should not depend on each other. Each test should:
- Create its own fixtures
- Not modify shared state
- Clean up after itself

```swift
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
final class InterpreterTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        // Common setup: lex, parse, interpret, capture output
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        
        // Capture stdout...
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        
        return capturedOutput
    }
}
```

## Error Handling Tests

### Explicitly Verify Error Types

Use `XCTAssertThrowsError` with pattern matching to verify the exact error:

```swift
func testLexerErrorInvalidCharacter() {
    let lexer = Lexer(source: "@", fileName: "test.pini")
    XCTAssertThrowsError(try lexer.tokenize()) { error in
        guard case LexerError.invalidCharacter("@", _) = error else {
            XCTFail("应为 invalidCharacter 错误")
            return
        }
    }
}
```

### Test Error Properties

Verify error payloads contain correct information:

```swift
func testRuntimeErrorTypeMismatch() {
    let error = RuntimeError.typeMismatch(expected: "int", got: "string", location: loc)
    
    switch error {
    case .typeMismatch(let expected, let got, let errorLoc):
        XCTAssertEqual(expected, "int")   // advancing
        XCTAssertEqual(got, "string")    // advancing
        XCTAssertEqual(errorLoc, loc)    // advancing
    default:
        XCTFail("应为 typeMismatch")     // dismissing
    }
}
```

## Regression Testing

### Every Bug Fix Gets a Test

When fixing a bug, write a test that:
1. Reproduces the bug
2. Fails before the fix
3. Passes after the fix

This prevents the bug from reappearing.

### Cross-Module Integration Tests

Test the full pipeline (lexer → parser → interpreter) for critical features:

```swift
func testMatchCase() throws {
    let source = """
[形状]
圆
矩形

{main|func}() -> ()
    var s = 圆
    match s:
        case 圆:
            print("圆形")
        case _:
            print("未知")
    return
"""
    let output = try runProgram(source)
    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "圆形")
}
```

## Verification Checklist

Before marking test refactoring complete:

- [ ] Every module has at least one test class
- [ ] Every test contains intent, advancing measures, and dismissing measures
- [ ] Tests are organized by module and behavior
- [ ] Error paths are tested alongside success paths
- [ ] Tests are independent and isolated
- [ ] All tests pass
- [ ] No regressions in existing tests

## 参考实现样板

以下样板直接复用到新测试文件，含模块专属 helper。

### 解释器执行（runProgram 模式）

```swift
final class MyFeatureTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        // … Pipe 捕获 stdout（见 IntegrationTests.runProgram 完整实现）
        let interpreter = Interpreter()
        try interpreter.run(module: module)
        return capturedOutput
    }

    /// 意图：正常输入产生预期输出
    func testNormalCase() throws {
        let source = """
main|func() -> ()
    print(expected)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "expected")
    }

    /// 意图：错误路径抛出正确异常
    func testErrorCase() throws {
        let source = "…"
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.someError = error else {
                XCTFail("应为 someError，实际: \(error)"); return
            }
        }
    }
}
```

### CodeGen 结构断言（IRGeneratorTests）

```swift
final class IRGeneratorTests: XCTestCase {
    private func generateIR(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        return try IRGenerator().generate(module: module)
    }

    /// 意图：验证某特性生成的 IR 包含预期指令
    func testFeatureIREmitted() throws {
        let source = """
main|func() -> ()
    // 使用目标特性
    return
"""
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("expected_ir_instruction"),
                      "应生成预期 IR 指令，实际:\n\(ir)")
    }
}
```

### CodeGen 真实执行（IRExecutionTests — LLI）

```swift
final class IRExecutionTests: XCTestCase {
    private var lliAvailable: Bool { LLVMToolchain.lliPath != nil }

    private func runViaLLI(_ source: String) throws -> String {
        try XCTSkipUnless(lliAvailable, "lli not available")
        let ir = try generateIR(source)           // 复用 IRGeneratorTests 同款 helper
        let tmp = FileManager.default.temporaryDirectory.path + "/pini_\(UUID()).ll"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try ir.write(toFile: tmp, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LLVMToolchain.lliPath!)
        proc.arguments = [tmp]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 意图：某特性经 LLI 真实执行产生预期输出
    func testFeatureViaLLI() throws {
        let output = try runViaLLI("""
main|func() -> ()
    print(result)
    return
""")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "result")
    }
}
```

### 类型检查（TypeCheckerTests）

```swift
final class TypeCheckerTests: XCTestCase {
    private func check(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        try SemanticAnalyzer().analyze(module: module)
        try TypeChecker().check(module: module)
    }

    func testValidProgram() throws {
        XCTAssertNoThrow(try check("main|func() -> () \n    return\n"))
    }

    func testTypeMismatchDetected() throws {
        XCTAssertThrowsError(try check("main|func() -> () \n    var x: I32 = \"hi\"\n    return\n")) { error in
            guard case TypeError.typeMismatch = error else {
                XCTFail("应为 TypeError.typeMismatch"); return
            }
        }
    }
}
```

### 错误 payload 断言（通用）

```swift
func testErrorPayload() {
    let loc = SourceLocation(line: 1, column: 5, fileName: "test.pini")
    let error = SomeError.caseX(param: "v", location: loc)
    switch error {
    case .caseX(let p, let l):
        XCTAssertEqual(p, "v"); XCTAssertEqual(l, loc)    // advancing
    default:
        XCTFail("应为 caseX")                             // dismissing
    }
}

## 注释风格（与代码注释指南协和）

本规范的「意图 / 推进性 / 驳回性」三要素**保持不变**；代码注释的通用风格见姊妹指南 `pini-comment-style-guide.md`（受 spec v0 §7 治理，本规范受 §6 治理），二者关系如下：

- **意图注释（每条测试首行）** 即该指南「自包含行为陈述」在测试代码上的具体实例 → 保留并鼓励。一句话说清验证什么行为，不额外嵌入行号 / 跨文件章节号 / 代码片段。
- 推进性 / 驳回性注释中若提到错误码，用稳定码 `E#-###`，不用行号。
- 测试里引用外部决策（如某边界为何被拒）走单行指针：`// 见 ADR-014`，理由在 ADR，不在注释叙事。

两者不冲突：本规范要求「写意图」，指南要求「意图之外不叙事、不引易变外部」——互补共存。
```
