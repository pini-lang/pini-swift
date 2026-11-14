import Foundation
import PiniSyntax

/// 4 级可见性：`private < internal < package < public`，严格度排序用于「多信号同现时取最严格」。
/// 文件内 ⊂ 包内 ⊂ 全局，故 internal 优先于 package、package 优先于 public。
public enum VisibilityLevel: Int, Comparable, Sendable {
    case `private` = 0
    case `internal` = 1
    case `package` = 2
    case `public` = 3

    public static func < (lhs: VisibilityLevel, rhs: VisibilityLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// 人类可读标签（用于错误报告）。
    public var label: String {
        switch self {
        case .private: return "private"
        case .internal: return "internal"
        case .package: return "package"
        case .public: return "public"
        }
    }
}

extension VisibilityLevel {
    /// 由「符号名 + 文件名 + 目录名」的 `_` 前缀推导可见性，取最严：符号 `_` → private，文件名 `_` → internal，
    /// 目录名 `_` → package，否则 public；`main` 恒 public、豁免整套规则。
    ///
    /// - Parameter name: 符号名（函数 / 类型 / 顶层变量）。
    /// - Parameter fileName: 定义该符号的源文件路径，用于抽取文件名与父目录前缀。
    public static func forSymbol(name: String, fileName: String) -> VisibilityLevel {
        // ⑥ main 恒全局可见、豁免整套规则
        if name == "main" { return .public }
        // 符号 `_` 前缀 = 硬私有（最高优先级，覆盖文件 / 目录逻辑）
        if name.hasPrefix("_") { return .private }
        let ns = fileName as NSString
        let basename = ns.lastPathComponent
        // 文件名 `_` 前缀 → internal
        if basename.hasPrefix("_") { return .internal }
        // 任一包内祖先目录带 `_` 前缀都收敛到 package，深层实现目录不能意外变成公开面。
        let directories = ns.deletingLastPathComponent.components(separatedBy: "/")
        if directories.contains(where: { $0.hasPrefix("_") }) { return .package }
        return .public
    }
}

/// 包级符号索引条目：记录符号名、定义文件与推导出的可见性级别。
public struct PackageSymbol: Equatable, Sendable {
    public let name: String
    /// 定义该符号的源文件路径（物理锚点）。
    public let fileName: String
    /// 依 spec 推导出的可见性级别。
    public let visibility: VisibilityLevel
    /// 符号种类（仅用于诊断信息）。
    public let kind: SymbolKind
    /// 符号在源文件中的定义位置（用于 LSP 跳转定义等场景）。
    public let location: SourceLocation

    /// 从 `referencingFile` 视角看该符号是否可见：同文件恒可见；跨文件仅 `package` / `public` 可见。
    /// 同模块内所有 `FileUnit` 同属一个包（`pini.toml` 边界锚定），故 package 级符号跨文件可见；
    /// 跨模块（import/export）边界的 enforce 尚未接入，此处一律按同包口径判定。
    public func isVisible(from referencingFile: String) -> Bool {
        if referencingFile == fileName { return true }
        return visibility == .package || visibility == .public
    }
}

/// 包级符号索引：把 `Package` 内所有 `FileUnit` 的顶级声明聚成「名字 → 定义文件 + 可见性」，
/// 供语义 / 类型层做跨文件解析与可见性 enforce；可见性仅按文件 / 目录 `_` 前缀计算。
/// 单文件 `Package` 由 `analyze(module:)` / `check(module:)` 原样处理，本索引只服务多文件场景。
public struct PackageSymbolIndex: Equatable, Sendable {
    private let byName: [String: PackageSymbol]
    /// 枚举 case 名 → 父枚举名集合。case 名按枚举命名空间隔离（P5-5 HIGH-1：
    /// 跨枚举同名 case 允许共存），故同名可映射到多个父枚举；多于一个即**歧义**，
    /// 未限定构造须改用 形状.圆(...) 限定写法。
    private let caseParents: [String: Set<String>]

    public init(byName: [String: PackageSymbol], caseParents: [String: Set<String>] = [:]) {
        self.byName = byName
        self.caseParents = caseParents
    }

    /// 构建包级符号索引；跨文件同名顶级声明视为**重声明错误**（包内命名空间共享）。
    /// 语义层调用（须主动暴露重声明），抛 `SemanticError.redeclaredSymbol`。
    public static func build(package: Package) throws -> PackageSymbolIndex {
        var byName: [String: PackageSymbol] = [:]
        var caseParents: [String: Set<String>] = [:]
        for unit in package.fileUnits {
            for decl in unit.module.declarations {
                for info in topLevelSymbolInfos(decl) {
                    let vis = visibility(of: info, fileName: package.relativeFileName(unit.fileName))
                    if let existing = byName[info.name] {
                        // 同名同型合并只对外部符号成立，签名是否一致由语义层 `ForeignSymbolTable` 预检；
                        // 索引这里只留首份，其余组合一律按重声明拒绝。
                        if existing.kind == .foreignSymbol, info.kind == .foreignSymbol { continue }
                        throw SemanticError.redeclaredSymbol(name: info.name, location: info.location)
                    }
                    byName[info.name] = PackageSymbol(
                        name: info.name, fileName: unit.fileName,
                        visibility: vis, kind: info.kind,
                        location: info.location
                    )
                }
                // 枚举 case 名同样进入包级索引：跨文件未限定构造（圆(5.0)）据此解析。
                // 同名跨枚举合法（各属其枚举命名空间），故只累积 parents，不抛重声明。
                if case .enumDecl(let e) = decl {
                    let parentVis = VisibilityLevel.forSymbol(name: e.name, fileName: package.relativeFileName(unit.fileName))
                    for ec in e.cases {
                        let ownVis = VisibilityLevel.forSymbol(name: ec.name, fileName: package.relativeFileName(unit.fileName))
                        // 可见性取父枚举与 case 名的较严者（private=0 最低）
                        let caseVis = min(parentVis, ownVis)
                        if byName[ec.name] == nil {
                            byName[ec.name] = PackageSymbol(
                                name: ec.name, fileName: unit.fileName,
                                visibility: caseVis, kind: .enumCase,
                                location: ec.location
                            )
                        }
                        caseParents[ec.name, default: []].insert(e.name)
                    }
                }
            }
        }
        return PackageSymbolIndex(byName: byName, caseParents: caseParents)
    }

