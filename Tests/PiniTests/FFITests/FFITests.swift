import XCTest
@testable import PiniCore

/// Phase 2a（ADR-015 FFI，§2.7）：FFI & unsafe 子系统测试——解释器优先（用户决策 D1）。
///
/// 覆盖：`[名称|foreign]` 块声明与原生函数表解析（malloc/free/memcpy/strlen/puts/cstr）、
/// `*T` 指针类型、`unsafe` 消耗点、`|unsafe` 自由函数、`&` 取地址、load/store/addressof 原语、
/// C 兼容性约束（*T 禁 object）、unsafe 上下文强制、未注册原生函数 fail-fast。
final class FFITests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    private func runProgram(_ source: String) throws -> String {
        let module = try parse(source)
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
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 语义 + 类型全链路检查；返回错误（nil = 通过）。
    private func analyzeErrors(_ source: String) -> Error? {
        do {
            let module = try parse(source)
            try SemanticAnalyzer().analyze(module: module)
            let checker = TypeChecker()
            let errors = checker.checkCollecting(module: module)
            return errors.first
        } catch {
            return error
        }
    }

    private func assertParseError(_ source: String, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try parse(source)
            XCTFail("应解析失败", file: file, line: line)
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains(fragment), "报错应含 `\(fragment)`，实际: \(text)", file: file, line: line)
        }
    }

    // MARK: - foreign 块 + 原生函数表

    /// 意图：`[libc|foreign]` 声明 malloc 后可用 `unsafe malloc(n)` 调用，返回 `*U8` 指针值。
    func testForeignMallocReturnsPointer() throws {
        let source = try loadPiniFixture("testForeignMallocReturnsPointer", filePath: #filePath)
        let out = try runProgram(source)
        XCTAssertTrue(out.hasPrefix("*U8@0x"), "malloc 应返回 `*U8@0x...` 指针，实际: \(out)")
    }

    /// 意图：store/load 指针原语按元素类型做写读往返，输出一致。
    func testStoreLoadRoundtrip() throws {
        let source = try loadPiniFixture("testStoreLoadRoundtrip", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "42\n100")
    }

    /// 意图：cstr 把 String 转 C 字符串，strlen 量出长度、puts 打印 C 字符串。
    func testForeignCstrStrlenPuts() throws {
        let source = try loadPiniFixture("testForeignCstrStrlenPuts", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "5\nhello")
    }

    /// 意图：memcpy 按字节拷贝，load 目标读出源值。
    func testForeignMemcpy() throws {
        let source = try loadPiniFixture("testForeignMemcpy", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "7")
    }

    /// 意图：foreign 声明未注册的 C 函数 → 注册期 fail-fast（E5-015）。
    func testUndefinedNativeFunctionRejected() throws {
        let source = try loadPiniFixture("testUndefinedNativeFunctionRejected", filePath: #filePath)
        do {
            _ = try runProgram(source)
            XCTFail("未注册原生函数应运行时报错")
        } catch {
            XCTAssertTrue(String(describing: error).contains("未找到符号"), "应报未找到符号（symbolNotFound），实际: \(error)")
        }
    }

    // MARK: - unsafe 上下文

    /// 意图：`unsafe` 前缀是单次不安全消耗点；`unsafe load(p)` 可用。
    func testUnsafePrefixConsumptionPoint() throws {
        let source = try loadPiniFixture("testUnsafePrefixConsumptionPoint", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "3")
    }

    /// 意图：`|unsafe` 函数体自动处于不安全上下文——内部 `&` 与 foreign 调用无需 `unsafe` 前缀。
    func testUnsafeFuncBodyAutoContext() throws {
        let source = try loadPiniFixture("testUnsafeFuncBodyAutoContext", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "5")
    }

    /// 意图：`&x` 快照取址（解释器限制）——store/load 自洽往返。
    func testAddressOfSnapshot() throws {
        let source = try loadPiniFixture("testAddressOfSnapshot", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "42\n99")
    }

    /// 意图：对指针值 `&` 返回自身（地址即值）。
    func testAddressOfPointerIsNoop() throws {
        let source = try loadPiniFixture("testAddressOfPointerIsNoop", filePath: #filePath)
        XCTAssertEqual(try runProgram(source), "5")
    }

    /// 意图：`&` 在非 unsafe 上下文（普通函数体）→ 类型检查拒绝。
    func testAddressOfOutsideUnsafeRejected() throws {
        let source = try loadPiniFixture("testAddressOfOutsideUnsafeRejected", filePath: #filePath)
        let err = analyzeErrors(source)
        guard let err else {
            XCTFail("非 unsafe 上下文取地址应报错")
            return
        }
        XCTAssertTrue("\(err)".contains("unsafe"), "报错应提及 unsafe 上下文，实际: \(err)")
    }

    // MARK: - 语法/语义拒绝面

    /// 意图：`*T` 元素禁 object（ARC 隔离）——`*计数器` 声明被类型检查拒绝。
    func testPointerToObjectRejected() throws {
        let source = try loadPiniFixture("testPointerToObjectRejected", filePath: #filePath)
        let err = analyzeErrors(source)
        guard let err else {
            XCTFail("`*object` 应被 C 兼容性校验拒绝")
            return
        }
        XCTAssertTrue("\(err)".contains("C 兼容"), "报错应提及 C 兼容性，实际: \(err)")
    }

    /// 意图：foreign 块内不允许字段声明等非签名行。
    func testForeignNonSignatureRejected() throws {
        let source = try loadPiniFixture("testForeignNonSignatureRejected", filePath: #filePath)
        assertParseError(source, contains: "只允许外部 C 函数签名")
    }

    /// 意图：类型体内出现 `|unsafe` 修饰符被拒（规则 3.2 类型体禁函数）。
    func testUnsafeFuncNotTopLevelRejected() throws {
        let source = try loadPiniFixture("testUnsafeFuncNotTopLevelRejected", filePath: #filePath)
        assertParseError(source, contains: "类型体内禁止函数声明")
    }
}