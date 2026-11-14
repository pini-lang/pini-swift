import Foundation
import PiniSyntax

/// 符号
/// 用于语义分析阶段的符号表条目
public struct Symbol {
    public let name: String
    public let kind: SymbolKind
    public let location: SourceLocation

    public init(name: String, kind: SymbolKind, location: SourceLocation) {
        self.name = name
        self.kind = kind
        self.location = location
    }
}

/// 符号种类
public enum SymbolKind: Equatable, Sendable {
    case variable(isMutable: Bool)
    case function
    case `struct`
    case `object`
    case `enum`
    case `enumCase`
    case trait
    case parameter
    /// 外部 C 符号：名字即符号名，跨文件可见。种类单列是为了让包级索引区分
    /// 「同型合并」与「重声明」——前者只对外部符号成立。
    case foreignSymbol
}
