import Foundation

/// `import` 块声明：引入一个外部模块并绑定到别名，是唯一的顶级导入形态。
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

/// 条目目标：`pini` 走模块可见性，`c` 走 C 发布面；省略目标即 `pini`。
public enum ExportTarget: Equatable, Sendable {
    case pini
    case c

    /// 目标标识符的两种写法；其余值返回 nil，由解析器给迁移消息。
    public init?(name: String) {
        switch name {
        case "pini": self = .pini
        case "c": self = .c
        default: return nil
        }
    }
}

/// `export` 块的一条：`名|目标 = 原符号`。目标决定左名进哪个命名空间：
/// `|c` 是 C 符号名，`|pini` 是可见性别名；省略 `|目标` 等价于 `|pini`。
public struct ExportEntry: Equatable, ASTNode, Sendable {
    public let name: String
    public let target: ExportTarget
    public let symbol: String
    public let location: SourceLocation

    public init(name: String, target: ExportTarget, symbol: String, location: SourceLocation) {
        self.name = name
        self.target = target
        self.symbol = symbol
        self.location = location
    }
}

/// `export` 块声明：本文件对外发布什么。块头 = 文件名，C 产物与生命周期符号据此命名。
/// `|pini` 条目是可见性逃生舱，`|c` 条目落成 C 符号；两条通道互不影响。
public struct ExportDecl: Equatable, ASTNode, Sendable {
    public let name: String
    public let entries: [ExportEntry]
    public let location: SourceLocation

    public init(name: String, entries: [ExportEntry], location: SourceLocation) {
        self.name = name
        self.entries = entries
        self.location = location
    }
}
