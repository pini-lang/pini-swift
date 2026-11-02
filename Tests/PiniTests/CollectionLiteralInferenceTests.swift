import Foundation
import Testing
import PiniSyntax

@testable import PiniBackendLLVM
@testable import PiniCore
@testable import PiniIR
@testable import PiniSemantics

/// 集合字面量的类型由元素给出，不是 `Any`。判据分三面：推断出的类型、作为实参是否被接受、
/// 混合元素是否收敛成 `Array<Any>` 并报不匹配 —— 只测「能通过」的话，把 `Any` 换个名字也能过。
@Suite("集合字面量的类型推断")
struct CollectionLiteralInferenceTests: Sendable, PiniSourceLowering {

    private func variableType(_ name: String, in source: String) throws -> String? {
        let (_, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return checker.typeInference.environment?.lookupVariable(name: name)?.describe()
    }

    @Test("数组字面量的元素类型进入变量，并可作为 [I32] 实参")
    func arrayLiteralKeepsItsElementType() throws {
        let source = #"""
        main|func() -> ():
            let a = [1, 2]
            print(取长(a))
            return

        取长|func(xs: [I32],) -> (I32,):
            return len(xs)
        """#
        #expect(try variableType("a", in: source) == "Array<I32>")
        try typeChecked(source)
    }

    @Test("嵌套数组逐层推断，不是只有最外层是数组")
    func nestedArrayInfersInnerElementType() throws {
        let source = #"""
        main|func() -> ():
            let grid = [[1, 2], [3, 4]]
            print(grid)
            return
        """#
        #expect(try variableType("grid", in: source) == "Array<Array<I32>>")
    }

    @Test("空数组取 I32 —— 与降载器的默认元素类型同一口径")
    func emptyArrayAdoptsTheLowerersDefault() throws {
        let source = #"""
        main|func() -> ():
            let empty = []
            print(len(empty))
            return
        """#
        #expect(try variableType("empty", in: source) == "Array<I32>")
    }

    @Test("集合字面量按元素推断，与数组同一套收敛规则")
    func setLiteralInfersElementType() throws {
        let source = #"""
        main|func() -> ():
            let s = {1, 2, 3}
            print(len(s))
            return
        """#
        #expect(try variableType("s", in: source) == "Set<I32>")
    }

    @Test("混合元素收敛成 Array<Any>，在期望 [I32] 的位置报不匹配")
    func mixedArrayBecomesArrayOfAny() throws {
        let source = #"""
        main|func() -> ():
            let mixed = [1, "x"]
            print(取长(mixed))
            return

        取长|func(xs: [I32],) -> (I32,):
            return len(xs)
        """#
        do {
            _ = try typeChecked(source)
            Issue.record("混合元素应报不匹配，却通过了检查")
        } catch let error as TypeError {
            guard case .mismatch(let expected, let got, _) = error else {
                Issue.record("期望 mismatch，实际为 \(error)")
                return
            }
            #expect(expected == "Array<I32>")
            #expect(got == "Array<Any>")
        }
    }

    @Test("字典字面量分别推断键与值，类型不符时按两个参数报")
    func dictionaryLiteralInfersKeyAndValueTypes() throws {
        let source = #"""
        main|func() -> ():
            let ages = {"Alice" = 30, "Bob" = 25}
            print(取键数(ages))
            return

        取键数|func(ages: {I32: String,},) -> (I32,):
            return len(ages)
        """#
        do {
            _ = try typeChecked(source)
            Issue.record("键值反置应报不匹配，却通过了检查")
        } catch let error as TypeError {
            guard case .mismatch(let expected, let got, _) = error else {
                Issue.record("期望 mismatch，实际为 \(error)")
                return
            }
            #expect(expected == "Dictionary<I32, String>")
            #expect(got == "Dictionary<String, I32>")
        }
    }

    @Test("joinAll 的实参元素不是 Future 时，类型层直接拒绝")
    func joinAllRejectsNonFutureElements() throws {
        let source = #"""
        main|func() -> ():
            var r = joinAll([1, 2])
            return
        """#
        do {
            _ = try typeChecked(source)
            Issue.record("非 Future 元素应报不匹配，却通过了检查")
        } catch let error as TypeError {
            guard case .mismatch(let expected, let got, _) = error else {
                Issue.record("期望 mismatch，实际为 \(error)")
                return
            }
            #expect(expected == "Array<Future<_, _>>")
            #expect(got == "Array<I32>")
        }
    }

    @Test("joinAll 的变量数组走运行时遍历：降载通过，发射出数组盒入口")
    func joinAllVariableArrayUsesTheBoxEntry() throws {
        let source = #"""
        快|func() => (I32,):
            return ok(1)

        main|func() -> ():
            var a = 快()
            var b = 快()
            var xs = [a, b]
            var all = joinAll(xs)
            return
        """#
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let listing = try IREmitter().emit(module: lowered)
        #expect(listing.contains("call i32 @bk_task_join_all_box(ptr"))
        #expect(!listing.contains("call i32 @bk_task_join_all(ptr"))
    }
}
