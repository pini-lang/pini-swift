import Foundation

/// 单个源文件编译单元：源文件路径 `fileName` 是可见性判定的物理锚点（与 `SourceLocation.fileName` 同源），
/// 后续阶段据此按「文件名 / 目录名 `_` 前缀」算可见性级别；本类型只承载解析结果，不做跨文件解析。
public struct FileUnit: Equatable, ASTNode, Sendable {
    /// 源文件绝对/相对路径；可见性判定的物理锚点（与 `SourceLocation.fileName` 同源）。
    public let fileName: String
    /// 该文件经 `Parser.parseModule` 解析出的单文件 `Module`。
    public let module: Module
    /// 该文件的词法警告：不阻断编译，随单元一起交给调用方决定怎么呈现。
    public let warnings: [LexerWarning]

    public var location: SourceLocation { module.location }

    public init(fileName: String, module: Module, warnings: [LexerWarning] = []) {
        self.fileName = fileName
        self.module = module
        self.warnings = warnings
    }
}

/// 包 = 编译单元集合，用一个或多个 `FileUnit` 包裹，`singleFile(...)` 是单文件模式的入口。
/// 本类型仅做聚合与路径归属：`SemanticAnalyzer` / `TypeChecker` / `Interpreter` 仍吃单文件 `Module`，
/// 跨文件符号解析与可见性 enforce 由上层以 `FileUnit` 集合为输入完成。
public struct Package: Equatable, ASTNode, Sendable {
    /// 模块名：来自 `pini.toml`，或在无清单时由目录名推导（隐式根模块兜底）。
    public let name: String
    /// 包内所有源文件单元（递归扫描所得，含嵌套 `_` 目录以支持后续包级可见性）。
    public let fileUnits: [FileUnit]
    /// 包根的规范路径；可见性用它把绝对文件名换成包根相对路径。
    public let rootPath: String?
    /// 已登记但不产符号的名字与原因（生成面的宏跳过项）。名字解析失败时先查它，
    /// 命中即报「头文件里有、翻译没产出」，不退回泛泛的未定义名。
    public let unavailableNames: [String: String]

    public var location: SourceLocation {
        fileUnits.first?.location ?? SourceLocation(line: 0, column: 0, fileName: name)
    }

    /// 包内全部词法警告，按文件单元顺序拼接。跨文件去重没有意义：每条警告都属于各自文件的位置。
    public var warnings: [LexerWarning] {
        fileUnits.flatMap { $0.warnings }
    }

    public init(
        name: String, fileUnits: [FileUnit], rootPath: String? = nil,
        unavailableNames: [String: String] = [:]
    ) {
        self.name = name
        self.fileUnits = fileUnits
        self.rootPath = rootPath
        self.unavailableNames = unavailableNames
    }

    /// 可见性只消费包内路径；无包根的内存包退到文件名，保持既有行为。
    public func relativeFileName(_ fileName: String) -> String {
        guard let rootPath else { return (fileName as NSString).lastPathComponent }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return fileName.hasPrefix(prefix)
            ? String(fileName.dropFirst(prefix.count))
            : (fileName as NSString).lastPathComponent
    }

    /// 向后兼容：单文件世界等价于一个只含 1 个 `FileUnit` 的包。
    public static func singleFile(name: String, fileName: String, module: Module) -> Package {
        return Package(
            name: name,
            fileUnits: [FileUnit(fileName: fileName, module: module)])
    }

    /// 只在第一个单元并入标准库：标准库是模块级声明，逐单元各带一份会在整包摊平时重复。
    /// 让位主张按整包全部单元收集：同名项写在别的文件里，也要摘掉标准库那份。
    /// 幂等——已装配过的单元原样保留。警告随单元保留：装配不改动该文件的词法结果。
    public func assemblingStdlib() -> Package {
        guard let first = fileUnits.first else { return self }
        let claims = FrontEnd.claims(in: fileUnits.map(\.module))
        var assembled = fileUnits
        assembled[0] = FileUnit(
            fileName: first.fileName, module: FrontEnd.assemble(module: first.module, claims: claims),
            warnings: first.warnings)
        return Package(
            name: name, fileUnits: assembled, rootPath: rootPath,
            unavailableNames: unavailableNames)
    }
}
