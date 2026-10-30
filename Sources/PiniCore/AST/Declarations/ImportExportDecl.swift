import Foundation

/// `import` 块声明：引入一个外部模块并绑定到别名，是唯一的顶级导入形态（裸语句已移除）。
/// 块头名 = 当前文件名（去 `.pini` 后缀，解析器校验一致），属自识性标签，不进访问路径。
/// 别名是静态限定符（`别名.符号`），不参与运行时值命名空间；本地符号禁止与别名同名。
public struct ImportDecl: Equatable, ASTNode, Sendable {
    /// import 别名（静态限定符，`别名.符号` 的前缀）。
    public let alias: String
    /// 被引入模块的包路径（相对当前文件目录或绝对路径）。
    public let packagePath: String
    public let location: SourceLocation

    public init(alias: String, packagePath: String, location: SourceLocation) {
        self.alias = alias
        self.packagePath = packagePath
        self.location = location
    }
}

/// `export` 块中的重命名导出项：`可见别名 = 原符号`。
public struct ExportRename: Equatable, ASTNode, Sendable {
    public let alias: String
    public let symbol: String
    public let location: SourceLocation

    public init(alias: String, symbol: String, location: SourceLocation) {
        self.alias = alias
        self.symbol = symbol
        self.location = location
    }
}

/// `export` 块声明：显式导出表，用可见别名覆盖默认的可见性推导规则，是可见性规则的逃生舱。
/// 绑定表随 AST 携带；跨模块导出的语义 enforce 不在解析层，由可见性定稿表决定。
public struct ExportDecl: Equatable, ASTNode, Sendable {
    public let renames: [ExportRename]
    public let location: SourceLocation

    public init(renames: [ExportRename], location: SourceLocation) {
        self.renames = renames
        self.location = location
    }
}
