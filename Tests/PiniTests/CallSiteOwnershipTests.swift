import Foundation
import PiniCore
import Testing

/// 调用点的所有权判据（两条通道各一份）：实参是临时值时，调用方在返回后当场还；实参是变量时一条也不还。
/// 两个方向各一条 —— 只加释放不管借用，借用那条会红；一条都不加，临时那条会红。
/// 判据是「调用之后紧跟什么」，故断言取调用行的下一行，而不是全产物里搜符号。
struct CallSiteOwnershipTests {

    private func lowered(_ source: String) throws -> IRModule {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    private func emitIR(_ source: String) throws -> String {
        IREmitter().emit(module: try lowered(source))
    }

    private func emitC(_ source: String) throws -> String {
        let files = try CEmitter().emit(module: try lowered(source), programName: "t")
        return files.map(\.contents).joined(separator: "\n")
    }

    /// 含 `marker` 的那一行的下一行。标记一律带调用形态的前缀，免得命中的是定义或原型。
    private func lineAfter(_ marker: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.contains(marker) }), index + 1 < lines.count
        else { return nil }
        return lines[index + 1]
    }

    /// 从 `header` 那一行起、按大括号配平切出一个函数体。按块计数而不是找第一个 `}`：
    /// 循环与分支都会在体内再开一层。找不到头 ⇒ nil，判据自己红。
    private func functionBody(_ header: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(header) }) else { return nil }
        var depth = 0
        var body: [String] = []
        for line in lines[start...] {
            body.append(line)
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if depth == 0 { return body.joined(separator: "\n") }
        }
        return nil
    }

    /// 一段制品里某符号出现的次数。
    private func occurrences(_ symbol: String, in text: String) -> Int {
        text.components(separatedBy: symbol).count - 1
    }

    /// 元素取长度：入参是容器句柄，出参是标量 ⇒ 实参位置只搬一个句柄，判据不受别的所有权动作干扰。
    private static let callee = """
        数|func(a: [I32],) -> (I32,):
            return len(a)

        """

    private static let temporaryArgument = callee + """
        main|func() -> ():
            print(数([1, 2, 3]))
            return

        """

    private static let variableArgument = callee + """
        main|func() -> ():
            var a: [I32] = [1, 2, 3]
            print(数(a) + len(a))
            return

        """

    @Test("临时容器实参：LLVM 通道在调用之后紧跟一句句柄释放")
    func llvmReleasesTemporaryArgument() throws {
        let next = try #require(
            lineAfter("= call i32 @_u6570(", in: try emitIR(Self.temporaryArgument)))
        #expect(next.contains("call void @bk_array_destroy(ptr"))
    }

    @Test("临时容器实参：C 通道在调用之后紧跟一句句柄释放")
    func cReleasesTemporaryArgument() throws {
        let next = try #require(
            lineAfter("= pini__u6570(", in: try emitC(Self.temporaryArgument)))
        #expect(next.contains("bk_array_destroy("))
    }

    @Test("变量容器实参：两条通道都不在调用点释放（份额归调用方，仍可再读）")
    func borrowsVariableArgument() throws {
        let ir = try emitIR(Self.variableArgument)
        let afterIRCall = try #require(lineAfter("= call i32 @_u6570(", in: ir))
        #expect(!afterIRCall.contains("@bk_array_destroy"))
        let irMain = try #require(functionBody("define i32 @main", in: ir))
        /// 主函数里恰好一次释放：`a` 自己的作用域退出那一次，调用点一次也没有。
        #expect(occurrences("@bk_array_destroy", in: irMain) == 1)

        let c = try emitC(Self.variableArgument)
        let cMain = try #require(functionBody("int main(void)", in: c))
        let afterCCall = try #require(lineAfter("pini__u6570(", in: cMain))
        #expect(!afterCCall.contains("bk_array_destroy("))
        #expect(occurrences("bk_array_destroy(", in: cMain) == 1)
    }
}
