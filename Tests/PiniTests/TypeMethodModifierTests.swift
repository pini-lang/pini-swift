import Testing
import PiniSyntax

/// `|own` 是扩展块内「本型方法」的修饰符，与 `|self` 并列；它同时是类型内自指关键字。
/// 两处共用一名，写法一旦换词，扩展块预判就认不出方法头，会把方法当自由函数放走。
/// 本件钉住名字与落点：方法必须留在扩展块内，修饰符原样到 AST。
struct TypeMethodModifierTests {

    /// 解析一段源码，取其中扩展块的方法。
    private func extensionMethods(_ source: String) throws -> [FuncDecl] {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let module = try Parser(tokens: try lexer.tokenize(), fileName: "inline.pini").parseModule()
        return module.declarations.flatMap { decl -> [FuncDecl] in
            guard case .extensionDecl(let ext) = decl else { return [] }
            return ext.methods
        }
    }

    @Test("扩展块内 `|own` 不被当作自由函数，修饰符原样保留")
    func ownModifierStaysInExtension() throws {
        let source = #"""
        (点)
        x: F64 = 0.0

        ((点))
        原点|own() -> (F64,):
            return 0.0
        """#
        let methods = try extensionMethods(source)
        #expect(methods.count == 1, "`|own` 方法应留在扩展块内")
        #expect(methods.first?.modifiers == ["own"])
    }
}