    /// 类型层专用：以「先到先得」聚合（不抛重声明）；
    /// 跨文件重声明由语义层 `build` 先行拦截，类型层仅在已通过语义的程序上运行。
    public init(package: Package) {
        var byName: [String: PackageSymbol] = [:]
        var caseParents: [String: Set<String>] = [:]
        for unit in package.fileUnits {
            for decl in unit.module.declarations {
                for info in topLevelSymbolInfos(decl) {
                    let vis = visibility(of: info, fileName: package.relativeFileName(unit.fileName))
                    if byName[info.name] == nil {
                        byName[info.name] = PackageSymbol(
                            name: info.name, fileName: unit.fileName,
                            visibility: vis, kind: info.kind,
                            location: info.location
                        )
                    }
                }
                if case .enumDecl(let e) = decl {
                    let parentVis = VisibilityLevel.forSymbol(name: e.name, fileName: package.relativeFileName(unit.fileName))
                    for ec in e.cases {
                        let ownVis = VisibilityLevel.forSymbol(name: ec.name, fileName: package.relativeFileName(unit.fileName))
                        let caseVis = min(parentVis, ownVis)
                        if byName[ec.name] == nil {
                            byName[ec.name] = PackageSymbol(
                                name: ec.name, fileName: unit.fileName,
                                visibility: caseVis, kind: .enumCase,
                                location: ec.location
                            )
                        }
                        caseParents[ec.name, default: []].insert(e.name)
                    }
                }
            }
        }
        self.byName = byName
        self.caseParents = caseParents
    }

    /// 按名字查找包级符号（含定义文件与可见性）。
    public func lookup(_ name: String) -> PackageSymbol? {
        byName[name]
    }

    /// 工作区接口文件只读取公开符号，顺序与声明和文件系统顺序无关。
    public var publicSymbols: [String] {
        byName.values.filter { $0.visibility == .public }.map(\.name).sorted()
    }

    /// 该 case 名是否歧义（包内多个枚举声明了同名 case）。歧义时未限定构造不可用，
    /// 须改用 形状.圆(...) 限定写法。
    public func isAmbiguousCase(_ name: String) -> Bool {
        (caseParents[name]?.count ?? 0) > 1
    }
}

/// 包级索引的一条候选符号。一条声明可带出多条（foreign 块是一张符号表），故以数组为单位。
typealias TopLevelSymbolInfo = (name: String, kind: SymbolKind, location: SourceLocation)

/// 从一个顶级声明抽取（名字, 种类, 位置）。一条声明可带出多个符号：foreign 块是一张符号表，
/// 块名只是标签。扩展块与 import / export 不引入包级名字，空数组返回。
func topLevelSymbolInfos(_ decl: TopLevelDecl) -> [TopLevelSymbolInfo] {
    switch decl {
    case .structDecl(let s): return [(s.name, .struct, s.location)]
    case .objectDecl(let o): return [(o.name, .object, o.location)]
    // 给定块是**具名复合类型** ⇒ 与对象同族纳入包级符号表（可见性规则保持一致）。
    // 细分种类（值 / 引用语义）尚未裁定 ⇒ 暂按 `.object` 归类。
    case .givenDecl(let g): return [(g.name, .object, g.location)]
    case .enumDecl(let e): return [(e.name, .enum, e.location)]
    case .funcDecl(let f): return [(f.name, .function, f.location)]
    case .traitDecl(let t): return [(t.name, .trait, t.location)]
    case .extensionDecl: return []  // 扩展块不引入新符号（方法归并到目标类型）
    // 外部符号是模块的公共资源：声明一次、全包可用，故每条都进索引。
    case .foreignDecl(let block):
        return block.symbols.map { ($0.name, .foreignSymbol, $0.location) }
    case .varDecl(let statement):
        if case .varDecl(let name, _, _, _, let loc) = statement {
            return [(name, .variable(isMutable: true), loc)]
        }
        return []
    case .statement(let statement):
        // 顶层 `let`/`var` 经 parseStatement 落到 `.statement(.varDecl(...))`，须同样纳入索引
        //顶层非成员符号同样受 4 级可见性约束。
        if case .varDecl(let name, _, _, _, let loc) = statement {
            return [(name, .variable(isMutable: true), loc)]
        }
        return []
    case .importDecl, .exportDecl:
        return []
    }
}

/// 外部符号的可见性只由「模块级」这一条给定：名字里的 `_` 属于 C 符号本身（`_exit`），
/// 按 Pini 的 `_` 前缀规则会把它判成 private，跨文件即不可见。其余符号照旧按文件名与目录判。
private func visibility(of info: TopLevelSymbolInfo, fileName: String) -> VisibilityLevel {
    info.kind == .foreignSymbol
        ? .package
        : VisibilityLevel.forSymbol(name: info.name, fileName: fileName)
}
