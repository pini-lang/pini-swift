import XCTest
import PiniCore

/// 语义分析器测试
final class SemanticAnalyzerTests: XCTestCase {
    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 意图：分析器应正确接受无错误的简单程序
    func testAnalyzeValidProgram() throws {
        let source = try loadPiniFixture("testAnalyzeValidProgram", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertNoThrow(try analyzer.analyze(module: module), "无错误的程序不应抛出异常")
    }

    /// 意图：分析器应检测到未定义的变量引用
    func testAnalyzeUndefinedVariable() throws {
        let source = try loadPiniFixture("testAnalyzeUndefinedVariable", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertThrowsError(try analyzer.analyze(module: module), "引用未定义变量应抛出错误") { error in
            guard case SemanticError.undefinedVariable(name: "undefinedVar", _) = error else {
                XCTFail("应为 undefinedVariable 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：分析器应正确接受变量声明后使用
    func testAnalyzeVariableUsedAfterDeclaration() throws {
        let source = try loadPiniFixture("testAnalyzeVariableUsedAfterDeclaration", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertNoThrow(try analyzer.analyze(module: module), "声明后使用不应抛出异常")
    }

    /// 意图：分析器应检测到使用尚未声明的变量（前向引用）
    func testAnalyzeVariableUsedBeforeDeclaration() throws {
        let source = try loadPiniFixture("testAnalyzeVariableUsedBeforeDeclaration", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertThrowsError(try analyzer.analyze(module: module), "前向引用应抛出错误")
    }

    /// 意图：分析器应正确注册顶级函数并在 main 中可调用
    func testAnalyzeTopLevelFunctionCall() throws {
        let source = try loadPiniFixture("testAnalyzeTopLevelFunctionCall", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertNoThrow(try analyzer.analyze(module: module), "调用已定义的顶级函数不应抛出异常")
    }

    /// 意图：分析器应检测到调用未定义的函数
    func testAnalyzeUndefinedFunctionCall() throws {
        let source = try loadPiniFixture("testAnalyzeUndefinedFunctionCall", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertThrowsError(try analyzer.analyze(module: module), "调用未定义函数应抛出错误") { error in
            guard case SemanticError.undefinedFunction(name: "undefinedFunc", _) = error else {
                XCTFail("应为 undefinedFunction 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：分析器应正确接受结构块字段访问
    func testAnalyzeStructFieldAccess() throws {
        let source = try loadPiniFixture("testAnalyzeStructFieldAccess", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertNoThrow(try analyzer.analyze(module: module), "结构块字段访问不应抛出异常")
    }

    /// 意图：分析器应将已注册的类型名作为合法标识符
    func testAnalyzeRegisteredTypeAsConstructor() throws {
        let source = try loadPiniFixture("testAnalyzeRegisteredTypeAsConstructor", filePath: #filePath)
        let module = try parseModule(source)
        let analyzer = SemanticAnalyzer()

        XCTAssertNoThrow(try analyzer.analyze(module: module), "类型构造器调用不应抛出异常")
    }
}

/// 类型检查器测试
final class TypeCheckerTests: XCTestCase {
    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 意图：验证 TypeChecker 可无参构造且实例非 nil（初始化成功路径）。
    func testTypeCheckerInitializes()  throws {
        let checker = TypeChecker()
        XCTAssertNotNil(checker)
    }

    /// 意图：类型检查器应正确接受类型一致的表达式
    func testCheckValidArithmetic() throws {
        let source = try loadPiniFixture("testCheckValidArithmetic", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        XCTAssertNoThrow(try checker.check(module: module), "整数加法不应抛出类型错误")
    }

    /// F5（issue-unsafe-gate-foreign）：安全上下文裸调 foreign 函数应报 mismatch
    ///（该消耗而未消耗的反向缺口；`|unsafe` 函数体 / `unsafe (...)` 消耗点放行）
    func testCheckForeignCallRequiresUnsafeContext() throws {
        let source = try loadPiniFixture("testCheckForeignCallRequiresUnsafeContext", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        XCTAssertThrowsError(try checker.check(module: module), "安全上下文裸调 foreign 应报错") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// F3：前缀 ++/-- 作用于不可赋值目标（字面量）应为静态编译错误
    func testCheckIncDecLiteralTargetRejected() throws {
        let source = try loadPiniFixture("testCheckIncDecLiteralTargetRejected", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        XCTAssertThrowsError(try checker.check(module: module), "++1 应为编译错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// F3：前缀 ++/-- 作用于可赋值目标（变量）应通过类型检查
    func testCheckIncDecIdentifierTargetAccepted() throws {
        let source = try loadPiniFixture("testCheckIncDecIdentifierTargetAccepted", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        XCTAssertNoThrow(try checker.check(module: module), "++可赋值变量不应报错")
    }

    /// 意图：类型检查器应检测到整数与字符串的算术运算类型不匹配
    func testCheckTypeMismatchArithmetic() throws {
        let source = try loadPiniFixture("testCheckTypeMismatchArithmetic", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        XCTAssertThrowsError(try checker.check(module: module), "整数加字符串应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    // MARK: - MED-3：枚举用例构造 arity 始终校验（P5-3）

    /// 意图：枚举用例构造在「无期望类型上下文」现场（如变量初始化）参数个数不符时，
    /// 类型检查器须报 argumentCountMismatch，而非静默放行。
    /// 回归护栏：此前 `var c = 圆(5.0, 6.0,)` 会被静默接受、多余实参在运行时被丢弃。
    func testEnumCaseConstructionArityMismatch() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionArityMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertThrowsError(try checker.check(module: module), "圆只有 1 个关联值却传入 2 个实参应抛出类型错误") { error in
            guard case TypeError.argumentCountMismatch(expected: 1, got: 2, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 1, got: 2)，实际: \(error)")
                return
            }
        }
    }

    /// 意图：正确 arity 的枚举用例构造不报错（零回归护栏）。
    func testEnumCaseConstructionArityMatch() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionArityMatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module), "正确 arity 的枚举用例构造不应报错")
    }

    /// 意图：不依赖期望类型的路径上，枚举用例构造须做基础类型比对（非泛型枚举字段类型具体）。
    func testEnumCaseConstructionBasicTypeMismatch() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionBasicTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertThrowsError(try checker.check(module: module), "圆(...) 关联值传入字符串应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：ADR-016 规则 3.15——关联值默认值特性已移除，`东(序: I32 = 0,)` 须在解析期报错。
    /// 回归护栏：此前 MED-3 容忍字面量默认（`东()` 全省略构造），3.15 起该写法不再合法。
    func testEnumCaseDefaultValueRejectedAtParse()  throws {
        let source = try loadPiniFixture("testEnumCaseDefaultValueRejectedAtParse", filePath: #filePath)
        XCTAssertThrowsError(try parseModule(source), "规则 3.15：关联值具名/默认写法应在解析期报错") { error in
            guard case ParserError.invalidStatement = error else {
                XCTFail("应为 ParserError.invalidStatement，实际: \(error)")
                return
            }
        }
    }

    /// 意图：位置化后关联值无默认值，全省略构造须报 arity 不符（`expected: 1, got: 0`）。
    func testEnumCaseConstructionRejectsOmittedArgs() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionRejectsOmittedArgs", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertThrowsError(try checker.check(module: module), "3.15：无默认值后全省略构造应报 arity 不符") { error in
            guard case TypeError.argumentCountMismatch(expected: 1, got: 0, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 1, got: 0)，实际: \(error)")
                return
            }
        }
    }

    /// 意图：位置化用例须拒绝「超额」实参。
    func testEnumCaseConstructionRejectsExtraArgs() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionRejectsExtraArgs", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()
        XCTAssertThrowsError(try checker.check(module: module), "位置化用例传入超额实参应抛出类型错误") { error in
            guard case TypeError.argumentCountMismatch(expected: 1, got: 2, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 1, got: 2)，实际: \(error)")
                return
            }
        }
    }

    /// 意图：类型推断应能推断整数字面量类型
    func testTypeInferenceIntegerLiteral() {
        let inference = TypeInference()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let expr = Expression.integerLiteral(value: 42, location: loc)
        let result = inference.infer(expression: expr)

        XCTAssertNotNil(result, "整数字面量应能推断出类型")
        if case .simple(let name, _) = result {
            XCTAssertEqual(name, "I32", "整数字面量应推断为 I32")
        } else {
            XCTFail("应为 simple 类型")
        }
    }

    /// 意图：类型推断应能推断字符串字面量类型
    func testTypeInferenceStringLiteral() {
        let inference = TypeInference()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let expr = Expression.stringLiteral(value: "hello", location: loc)
        let result = inference.infer(expression: expr)

        XCTAssertNotNil(result, "字符串字面量应能推断出类型")
        if case .simple(let name, _) = result {
            XCTAssertEqual(name, "String", "字符串字面量应推断为 String")
        } else {
            XCTFail("应为 simple 类型")
        }
    }

    /// 意图：类型推断应能推断布尔字面量类型
    func testTypeInferenceBoolLiteral() {
        let inference = TypeInference()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let expr = Expression.boolLiteral(value: true, location: loc)
        let result = inference.infer(expression: expr)

        XCTAssertNotNil(result, "布尔字面量应能推断出类型")
        if case .simple(let name, _) = result {
            XCTAssertEqual(name, "Bool", "布尔字面量应推断为 Bool")
        } else {
            XCTFail("应为 simple 类型")
        }
    }

    /// 意图：类型推断应能推断浮点字面量类型
    func testTypeInferenceFloatLiteral() {
        let inference = TypeInference()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let expr = Expression.floatLiteral(value: 3.14, location: loc)
        let result = inference.infer(expression: expr)

        XCTAssertNotNil(result, "浮点字面量应能推断出类型")
        if case .simple(let name, _) = result {
            XCTAssertEqual(name, "F64", "浮点字面量应推断为 F64")
        } else {
            XCTFail("应为 simple 类型")
        }
    }

    /// 意图：构造 mismatch 错误后解包验证 expected/got/location 三要素与构造值一致。
    func testTypeErrorMismatch() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let error = TypeError.mismatch(expected: "I32", got: "String", location: loc)

        switch error {
        case .mismatch(let expected, let got, let errorLoc):
            XCTAssertEqual(expected, "I32")
            XCTAssertEqual(got, "String")
            XCTAssertEqual(errorLoc, loc)
        default:
            XCTFail("应为 mismatch")
        }
    }

    /// 意图：类型环境应能在作用域栈中注册和查找变量类型
    func testTypeEnvVariableDefineAndLookup() {
        let env = TypeEnvironment()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let intType = TypeAnnotation.simple(name: "I32", location: loc)

        // 推进性测量：注册后能查到且类型正确
        env.pushScope()
        env.defineVariable(name: "count", type: intType)
        let found = env.lookupVariable(name: "count")
        XCTAssertNotNil(found, "已注册的变量应能查找到")
        guard case .simple(let name, _) = found else {
            XCTFail("变量类型应为 simple")
            return
        }
        XCTAssertEqual(name, "I32", "变量类型应为 I32")

        // 驳回性测量：未注册的变量查不到
        let notFound = env.lookupVariable(name: "nonexistent")
        XCTAssertNil(notFound, "未注册的变量应返回 nil")

        // 驳回性测量：作用域弹出后变量不可见
        env.popScope()
        let afterPop = env.lookupVariable(name: "count")
        XCTAssertNil(afterPop, "作用域弹出后变量应不可见")
    }

    /// 意图：类型环境应能注册和查找函数签名
    func testTypeEnvFunctionDefineAndLookup()  throws {
        let env = TypeEnvironment()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let returnType = TypeAnnotation.simple(name: "I32", location: loc)
        let paramType = TypeAnnotation.simple(name: "I32", location: loc)

        // 推进性测量：注册后能查到且签名正确
        env.defineFunction(name: "increment", params: [paramType], returns: [returnType])
        let result = env.lookupFunction(name: "increment")
        XCTAssertNotNil(result, "已注册的函数应能查找到")
        XCTAssertEqual(result?.params.count, 1, "函数应有 1 个参数")
        XCTAssertEqual(result?.returns.count, 1, "函数应有 1 个返回值")

        // 驳回性测量：未注册的函数查不到
        let notFound = env.lookupFunction(name: "nonexistent")
        XCTAssertNil(notFound, "未注册的函数应返回 nil")
    }

    /// 意图：类型推断应能从类型环境中解析标识符的类型
    func testTypeInferenceIdentifierFromEnvironment()  throws {
        let env = TypeEnvironment()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let intType = TypeAnnotation.simple(name: "I32", location: loc)

        // 推进性测量：环境中有变量时能推断出类型
        env.pushScope()
        env.defineVariable(name: "count", type: intType)
        let inference = TypeInference(environment: env)
        let idExpr = Expression.identifier(name: "count", location: loc)
        let result = inference.infer(expression: idExpr)
        XCTAssertNotNil(result, "标识符应能从环境中推断出类型")
        guard case .simple(let name, _) = result else {
            XCTFail("应为 simple 类型")
            return
        }
        XCTAssertEqual(name, "I32", "标识符 count 应推断为 I32")

        // 驳回性测量：环境中没有的变量返回 nil
        let notFoundExpr = Expression.identifier(name: "nonexistent", location: loc)
        let notFound = inference.infer(expression: notFoundExpr)
        XCTAssertNil(notFound, "未定义的标识符应返回 nil")

        env.popScope()
    }

    /// 意图：类型检查器应检测变量参与运算时的类型不匹配
    func testCheckVariableTypeMismatch() throws {
        let source = try loadPiniFixture("testCheckVariableTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：类型不匹配应抛出错误
        XCTAssertThrowsError(try checker.check(module: module), "变量参与类型不匹配运算应抛出错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：变量类型一致的运算应通过检查
    func testCheckVariableTypeConsistent() throws {
        let source = try loadPiniFixture("testCheckVariableTypeConsistent", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：类型一致不应抛出错误
        XCTAssertNoThrow(try checker.check(module: module), "类型一致的变量运算不应抛出错误")
    }

    /// 意图：类型检查器应能通过函数参数类型检查运算
    func testCheckFunctionParamTypeMismatch() throws {
        let source = try loadPiniFixture("testCheckFunctionParamTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：参数类型一致的函数体应通过检查
        XCTAssertNoThrow(try checker.check(module: module), "参数类型一致的函数不应抛出错误")
    }

    /// 意图：函数返回类型应能推断，调用返回值参与运算时应做类型检查
    func testCheckFunctionCallReturnTypeMismatch() throws {
        let source = try loadPiniFixture("testCheckFunctionCallReturnTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：函数返回值与字符串相加应抛出类型错误
        XCTAssertThrowsError(try checker.check(module: module), "函数返回值与字符串相加应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：带显式返回类型标注的函数应被正确注册
    func testCheckFunctionWithExplicitReturnType() throws {
        let source = try loadPiniFixture("testCheckFunctionWithExplicitReturnType", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：显式类型的函数调用应通过检查
        XCTAssertNoThrow(try checker.check(module: module), "显式类型的函数调用应通过检查")
    }

    /// 意图：结构体字段访问应能推断类型，字段与字符串运算应报错
    func testCheckStructFieldTypeMismatch() throws {
        let source = try loadPiniFixture("testCheckStructFieldTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：结构体字段与字符串运算应抛出类型错误
        XCTAssertThrowsError(try checker.check(module: module), "结构体字段与字符串运算应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：结构体字段类型正确的运算应通过检查
    func testCheckStructFieldTypeCorrect() throws {
        let source = try loadPiniFixture("testCheckStructFieldTypeCorrect", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：同类型字段运算应通过检查
        XCTAssertNoThrow(try checker.check(module: module), "同类型字段运算应通过检查")
    }

    /// 意图：函数中不同 return 的返回类型不一致应报错
    func testCheckInconsistentReturnTypes() throws {
        let source = try loadPiniFixture("testCheckInconsistentReturnTypes", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：返回类型不一致应抛出错误
        XCTAssertThrowsError(try checker.check(module: module), "返回类型不一致应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：赋值给变量的值类型不匹配应检测（变量已有类型时）
    func testCheckAssignmentTypeMismatch() throws {
        let source = try loadPiniFixture("testCheckAssignmentTypeMismatch", filePath: #filePath)
        let module = try parseModule(source)
        let checker = TypeChecker()

        // 推进性测量：赋值类型不匹配应抛出错误
        XCTAssertThrowsError(try checker.check(module: module), "赋值类型不匹配应抛出类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch 错误，实际: \(error)")
                return
            }
        }
    }

    /// 意图：类型环境应能注册结构体字段并按名称查找
    func testTypeEnvStructFieldDefineAndLookup()  throws {
        let env = TypeEnvironment()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let floatType = TypeAnnotation.simple(name: "F64", location: loc)

        // 推进性测量：注册后能查到字段且类型正确
        env.defineStruct(name: "点", fields: [(name: "x", type: intType), (name: "y", type: floatType)])

        let xType = env.lookupField(typeName: "点", fieldName: "x")
        XCTAssertNotNil(xType, "字段 x 应存在")
        guard case .simple(let xName, _) = xType else {
            XCTFail("字段 x 类型应为 simple")
            return
        }
        XCTAssertEqual(xName, "I32", "字段 x 类型应为 I32")

        let yType = env.lookupField(typeName: "点", fieldName: "y")
        XCTAssertNotNil(yType, "字段 y 应存在")
        guard case .simple(let yName, _) = yType else {
            XCTFail("字段 y 类型应为 simple")
            return
        }
        XCTAssertEqual(yName, "F64", "字段 y 类型应为 F64")

        // 驳回性测量：不存在的字段查不到
        let noField = env.lookupField(typeName: "点", fieldName: "z")
        XCTAssertNil(noField, "不存在的字段应返回 nil")

        // 驳回性测量：不存在的类型查不到
        let noType = env.lookupField(typeName: "不存在", fieldName: "x")
        XCTAssertNil(noType, "不存在的类型的字段应返回 nil")
    }

    /// 意图：类型组合声明应与顺序无关
    /// 推进性测量：前向引用和后向引用都应能通过
    /// 驳回性测量：不存在的类型引用应报错
    func testTypeDeclOrderIndependence() throws {
        let source = try loadPiniFixture("testTypeDeclOrderIndependence", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module), "类型声明应与顺序无关")
    }
}
