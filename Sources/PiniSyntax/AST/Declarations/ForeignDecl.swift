import Foundation

/// 外部符号的一项：名字、类型、标志。类型是函数类型即外部函数，其余即外部数据符号。
/// 名字就是外部符号名，不提供别名——换名字等于盖住外部符号。
public struct ForeignSymbol: Equatable, ASTNode, Sendable {
    public let name: String
    public let annotation: TypeAnnotation
    /// `|` 之后的标志，按书写顺序；取值须在 `knownFlags` 内，重复即错。
    public let flags: [String]
    public let location: SourceLocation

    public init(name: String, annotation: TypeAnnotation, flags: [String] = [], location: SourceLocation) {
        self.name = name
        self.annotation = annotation
        self.flags = flags
        self.location = location
    }

    /// 认识的标志。不在此列的写法在解析期报错，不留到语义期猜。
    public static let knownFlags: [String] = ["readonly", "macro"]

    /// 类型是函数类型即外部函数，其余为外部数据符号。
    public var isFunction: Bool {
        if case .function = annotation { return true }
        return false
    }

    /// 函数型条目的形参类型；非函数型为空。
    public var paramTypes: [TypeAnnotation] {
        if case .function(let params, _, _, _, _) = annotation { return params }
        return []
    }

    /// 函数型条目的返回类型；非函数型为空。
    public var returnTypes: [TypeAnnotation] {
        if case .function(_, let returns, _, _, _) = annotation { return returns }
        return []
    }
}

/// 外部 C 声明块 `[名称|foreign]`：块内是一张外部符号表，条目形如 `名{|标志}: 类型`。
/// 库绑定由块名给出，块内的名字就是外部符号名。
public struct ForeignDecl: Equatable, ASTNode, Sendable {
    /// 块名（`[libc|foreign]` 的 `libc`）——库绑定键，不参与符号解析。
    public let name: String
    /// 外部符号表，按书写顺序。
    public let symbols: [ForeignSymbol]
    public let location: SourceLocation

    public init(name: String, symbols: [ForeignSymbol], location: SourceLocation) {
        self.name = name
        self.symbols = symbols
        self.location = location
    }
}
