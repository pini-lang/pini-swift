import XCTest
@testable import PiniCore

final class GenericTypeTests: XCTestCase {

    private func makeLoc() -> SourceLocation {
        SourceLocation(line: 1, column: 1, fileName: "test.pini")
    }

    // MARK: - TypeEnvironment 泛型模板

    /// 意图：定义泛型结构体「容器<T>」后以 I32 特化查找字段「值」，验证特化字段类型变为 simple(I32)。
    func testTypeEnvironmentDefineAndLookupGeneric() {
        let env = TypeEnvironment()
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)

        env.defineGenericStruct(
            name: "容器",
            genericParams: ["T"],
            fields: [("值", tType)]
        )

        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let fieldType = env.lookupSpecializedField(
            typeName: "容器",
            typeArgs: [intType],
            fieldName: "值"
        )

        guard let field = fieldType else {
            XCTFail("特化后的字段应能查找到")
            return
        }
        guard case .simple(let name, _) = field else {
            XCTFail("字段类型应为 simple")
            return
        }
        XCTAssertEqual(name, "I32", "特化后 T 应变为 I32")
    }

    /// 意图：对未注册的泛型类型名执行特化字段查找，验证错误路径返回 nil。
    func testTypeEnvironmentLookupNonexistentGeneric() {
        let env = TypeEnvironment()
        let loc = makeLoc()
        let intType = TypeAnnotation.simple(name: "I32", location: loc)

        let result = env.lookupSpecializedField(
            typeName: "不存在",
            typeArgs: [intType],
            fieldName: "值"
        )

        XCTAssertNil(result, "未注册的泛型类型应返回 nil")
    }

    /// 意图：泛型「容器」声明 1 个类型参数却传入 2 个类型实参，验证参数数量不匹配时返回 nil。
    func testTypeEnvironmentLookupWrongArity() {
        let env = TypeEnvironment()
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)

        env.defineGenericStruct(
            name: "容器",
            genericParams: ["T"],
            fields: [("值", tType)]
        )

        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let strType = TypeAnnotation.simple(name: "String", location: loc)
        let result = env.lookupSpecializedField(
            typeName: "容器",
            typeArgs: [intType, strType],
            fieldName: "值"
        )

        XCTAssertNil(result, "类型参数数量不匹配时应返回 nil")
    }

    /// 意图：泛型「容器」特化为 I32 后查找不存在的字段名，验证错误路径返回 nil。
    func testTypeEnvironmentLookupGenericNonexistentField() {
        let env = TypeEnvironment()
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)

        env.defineGenericStruct(
            name: "容器",
            genericParams: ["T"],
            fields: [("值", tType)]
        )

        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let result = env.lookupSpecializedField(
            typeName: "容器",
            typeArgs: [intType],
            fieldName: "不存在"
        )

        XCTAssertNil(result, "不存在的字段应返回 nil")
    }

    // MARK: - TypeInference 泛型成员推断

    /// 意图：通过 TypeInference 推断「容器<I32>」变量成员访问 c.值 的类型，验证特化后推断为 simple(I32)。
    func testGenericMemberTypeInference() {
        let loc = makeLoc()
        let env = TypeEnvironment()
        let tType = TypeAnnotation.simple(name: "T", location: loc)

        env.defineGenericStruct(
            name: "容器",
            genericParams: ["T"],
            fields: [("值", tType)]
        )

        let inference = TypeInference(environment: env)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let genericType = TypeAnnotation.generic(name: "容器", params: [intType], location: loc)

        let memberExpr = Expression.member(
            object: .identifier(name: "c", location: loc),
            name: "值",
            location: loc
        )

        env.defineVariable(name: "c", type: genericType)

        let result = inference.infer(expression: memberExpr)
        guard let r = result else {
            XCTFail("泛型成员访问应能推断类型")
            return
        }
        guard case .simple(let name, _) = r else {
            XCTFail("推断结果应为 simple 类型")
            return
        }
        XCTAssertEqual(name, "I32", "特化后字段类型应为 I32")
    }

    /// 意图：对非泛型 simple 类型变量访问不存在的成员 x.foo，验证错误路径推断返回 nil。
    func testGenericMemberInferenceOnNonGeneric() {
        let loc = makeLoc()
        let env = TypeEnvironment()
        let inference = TypeInference(environment: env)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)

        env.defineVariable(name: "x", type: intType)

        let memberExpr = Expression.member(
            object: .identifier(name: "x", location: loc),
            name: "foo",
            location: loc
        )

        let result = inference.infer(expression: memberExpr)
        XCTAssertNil(result, "simple 类型的成员访问若无匹配应返回 nil")
    }

    // MARK: - TypeChecker 泛型声明

    /// 意图：用完整源码管线（词法→解析→类型检查）验证单类型参数泛型结构体「容器<T>」声明通过检查不抛错。
    func testTypeCheckerRegistersGenericStruct() throws {
        let source = try loadPiniFixture("testTypeCheckerRegistersGenericStruct", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()

        XCTAssertNoThrow(try checker.check(module: module), "泛型结构体定义应通过检查")
    }

    /// 意图：用完整源码管线验证多类型参数泛型结构体「对<T, U>」声明通过检查不抛错。
    func testTypeCheckerGenericMultipleParams() throws {
        let source = try loadPiniFixture("testTypeCheckerGenericMultipleParams", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()

        XCTAssertNoThrow(try checker.check(module: module), "多类型参数泛型应通过检查")
    }
}
