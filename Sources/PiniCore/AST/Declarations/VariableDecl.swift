import Foundation

/// 顶级声明枚举
public enum TopLevelDecl: Equatable {
 case structDecl(StructDecl)
 case objectDecl(ObjectDecl)
 case enumDecl(EnumDecl)
 case funcDecl(FuncDecl)
 case traitDecl(TraitDecl)
 /// ADR-016 规则 3.2/3.14（ extension-decl）：扩展块 `((T))`/`{{T}}`/`[[T]]`/`<<T>>`，
 /// 承载类型的 `|self`/`|Self` 方法（数据与逻辑分离）。
 case extensionDecl(ExtensionDecl)
 /// Phase 2a（ADR-015 FFI， foreign-decl）：外部 C 函数声明块 `[名称|foreign]`。
 case foreignDecl(ForeignDecl)
 case varDecl(Statement)
 case statement(Statement)
 case importDecl(ImportDecl)
 case exportDecl(ExportDecl)
}

/// 模块
public struct Module: Equatable, ASTNode {
 public let declarations: [TopLevelDecl]
 /// P4 模块化：原始 `import` 声明（仅暂存，不解析 / 不 enforce）。
 public let imports: [ImportDecl]
 /// P4 模块化：原始 `export` 声明（仅暂存，不解析 / 不 enforce）。
 public let exports: [ExportDecl]
 public let location: SourceLocation

 public init(declarations: [TopLevelDecl],
 imports: [ImportDecl] = [],
 exports: [ExportDecl] = [],
 location: SourceLocation) {
 self.declarations = declarations
 self.imports = imports
 self.exports = exports
 self.location = location
 }
}
