import XCTest
@testable import PiniCore

final class TypeSubstitutorTests: XCTestCase {

    private func makeLoc() -> SourceLocation {
        SourceLocation(line: 1, column: 1, fileName: "test.pini")
    }

    /// 意图：验证绑定中匹配的类型参数 T 被替换为 I32（匹配参数替换成功路径）。
    func testSubstituteSimpleMatchingParam() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let subst = TypeSubstitutor(bindings: ["T": intType])

        let result = subst.substitute(type: tType)

        guard case .simple(let name, _) = result else {
            XCTFail("替换结果应为 simple 类型")
            return
        }
        XCTAssertEqual(name, "I32", "匹配的类型参数应被替换")
    }

    /// 意图：验证未出现在绑定中的类型参数 U 替换后保持原名不变。
    func testSubstituteSimpleNonMatching() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "U", location: loc)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let subst = TypeSubstitutor(bindings: ["T": intType])

        let result = subst.substitute(type: tType)

        guard case .simple(let name, _) = result else {
            XCTFail("替换结果应为 simple 类型")
            return
        }
        XCTAssertEqual(name, "U", "不匹配的类型参数应保持不变")
    }

    /// 意图：验证 tuple 各元素按绑定逐一替换（T→I32、U→String），元素数量保持不变。
    func testSubstituteTuple() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)
        let uType = TypeAnnotation.simple(name: "U", location: loc)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let strType = TypeAnnotation.simple(name: "String", location: loc)
        let tupleType = TypeAnnotation.tuple(labels: [], elements: [tType, uType], location: loc)
        let subst = TypeSubstitutor(bindings: ["T": intType, "U": strType])

        let result = subst.substitute(type: tupleType)

        guard case .tuple(_, let elements, _) = result else {
            XCTFail("替换结果应为 tuple 类型")
            return
        }
        XCTAssertEqual(elements.count, 2, "tuple 元素数量应保持不变")
        guard case .simple(let n1, _) = elements[0],
              case .simple(let n2, _) = elements[1] else {
            XCTFail("tuple 元素都应为 simple 类型")
            return
        }
        XCTAssertEqual(n1, "I32", "第一个元素应被替换")
        XCTAssertEqual(n2, "String", "第二个元素应被替换")
    }

    /// 意图：验证泛型类型名保持不变、泛型参数 T 被替换为 I32（参数数量不变）。
    func testSubstituteGenericParams() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let genericType = TypeAnnotation.generic(name: "Optional", params: [tType], location: loc)
        let subst = TypeSubstitutor(bindings: ["T": intType])

        let result = subst.substitute(type: genericType)

        guard case .generic(let name, let params, _) = result else {
            XCTFail("替换结果应为 generic 类型")
            return
        }
        XCTAssertEqual(name, "Optional", "泛型名称应保持不变")
        XCTAssertEqual(params.count, 1, "泛型参数数量应保持不变")
        guard case .simple(let pname, _) = params[0] else {
            XCTFail("泛型参数应为 simple 类型")
            return
        }
        XCTAssertEqual(pname, "I32", "泛型参数应被替换")
    }

    /// 意图：验证函数类型参数 T 被替换为 I32，未绑定的返回类型 String 保持不变。
    func testSubstituteFunctionType() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let strType = TypeAnnotation.simple(name: "String", location: loc)
        let funcType = TypeAnnotation.function(params: [tType], returns: [strType], captured: [], location: loc)
        let subst = TypeSubstitutor(bindings: ["T": intType])

        let result = subst.substitute(type: funcType)

        guard case .function(let params, let returns, _, _) = result else {
            XCTFail("替换结果应为 function 类型")
            return
        }
        XCTAssertEqual(params.count, 1, "参数数量应保持不变")
        guard case .simple(let pname, _) = params[0] else {
            XCTFail("参数应为 simple 类型")
            return
        }
        XCTAssertEqual(pname, "I32", "参数类型应被替换")
        guard case .simple(let rname, _) = returns[0] else {
            XCTFail("返回类型应为 simple")
            return
        }
        XCTAssertEqual(rname, "String", "未绑定的返回类型应保持不变")
    }

    /// 意图：验证空绑定（无任何替换映射）时类型 T 保持原样。
    func testSubstituteEmptyBindings() {
        let loc = makeLoc()
        let tType = TypeAnnotation.simple(name: "T", location: loc)
        let subst = TypeSubstitutor(bindings: [:])

        let result = subst.substitute(type: tType)

        guard case .simple(let name, _) = result else {
            XCTFail("结果应为 simple 类型")
            return
        }
        XCTAssertEqual(name, "T", "空绑定时类型应保持不变")
    }
}
