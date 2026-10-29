import Foundation

/// 单个源文件编译单元：源文件路径 `fileName` 是可见性判定的物理锚点（与 `SourceLocation.fileName` 同源），
/// 后续阶段据此按「文件名 / 目录名 `_` 前缀」算可见性级别；本类型只承载解析结果，不做跨文件解析。
public struct FileUnit: Equatable, ASTNode {
    /// 源文件绝对/相对路径；可见性判定的物理锚点（与 `SourceLocation.fileName` 同源）。
    public let fileName: String
    /// 该文件经 `Parser.parseModule` 解析出的单文件 `Module`。
    public let module: Module

    public var location: SourceLocation { module.location }

    public init(fileName: String, module: Module) {
        self.fileName = fileName
        self.module = module
    }
}

/// 包 = 编译单元集合，用一个或多个 `FileUnit` 包裹，`singleFile(...)` 是单文件模式的入口。
/// 本类型仅做聚合与路径归属：`SemanticAnalyzer` / `TypeChecker` / `Interpreter` 仍吃单文件 `Module`，
/// 跨文件符号解析与可见性 enforce 由上层以 `FileUnit` 集合为输入完成。
public struct Package: Equatable, ASTNode {
    /// 模块名：来自 `pini.toml`，或在无清单时由目录名推导（隐式根模块兜底）。
    public let name: String
    /// 包内所有源文件单元（递归扫描所得，含嵌套 `_` 目录以支持后续包级可见性）。
    public let fileUnits: [FileUnit]

    public var location: SourceLocation {
        fileUnits.first?.location ?? SourceLocation(line: 0, column: 0, fileName: name)
    }

    public init(name: String, fileUnits: [FileUnit]) {
        self.name = name
        self.fileUnits = fileUnits
    }

    /// 向后兼容：单文件世界等价于一个只含 1 个 `FileUnit` 的包。
    public static func singleFile(name: String, fileName: String, module: Module) -> Package {
        return Package(
            name: name,
            fileUnits: [FileUnit(fileName: fileName, module: module)])
    }
}
