import XCTest
@testable import PiniCore

final class OptionalTests: XCTestCase {

    // MARK: - TypeInference 测试

    /// 意图：验证 Optional.some(42) 调用经类型推断返回 Optional<T>，且类型参数从实参 42 推断为 I32。
    func testOptionalSomeTypeInference() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let env = TypeEnvironment()
        let inference = TypeInference(environment: env)

        let tType = TypeAnnotation.simple(name: "T", location: loc)
        env.defineGenericStruct(name: "Optional", genericParams: ["T"], fields: [], methods: [])

        let someCall = Expression.call(
            callee: .member(
                object: .identifier(name: "Optional", location: loc),
                name: "some",
                location: loc
            ),
            arguments: [CallArgument(label: nil, expression: .integerLiteral(value: 42, location: loc))],
            location: loc
        )

        let result = inference.infer(expression: someCall)
        guard let r = result else {
            XCTFail("Optional.some 应能推断返回类型")
            return
        }
        guard case .generic(let name, let params, _) = r else {
            XCTFail("返回类型应为 generic")
            return
        }
        XCTAssertEqual(name, "Optional", "泛型名称应为 Optional")
        XCTAssertEqual(params.count, 1, "应有一个类型参数")
        guard case .simple(let pname, _) = params[0] else {
            XCTFail("类型参数应为 simple")
            return
        }
        XCTAssertEqual(pname, "I32", "参数类型应从参数推断为 I32")
    }

    /// 意图：验证 Optional.none 调用无需实参即可推断为 Optional<T>（generic 名 Optional、带一个类型参数）。
    func testOptionalNoneTypeInference() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let env = TypeEnvironment()
        let inference = TypeInference(environment: env)

        let tType = TypeAnnotation.simple(name: "T", location: loc)
        env.defineGenericStruct(name: "Optional", genericParams: ["T"], fields: [], methods: [])

        let noneCall = Expression.call(
            callee: .member(
                object: .identifier(name: "Optional", location: loc),
                name: "none",
                location: loc
            ),
            arguments: [],
            location: loc
        )

        let result = inference.infer(expression: noneCall)
        guard let r = result else {
            XCTFail("Optional.none 应能推断返回类型")
            return
        }
        guard case .generic(let name, let params, _) = r else {
            XCTFail("返回类型应为 generic")
            return
        }
        XCTAssertEqual(name, "Optional")
        XCTAssertEqual(params.count, 1)
    }

    /// 意图：验证对非 Optional 类型调用 .some(42)（`其它.some`）不会被当作 Optional 特例处理，推断结果为 nil。
    func testNonOptionalMemberNotInferredAsOptional()  throws {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let env = TypeEnvironment()
        let inference = TypeInference(environment: env)

        let otherCall = Expression.call(
            callee: .member(
                object: .identifier(name: "其它", location: loc),
                name: "some",
                location: loc
            ),
            arguments: [CallArgument(label: nil, expression: .integerLiteral(value: 42, location: loc))],
            location: loc
        )

        let result = inference.infer(expression: otherCall)
        XCTAssertNil(result, "非 Optional.some 调用不应被特殊处理")
    }

    // MARK: - P2-2 `nil` 类型层（spec G30 / G30）

    /// 意图：验证 nil（解析为 Optional.none 成员）与 Optional.none 同样推断为 Optional<Any>（带一个类型参数）。
    func testNilTypeInference()  throws {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let env = TypeEnvironment()
        let inference = TypeInference(environment: env)
        env.defineGenericStruct(name: "Optional", genericParams: ["T"], fields: [], methods: [])

        // `nil` 解析为 .member(Optional, none)，应与 Optional.none 同推断为 Optional<Any>
        let nilExpr = Expression.member(
            object: .identifier(name: "Optional", location: loc),
            name: "none",
            location: loc
        )
        let result = inference.infer(expression: nilExpr)
        guard let r = result else {
            XCTFail("nil 应能推断返回类型"); return
        }
        guard case .generic(let name, let params, _) = r else {
            XCTFail("返回类型应为 generic"); return
        }
        XCTAssertEqual(name, "Optional", "nil 推断应为 Optional")
        XCTAssertEqual(params.count, 1, "nil 推断应带一个类型参数 (Any)")
    }

    /// 意图：验证带类型注解的 nil 赋值 var x: Optional<I32> = nil 能通过类型检查（不抛出）。
    func testNilWithTypeAnnotationTypeChecks() throws {
        let source = try loadPiniFixture("testNilWithTypeAnnotationTypeChecks", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module), "let x: Optional<I32> = nil 应通过类型检查")
    }

    // MARK: - P3-3 `?` 可选类型糖类型层（spec G31 / G31）

    /// 意图：验证糖语法类型注解 var x: ?I32 = nil 能通过类型检查（不抛出）。
    func testQuestionTypeAnnotationTypeChecks() throws {
        let source = try loadPiniFixture("testQuestionTypeAnnotationTypeChecks", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module), "let x: ?I32 = nil 应通过类型检查")
    }

    /// 意图：验证 ?I32 与 Optional<I32> 为同类型，将 Optional 值赋给 ? 变量应能通过类型检查。
    func testQuestionTypeEquivalentToOptionalForAssignment() throws {
        // ?I32 与 Optional<I32> 是同类型，应可互相赋值
        let source = try loadPiniFixture("testQuestionTypeEquivalentToOptionalForAssignment", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module),
                         "?I32 与 Optional<I32> 应可互相赋值（同类型）")
    }

    /// 意图：验证 Optional<I32> 与 ?I32 变量多次互赋（a→b→c）后类型保持一致，均能通过类型检查。
    func testQuestionTypeInferredFromOptionalValue() throws {
        // 将 Optional<I32> 值赋给 ?I32 变量，推断结果应等价
        let source = try loadPiniFixture("testQuestionTypeInferredFromOptionalValue", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module),
                         "?I32 / Optional<I32> 多次互赋应保持类型一致")
    }

    // MARK: - P3-4 `?` 可选类型糖解释器语义（spec G31 / G31）

    /// 意图：验证解释器下 ?I32 变量赋 nil 后 match case nil: 命中并输出 q-none。
    func testQuestionTypeInterpreterNilMatch() throws {
        let source = try loadPiniFixture("testQuestionTypeInterpreterNilMatch", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "q-none",
                       "?I32 变量赋 nil 应匹配 case nil:")
    }

    /// 意图：验证解释器下 ?I32 接收 Optional.some(3) 后可 match 解构得到 3（LLVM IR 构造属已知延期缺口，仅覆盖解释器）。
    func testQuestionTypeInterpreterSomeDestruct() throws {
        // 解释器侧：?I32 接收 Optional.some(3) 并能解构
        // （some 的 LLVM IR 构造属已知延期缺口，本测试仅覆盖解释器）
        let source = try loadPiniFixture("testQuestionTypeInterpreterSomeDestruct", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "3",
                       "?I32 接收 Optional.some(3) 解构应得到 3")
    }

    /// 意图：验证解释器下 ?I32 值赋给 Optional<I32> 变量后 match 命中 case none: 并输出 ok。
    func testQuestionTypeEquivalentToOptionalInterpreter() throws {
        // ?I32 与 Optional<I32> 同类型，互赋后可独立 match
        let source = try loadPiniFixture("testQuestionTypeEquivalentToOptionalInterpreter", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok",
                       "?I32 值赋给 Optional<I32> 变量后应能匹配 case none:")
    }

    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    // MARK: - 运行时测试

    /// 意图：验证解释器运行时 Optional.some(42) 经 match 解构输出 42。
    func testOptionalSomeRuntime() throws {
        let source = try loadPiniFixture("testOptionalSomeRuntime", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42", "Optional.some(42) match 应得到 42")
    }

    /// 意图：验证解释器运行时 Optional.none 经 match 命中 case none: 输出 none。
    func testOptionalNoneRuntime() throws {
        let source = try loadPiniFixture("testOptionalNoneRuntime", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "none", "Optional.none match 应得到 none")
    }

    /// 意图：验证解释器运行时 Optional.some("hello") 字符串装箱经 match 解构输出 hello。
    func testOptionalSomeStringRuntime() throws {
        let source = try loadPiniFixture("testOptionalSomeStringRuntime", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello", "Optional.some(String) 应正确工作")
    }

    // MARK: - P2-3 `nil` 解释器语义（spec G30 / G30）

    /// 意图：验证 var a = nil 后 match case nil: 命中 Optional.none 并输出 nil-matched。
    func testNilMatchesViaMatchCaseNil() throws {
        let source = try loadPiniFixture("testNilMatchesViaMatchCaseNil", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "nil-matched",
                       "match case nil: 应命中 Optional.none")
    }

    /// 意图：验证 var x: Optional<I32> = nil 后 match 命中 case none: 并输出 none。
    func testNilAssignedToOptionalI32ThenMatchesNone() throws {
        let source = try loadPiniFixture("testNilAssignedToOptionalI32ThenMatchesNone", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "none",
                       "let x: Optional<I32> = nil 应匹配 case none:")
    }

    /// 意图：验证 nil 与 Optional.none 在解释器下逐字节等价（同一路径），二者输出一致且均匹配 case none:。
    func testNilEquivalentToOptionalNone() throws {
        // nil 与 Optional.none 应逐字节等价（同一条解释器路径）
        let withNil = try loadPiniFixture("testNilEquivalentToOptionalNone", filePath: #filePath)
        let withNone = try loadPiniFixture("testNilEquivalentToOptionalNone_2", filePath: #filePath)
        let outNil = try runProgram(withNil).trimmingCharacters(in: .whitespacesAndNewlines)
        let outNone = try runProgram(withNone).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(outNil, outNone, "nil 与 Optional.none 输出应一致")
        XCTAssertEqual(outNil, "none", "二者均应匹配 case none:")
    }

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
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

    // MARK: - #46-optional：LLVM 后端 Optional.some 构造/解构（G33 闭合）

    /// 经 CLI 同款路径：parse → TypeChecker.check → IRGenerator(typeInference) → lli。
    /// 验证 Optional.some 的装箱构造 + match 解构在 run-llvm 与解释器对齐。
    private func runViaLLIWithTypeCheck(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
        // #46-optional：开启持久表兜底，codegen 重推 match scrutinee 类型不受 check 后作用域 pop 影响。
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let generator = IRGenerator()
        generator.typeInference = checker.typeInference
        let ir = try generator.generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_opt_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = LLVMToolchain.lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        process.arguments = [tmpIR]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// match Optional.some(v) 应通过类型检查（确认 type checker 支持解构绑定）
    /// 意图：验证含 Optional.some(42) 与 match some(v) 解构绑定的源码能通过类型检查（不抛出）。
    func testOptionalSomeMatchTypeChecks() throws {
        let source = try loadPiniFixture("testOptionalSomeMatchTypeChecks", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module), "match Optional.some(v) 应通过类型检查")
    }

    /// run-llvm 与解释器对 Optional.some(42)/none 输出一致（trim 后）。
    /// 意图：经 CLI 同款路径（parse→check→codegen→lli）验证 Optional.some(42)/none 在 run-llvm 与解释器下输出去换行后一致，且 LLVM 输出为 42none。
    func testOptionalSomeRunLLVMParity() throws {
        try XCTSkipIf(LLVMToolchain.lliPath == nil, "lli 不可用，跳过 run-llvm 验证")
        let source = try loadPiniFixture("testOptionalSomeRunLLVMParity", filePath: #filePath)
        let llvmOut = try runViaLLIWithTypeCheck(source).trimmingCharacters(in: .whitespacesAndNewlines)
        let interpOut = try runProgram(source).trimmingCharacters(in: .whitespacesAndNewlines)
        // LLVM 后端 print 不补换行（已知预存特征），解释器两 print 间有换行；比对时消除全部换行。
        let normalize = { (s: String) -> String in
            s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        }
        XCTAssertEqual(normalize(llvmOut), normalize(interpOut),
                       "run-llvm 与解释器对 Optional.some/none 应输出一致（去换行后）")
        XCTAssertEqual(llvmOut, "42none", "Optional.some(42) 走 run-llvm 应输出 42，none 输出 none")
    }

    /// run-llvm 与解释器对 Optional.some(String) 输出一致（验证 ptr 元素装箱/解构）。
    /// 意图：验证 Optional.some("hello") 的 ptr 元素装箱/解构在 run-llvm 与解释器下输出一致，且 LLVM 输出为 hello。
    func testOptionalSomeStringRunLLVMParity() throws {
        try XCTSkipIf(LLVMToolchain.lliPath == nil, "lli 不可用，跳过 run-llvm 验证")
        let source = try loadPiniFixture("testOptionalSomeStringRunLLVMParity", filePath: #filePath)
        let llvmOut = try runViaLLIWithTypeCheck(source).trimmingCharacters(in: .whitespacesAndNewlines)
        let interpOut = try runProgram(source).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(llvmOut, interpOut, "run-llvm 与解释器对 Optional.some(String) 应输出一致")
        XCTAssertEqual(llvmOut, "hello", "Optional.some(\"hello\") 走 run-llvm 应输出 hello")
    }
}
