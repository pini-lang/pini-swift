import Foundation
import Testing

@testable import PiniCore

/// 内建清单的三个判据：符号唯一、声明由签名拼出、发射器调用到的符号都带声明。
@Suite("内建清单")
struct BuiltinInventoryTests: Sendable {

    private func lowered(_ source: String) throws -> IRModule {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    @Test("符号唯一，每条都有降级点，族名可枚举")
    func theInventoryIsAKeyedTable() {
        let symbols = Builtins.all.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        for spec in Builtins.all {
            #expect(!spec.lowerings.isEmpty, "\(spec.symbol) 没有降级点")
            #expect(BuiltinSpec.Family.allCases.contains(spec.family))
        }
    }

    @Test("声明行由签名拼出，查不到符号时返回 nil")
    func declarationsFollowTheirSignatures() throws {
        for spec in Builtins.all {
            let line = spec.declaration
            #expect(line.hasPrefix("declare \(spec.signature.result) @\(spec.symbol)("))
            #expect(line.hasSuffix("\n"))
        }
        let panic = try #require(Builtins.spec(for: "bk_panic"))
        #expect(panic.declaration.contains(") noreturn"))
        #expect(Builtins.spec(for: "bk_nope") == nil)
    }

    /// 一条调用若没有对应声明，LLVM 要到 clang 才报「use of undefined value」。
    /// 本用例用一份含数组、字典、字符串与内建的语料，把调用集与声明集对齐。
    @Test("发射器调用到的每个 bk_* 都在模块里声明过")
    func everyCallIsDeclared() throws {
        let module = try lowered(
            #"""
            main|func() -> ():
                let xs: Array<I32> = [1, 2, 3]
                let names = ["a" = 1, "b" = 2]
                var total = 0
                for (x,) in xs:
                    total = total + x
                let s = "pini"
                print(s.upper(), s.substring(0, 2), len(xs), len(names), total)
                return
            """#)
        let ir = IREmitter().emit(module: module)
        let called = Self.symbols(in: ir) { $0.contains("call ") }
        let declared = Self.symbols(in: ir) { $0.hasPrefix("declare ") }
        #expect(!called.isEmpty)
        #expect(called.subtracting(declared).isEmpty, "调用了没有声明的符号")
    }

    /// 取消一度降成裸 `@cancel`：符号名拼对了才叫接线，拼错要等到 clang 才报。
    @Test("取消落到运行时符号，不是裸名字")
    func cancelBindsTheRuntimeSymbol() throws {
        let module = try lowered(
            #"""
            慢|func() => (I32,):
                return ok(1)

            main|func() -> ():
                var t = 慢()
                t.cancel()
                return
            """#)
        let ir = IREmitter().emit(module: module)
        #expect(ir.contains("@bk_task_cancel("))
        #expect(!ir.contains("@cancel("))
    }

    private static func symbols(in ir: String, where predicate: (String) -> Bool) -> Set<String> {
        var found: Set<String> = []
        for line in ir.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard predicate(text) else { continue }
            var cursor = text.startIndex
            while cursor < text.endIndex, let at = text[cursor...].firstIndex(of: "@") {
                var index = text.index(after: at)
                var name = ""
                while index < text.endIndex,
                    text[index].isLetter || text[index].isNumber || text[index] == "_"
                {
                    name.append(text[index])
                    index = text.index(after: index)
                }
                if name.hasPrefix("bk_") { found.insert(name) }
                cursor = index
            }
        }
        return found
    }
}
