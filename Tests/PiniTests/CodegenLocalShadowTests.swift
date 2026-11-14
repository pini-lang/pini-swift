import Testing
import PiniSyntax

@testable import PiniIR
@testable import PiniSemantics

/// 降载重推的类型环境按裸名共享持久表：另一个文件的同名局部会顶替本函数的参数。
/// 两个单元的检查顺序是触发条件 —— 参数那份先查，带同名局部的那份后查，持久表留下的才是错答案。
/// 判据是「能降载」而不是「类型猜对」：猜错时这里抛 E6-005，正是缺陷的可见形态。
@Suite("降载期的同名局部")
struct CodegenLocalShadowTests: Sendable {

    private func module(_ source: String, fileName: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return try FrontEnd.passes(module: parsed.module)
    }

    /// 两个编译单元依次检查与降载；`persistAcrossScopesForCodegen` 与 CLI 的 codegen 路径同规。
    private func lowerTwoUnits(_ first: String, _ second: String) throws {
        let units = [
            FileUnit(fileName: "a.pini", module: try module(first, fileName: "a.pini")),
            FileUnit(fileName: "b.pini", module: try module(second, fileName: "b.pini")),
        ]
        let package = Package(name: "shadow", fileUnits: units)
        try SemanticAnalyzer().analyze(package: package)
        let checker = TypeChecker()
        try checker.check(package: package)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        _ = try IRLowerer.lower(package: package, typeInference: checker.typeInference)
    }

    @Test("另一文件的同名局部不顶替本函数的参数类型")
    func sameLocalNameDoesNotLeakAcrossFiles() throws {
        let 参数份 = #"""
        (Item)
        name: String = ""

        复制|func(_out: Array<Item>,) -> (Array<Item>,):
            var result = out
            return result

        main|func() -> ():
            var items: Array<Item> = []
            items = 复制(items)
            print(len(items), len(取首(["x"])))
            return
        """#
        let 局部份 = #"""
        取首|func(_names: Array<String>,) -> (Array<String>,):
            var out: Array<String> = []
            out = out.append(names[0])
            return out
        """#
        try lowerTwoUnits(参数份, 局部份)
    }
}
