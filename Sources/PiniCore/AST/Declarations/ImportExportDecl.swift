import Foundation

/// `import` 块声明（G52 批 1，2026-08-31）：引入一个外部模块，绑定到别名。
///
/// 语法（唯一顶级形态；裸语句已移除）：
/// ```
/// [当前文件名|import]
/// 别名 = "包路径"
/// ```
/// 块头名 = 当前文件名（去 `.pini` 后缀，解析器校验一致）——自识性标签，
/// 不进访问路径（G52 R4）。别名是静态限定符：`别名.符号` 限定访问，
/// 不参与运行时值命名空间（D-2 静态互斥：本地符号禁止与别名同名）。
public struct ImportDecl: Equatable, ASTNode {
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
public struct ExportRename: Equatable, ASTNode {
 public let alias: String
 public let symbol: String
 public let location: SourceLocation

 public init(alias: String, symbol: String, location: SourceLocation) {
 self.alias = alias
 self.symbol = symbol
 self.location = location
 }
}

/// `export` 块声明（G52 批 1）：显式导出表（覆盖默认可见性规则的逃生舱，
/// 语义 enforce 随可见性定稿表批次落地；本批解析并携带）。
///
/// 语法：
/// ```
/// [当前文件名|export]
/// 可见别名 = 原符号
/// ```
public struct ExportDecl: Equatable, ASTNode {
 public let renames: [ExportRename]
 public let location: SourceLocation

 public init(renames: [ExportRename], location: SourceLocation) {
 self.renames = renames
 self.location = location
 }
}
