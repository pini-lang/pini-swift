import Foundation
import Testing
import PiniSyntax

@testable import PiniBackendEmbedded
@testable import PiniBackendKit
@testable import PiniCore
@testable import PiniIR
@testable import PiniSemantics

/// 试点通道的三条判据：清单正好是声明的那 26 条、声明支持的族真能发射、声明之外的节点按族拒绝。
/// 判据盯的是「声明与实现不漂移」，不是覆盖率 —— 覆盖率由能力矩阵那张表说话。
@Suite("试点后端 embedded_min")
struct EmbeddedMinBackendTests: Sendable, PiniSourceLowering {

    private func listing(_ source: String) throws -> String {
        try EmbeddedMinBackend().emit(module: try lowered(source))
    }

    /// 一条走遍全部语法的语料：算术六则 · 比较六种 · 变量 · 调用 · 分支 · 循环 · 字符串 · 断言。
    private let tour = """
        add|func(a: I32, b: I32) -> (I32,):
            return a + b

        main|func() -> ():
            var a = 6
            var b = 4
            var c = a + b
            c = a - b
            c = a * b
            c = a / b
            c = a % b
            c = -a
            var t = true
            t = !t
            t = a == b
            t = a != b
            t = a < b
            t = a <= b
            t = a > b
            t = a >= b
            c = add(a, b)
            if t:
                print(c)
            while t:
                break
            var s = "a" + "b"
            print("v: " + s)
            assert(a > 0, "a 应为正")
        """

    @Test("清单正好 26 条，助记符不重复")
    func theOpcodeSetIsTheWholeProfile() {
        #expect(EmbeddedMinOpcode.count == 26)
        let names = EmbeddedMinOpcode.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(Set(names) == Set(["LOADK", "LOADVAR", "STOREVAR", "ADD", "SUB", "MUL", "DIV", "MOD",
                                   "NEG", "NOT", "EQ", "NE", "LT", "LE", "GT", "GE", "JUMP", "JUMPIF",
                                   "JUMPIFNOT", "CALL", "RET", "HALT", "PANIC", "CONCAT", "TOSTR", "PRINT"]))
    }

    @Test("一条语料用满 26 条指令 —— 清单里没有死指令")
    func theTourProgramUsesEveryOpcode() throws {
        let text = try listing(tour)
        var used: Set<String> = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("  ") else { continue }
            let token = line.dropFirst(2).prefix { $0 != " " && $0 != "," }
            guard !token.isEmpty, token.allSatisfy({ $0.isUppercase }) else { continue }
            used.insert(String(token))
        }
        #expect(used == Set(EmbeddedMinOpcode.allCases.map(\.rawValue)))
    }

    @Test("同一模块两次发射逐字节相同")
    func theListingIsDeterministic() throws {
        #expect(try listing(tour) == (try listing(tour)))
    }

    @Test("声明支持的族：能力表说支持，样例就真能发射")
    func declaredFamiliesEmit() throws {
        let capabilities = EmbeddedMinBackend.capabilities
        #expect(capabilities.output == .bytecode)
        #expect(capabilities.supported == [.scalars, .variablesAndOperators, .controlFlow, .calls, .strings])
        #expect(capabilities.unsupported.count == 9)
        #expect(!(try listing(tour)).isEmpty)
    }

    @Test("声明之外的节点按族拒绝，并写明节点与原因")
    func outOfProfileNodesAreRejectedByFamily() throws {
        let cases: [(String, BackendCapabilities.Family)] = [
            ("main|func() -> ():\n    var xs = [1, 2]\n    print(len(xs))\n", .collections),
            ("main|func() -> ():\n    let c = 圆(2.0,)\n    return\n\n[形状]\n圆(F64,)\n", .nominals),
            ("main|func() -> ():\n    var f = func (n: I32) -> (I32,):\n        return n\n    print(f(1))\n", .calls),
            ("main|func() -> ():\n    var s = readFile(\"nope.txt\")\n    print(s)\n", .fileIO),
        ]
        for (source, family) in cases {
            do {
                _ = try listing(source)
                Issue.record("应当拒绝属于 \(family.rawValue) 的节点，却发射成功")
            } catch let error as BackendError {
                #expect(error.family == family)
                #expect(!error.node.isEmpty)
                #expect(!error.reason.isEmpty)
            }
        }
    }
}
