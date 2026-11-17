import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// 赋值位的自追加形态走消费路径：槽位清空后数组只剩一份引用，追加就地增长。
/// 判据分两层：自追加必须命中快路（用命中计数，不拿耗时作准）；命中之后值语义与别名隔离一条不许变。
@Suite(.serialized)
struct ConsumingAppendTests: Sendable, PiniSourceLowering {

    private func run(_ source: String) throws -> [String] {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    @Test("变量自追加命中消费路径")
    func varSelfAppendHitsConsumingPath() throws {
        RuntimeOps.consumingAppendHits = 0
        let lines = try run(
            #"""
            main|func() -> ():
                var xs: Array<I32> = []
                var i = 0
                while i < 1000:
                    xs = xs.append(i)
                    i = i + 1
                print(len(xs))
                return
            """#)
        #expect(lines == ["1000"])
        #expect(RuntimeOps.consumingAppendHits >= 900)
    }

    @Test("字段自追加命中消费路径")
    func fieldSelfAppendHitsConsumingPath() throws {
        RuntimeOps.consumingAppendHits = 0
        let lines = try run(
            #"""
            (框)
            xs: Array<I32> = []

            main|func() -> ():
                var 盒 = 框()
                var i = 0
                while i < 1000:
                    盒.xs = 盒.xs.append(i)
                    i = i + 1
                print(len(盒.xs))
                return
            """#)
        #expect(lines == ["1000"])
        #expect(RuntimeOps.consumingAppendHits >= 900)
    }

    @Test("消费路径不破值语义")
    func consumingKeepsValueSemantics() throws {
        let lines = try run(
            #"""
            main|func() -> ():
                var a: Array<I32> = [1]
                var b = a
                a = a.append(2)
                print(len(a))
                print(len(b))
                return
            """#)
        #expect(lines == ["2", "1"])
    }

    @Test("元素先求值再清槽")
    func elementIsEvaluatedBeforeSlotIsCleared() throws {
        let lines = try run(
            #"""
            main|func() -> ():
                var xs: Array<I32> = [7]
                xs = xs.append(len(xs))
                print(len(xs))
                print(xs[1])
                return
            """#)
        #expect(lines == ["2", "1"])
    }
}
