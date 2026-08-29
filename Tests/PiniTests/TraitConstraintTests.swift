import XCTest
import PiniCore
import Foundation

/// trait 约束求解（类型层）。
/// 驱动链路：Lexer → Parser → TypeChecker.checkCollecting(module:)，与 CLI `pini check` 同构。
final class TraitConstraintTests: XCTestCase {

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    // MARK: - 内建特征 collection（ADR-020 步骤 A 声明面）

    /// 意图：宿主预注册的 `collection` 特征对用户类型可用——
    /// 提供 6 个抽象方法（len/contains/append/pop/slice/join）的用户类型可通过
    /// verifyTraitConformance 严格校验（内建 String/Array 为标记式登记，不走此路径）。
    /// 推进性测量：整个模块零类型错误。
    func testBuiltinCollectionTraitConformanceSatisfied() throws {
        let source = """
(袋子)
    实现: collection

((袋子))
    len|self() -> (I32,)
        return 0
    contains|self(v: I32,) -> (Bool,)
        return false
    append|self(v: I32,) -> (I32,)
        return 0
    pop|self() -> (I32,)
        return 0
    slice|self(a: I32, b: I32,) -> (I32,)
        return 0
    join|self(sep: I32,) -> (I32,)
        return 0

main|func() -> ()
    return
"""
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "补齐 6 方法的类型应通过 collection 校验，实际: \(diagnostics)")
    }

    /// 意图：collection 为严格抽象特征——缺任一抽象方法即报
    /// traitRequirementNotSatisfied（与用户声明特征同语义）。
    /// 驳回性测量：缺 len 时应命中该方法缺失诊断。
    func testBuiltinCollectionTraitMissingMethodRejected() throws {
        let source = """
(袋子)
    实现: collection

((袋子))
    contains|self(v: I32,) -> (Bool,)
        return false

main|func() -> ()
    return
"""
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .traitRequirementNotSatisfied(typeName: "袋子", traitName: "collection", methodName: "len", _) = $0 {
                return true
            }
            return false
        }
        XCTAssertTrue(hit, "缺 len 应报 traitRequirementNotSatisfied，实际: \(diagnostics)")
    }

    /// 意图：类型声明实现 trait 且提供了抽象方法，且 `obj.traitMethod()` 成员调用能过类型检查。
    /// 推进性测量：整个模块零类型错误。
    /// 驳回性测量：若 trait 方法未注册为可见方法，成员调用会落入不匹配分支而报错。
    func testConformanceSatisfiedAndMemberCallVisible() throws {
        let source = """
        <Greetable>
            greet(self) -> (String,)
                return "默认"

        (Dog)
            名称: String = "Rex"
            实现: Greetable

        ((Dog))
            greet|self() -> (String,)
                return "woof"

        main|func() -> ()
            var dog = Dog()
            var g = dog.greet()
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "满足 trait 约束且成员调用应无类型错误，实际: \(diagnostics)")
    }

    /// 意图：类型声明实现 trait 但漏掉抽象方法，类型层必须报 traitRequirementNotSatisfied。
    /// 推进性测量：诊断含 (typeName: "Cat", traitName: "Greetable", methodName: "greet")。
    /// 驳回性测量：若 verifyTraitConformance 不查抽象方法，此测试会失败（漏报）。
    func testMissingAbstractMethodReported() throws {
        let source = """
        <Greetable>
            greet(self) -> (String,)

        (Cat)
            名称: String = "Tom"
            实现: Greetable

        main|func() -> ()
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .traitRequirementNotSatisfied(typeName: "Cat", traitName: "Greetable", methodName: "greet", _) = $0 {
                return true
            }
            return false
        }
        XCTAssertTrue(hit, "漏实现抽象方法应报 traitRequirementNotSatisfied，实际: \(diagnostics)")
    }

    /// 意图：trait 方法返回类型用 `own`（G50 更名），实现方法返回具体类型，约束求解不应误判。
    /// 推进性测量：整个模块零类型错误（own 被正确替换为实现类型）。
    /// 驳回性测量：若 own 被当字面类型名比较，isAssignable(点, own) 失败会误报 mismatch。
    func testSelfReturnTypeConformance() throws {
        let source = """
        <可克隆>
            克隆(self) -> (own,)

        (点)
            x: I32 = 0
            实现: 可克隆

        ((点))
            克隆|self() -> (点,)
                return 点()

        main|func() -> ()
            var p = 点()
            var q = p.克隆()
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "own 返回类型约束应不误判，实际: \(diagnostics)")
    }

    /// 意图：实现方法返回类型与 trait 要求（own 替换后）不符，类型层必须报 traitMethodSignatureMismatch。
    /// 推进性测量：诊断含 (typeName: "点", traitName: "可克隆", methodName: "克隆")。
    /// 驳回性测量：若返回类型比对缺失，此测试会失败（漏报）。
    func testReturnTypeMismatchReported() throws {
        let source = """
        <可克隆>
            克隆(self) -> (own,)

        (点)
            x: I32 = 0
            实现: 可克隆

        ((点))
            克隆|self() -> (String,)
                return ""

        main|func() -> ()
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .traitMethodSignatureMismatch(typeName: "点", traitName: "可克隆", methodName: "克隆", _, _) = $0 {
                return true
            }
            return false
        }
        XCTAssertTrue(hit, "返回类型不符应报 traitMethodSignatureMismatch，实际: \(diagnostics)")
    }

    /// 意图：trait **默认实现**（带 body）返回 `own` 时，经 registerTraitMethods 以具体类型
    /// 替换后注册为可见方法——`p.克隆()` 成员调用类型检查通过且返回具体类型。
    /// 推进性测量：整个模块零类型错误。
    /// 驳回性测量：若默认实现的 own 未替换，成员调用会落「未注册方法」报错。
    func testSelfReturnTypeInDefaultImplementation() throws {
        let source = """
        <可克隆>
            克隆(self) -> (own,)
                return 点()

        (点)
            x: I32 = 0
            实现: 可克隆

        main|func() -> ()
            var p = 点()
            var q = p.克隆()
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "默认实现返回 own 应经具体类型替换后注册，实际: \(diagnostics)")
    }
}
