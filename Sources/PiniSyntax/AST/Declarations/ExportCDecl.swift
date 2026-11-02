import Foundation

/// `[库|c]` 的一条导出项。等号右端是 Pini 自由函数，冒号右端是给定块类型名；
/// 左端是 C 符号名，导出期过一遍 `CName.escape` 后原样发布。
public enum ExportCItem: Equatable, Sendable {
    case function(cName: String, pinName: String, location: SourceLocation)
    case storage(cName: String, typeName: String, location: SourceLocation)

    public var cName: String {
        switch self {
        case .function(let cName, _, _): return cName
        case .storage(let cName, _, _): return cName
        }
    }

    public var location: SourceLocation {
        switch self {
        case .function(_, _, let location): return location
        case .storage(_, _, let location): return location
        }
    }
}

/// `[库|c]` 声明：把 Pini 自由函数与给定块发布成 C 符号。
/// 块名只命名产物与三个生命周期符号，不参与条目符号名；模块内最多一块。
public struct ExportCDecl: Equatable, ASTNode, Sendable {
    public let name: String
    public let items: [ExportCItem]
    public let location: SourceLocation

    public init(name: String, items: [ExportCItem], location: SourceLocation) {
        self.name = name
        self.items = items
        self.location = location
    }
}
