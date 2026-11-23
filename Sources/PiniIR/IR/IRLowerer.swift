import Foundation
import PiniSyntax
import PiniSemantics

/// 把已通过类型检查的 `Module` 与检查器的 `TypeInference` 降载为带类型的 `IRModule`。
/// 所有后端的类型判定都在这里完成，这里也是唯一允许说「不支持」的地方：
/// 每处能力缺口都从本文件抛一个 `IRLoweringError`。
public enum IRLowerer {

    /// 唯一的能力门禁错误：自由文本细节，加被拒构造的位置。
    /// 默认码是「未支持特性」桶（E6-004）；若门禁的原因是用错而非能力缺失，则携带自己的码，
    /// 让 CLI 能区分两者。
    public struct IRLoweringError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public let location: SourceLocation
        /// Diagnostic code，默认落在 E6「不支持特性」桶。
        /// 域枚举与生成器取码同源，故换管线不改变 code 的取值域。
        public var code: String = "\(DiagnosticDomain.irgen.rawValue)-004"
        /// E6-005「类型不匹配」的两个槽。非空时诊断模板按 `{expected}` / `{got}` 填，
        /// 不再借用 `{feature}` 塞自由文本；其余码留 nil，维持单槽。
        public var expected: String?
        public var got: String?

        public var description: String {
            "IR lowering error at \(location.line):\(location.column): \(message)"
        }

        public var errorDescription: String? { description }
    }

    /// 降载后的表达式及其解析类型。发射器用得到类型的地方，IR 节点自己已经带了；
    /// 这一层包装只是让降载期的类型判定显式且统一。
    private struct LoweredExpr {
        let node: IRExpr
        let type: IRType
    }

    /// 单态化暂存：每个具体类型实参组合一份特化，按特化后的源名（`盒_I32`、`身份_I32`）为键。
    /// 结构体实例带上它的替换表，扩展方法才能按实例重新特化。
    fileprivate struct G10SpecializationState {
        var structSpecializations: [String: StructDecl] = [:]
        /// 泛型**给定块**的特化体（按特化名键，形如 `匣_I32`）。
        /// 与结构体那一格分开：给定块不是 `StructDecl`，且它还要驱动默认实例的取用。
        var givenSpecializations: [String: GivenDecl] = [:]
        var funcSpecializations: [String: FuncDecl] = [:]
        /// 特化名 → 该结构实例的替换表（泛型参数名 → 具体注解）。
        var structSubstitutions: [String: [String: TypeAnnotation]] = [:]
        /// 特化后的泛型枚举体，键风格同上（`结果_I32_String`）。
        var enumSpecializations: [String: EnumDecl] = [:]
        /// 前置扫描解析枚举构造点时查的表。放在状态里而不逐层传参：`precollectGenericUses`
        /// 已经把状态传遍每个递归调用，另立一张按值传递的表就得在每个调用点补一次。
        var genericEnums: IRGenericEnumIndex = .empty
    }

    /// 泛型实例的特化源名：`盒` + ["I32"] -> `盒_I32`。与方法的 `方法__类型`
    /// 分隔符不同，两种 mangling 因此永远不会撞名。
    fileprivate static func specializedSourceName(_ base: String, typeArgs: [TypeAnnotation]) -> String {
        let argNames = typeArgs.map { arg -> String in
            switch arg {
            case .simple(let name, _): return name
            case .generic(let name, _, _): return name
            default: return "T"
            }
        }
        return "\(base)_\(argNames.joined(separator: "_"))"
    }

    /// 名义类型登记项：struct / object 的 AST 声明，加上从 `((T))` / `{{T}}` 扩展块并入的方法
    /// （数据与逻辑分离 —— 解析器把方法放进扩展块）。
    fileprivate struct NominalInfo {
        let name: String
        let isObject: Bool
        var decl: TopLevelDecl
        var extensionMethods: [FuncDecl] = []

        var fields: [FieldDecl] {
            switch decl {
            case .structDecl(let sd): return sd.fields
            case .objectDecl(let od): return od.fields
            /// 给定块与对象同规 —— 块内字段即其字段表（`[[T]]` 追加的
            /// 只有方法，从不追加字段，故这里不含 `extensionMethods` 对应物）。
            case .givenDecl(let gd): return gd.fields
            default: return []
            }
        }

        var methods: [FuncDecl] {
            let own: [FuncDecl]
            switch decl {
            case .structDecl(let sd): own = sd.methods
            case .objectDecl(let od): own = od.methods
            /// 给定块**自带的方法**与 `[[给定块名]]` 归并进来的方法合成一张表 ——
            /// 须显式列出；`default:` 分支只给 `extensionMethods`，会丢块内方法。
            case .givenDecl(let gd): own = gd.methods
            default: own = []
            }
            let instanceMethods = (own + extensionMethods).filter { !$0.modifiers.contains("own") }
            return Self.merging(own: instanceMethods, extensions: [])
        }

        /// 合并一个名义类型的两处方法来源：类型自身带的方法，与各扩展块按声明顺序归并进来的方法。
        /// 按名合并、同名者后者胜：无重载 ⇒ 一名一体；扩展块声明在后 ⇒ 覆盖块压过自身那份。位置取首次
        /// 出现处，故发射顺序与方法表顺序稳定。不去重则同名两条成为两个同名定义，模块被执行前即被拒。
        static func merging(own: [FuncDecl], extensions: [FuncDecl]) -> [FuncDecl] {
            var byName: [String: FuncDecl] = [:]
            var order: [String] = []
            for method in own + extensions {
                if byName[method.name] == nil { order.append(method.name) }
                byName[method.name] = method
            }
            return order.compactMap { byName[$0] }
        }

        var composedParent: String? {
            switch decl {
            case .structDecl(let sd): return sd.composedType
            default: return nil
            }
        }

        /// 用合并后的字段 / 方法重建本项（组合摊平的结果）。完整合并表（自有 + 扩展 + 继承）
        /// 作为扩展方法放回，故 `methods` 保持「自有 + 扩展」形状，mangling 仍在子类型一侧。
        func replacing(fields: [FieldDecl], methods: [FuncDecl]) -> NominalInfo {
            var copy = self
            switch decl {
            case .structDecl(let sd):
                copy.decl = .structDecl(
                    StructDecl(
                        name: sd.name, genericParams: sd.genericParams,
                        fields: fields, methods: [],
                        composedType: sd.composedType, traits: sd.traits, location: sd.location
                    ))
            case .objectDecl(let od):
                copy.decl = .objectDecl(
                    ObjectDecl(
                        name: od.name, genericParams: od.genericParams,
                        fields: fields, methods: [], traits: od.traits, location: od.location
                    ))
            default: break
            }
            copy.extensionMethods = methods
            return copy
        }
    }

    /// 解析结构组合：把被组合父级的字段 / 方法并进子名义类型 —— 先子成员，再父级未被覆盖的成员。
    /// 嵌套组合在 `visited` 环保护下递归；只有 struct 带 `composedType`，object 父级到不了这里。
    private static func flattenComposedNominals(_ nominals: inout [String: NominalInfo]) {
        func merged(_ info: NominalInfo, _ visited: inout Set<String>) -> NominalInfo {
            guard let parentName = info.composedParent,
                let parent = nominals[parentName]
            else {
                return info
            }
            guard !visited.contains(parentName) else { return info }
            visited.insert(parentName)
            let resolvedParent = merged(parent, &visited)
            let childFields = info.fields
            let childMethods = info.methods
            let childFieldNames = Set(childFields.map { $0.name })
            let childMethodNames = Set(childMethods.map { $0.name })
            let fields = childFields + resolvedParent.fields.filter { !childFieldNames.contains($0.name) }
            let methods = childMethods + resolvedParent.methods.filter { !childMethodNames.contains($0.name) }
            return info.replacing(fields: fields, methods: methods)
        }
        for name in Array(nominals.keys) {
            guard nominals[name]?.composedParent != nil else { continue }
            var visited: Set<String> = [name]
            nominals[name] = merged(nominals[name]!, &visited)
        }
    }

    /// 模块级特征登记表。特征默认体在派发点按实现类型各降载一次；抽象签名跳过（一致性归检查器）。
    struct TraitRegistry {
        let traits: [String: TraitDecl]
        let typeTraits: [String: [String]]
    }

    /// 收集在派发点特化的特征默认体。引用类型 —— 嵌套上下文（main 内的函数体）的追加
    /// 要能汇到 `lower()` 的模块装配。
    final class TraitDefaultCollector {
        private(set) var functions: [IRFunction] = []
        private var seen: Set<String> = []

        func add(_ function: IRFunction) {
            guard seen.insert(function.name).inserted else { return }
            functions.append(function)
        }
    }

    /// 降载已检查的多文件包：调用方须先跑包级语义与类型检查。所有文件并进一个虚拟模块，
    /// 于是每个前置扫描都成了全局扫描，跨文件引用按前向引用解析；文件序（名字升序）保证结果稳定。
    public static func lower(
        package: Package, typeInference: TypeInference?,
        foreignConstants: [IRForeignConstant] = [],
        requiresMain: Bool = true
    ) throws -> IRModule {
        let base = Module(
            declarations: package.fileUnits.flatMap { $0.module.declarations },
            imports: package.fileUnits.flatMap { $0.module.imports },
            exports: package.fileUnits.flatMap { $0.module.exports },
            location: package.location
        )
        let (merged, aliasMap) = try mergedWithImports(base)
        return try lower(
            module: merged, typeInference: typeInference,
            moduleAliases: aliasMap, foreignConstants: foreignConstants, requiresMain: requiresMain)
    }

    /// 把 `import` 目标的声明并入虚拟模块，返回「别名 → 可引入符号名」表。依赖声明不在本包清单里
    /// （加载器把自带清单的子目录剔出本包），故静态降载并进同一虚拟模块：裸调用走前向引用，限定调用走
    /// `别名.符号`；只并 public 符号，传递性靠 `pending` 队列。单文件路径也走此处，否则别名无键可查。
    public static func mergedWithImports(_ module: Module) throws -> (Module, [String: Set<String>]) {
        guard !module.imports.isEmpty else { return (module, [:]) }
        let loader = ModuleDependencyLoader.shared
        var aliasMap: [String: Set<String>] = [:]
        var extraDecls: [TopLevelDecl] = []
        var seenRoots = Set<String>()
        // 记录每个并入的顶层名由哪个模块提供。平铺合并让所有导入模块共用一个命名空间，
        // 两个模块导出同名公开符号时后到者会覆盖前者 —— 那是错值而非缺失。
        // 记下提供方，合并时就能拒绝而不是覆盖。
        var supplier: [String: String] = [:]
        var pending = module.imports
        var index = 0
        while index < pending.count {
            let imp = pending[index]
            index += 1
            let dir = (imp.location.fileName as NSString).deletingLastPathComponent
            let loaded = try loader.load(packagePath: imp.packagePath, relativeTo: dir)
            aliasMap[imp.alias] = loaded.publicSymbols
            guard seenRoots.insert(loaded.rootPath).inserted else { continue }
            for decl in loaded.declarations {
                guard let name = topLevelName(of: decl) else { continue }
                if let previous = supplier[name], previous != loaded.rootPath {
                    throw IRLoweringError(
                        message: "imported modules '\(previous)' and '\(loaded.rootPath)' both "
                            + "export the top-level name '\(name)': this channel merges import "
                            + "targets into one module, so it cannot keep their namespaces apart",
                        location: imp.location
                    )
                }
                supplier[name] = loaded.rootPath
            }
            extraDecls.append(contentsOf: loaded.declarations)
            pending.append(contentsOf: loaded.imports)
        }
        let merged = Module(
            declarations: module.declarations + extraDecls,
            imports: module.imports,
            exports: module.exports,
            location: module.location
        )
        return (merged, aliasMap)
    }

    /// 降载已检查的模块；`typeInference` 是检查器的输出，故调用方须先跑检查器。
    /// - Parameter requiresMain: `pini test` 对纯测试文件传 `false` —— 它们是合法模块，只是没有 `main`；
    ///   这条要求在运行器，不在 IR。
    public static func lower(
        module: Module, typeInference: TypeInference?,
        moduleAliases: [String: Set<String>] = [:],
        foreignConstants: [IRForeignConstant] = [],
        requiresMain: Bool = true
    ) throws -> IRModule {
        /// 码表只依赖声明与导出面，先于函数体降载建好：`err(...)` 造 Result 时要按载荷类型取码。
        /// 分配逻辑在语义层（`ErrorCodePlan`），E7-004 警告与这里共用同一份结果。
        let errorCodePlan = ErrorCodePlan.build(module: module)
        // 特征登记前置扫描：带体的默认实现签名与普通具名函数一样进签名表；抽象签名跳过，
        // 检查器已验过一致性。两张表都是模块级。
        var traits: [String: TraitDecl] = [:]
        var typeTraits: [String: [String]] = [:]
        for decl in module.declarations {
            switch decl {
            case .traitDecl(let td): traits[td.name] = td
            case .structDecl(let sd) where !sd.traits.isEmpty: typeTraits[sd.name] = sd.traits
            case .objectDecl(let od) where !od.traits.isEmpty: typeTraits[od.name] = od.traits
            default: break
            }
        }
        let traitRegistry = TraitRegistry(traits: traits, typeTraits: typeTraits)
        let traitDefaultsCollector = TraitDefaultCollector()
        // 名义类型登记前置扫描：struct / object，加上从扩展块 `((T))` / `{{T}}` 并入的方法。
        var nominals: [String: NominalInfo] = [:]
        var genericStructTemplates: [String: StructDecl] = [:]
        var genericFuncTemplates: [String: FuncDecl] = [:]
        // 泛型枚举模板，加上 case -> 归属枚举的索引 —— 裸构造写法靠它反查（泛型枚举构造形态）。
        // 限定写法自己就点明了枚举，无需索引。
        var genericEnumTemplates: [String: EnumDecl] = [:]
        var genericEnumCaseOwners: [String: [String]] = [:]
        // 预置声明（宿主提供）中未被本模块占用名字的那些 —— 见 `visiblePredefined`。落在这里而非各入口：
        // 整包降载会把各文件摊平成一个模块再走本函数，一处即覆盖两条路。名义表又是 `userTypes` 的来源，
        // 故这一步同时让 `using` 形参的类型标注找得到这个名字。
        let predefined = IRLowerer.visiblePredefined(in: module)
        for decl in predefined {
            guard case .givenDecl(let gd) = decl else { continue }
            nominals[gd.name] = NominalInfo(name: gd.name, isObject: false, decl: decl)
        }
        for decl in module.declarations {
            switch decl {
            case .structDecl(let sd):
                if sd.genericParams.isEmpty {
                    nominals[sd.name] = NominalInfo(name: sd.name, isObject: false, decl: decl)
                } else {
                    genericStructTemplates[sd.name] = sd
                }
            case .objectDecl(let od): nominals[od.name] = NominalInfo(name: od.name, isObject: true, decl: decl)
            // 给定块与结构 / 对象同规进入归并表 ⇒ `[[给定块名]]` 的方法能归并进来；`[[X]]` 的覆盖面由这张表
            // 决定，与括号形无关。`isObject: false` 与类型层现状对齐：`TypeChecker` 不把给定块登记进
            // `referenceTypeNames`，故此处不预裁值 / 引用语义；将来若改判，改这一处即可。
            case .givenDecl(let gd): nominals[gd.name] = NominalInfo(name: gd.name, isObject: false, decl: decl)
            case .funcDecl(let fd) where !fd.genericParams.isEmpty:
                genericFuncTemplates[fd.name] = fd
            case .enumDecl(let ed) where !ed.genericParams.isEmpty:
                genericEnumTemplates[ed.name] = ed
                for enumCase in ed.cases {
                    genericEnumCaseOwners[enumCase.name, default: []].append(ed.name)
                }
            default: break
            }
        }
        let genericEnums = IRGenericEnumIndex(
            templates: genericEnumTemplates, caseOwners: genericEnumCaseOwners
        )
        // 三形扩展的目标按实际注册类别分四类处置。放过但不归并的名单 = 已声明、却不在 `nominals` 里的
        // 类型名：枚举（含泛型枚举）无归并路径；泛型结构模板在特化段落按 `盒_<实参>` 另行归并。
        // 内建类型（`String` / `Array`）同样不归并 —— 它们的扩展体由下方 `builtinExtensionMethods` 通道降载。
        var toleratedExtensionTargets: Set<String> = []
        for decl in module.declarations {
            switch decl {
            case .enumDecl(let ed): toleratedExtensionTargets.insert(ed.name)
            case .structDecl(let sd) where !sd.genericParams.isEmpty:
                toleratedExtensionTargets.insert(sd.name)
            default: break
            }
        }
        for decl in module.declarations {
            // `.bracketExt`（方括号）与 `((` / `{{` 两形同权：归并条件只看「目标是否注册为名义类型」，不看
            // kind 本身。四类处置：在 `nominals` 里 ⇒ 归并；内建类型 ⇒ 放过（另有降载通道）；在
            // `toleratedExtensionTargets` 里（枚举 / 泛型模板）⇒ 放过；其余 ⇒ 响亮拒绝 —— 静默丢弃无从定位。
            if case .extensionDecl(let ext) = decl,
                ext.kind == .structExt || ext.kind == .objectExt || ext.kind == .bracketExt
            {
                if nominals[ext.targetType] != nil {
                    nominals[ext.targetType]!.extensionMethods.append(contentsOf: ext.methods)
                } else if !toleratedExtensionTargets.contains(ext.targetType),
                    builtinReceiverType(named: ext.targetType) == nil
                {
                    let spelling =
                        ext.kind == .structExt ? "((\(ext.targetType)))"
                        : ext.kind == .objectExt ? "{{\(ext.targetType)}}" : "[[\(ext.targetType)]]"
                    throw IRLoweringError(
                        message: "extension block `\(spelling)`：目标 `\(ext.targetType)` 未声明为"
                            + "可归并的类型（结构 / 对象 / 给定块），或指向特征 —— 方法无处可归",
                        location: ext.location,
                        code: "\(DiagnosticDomain.irgen.rawValue)-006"
                    )
                }
            }
        }

        // 结构组合摊平：体第一行是裸父类型名的结构体内嵌该父级 —— 先子字段/方法，
        // 再追加父级未被覆盖的。父方法以子类型的 self 重新降载，故摊平后的名字是 `方法__子类型`。
        flattenComposedNominals(&nominals)

        /// 前处理给每个 funcLiteral 分配稳定闭包 id，键为 "行:列"，按源码顺序编号。
        var closureIds: [String: Int] = [:]
        var closureCounter = 0
        for decl in module.declarations {
            switch decl {
            case .funcDecl(let fd):
                precollectClosureIds(in: fd.body?.statements ?? [], counter: &closureCounter, into: &closureIds)
            case .structDecl(let sd):
                for m in sd.methods { precollectClosureIds(in: m.body?.statements ?? [], counter: &closureCounter, into: &closureIds) }
            case .objectDecl(let od):
                for m in od.methods { precollectClosureIds(in: m.body?.statements ?? [], counter: &closureCounter, into: &closureIds) }
            case .extensionDecl(let ext):
                for m in ext.methods { precollectClosureIds(in: m.body?.statements ?? [], counter: &closureCounter, into: &closureIds) }
            default: break
            }
        }

        // 单态化预扫描：扫模块里的泛型构造/调用点（`盒<I32>()`），按类型实参组合登记
        // 特化后的名义类型（字段已替换）或函数声明，并并入登记表，
        // 让后续降载只看到具体类型。
        var specializationState = G10SpecializationState()
        specializationState.genericEnums = genericEnums
        for decl in module.declarations {
            precollectGenericUses(
                in: decl,
                genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates,
                nominals: &nominals,
                state: &specializationState)
        }
        for (specializedName, specialized) in specializationState.structSpecializations {
            nominals[specializedName] = NominalInfo(name: specializedName, isObject: false, decl: .structDecl(specialized))
            let substitution = specializationState.structSubstitutions[specializedName] ?? [:]
            // `((盒<T>))` 解析出的 targetType 是 `盒`（类型参数已剥掉），而实例名是 `盒_I32`，
            // 故模板按前缀 `盒_` 或全名 `盒` 匹配；同名非泛型结构体无法与该模板共存。
            for decl in module.declarations {
                if case .extensionDecl(let ext) = decl, ext.kind == .structExt,
                    specializedName == ext.targetType || specializedName.hasPrefix("\(ext.targetType)_")
                {
                    // 泛型结构体模板的方法经 `((盒<T>))` 扩展到达；按实例逐个重新特化。
                    for method in ext.methods {
                        let specializedMethod = specializeMethodForGenericStruct(
                            method, structTemplate: specialized,
                            substitution: substitution,
                            specializedName: specializedName
                        )
                        nominals[specializedName]!.extensionMethods.append(specializedMethod)
                    }
                }
            }
        }

        // 枚举登记表，外加注解解析用的用户类型表：先收名字，再收载荷注解（后者可能引用别的用户类型）。
        // 泛型枚举是模板而非类型 —— 它的载荷写的是类型参数 —— 故只登记特化体，不登记模板。
        var enums: [String: IREnumDecl] = [:]
        // 声明序单独记一份：`IRModule.enums` 是数组，而 `Array(enums.values)` 取字典遍历序 —— String 哈希
        // 带逐进程随机种子 ⇒ 多枚举模块每次运行的类型定义段顺序都不同，发射器逐条发定义 ⇒ 产物不可复现。
        // 这里记声明序，特化枚举按特化名定序排在声明枚举之后，两者都确定。
        var enumOrder: [String] = []
        var userTypes: [String: IRType] = [:]
        for decl in module.declarations {
            switch decl {
            case .enumDecl(let ed):
                guard ed.genericParams.isEmpty else { break }
                enumOrder.append(ed.name)
                enums[ed.name] = IREnumDecl(
                    name: ed.name,
                    cases: ed.cases.enumerated().map { index, ec in
                        IREnumCase(
                            name: ec.name, tag: index,
                            paramNames: ec.associatedParams.map { $0.name },
                            payloadTypes: [])
                    }
                )
                userTypes[ed.name] = .enumeration(name: ed.name)
            default: break
            }
        }
        for (name, info) in nominals {
            userTypes[name] = .nominal(name: name, isObject: info.isObject)
        }
        for specializedName in specializationState.enumSpecializations.keys {
            userTypes[specializedName] = .enumeration(name: specializedName)
        }
        for decl in module.declarations {
            if case .enumDecl(let ed) = decl, ed.genericParams.isEmpty {
                enums[ed.name] = try resolveEnumPayloads(ed, userTypes: userTypes)
            }
        }
        // 特化体现在已是普通枚举（不再带类型参数），故走同一个解析调用。遍历用 `.sorted()`：
        // 这个字典的键序同样是哈希随机，而这些名字会进 `IRModule.enums` 的尾部，
        // 不排序的遍历会再次产出不可复现的顺序。
        for specializedName in specializationState.enumSpecializations.keys.sorted() {
            guard let specialized = specializationState.enumSpecializations[specializedName] else {
                continue
            }
            enums[specializedName] = try resolveEnumPayloads(specialized, userTypes: userTypes)
            enumOrder.append(specializedName)
        }

        // 泛型给定块的模板与被用到的特化。位置是承重的：必须排在签名表构造之前 —— 签名表要解析每个形参的
        // 类型标注，而 `using 箱: 匣<I32>` 的标注是泛型形，特化得先登记进 `userTypes`，否则当场报「缺可解析
        // 标量类型」。只有 `using` 形参这一个可达入口（无构造点、无调用点），故在此单独扫一段，只登记可达集合。
        var genericGivenTemplates: [String: GivenDecl] = [:]
        for decl in module.declarations {
            guard case .givenDecl(let gd) = decl, !gd.genericParams.isEmpty else { continue }
            genericGivenTemplates[gd.name] = gd
        }
        if !genericGivenTemplates.isEmpty {
            for decl in module.declarations {
                for params in usingAnnotationParamLists(of: decl) {
                    for parameter in params {
                        guard case .generic(let typeName, let typeArgs, _)? = parameter.typeAnnotation,
                            let template = genericGivenTemplates[typeName],
                            typeArgs.count == template.genericParams.count
                        else { continue }
                        let specialized = registerGivenSpecialization(
                            template, typeArgs: typeArgs, state: &specializationState)
                        // 登记进 `nominals`（方法表 / 字段表由此可查）与 `userTypes`（类型标注
                        // 可解析）。`isObject: false` 与 `nominals` 里的登记一致：值/引用语义不预裁。
                        if nominals[specialized.name] == nil {
                            nominals[specialized.name] = NominalInfo(
                                name: specialized.name, isObject: false, decl: .givenDecl(specialized))
                        }
                        userTypes[specialized.name] = .nominal(name: specialized.name, isObject: false)
                    }
                }
            }
        }

        var signatures: [String: IRLowererSignatureInfo] = [:]

        /// 特征默认实现的签名信息。带头的 `self` 形参（注解为 nil —— 特征体不标它）剥掉；
        /// 其余形参照常解析。
        func traitSignatureInfo(_ sig: FuncDecl, userTypes: [String: IRType]) throws -> IRLowererSignatureInfo {
            let bodyParams = sig.params.first?.name == "self" ? Array(sig.params.dropFirst()) : sig.params
            let paramTypes = try bodyParams.map { parameter -> IRType in
                guard let annotation = parameter.typeAnnotation,
                    let type = resolveAnnotationType(annotation, userTypes: userTypes)
                else {
                    throw unsupported(
                        "parameter '\(parameter.name)' of trait default '\(sig.name)' lacks a resolvable scalar type",
                        at: sig.location
                    )
                }
                return type
            }
            let returnType = try resolveReturnType(
                sig, userTypes: userTypes, subject: "trait default '\(sig.name)'"
            )
            return IRLowererSignatureInfo(paramTypes: paramTypes, returnType: returnType)
        }

        for decl in module.declarations {
            switch decl {
            case .traitDecl(let td):
                // 默认实现体进签名表（体内可能调用后声明的顶层函数）；抽象签名跳过。
                for sig in td.signatures where sig.body != nil && sig.genericParams.isEmpty {
                    signatures[sig.name] = try traitSignatureInfo(sig, userTypes: userTypes)
                }
            case .funcDecl(let funcDecl):
                // 泛型模板从不直接降载 —— 只有其特化体降载。模板的形参注解引用类型参数，在这里解析不出来。
                guard funcDecl.genericParams.isEmpty else { continue }
                let paramTypes = try resolveParamTypes(funcDecl, userTypes: userTypes)
                let returnType = try resolveReturnType(
                    funcDecl, userTypes: userTypes, subject: "'\(funcDecl.name)'"
                )
                // 声明为空的顶层函数若实际返回值，取生效后的返回类型：签名表驱动调用点，
                // 必须与定义侧的上提一致。
                let effectiveReturn =
                    try effectiveReturnType(
                        decl: funcDecl, userTypes: userTypes, nominals: nominals
                    ) ?? returnType
                signatures[funcDecl.name] = IRLowererSignatureInfo(
                    paramTypes: paramTypes,
                    returnType: asyncSignatureReturnType(
                        declared: effectiveReturn, isAsync: funcDecl.isAsync),
                    bodyReturnType: asyncBodyReturnType(
                        declared: effectiveReturn, isAsync: funcDecl.isAsync),
                    untypedParamIndices: untypedParamIndices(funcDecl),
                    usingParamIndices: usingParamIndices(funcDecl)
                )
            case .foreignDecl(let foreignDecl):
                // 外部函数签名并入共享签名表，调用点照常解析。数据符号不进这张表：
                // 它不是可调用的，按名读到的是存储而不是函数。
                for symbol in foreignDecl.symbols where symbol.isFunction {
                    let signature = try resolveForeignSignature(symbol)
                    signatures[symbol.name] = IRLowererSignatureInfo(
                        paramTypes: signature.params.map(\.irType),
                        returnType: signature.returnType?.irType,
                        isVariadic: symbol.isVariadic,
                        handleParamIndices: Set(
                            signature.params.enumerated()
                                .filter { $0.element == .stringHandle }.map(\.offset))
                    )
                }
            default: break
            }
        }
        // 特化后的泛型函数进签名表（它们的体现在只引用具体类型）。
        for (_, specialized) in specializationState.funcSpecializations {
            let paramTypes = try resolveParamTypes(specialized, userTypes: userTypes)
            let returnType = try resolveReturnType(
                specialized, userTypes: userTypes, subject: "'\(specialized.name)'"
            )
            signatures[specialized.name] = IRLowererSignatureInfo(
                paramTypes: paramTypes, returnType: returnType, untypedParamIndices: untypedParamIndices(specialized),
                usingParamIndices: usingParamIndices(specialized)
            )
        }

        // 跨模块限定名键：`别名.符号` 与裸名共用同一份签名，只在键上带别名前缀。
        // 于是限定调用不必另开解析路径，也不会与变量的成员访问混淆 ——
        // 变量 `a.b(...)` 的键永远不会出现在签名表里。
        for (alias, symbols) in moduleAliases {
            for symbol in symbols {
                if let info = signatures[symbol] { signatures["\(alias).\(symbol)"] = info }
            }
        }

        var functions: [IRFunction] = []

        // 三级派发（用户扩展 > 标准库 > 宿主原生）的第一级。内建类型（`String` / `Array`）不是名义声明，
        // 上面的扩展注册收不到它们，方法体从未降载 ⇒ 这里降载成普通 `IRFunction`（IR 名 `方法__类型`），
        // 调用点按名分派。必须先于函数降载跑，否则该表进不了先降载函数的上下文。`Array` 的 self 取 i32 占位。
        var builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:]
        for decl in module.declarations {
            guard case .extensionDecl(let ext) = decl,
                ext.kind == .structExt || ext.kind == .objectExt,
                let selfType = builtinReceiverType(named: ext.targetType)
            else { continue }
            for method in ext.methods {
                let lowered = try lowerMethod(
                    method, typeName: ext.targetType, selfType: selfType,
                    typeInference: typeInference, moduleSignatures: signatures,
                    nominalTypes: nominals, userTypes: userTypes, enums: enums,
                    genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds, traitRegistry: traitRegistry,
                    traitDefaultsCollector: traitDefaultsCollector
                )
                functions.append(lowered)
                builtinExtensionMethods[ext.targetType, default: [:]][method.name] =
                    (irName: lowered.name, returnType: lowered.returnType ?? .i32)
            }
        }

        // 本型方法以类型名为接收者：不带 self，降载成顶层函数，调用点按 IR 名直发。
        // 只认扩展块写法，故枚举目标也在这里落地，不经名义类型归并。
        for decl in module.declarations {
            guard case .extensionDecl(let ext) = decl else { continue }
            for method in ext.methods where method.modifiers.contains("own") {
                functions.append(
                    try lowerMethod(
                        method, typeName: ext.targetType, selfType: .i32, isOwn: true,
                        typeInference: typeInference, moduleSignatures: signatures,
                        nominalTypes: nominals, userTypes: userTypes, enums: enums,
                        genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                        closureIds: closureIds, traitRegistry: traitRegistry,
                        traitDefaultsCollector: traitDefaultsCollector
                    ))
            }
        }

        // 外部数据符号先建表再降载函数体：声明块可以在文件里写在函数之后，边降载边查会漏。
        // 宏常量不进这张表——它没有存储，读它是读一个字面量，取址更无从谈起。
        var foreignData: [String: IRType] = [:]
        var constantTable: [String: IRForeignConstant] = [:]
        for constant in foreignConstants { constantTable[constant.name] = constant }
        for decl in module.declarations {
            guard case .foreignDecl(let block) = decl else { continue }
            for symbol in block.symbols
            where !symbol.isFunction && !symbol.flags.contains("macro") {
                let type = try ffiType(symbol.annotation, at: .data, symbol: symbol)
                foreignData[symbol.name] = type.irType
            }
        }
        /// 声明了但没值的宏不进常量表：未求值已由 check 报过，这里不再逐条打红。
        /// 名字仍记下，读点遇到时给一条比「未定义变量」更近的兜底。
        var declaredMacroNames: Set<String> = []
        for decl in module.declarations {
            guard case .foreignDecl(let block) = decl else { continue }
            for symbol in block.symbols where symbol.flags.contains("macro") {
                declaredMacroNames.insert(symbol.name)
            }
        }

        for decl in module.declarations {
            switch decl {
            case .funcDecl(let funcDecl):
                // 泛型模板不发射 —— 只发射其特化体（单态化）。
                guard funcDecl.genericParams.isEmpty else { continue }
                functions.append(
                    try lowerFunction(
                        funcDecl, typeInference: typeInference, moduleSignatures: signatures,
                        nominalTypes: nominals, userTypes: userTypes, enums: enums, genericEnums: genericEnums,
                        genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                        traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector,
                        builtinExtensionMethods: builtinExtensionMethods,
                        foreignData: foreignData, foreignConstants: constantTable,
                        declaredMacros: declaredMacroNames,
                        errorCodeByType: errorCodePlan.byType,
                        hashedErrorCodes: errorCodePlan.hashedTables)
                )
            case .traitDecl, .structDecl, .objectDecl, .extensionDecl, .enumDecl:
                // 由下面的名义类型 / 枚举各趟处理；特征默认体在各自的派发点特化。
                continue
            case .foreignDecl:
                // 纯声明面 —— 下面降载进 `foreigns`，没有函数体要发射。
                continue
            case .givenDecl(let givenDecl):
                // 给定块与结构 / 对象同规进入类型面，默认实例由 `using` 取用点物化。字段初值必须齐全：默认实例的
                // 定义就是「各字段初值合起来」⇒ 缺一个就没有完整默认值，故降载期对每个给定块报错，不区分是否被用到
                // —— 未被任何 `using` 使用的给定块同样报错：字段留空、以后显式构造这种写法因此不被接受。
                for field in givenDecl.fields where field.initializer == nil {
                    throw rejected(
                        "给定块 `\(givenDecl.name)` 的字段 `\(field.name)` 缺初值"
                            + " ⇒ 无完整默认实例（ADR-001：默认实例 = 各字段初值合起来）",
                        code: noDefaultInstanceCode, at: field.location
                    )
                }
                continue
            default:
                throw unsupported(
                    "top-level construct outside the slice (named functions + struct/object types)",
                    at: module.location
                )
            }
        }
        // 发射特化后的泛型函数体。
        for (_, specialized) in specializationState.funcSpecializations {
            functions.append(
                try lowerFunction(
                    specialized, typeInference: typeInference, moduleSignatures: signatures,
                    nominalTypes: nominals, userTypes: userTypes, enums: enums, genericEnums: genericEnums,
                    genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                    traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector,
                    builtinExtensionMethods: builtinExtensionMethods,
                    foreignData: foreignData, foreignConstants: constantTable,
                    declaredMacros: declaredMacroNames)
            )
        }
        if requiresMain {
            guard functions.contains(where: { $0.name == "main" }) else {
                throw unsupported("no 'main' function found", at: module.location)
            }
        }

        // 降载名义类型声明：字段默认值走一个临时上下文，方法降载成以 self 为首参的函数，
        // IR 名为 `方法__类型`，故不会与顶层函数撞名。
        // 字段取自登记表而非原始声明 —— 组合摊平已把继承来的成员并进去了。

        // 给定块字段初值里的两类边：取了哪个给定块、调了哪个顶层函数。键都是给定块名，与函数体的同类边
        // 合成同两张表，环检测读的就是它们。
        var edges = DependencyEdges()
        var typeDecls: [IRTypeDecl] = []
        // 预置声明（宿主提供）也进本表：名义表只让类型名可解析，本表才是执行器建类型表并物化默认实例的
        // 来源 —— 只进名义表会让实例「类型上存在、字段上空」。用同一份 `predefined`：本表是数组，两条同名项
        // 会让下游拿到两份定义（执行器后者胜、发射器发两份）⇒ 在入口处消歧。
        for decl in predefined + module.declarations {
            switch decl {
            case .structDecl(let sd):
                // 泛型模板不产出 typeDecl —— 由特化体产出（登记为名义类型，下面从登记表发射）。
                guard sd.genericParams.isEmpty else { continue }
                let info = nominals[sd.name]!
                typeDecls.append(
                    try lowerNominal(
                        name: sd.name, isObject: false, fields: info.fields,
                        methods: info.methods,
                        typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                        userTypes: userTypes, enums: enums, edges: &edges,
                        genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                        closureIds: closureIds,
                        traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector
                    ))
            case .objectDecl(let od):
                let info = nominals[od.name]!
                typeDecls.append(
                    try lowerNominal(
                        name: od.name, isObject: true, fields: info.fields,
                        methods: info.methods,
                        typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                        userTypes: userTypes, enums: enums, edges: &edges,
                        genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                        closureIds: closureIds,
                        traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector
                    ))
            case .givenDecl(let gd):
                /// 给定块进**类型面**：既登记 `nominals`，也进 `types` ⇒ 有聚合体、可构造
                /// （`配置()` 合法），默认实例才物化得出来。`isObject: false` 与 `nominals` 的
                /// 登记一致：值 / 引用语义不预裁。
                let info = nominals[gd.name]!
                typeDecls.append(
                    try lowerNominal(
                        name: gd.name, isObject: false, fields: info.fields,
                        methods: info.methods,
                        typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                        userTypes: userTypes, enums: enums, edges: &edges, recordsDependencyEdges: true,
                        genericEnums: genericEnums,
                        genericFuncTemplates: genericFuncTemplates,
                        closureIds: closureIds,
                        traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector
                    ))
            default:
                break
            }
        }

        // 泛型给定块的特化进同一张类型表，只到降载面：发射与引擎沿用非泛型路径，故这里只保证「类型存在且
        // 字段已替换」，不新增特化专属的槽位或初始化函数。
        for specializedName in specializationState.givenSpecializations.keys.sorted() {
            let info = nominals[specializedName]!
            typeDecls.append(
                try lowerNominal(
                    name: specializedName, isObject: false, fields: info.fields,
                    methods: info.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                    userTypes: userTypes, enums: enums, edges: &edges, recordsDependencyEdges: true,
                    genericEnums: genericEnums,
                    genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds
                ))
        }

        // 为特化后的结构实例发射 typeDecl（字段 + 重新特化的扩展方法，两者都已登记进 `nominals`）。
        for specializedName in specializationState.structSpecializations.keys {
            let info = nominals[specializedName]!
            guard case .structDecl(let sd) = info.decl else { continue }
            typeDecls.append(
                try lowerNominal(
                    name: specializedName, isObject: false, fields: sd.fields,
                    methods: info.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                    userTypes: userTypes, enums: enums, edges: &edges,
                    genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds
                ))
        }
        // 在派发点特化的特征默认体并入函数表（按 IR 名去重已在派发处完成）。
        functions.append(contentsOf: traitDefaultsCollector.functions)

        // 把 foreign 块降载进纯声明面。
        var foreigns: [IRForeignBlock] = []
        for decl in module.declarations {
            guard case .foreignDecl(let foreignDecl) = decl else { continue }
            var foreignFuncs: [IRForeignFunction] = []
            var foreignDataEntries: [IRForeignData] = []
            for symbol in foreignDecl.symbols where symbol.isFunction {
                let signature = try resolveForeignSignature(symbol)
                foreignFuncs.append(
                    IRForeignFunction(
                        name: symbol.name, params: signature.params, returnType: signature.returnType,
                        isVariadic: symbol.isVariadic
                    ))
            }
            for symbol in foreignDecl.symbols
            where !symbol.isFunction && !symbol.flags.contains("macro") {
                guard let type = foreignData[symbol.name] else {
                    throw unsupported("外部数据符号 '\(symbol.name)' 没有可解析的类型", at: symbol.location)
                }
                foreignDataEntries.append(
                    IRForeignData(
                        name: symbol.name, type: type,
                        isReadonly: symbol.flags.contains("readonly")))
            }
            var constantEntries: [IRForeignConstant] = []
            for symbol in foreignDecl.symbols where symbol.flags.contains("macro") {
                // 没值的宏不进 IR：未求值由 check 在使用点报，这里只收求到值的那几条。
                if let constant = constantTable[symbol.name] {
                    constantEntries.append(constant)
                }
            }
            foreigns.append(
                IRForeignBlock(
                    name: foreignDecl.name, funcs: foreignFuncs, data: foreignDataEntries,
                    constants: constantEntries))
        }

        // 两路键不同源（函数名 / 给定块名），合成一张表而不做覆盖检查：符号表已禁止两者同名。
        // 方法体不在 `functions` 里，要单独并进来：漏了它，经方法的环在方法那里断成两截，整条看不见。
        let methodFunctions = typeDecls.flatMap(\.methods)
        var references = Self.givenReferences(of: functions + methodFunctions)
        for (name, targets) in edges.given { references[name] = targets }
        var calls = Self.callReferences(of: functions + methodFunctions)
        for (name, targets) in edges.call { calls[name] = targets }
        var exportBlock: IRExportBlock?
        let cBlocks = module.exports.filter { block in
            block.entries.contains { $0.target == .c }
        }
        if cBlocks.count > 1 {
            throw unsupported(
                "模块内最多一个文件带 `|c` 条目；`\(cBlocks[1].location.fileName)` 是第二个",
                at: cBlocks[1].location)
        }
        if let block = cBlocks.first {
            exportBlock = try Self.lowerExportBlock(
                block, declarations: module.declarations, userTypes: userTypes,
                errorCodes: errorCodePlan.entries)
        }
        return IRModule(
            functions: functions, types: typeDecls,
            enums: enumOrder.compactMap { enums[$0] },
            foreigns: foreigns,
            export: exportBlock,
            // 物化依赖留痕：这里**不产诊断**。环检测是后置的，此表只保证后置检测
            // 加一条遍历即可，不必重扫降载结果。
            givenReferences: references, callReferences: calls)
    }

    /// 错误载荷的码来源。基址来自 `byType`；枚举载荷由运行时读 tag，非 enum 直接取基址；
    /// 散列类型另带按 tag 索引的码表，非 nil 时运行时不走「基址或 tag」。
    private static func errorCodeInfo(
        for type: IRType, in context: FunctionContext
    ) -> (base: Int32, tagged: Bool, codes: [Int32]?) {
        switch type {
        case .enumeration(let name):
            return (context.errorCodeByType[name] ?? 1, true, context.hashedErrorCodes[name])
        case .nominal(let name, _):
            return (context.errorCodeByType[name] ?? 1, false, nil)
        default:
            return (1, false, nil)
        }
    }

    /// 把 export 块的 `|c` 条目降载成发布面：函数取去掉取用位后的签名，给定块取字段表。
    /// 名字在这里转成 C 标识符，后端只认转写后的名字，不再各自改名。
    private static func lowerExportBlock(
        _ block: ExportDecl, declarations: [TopLevelDecl], userTypes: [String: IRType],
        errorCodes: [PiniErrorCode]
    ) throws -> IRExportBlock {
        var functions: [IRExportFunction] = []
        var storages: [IRExportStorage] = []
        for entry in block.entries where entry.target == .c {
            if let function = freeFunction(named: entry.symbol, in: declarations) {
                let params = try function.params.map { param -> IRExportParam in
                    guard let annotation = param.typeAnnotation,
                        let type = resolveAnnotationType(annotation, userTypes: userTypes)
                    else {
                        throw unsupported(
                            "导出函数 '\(entry.symbol)' 的形参 '\(param.name)' 没有可解析的类型",
                            at: entry.location)
                    }
                    return IRExportParam(type: type, isUsing: param.isUsing)
                }
                functions.append(
                    IRExportFunction(
                        cName: CName.escape(entry.name), pinName: entry.symbol,
                        params: params,
                        returnType: try exportReturnType(function, userTypes: userTypes)))
                continue
            }
            guard let given = givenBlock(named: entry.symbol, in: declarations) else {
                throw unsupported(
                    "导出项 '\(entry.symbol)' 不是本模块的自由函数或给定块", at: entry.location)
            }
            let fields = try given.fields.map { field -> IRExportStorage.Field in
                guard let type = resolveAnnotationType(field.typeAnnotation, userTypes: userTypes)
                else {
                    throw unsupported(
                        "C 面的量 '\(entry.symbol)' 的字段 '\(field.name)' 没有可解析的类型",
                        at: entry.location)
                }
                return IRExportStorage.Field(name: CName.escape(field.name), type: type)
            }
            let escaped = CName.escape(entry.name)
            storages.append(
                IRExportStorage(
                    cName: escaped, typeName: entry.symbol, fields: fields,
                    getterName: "\(escaped)_get"))
        }
        let blockName = CName.escape(block.name)
        return IRExportBlock(
            name: blockName, functions: functions, storages: storages, errorCodes: errorCodes,
            initName: "\(blockName)_init", shutdownName: "\(blockName)_shutdown")
    }

    /// 导出函数的返回位：`-> ()` 与无返回位都是 void，其余按首个返回类型求 IR 类型。
    /// 多返回在语义期已拒，故这里不再合并元组。
    private static func exportReturnType(
        _ function: FuncDecl, userTypes: [String: IRType]
    ) throws -> IRType? {
        guard let declared = function.returnTypes.first else { return nil }
        if case .tuple(_, let elements, _) = declared, elements.isEmpty { return nil }
        guard let type = resolveAnnotationType(declared, userTypes: userTypes) else {
            throw unsupported(
                "导出函数 '\(function.name)' 的返回类型无法解析", at: function.location)
        }
        return type
    }

    private static func freeFunction(named name: String, in declarations: [TopLevelDecl]) -> FuncDecl? {
        for declaration in declarations {
            if case .funcDecl(let function) = declaration, function.name == name { return function }
        }
        return nil
    }

    private static func givenBlock(named name: String, in declarations: [TopLevelDecl]) -> GivenDecl? {
        for declaration in declarations {
            if case .givenDecl(let given) = declaration, given.name == name { return given }
        }
        return nil
    }

    // MARK: - 泛型单态化

    /// 全模块扫描泛型构造点与调用点，登记结构体、枚举、函数的特化。幂等：状态按特化后的源名去重。
    private static func precollectGenericUses(
        in decl: TopLevelDecl,
        genericStructTemplates: [String: StructDecl],
        genericFuncTemplates: [String: FuncDecl],
        nominals: inout [String: NominalInfo],
        state: inout G10SpecializationState
    ) {
        switch decl {
        case .funcDecl(let fd):
            precollectGenericUses(
                in: fd.body?.statements ?? [],
                genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates,
                state: &state)
        case .structDecl(let sd):
            for m in sd.methods {
                precollectGenericUses(
                    in: m.body?.statements ?? [],
                    genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates,
                    state: &state)
            }
        case .objectDecl(let od):
            for m in od.methods {
                precollectGenericUses(
                    in: m.body?.statements ?? [],
                    genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates,
                    state: &state)
            }
        case .enumDecl(let ed):
            for m in ed.methods {
                precollectGenericUses(
                    in: m.body?.statements ?? [],
                    genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates,
                    state: &state)
            }
        case .extensionDecl(let ext):
            for m in ext.methods {
                precollectGenericUses(
                    in: m.body?.statements ?? [],
                    genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates,
                    state: &state)
            }
        default:
            break
        }
    }

    private static func precollectGenericUses(
        in statements: [Statement],
        genericStructTemplates: [String: StructDecl],
        genericFuncTemplates: [String: FuncDecl],
        state: inout G10SpecializationState
    ) {
        for statement in statements {
            precollectGenericUses(
                in: statement,
                genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates,
                state: &state)
        }
    }

    private static func precollectGenericUses(
        in statement: Statement,
        genericStructTemplates: [String: StructDecl],
        genericFuncTemplates: [String: FuncDecl],
        state: inout G10SpecializationState
    ) {
        switch statement {
        case .varDecl(_, _, let initializer, _, _):
            if let e = initializer {
                precollectGenericUses(
                    in: e, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .assign(let target, let value, _):
            if case .member(let base, _) = target {
                precollectGenericUses(
                    in: base, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
            precollectGenericUses(
                in: value, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .expressionStmt(let e, _):
            precollectGenericUses(
                in: e, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .returnStatement(let e, _):
            if let e = e {
                precollectGenericUses(
                    in: e, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
            precollectGenericUses(
                in: condition, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(
                in: thenBlock.statements, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            for branch in elifs {
                precollectGenericUses(
                    in: branch.condition, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
                precollectGenericUses(
                    in: branch.block.statements, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
            if let elseBlock = elseBlock {
                precollectGenericUses(
                    in: elseBlock.statements, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .whileStatement(let condition, let body, _, _, _):
            precollectGenericUses(
                in: condition, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(
                in: body.statements, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .matchStatement(let value, let cases, _):
            precollectGenericUses(
                in: value, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            for matchCase in cases {
                precollectGenericUses(
                    in: matchCase.block.statements, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .deferStatement(let wrapped, _):
            precollectGenericUses(
                in: wrapped, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        default:
            break
        }
    }

    private static func precollectGenericUses(
        in expr: Expression,
        genericStructTemplates: [String: StructDecl],
        genericFuncTemplates: [String: FuncDecl],
        state: inout G10SpecializationState
    ) {
        switch expr {
        case .genericConstruct(let typeName, let typeArgs, _, _):
            if let template = genericStructTemplates[typeName] {
                registerStructSpecialization(
                    template, typeArgs: typeArgs, state: &state
                )
            }
            if genericFuncTemplates[typeName] != nil {
                registerFuncSpecialization(
                    genericFuncTemplates[typeName]!, typeArgs: typeArgs, state: &state
                )
            }
            // 泛型枚举的 case 在裸写法里自带类型实参（`ok<I32, String>(42)`），两个分支都不匹配，
            // 故 case 名查找落在这里。限定写法（`结果<I32, String>.ok(42)`）
            // 经成员的接收者走到同一分支。
            if genericStructTemplates[typeName] == nil, genericFuncTemplates[typeName] == nil,
                let enumTemplate = state.genericEnums.parentTemplate(qualifier: typeName, caseName: typeName)
            {
                registerEnumSpecialization(enumTemplate, typeArgs: typeArgs, state: &state)
            }
        case .call(let callee, let arguments, _):
            precollectGenericUses(
                in: callee, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            // `身份<I32>(...)` 以 genericConstruct 作 callee 出现在调用里 —— 上面的 callee 扫描已登记它。
            for argument in arguments {
                precollectGenericUses(
                    in: argument.expression, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .binary(let lhs, _, let rhs, _):
            precollectGenericUses(
                in: lhs, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(
                in: rhs, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .unary(_, let operand, _):
            precollectGenericUses(
                in: operand, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .member(let base, _, _):
            precollectGenericUses(
                in: base, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .subscript(let container, let index, _):
            precollectGenericUses(
                in: container, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(
                in: index, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tupleIndex(let base, _, _):
            precollectGenericUses(
                in: base, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tryExpression(let operand, _, _, _):
            precollectGenericUses(
                in: operand, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tuple(_, let elements, _):
            for e in elements {
                precollectGenericUses(
                    in: e, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .arrayLiteral(let elements, _):
            for e in elements {
                precollectGenericUses(
                    in: e, genericStructTemplates: genericStructTemplates,
                    genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .stringInterpolation(let segments, _):
            for segment in segments {
                if case .expression(let e) = segment {
                    precollectGenericUses(
                        in: e, genericStructTemplates: genericStructTemplates,
                        genericFuncTemplates: genericFuncTemplates, state: &state)
                }
            }
        default:
            break
        }
    }

    /// 单态化时的类型实参替换：把类型参数名换成实参，递归进元组 / 泛型 / 函数 / 指针的组成位。
    /// 只换 `.simple` 且名字命中替换表的位置，其余原样返回；深度不限，故 `Array<T>` 与 `(T,) -> (T,)`
    /// 一次替换到位，调用方不必逐形处理。不做此递归时容器形参停在 `Array<T>`，降载层无从解析元素类型。
    private static func substituting(
        _ annotation: TypeAnnotation,
        _ substitution: [String: TypeAnnotation]
    ) -> TypeAnnotation {
        switch annotation {
        case .simple(let name, _):
            return substitution[name] ?? annotation
        case .tuple(let labels, let elements, let location):
            return .tuple(
                labels: labels,
                elements: elements.map { substituting($0, substitution) },
                location: location)
        case .generic(let name, let params, let location):
            return .generic(
                name: name,
                params: params.map { substituting($0, substitution) },
                location: location)
        case .function(let params, let returns, let captured, let usingIndices, let location):
            return .function(
                params: params.map { substituting($0, substitution) },
                returns: returns.map { substituting($0, substitution) },
                captured: captured.map { substituting($0, substitution) },
                usingIndices: usingIndices,
                location: location)
        case .pointer(let element, let location):
            return .pointer(element: substituting(element, substitution), location: location)
        }
    }

    /// 登记一份特化函数声明（`身份<I32>` -> `身份_I32`），参数与返回里的类型参数已替换。幂等。
    private static func registerFuncSpecialization(
        _ template: FuncDecl,
        typeArgs: [TypeAnnotation],
        state: inout G10SpecializationState
    ) {
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        guard state.funcSpecializations[specializedName] == nil else { return }
        var substitution: [String: TypeAnnotation] = [:]
        for (index, genericParam) in template.genericParams.enumerated() {
            substitution[genericParam.name] = typeArgs[index]
        }
        let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { annotation in
            guard let annotation = annotation else { return nil }
            return substituting(annotation, substitution)
        }
        let newParams = template.params.map { param in
            Parameter(name: param.name, typeAnnotation: resolveType(param.typeAnnotation))
        }
        let newReturns = template.returnTypes.map(resolveType).compactMap { $0 }
        state.funcSpecializations[specializedName] = FuncDecl(
            name: specializedName,
            modifiers: template.modifiers,
            genericParams: [],
            params: newParams,
            returnTypes: newReturns,
            returnLabels: template.returnLabels,
            isAsync: template.isAsync,
            body: template.body,
            location: template.location
        )
    }

    /// 若这组类型实参尚未出现，登记一份字段已替换的特化结构体声明。
    private static func registerStructSpecialization(
        _ template: StructDecl,
        typeArgs: [TypeAnnotation],
        state: inout G10SpecializationState
    ) {
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        guard state.structSpecializations[specializedName] == nil else { return }
        var substitution: [String: TypeAnnotation] = [:]
        for (index, genericParam) in template.genericParams.enumerated() {
            substitution[genericParam.name] = typeArgs[index]
        }
        let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { annotation in
            guard let annotation = annotation else { return nil }
            if case .simple(let name, _) = annotation, let sub = substitution[name] {
                return sub
            }
            return annotation
        }
        let newFields = template.fields.map { field in
            FieldDecl(
                name: field.name,
                typeAnnotation: resolveType(field.typeAnnotation) ?? field.typeAnnotation,
                initializer: field.initializer,
                location: field.location
            )
        }
        let specialized = StructDecl(
            name: specializedName,
            genericParams: [],
            fields: newFields,
            methods: [],
            composedType: template.composedType,
            traits: template.traits,
            location: template.location
        )
        state.structSpecializations[specializedName] = specialized
        state.structSubstitutions[specializedName] = substitution
    }

    /// 登记一份给定块特化（字段经同一套替换）。与结构体那条的差别只有两点：模板是 `GivenDecl`；
    /// 方法一并带上 —— 给定块的方法表要参与默认实例的成员访问，丢掉就不是同一个类型了。
    /// 字段初值原样保留：替换只动类型标注，不动初值表达式。
    private static func registerGivenSpecialization(
        _ template: GivenDecl,
        typeArgs: [TypeAnnotation],
        state: inout G10SpecializationState
    ) -> GivenDecl {
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        if let existing = state.givenSpecializations[specializedName] { return existing }
        var substitution: [String: TypeAnnotation] = [:]
        for (index, genericParam) in template.genericParams.enumerated() where index < typeArgs.count {
            substitution[genericParam.name] = typeArgs[index]
        }
        let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { annotation in
            guard let annotation = annotation else { return nil }
            if case .simple(let name, _) = annotation, let sub = substitution[name] { return sub }
            return annotation
        }
        let resolveParam: (Parameter) -> Parameter = { parameter in
            Parameter(
                name: parameter.name,
                typeAnnotation: resolveType(parameter.typeAnnotation) ?? parameter.typeAnnotation,
                isUsing: parameter.isUsing
            )
        }
        let specialized = GivenDecl(
            name: specializedName,
            genericParams: [],
            fields: template.fields.map { field in
                FieldDecl(
                    name: field.name,
                    typeAnnotation: resolveType(field.typeAnnotation) ?? field.typeAnnotation,
                    initializer: field.initializer,
                    location: field.location
                )
            },
            methods: template.methods.map { method in
                FuncDecl(
                    name: method.name,
                    modifiers: method.modifiers,
                    genericParams: method.genericParams,
                    params: method.params.map(resolveParam),
                    returnTypes: method.returnTypes.map { resolveType($0) ?? $0 },
                    returnLabels: method.returnLabels,
                    isAsync: method.isAsync,
                    body: method.body,
                    location: method.location,
                    captured: method.captured
                )
            },
            traits: template.traits,
            location: template.location
        )
        state.givenSpecializations[specializedName] = specialized
        return specialized
    }

    /// 每个具体类型实参组合一份特化枚举体（`结果` + [I32, String] -> `结果_I32_String`），
    /// 载荷都按结构体路径那套替换改过。case 顺序、进而是每个 tag，原样继承 ——
    /// 这正是按值 `match` 还能继续用下去的原因。
    private static func registerEnumSpecialization(
        _ template: EnumDecl,
        typeArgs: [TypeAnnotation],
        state: inout G10SpecializationState
    ) {
        // 实参个数在构造点校验，那里拿得到源码拼写，报错信息才带得上。
        // 这里不登记任何东西，用户看到的就仍是构造点自己抛的那个错。
        guard typeArgs.count == template.genericParams.count else { return }
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        guard state.enumSpecializations[specializedName] == nil else { return }
        var substitution: [String: TypeAnnotation] = [:]
        for (index, genericParam) in template.genericParams.enumerated() {
            substitution[genericParam.name] = typeArgs[index]
        }
        let resolveType: (TypeAnnotation) -> TypeAnnotation = { annotation in
            if case .simple(let name, _) = annotation, let sub = substitution[name] {
                return sub
            }
            return annotation
        }
        let specializedCases = template.cases.map { enumCase in
            EnumCase(
                name: enumCase.name,
                associatedParams: enumCase.associatedParams.map { param in
                    AssociatedParam(
                        name: param.name,
                        type: resolveType(param.type),
                        defaultValue: param.defaultValue
                    )
                },
                location: enumCase.location
            )
        }
        state.enumSpecializations[specializedName] = EnumDecl(
            name: specializedName,
            genericParams: [],
            cases: specializedCases,
            methods: [],
            traits: template.traits,
            location: template.location
        )
    }

    /// 为一个具体实例重新特化一条 `((盒<T>))` 扩展方法：类型参数替换，名字不动
    /// （名义派发经接收者把它绑到特化后的类型上）。
    fileprivate static func specializeMethodForGenericStruct(
        _ method: FuncDecl,
        structTemplate: StructDecl,
        substitution: [String: TypeAnnotation],
        specializedName: String
    ) -> FuncDecl {
        _ = structTemplate
        _ = specializedName
        let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { annotation in
            guard let annotation = annotation else { return nil }
            if case .simple(let name, _) = annotation, let sub = substitution[name] {
                return sub
            }
            return annotation
        }
        let newParams = method.params.map { param in
            Parameter(name: param.name, typeAnnotation: resolveType(param.typeAnnotation))
        }
        let newReturns = method.returnTypes.map(resolveType).compactMap { $0 }
        return FuncDecl(
            name: method.name,
            modifiers: method.modifiers,
            genericParams: [],
            params: newParams,
            returnTypes: newReturns,
            returnLabels: method.returnLabels,
            isAsync: method.isAsync,
            body: method.body,
            location: method.location
        )
    }

    /// 把 `身份<I32>(x = 100)` 派发到已登记的特化 `身份_I32`。
    /// 类型实参个数必须与模板一致；实参类型按特化后的签名校验。
    private static func lowerGenericFuncCall(
        template: FuncDecl,
        typeArgs: [TypeAnnotation],
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        guard template.genericParams.count == typeArgs.count else {
            throw unsupported(
                "type arg count mismatch: \(template.name) expects \(template.genericParams.count), got \(typeArgs.count)",
                at: location
            )
        }
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        guard let signature = context.moduleSignatures[specializedName] else {
            throw unsupported(
                "generic call '\(specializedName)' has no registered specialization",
                at: location
            )
        }
        // 实参降载按位置顺序；标签已由解析器按参数名校验过。
        let loweredArgs = try arguments.map { argument in
            try lowerExpr(argument.expression, expected: nil, into: &context)
        }
        guard loweredArgs.count == signature.paramTypes.count else {
            throw unsupported(
                "call to '\(specializedName)' expects \(signature.paramTypes.count) arguments, got \(loweredArgs.count)",
                at: location
            )
        }
        for (index, argument) in loweredArgs.enumerated() where !signature.untypedParamIndices.contains(index) {
            try requireAssignable(argument.type, to: signature.paramTypes[index], at: location)
        }
        context.recordCall(specializedName)
        return LoweredExpr(
            node: .call(
                function: specializedName,
                arguments: loweredArgs.map { $0.node },
                returnType: signature.bodyReturnType
            ),
            type: signature.returnType ?? .i32
        )
    }

    // MARK: - 函数

    /// 异步（`=>`）函数体交给调用方 join 的类型，即函数体自己的返回类型：`return ok(v)` / `return err(e)`
    /// 各点都按它校验（检查器要求 `Result<T, Error>`，裸 `=> ()` 保留空返回值路径）。
    /// 调用方看到的是 `asyncSignatureReturnType`，不是这个。
    private static func asyncBodyReturnType(
        declared: IRType?, isAsync: Bool
    ) -> IRType? {
        guard isAsync else { return declared }
        // `=> ()` 没有载荷，但体的每条出口都要写三槽 Result ⇒ void 也占一个 i32 槽。
        return .result(ok: declared ?? .i32)
    }

    /// 调用方看到的异步（`=>`）函数类型：一个运行中的句柄，而非它最终落定的值。必须是独立的 IR 类型 ——
    /// 后端按类型搬运值，两处都标成 Result 的话，fork 到 worker 的调用就跟普通调用分不开了。
    private static func asyncSignatureReturnType(
        declared: IRType?, isAsync: Bool
    ) -> IRType? {
        guard isAsync else { return declared }
        // 与体的三槽一致：void 载荷同样占一个 i32 槽，调用点才拿得到句柄。
        return .future(ok: declared ?? .i32)
    }

    private static func lowerFunction(
        _ decl: FuncDecl,
        typeInference: TypeInference?,
        moduleSignatures: [String: IRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: IRType],
        enums: [String: IREnumDecl],
        genericEnums: IRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector(),
        builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:],
        foreignData: [String: IRType] = [:],
        foreignConstants: [String: IRForeignConstant] = [:],
        declaredMacros: Set<String> = [],
        errorCodeByType: [String: Int32] = [:],
        hashedErrorCodes: [String: [Int32]] = [:]
    ) throws -> IRFunction {
        guard decl.body != nil else {
            throw unsupported("function '\(decl.name)' has no body", at: decl.location)
        }
        guard decl.genericParams.isEmpty else {
            throw unsupported("generic function '\(decl.name)'", at: decl.location)
        }
        // 多个返回槽折叠成一个元组值，见 resolveReturnType。
        let returnType = try resolveReturnType(
            decl, userTypes: userTypes, subject: "'\(decl.name)'"
        )
        // 声明为 void 却返回值时按有效返回类型处理；必须与签名表的升级一致，否则调用点与定义对不上。
        let effectiveReturn =
            try effectiveReturnType(
                decl: decl, userTypes: userTypes, nominals: nominalTypes
            ) ?? returnType

        // 定义与签名表必须给出同一个返回类型（见 effectiveReturnType），异步 Result 形状也算在内。
        let bodyReturn = asyncBodyReturnType(declared: effectiveReturn, isAsync: decl.isAsync)

        let paramTypes = try resolveParamTypes(decl, userTypes: userTypes)
        let params: [IRFunction.IRParam] = zip(decl.params, paramTypes).map { param, type in
            IRFunction.IRParam(name: param.name, type: type, isUsing: param.isUsing)
        }

        var context = FunctionContext(
            functionName: decl.name,
            returnType: bodyReturn,
            paramTypes: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.type) }),
            typeInference: typeInference,
            moduleSignatures: moduleSignatures,
            nominalTypes: nominalTypes,
            userTypes: userTypes,
            enums: enums,
            genericEnums: genericEnums,
            genericFuncTemplates: genericFuncTemplates,
            closureIds: closureIds,
            traitRegistry: traitRegistry,
            traitDefaultsCollector: traitDefaultsCollector,
            builtinExtensionMethods: builtinExtensionMethods
        )
        context.foreignData = foreignData
        context.errorCodeByType = errorCodeByType
        context.hashedErrorCodes = hashedErrorCodes
        context.foreignConstants = foreignConstants
        context.declaredMacros = declaredMacros
        context.isAsync = decl.isAsync
        context.isAsyncVoid = decl.isAsync && effectiveReturn == nil
        let body = try lowerBlock(decl.body!, into: &context, trailingValue: bodyReturn)
        return IRFunction(
            name: decl.name, params: params, returnType: bodyReturn, body: body,
            isAsync: decl.isAsync,
            // `|test` 以修饰符字符串到达；词法器已把该块的关键字归一成这个拼写。
            isTest: decl.modifiers.contains("test"),
            sourceFile: decl.location.fileName,
            givenReferenceNames: context.givenReferenceNames,
            calledFunctionNames: context.calledFunctionNames
        )
    }

    // MARK: - 标注解析（用户定义类型）

    /// 为一个枚举声明构造 IR 枚举登记项，其载荷标注预期可解析。模块自身的非泛型枚举与
    /// 特化后的泛型体共用此函数 —— 走到这里两者已无从区分。
    private static func resolveEnumPayloads(
        _ ed: EnumDecl,
        userTypes: [String: IRType]
    ) throws -> IREnumDecl {
        var resolvedCases: [IREnumCase] = []
        for (index, ec) in ed.cases.enumerated() {
            var payloadTypes: [IRType] = []
            for param in ec.associatedParams {
                guard let payloadType = resolveAnnotationType(param.type, userTypes: userTypes) else {
                    throw unsupported(
                        "associated value '\(param.name ?? "?")' of case '\(ec.name)' lacks a resolvable type",
                        at: ed.location
                    )
                }
                payloadTypes.append(payloadType)
            }
            resolvedCases.append(
                IREnumCase(
                    name: ec.name, tag: index,
                    paramNames: ec.associatedParams.map { $0.name },
                    payloadTypes: payloadTypes
                ))
        }
        return IREnumDecl(name: ed.name, cases: resolvedCases)
    }

    private static func resolveAnnotationType(
        _ annotation: TypeAnnotation,
        userTypes: [String: IRType]
    ) -> IRType? {
        // 函数标注的形参可以是用户类型（如取用参数的给定块），`IRType(from:)` 只认内建，故逐位过
        // `resolveUsingParamType`。多返回不在 slice 集内，与内建路径同样拒绝。
        if case .function(let aParams, let aReturns, _, let usingIndices, _) = annotation {
            guard aReturns.count <= 1 else { return nil }
            var paramTypes: [IRType] = []
            for param in aParams {
                guard let resolved = resolveUsingParamType(param, userTypes: userTypes) else { return nil }
                paramTypes.append(resolved)
            }
            var resolvedReturn: IRType?
            if let first = aReturns.first {
                guard let resolved = resolveUsingParamType(first, userTypes: userTypes) else { return nil }
                resolvedReturn = resolved
            }
            return .function(params: paramTypes, returnType: resolvedReturn, usingIndices: usingIndices)
        }
        if let builtin = IRType(from: annotation) { return builtin }
        // 内建容器只在元素也是内建时才被 `IRType(from:)` 接住；`Array<用户类型>` 这类字段要逐层
        // 走用户类型表，否则字段查得到却解析不出类型，报出来像是「字段不存在」。
        if case .generic(let container, let params, _) = annotation {
            switch container {
            case "Array" where params.count == 1:
                guard let element = resolveAnnotationType(params[0], userTypes: userTypes) else {
                    return nil
                }
                return .array(element: element)
            case "Optional" where params.count == 1:
                guard let wrapped = resolveAnnotationType(params[0], userTypes: userTypes) else {
                    return nil
                }
                return .optional(wrapped: wrapped)
            case "Set" where params.count == 1:
                guard let element = resolveAnnotationType(params[0], userTypes: userTypes) else {
                    return nil
                }
                return .set(element: element)
            case "Dict" where params.count == 2:
                guard let key = resolveAnnotationType(params[0], userTypes: userTypes),
                    let value = resolveAnnotationType(params[1], userTypes: userTypes)
                else { return nil }
                return .dict(key: key, value: value)
            /// 三种引用句柄的元素可以是用户类型，`IRType(from:)` 只认内建元素，故在此逐层重解。
            case "WeakRef" where params.count == 1:
                guard let element = resolveAnnotationType(params[0], userTypes: userTypes) else { return nil }
                return .weakRef(element: element)
            case "UnownedRef" where params.count == 1:
                guard let element = resolveAnnotationType(params[0], userTypes: userTypes) else { return nil }
                return .unownedRef(element: element)
            case "LazyRef" where params.count == 1:
                guard let element = resolveAnnotationType(params[0], userTypes: userTypes) else { return nil }
                return .lazyRef(element: element)
            default:
                break
            }
        }
        if case .simple(let name, _) = annotation {
            return userTypes[name]
        }
        return nil
    }

    /// 未写类型标注的参数位置。调用点规则的唯一来源：签名构建时记下这些位置，
    /// 调用点比对正好跳过它们。这些槽的类型仍取声明的回退值（单一已声明返回类型，否则 `I32`）。
    private static func untypedParamIndices(_ decl: FuncDecl) -> Set<Int> {
        Set(
            decl.params.enumerated().compactMap { index, parameter in
                parameter.typeAnnotation == nil ? index : nil
            })
    }

    /// 一个顶层声明里全部参数表（自由函数 / 方法 / 特征默认体 / 扩展方法）。泛型给定块的特化只出现在
    /// `using` 形参的类型标注上，故扫描面就是参数表本身：语句级预扫看不见类型标注，两者互补而非重复。
    private static func usingAnnotationParamLists(of decl: TopLevelDecl) -> [[Parameter]] {
        switch decl {
        case .funcDecl(let fd): return [fd.params]
        case .structDecl(let sd): return sd.methods.map(\.params)
        case .objectDecl(let od): return od.methods.map(\.params)
        case .givenDecl(let gd): return gd.methods.map(\.params)
        case .extensionDecl(let x): return x.methods.map(\.params)
        case .traitDecl(let td): return td.signatures.filter { $0.body != nil }.map(\.params)
        case .enumDecl(let ed): return ed.methods.map(\.params)
        case .foreignDecl: return []
        case .varDecl, .statement, .importDecl, .exportDecl: return []
        }
    }

    /// `using` 形参的位置（0 基）。与 `untypedParamIndices` 并列，理由相同：这个量在声明侧成立，
    /// 调用侧照它判合法性并补实参 —— 两处必须来自同一个函数，否则会漂。
    private static func usingParamIndices(_ decl: FuncDecl) -> Set<Int> {
        Set(
            decl.params.enumerated().compactMap { index, parameter in
                parameter.isUsing ? index : nil
            })
    }

    /// 依赖留痕的聚合 —— 函数名 → 它取用过的给定块类型（升序）。
    private static func givenReferences(of functions: [IRFunction]) -> [String: [String]] {
        var edges: [String: [String]] = [:]
        for function in functions where !function.givenReferenceNames.isEmpty {
            edges[function.name] = function.givenReferenceNames.sorted()
        }
        return edges
    }

    /// 调用留痕的聚合 —— 函数名 → 它直接调用过的顶层函数（升序）。与上面那张表分开聚合，
    /// 因为环检测要能只凭值的面判定「哪些节点是给定块」。
    private static func callReferences(of functions: [IRFunction]) -> [String: [String]] {
        var edges: [String: [String]] = [:]
        for function in functions where !function.calledFunctionNames.isEmpty {
            edges[function.name] = function.calledFunctionNames.sorted()
        }
        return edges
    }

    /// 把一次调用的实参映射到形参位，口径与检查器 `FunctionSignature.argumentToParamIndices` 一致：
    /// 全显式 ⇒ 恒等；省略式（个数 = 形参个数 − using 个数）⇒ 实参只落非 using 位；都不成立 ⇒ arity 错。
    private static func usingParamMapping(
        callee: String,
        paramCount: Int,
        usingParamIndices: Set<Int>,
        argumentCount: Int,
        at location: SourceLocation
    ) throws -> [Int] {
        if argumentCount == paramCount { return Array(0..<paramCount) }
        guard !usingParamIndices.isEmpty, argumentCount == paramCount - usingParamIndices.count else {
            throw unsupported(
                "call to '\(callee)' expects \(paramCount - usingParamIndices.count) arguments, got \(argumentCount)",
                at: location
            )
        }
        return (0..<paramCount).filter { !usingParamIndices.contains($0) }
    }

    /// `using` 形参的类型：通用路径之外多一条泛型给定块特化的路。`IRType(from:)` 与
    /// `resolveAnnotationType` 只吃简单名，而标注位写的是 `匣<I32>`，故先按特化名查一次 `userTypes`。
    private static func resolveUsingParamType(
        _ annotation: TypeAnnotation,
        userTypes: [String: IRType]
    ) -> IRType? {
        if case .generic(let name, let typeArgs, _) = annotation,
            let specialized = userTypes[specializedSourceName(name, typeArgs: typeArgs)]
        {
            return specialized
        }
        return IRType(from: annotation) ?? resolveAnnotationType(annotation, userTypes: userTypes)
    }

    /// 把推断出的函数类型标注逐位解析成 IR 函数类型。不能直接用 `IRType(from:)` —— 它只吃内建简单名，
    /// 而匿名函数的参数类型可以是用户类型（给定块、结构、对象…），故逐位走 `resolveUsingParamType`。
    /// 取用下标集合原样透传。
    private static func resolvedFunctionType(
        _ annotation: TypeAnnotation,
        userTypes: [String: IRType]
    ) -> IRType? {
        guard case .function(let aParams, let aReturns, _, let usingIndices, _) = annotation else {
            return IRType(from: annotation)
        }
        let params = aParams.compactMap { resolveUsingParamType($0, userTypes: userTypes) }
        guard params.count == aParams.count else { return nil }
        let returns = aReturns.compactMap { resolveUsingParamType($0, userTypes: userTypes) }
        return .function(params: params, returnType: returns.first, usingIndices: usingIndices)
    }

    /// 一个 `using` 形参的取用点：只判该类型有默认实例，即它得是给定块（`[名|given]`）。字段是否齐全
    /// 不在这里判 —— 那条判据在声明处对每个给定块执行，跑到调用点时声明早已过一遍。
    private static func givenInstanceNode(
        forParamType type: IRType,
        callee: String,
        nominalTypes: [String: NominalInfo],
        into context: inout FunctionContext,
        at location: SourceLocation
    ) throws -> LoweredExpr {
        guard case .nominal(let name, let isObject) = type, !isObject,
            let info = nominalTypes[name], case .givenDecl = info.decl
        else {
            throw rejected(
                "'\(callee)' 的取用参数：类型 '\(type.llvmSpelling)' 无默认实例"
                    + "（默认实例只由给定块 `[名|given]` 提供 —— ADR-001）",
                code: noDefaultInstanceCode, at: location
            )
        }
        context.givenReferenceNames.insert(name)
        return LoweredExpr(node: .givenInstance(type: type), type: type)
    }

    /// 把降载好的实参放回形参位，并在 `using` 位补取用点。
    private static func fillUsingArguments(
        retypedArgs: [LoweredExpr],
        paramIndices: [Int],
        paramTypes: [IRType],
        usingParamIndices: Set<Int>,
        omittedForm: Bool,
        callee: String,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [IRExpr] {
        // 全显式形态下一位都不注入：那种形态里每个形参位都有调用点给的实参，在 `using` 位再插一个取用点会
        // 把它顶掉（`取(5, 6,)` 会变成「5 被忽略、甲 取默认实例」）。显式提供合法，这条守卫就是它的落地。
        guard omittedForm else { return retypedArgs.map(\.node) }
        var nodes: [IRExpr] = []
        var next = 0
        for paramIndex in paramTypes.indices {
            if usingParamIndices.contains(paramIndex) {
                nodes.append(
                    try givenInstanceNode(
                        forParamType: paramTypes[paramIndex], callee: callee,
                        nominalTypes: context.nominalTypes, into: &context, at: location
                    ).node)
            } else {
                nodes.append(retypedArgs[next].node)
                next += 1
            }
        }
        return nodes
    }

    /// 一个实参按形参位降载。句柄位是唯一有转换的方向：Pini 串在这一位包一次 `bk_str_handle_new`，
    /// 已经是句柄的值原样过，其余位置照旧逐位比对。转换在这里而不是发射层 ——
    /// 那里只剩 LLVM 拼写，`String` 与 `StringHandle` 都是 `ptr`，分不出该不该包。
    private static func lowerCallArgument(
        _ expression: Expression, paramIndex: Int, signature: IRLowererSignatureInfo,
        at location: SourceLocation, into context: inout FunctionContext
    ) throws -> LoweredExpr {
        guard signature.handleParamIndices.contains(paramIndex) else {
            return try lowerExpr(
                expression, expected: signature.paramTypes[paramIndex], into: &context)
        }
        let lowered = try lowerExpr(expression, expected: .string, into: &context)
        switch lowered.type {
        case .stringHandle:
            return lowered
        case .string:
            return LoweredExpr(
                node: .call(
                    function: stringHandleMakeName, arguments: [lowered.node],
                    returnType: .stringHandle),
                type: .stringHandle)
        default:
            throw unsupported(
                "句柄形参只收 String 或另一个句柄，实际得到 `\(lowered.type.describe())`",
                at: location)
        }
    }

    /// 句柄构造在 IR 里的调用名。带点 ⇒ 不可能是合法的 Pini 标识符，与用户函数无从重名；
    /// 发射层按这个名字接 `bk_str_handle_new`（两侧共用这一份，名字不会各写一遍）。
    public static let stringHandleMakeName = "pini.str.handle"

    /// 变参调用的实参表：固定前缀按签名逐位降载，多出来的只收 C 标量与指针。
    /// 提升不在这里做 —— 同一个值在别处也有自己的宽度，改写留给只看得到调用形状的发射层。
    private static func lowerVariadicArguments(
        callee: String, arguments: [CallArgument], signature: IRLowererSignatureInfo,
        at location: SourceLocation, into context: inout FunctionContext
    ) throws -> [IRExpr] {
        let fixed = signature.paramTypes.count
        guard arguments.count >= fixed else {
            throw unsupported(
                "call to '\(callee)' expects at least \(fixed) arguments, got \(arguments.count)",
                at: location)
        }
        var nodes: [IRExpr] = []
        for (index, argument) in arguments.prefix(fixed).enumerated() {
            let lowered = try lowerCallArgument(
                argument.expression, paramIndex: index, signature: signature,
                at: location, into: &context)
            if !signature.untypedParamIndices.contains(index),
                !signature.handleParamIndices.contains(index)
            {
                try requireAssignable(lowered.type, to: signature.paramTypes[index], at: location)
            }
            nodes.append(lowered.node)
        }
        for argument in arguments.dropFirst(fixed) {
            let lowered = try lowerExpr(argument.expression, expected: nil, into: &context)
            guard variadicTailAccepts(lowered.type) else {
                throw unsupported(
                    "variadic argument of '\(callee)' has type \(lowered.type.describe()); "
                        + "C's default argument promotions cover only scalars and pointers",
                    at: location)
            }
            nodes.append(lowered.node)
        }
        return nodes
    }

    /// 变参尾能接的形状。`.string` 按借出传；`.cFunction` 不在内 —— 变参尾不带类型标记，
    /// C 看不出这里要一个函数指针。
    private static func variadicTailAccepts(_ type: IRType) -> Bool {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .f64, .boolean, .string, .pointer:
            return true
        default:
            return false
        }
    }

    private static func resolveParamTypes(
        _ decl: FuncDecl,
        userTypes: [String: IRType]
    ) throws -> [IRType] {
        let fallback: IRType
        if decl.returnTypes.count == 1,
            let single = resolveAnnotationType(decl.returnTypes[0], userTypes: userTypes)
        {
            fallback = single
        } else {
            fallback = .i32
        }
        return try decl.params.map { parameter in
            guard let annotation = parameter.typeAnnotation else { return fallback }
            // 走 `resolveUsingParamType`：它比 `resolveAnnotationType` 多一条**泛型给定块
            // 特化**的路（`using 箱: 匣<I32>` 的类型标注是泛型形，通用解析只吃简单名）。
            // 非泛型标注两条路等价，故这只是放宽。
            guard let type = resolveUsingParamType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "parameter '\(parameter.name)' of '\(decl.name)' lacks a resolvable scalar type",
                    at: decl.location
                )
            }
            return type
        }
    }

    /// 解析一条外部函数的签名：形参逐位求 FFI 类型，返回至多一项。
    /// 类型面只有 `FFIType` 一份判据，这里只搬运；多返回仍在这里拒绝，因为 IR 只有一个返回位。
    private static func resolveForeignSignature(
        _ symbol: ForeignSymbol
    ) throws -> (params: [FFIType], returnType: FFIType?) {
        let params = try symbol.paramTypes.map { annotation in
            try ffiType(annotation, at: .parameter, symbol: symbol)
        }
        guard symbol.returnTypes.count <= 1 else {
            throw unsupported(
                "foreign '\(symbol.name)' declares \(symbol.returnTypes.count) return values; only one is supported",
                at: symbol.location
            )
        }
        let returnType = try symbol.returnTypes.first.map { annotation in
            try ffiType(annotation, at: .result, symbol: symbol)
        }
        return (params, returnType)
    }

    /// 归一失败翻成降载期的 unsupported，措辞与语义期同一套判据、不同的出口。
    private static func ffiType(
        _ annotation: TypeAnnotation, at position: FFIType.Position, symbol: ForeignSymbol
    ) throws -> FFIType {
        do {
            return try FFIType.resolve(annotation, at: position)
        } catch let error as FFITypeError {
            throw unsupported(Self.message(for: error, symbol: symbol.name), at: symbol.location)
        }
    }

    private static func message(for error: FFITypeError, symbol: String) -> String {
        switch error {
        case .notRepresentable(let type, let reason):
            return "外部符号 '\(symbol)' 的类型 `\(type)` 不可用：\(reason)"
        case .widthNotInIR(let type):
            return "外部符号 '\(symbol)' 的类型 `\(type)` 在 IR 里没有对应宽度"
        case .cStringInReturnPosition:
            return "外部符号 '\(symbol)' 不能用 String 作返回类型：C 返回的指针归属不明"
        case .callbackOutsideParameter:
            return "外部符号 '\(symbol)' 的函数指针不在形参位：返回位没有可承载它的值类型"
        case .booleanInCallback:
            return "外部符号 '\(symbol)' 的回调签名含 Bool：`i1` 与 `_Bool` 的寄存器约定不同"
        }
    }

    /// 声明的返回类型（IR 形式）。多个返回槽（`-> (I32, I32,)`）折叠成一个元组值 ——
    /// 与 `-> ((I32, I32,),)` 的表示相同 —— 调用点、返回语句和 ABI 都不必走第二条路径。
    /// 元素按位置排列，故标签全为 nil；`subject` 说明这是哪一类声明。
    private static func resolveReturnType(
        _ decl: FuncDecl,
        userTypes: [String: IRType],
        subject: String
    ) throws -> IRType? {
        func resolve(_ annotation: TypeAnnotation) throws -> IRType {
            guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "return type '\(annotation.simpleName ?? "(non-scalar)")' of \(subject)",
                    at: decl.location
                )
            }
            return type
        }
        switch decl.returnTypes.count {
        case 0:
            return nil
        case 1:
            return try resolve(decl.returnTypes[0])
        default:
            let fieldTypes = try decl.returnTypes.map(resolve)
            // 声明的分量名要随行：`-> (商: I32, 余: I32,)` 不是装饰。解释器在边界按
            // `decl.returnLabels` 重挂标签，执行器按这个类型重挂，发射器直接从它打印元组标签。
            // 只有真正写了名字的签名才打开它。
            let named = decl.returnLabels.contains { $0 != nil }
            return .tuple(
                labels: named && decl.returnLabels.count == fieldTypes.count
                    ? decl.returnLabels
                    : Array(repeating: nil, count: fieldTypes.count),
                fieldTypes: fieldTypes
            )
        }
    }

    // MARK: - 名义类型

    /// 降载期收集的两类边，键都是「谁」，值都是「它依赖谁」。给定块字段初值与函数体共用同一套收集器；
    /// 结构体与对象块的初值发生在构造时、不是载入时，故它们的边只在开关打开时才写出。
    struct DependencyEdges {
        var given: [String: [String]] = [:]
        var call: [String: [String]] = [:]
    }

    /// 降载一个结构体/object 声明：字段默认值走临时上下文，方法降载成以 self 为首参的
    /// `IRFunction`，名为 `方法__类型`（双下划线分隔符不会与 mangle 输出相撞，
    /// 后者对 ASCII 名字从不产出下划线）。
    private static func lowerNominal(
        name: String,
        isObject: Bool,
        fields: [FieldDecl],
        methods: [FuncDecl],
        typeInference: TypeInference?,
        moduleSignatures: [String: IRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: IRType],
        enums: [String: IREnumDecl],
        edges: inout DependencyEdges,
        recordsDependencyEdges: Bool = false,
        genericEnums: IRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> IRTypeDecl {
        let selfType = IRType.nominal(name: name, isObject: isObject)
        var scratch = FunctionContext(
            functionName: "<field-default:\(name)>", returnType: nil, paramTypes: [:],
            typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes,
            userTypes: userTypes, enums: enums, genericEnums: genericEnums, closureIds: closureIds
        )
        var loweredFields: [IRTypeDecl.Field] = []
        for field in fields {
            guard let fieldType = resolveAnnotationType(field.typeAnnotation, userTypes: userTypes) else {
                throw unsupported(
                    "field '\(field.name)' of '\(name)' lacks a resolvable type",
                    at: field.location
                )
            }
            var defaultValue: IRExpr? = nil
            if let initializer = field.initializer {
                let lowered = try lowerExpr(initializer, expected: fieldType, into: &scratch)
                try requireAssignable(lowered.type, to: fieldType, at: field.location)
                defaultValue = lowered.node
            }
            loweredFields.append(IRTypeDecl.Field(name: field.name, type: fieldType, defaultValue: defaultValue))
        }
        var loweredMethods: [IRFunction] = []
        for method in methods {
            loweredMethods.append(
                try lowerMethod(
                    method, typeName: name, selfType: selfType,
                    typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes,
                    userTypes: userTypes, enums: enums, genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds, traitRegistry: traitRegistry,
                    traitDefaultsCollector: traitDefaultsCollector
                ))
        }
        // 字段初值里的取用点记在临时上下文上，函数返回时本该随上下文丢弃。给定块那一路要把它带出去：
        // 默认实例正是由这些初值物化出来的，取用与调用都是「载入期依赖」；结构体与对象块的同类边发生在构造时，不算。
        if recordsDependencyEdges {
            if !scratch.givenReferenceNames.isEmpty {
                edges.given[name] = scratch.givenReferenceNames.sorted()
            }
            if !scratch.calledFunctionNames.isEmpty {
                edges.call[name] = scratch.calledFunctionNames.sorted()
            }
        }
        return IRTypeDecl(name: name, isObject: isObject, fields: loweredFields, methods: loweredMethods)
    }

    /// 降载一个方法：IR 名为 `方法__类型`，参数表 = [self] + 声明的参数。
    private static func lowerMethod(
        _ decl: FuncDecl,
        typeName: String,
        selfType: IRType,
        isOwn: Bool = false,
        typeInference: TypeInference?,
        moduleSignatures: [String: IRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: IRType],
        enums: [String: IREnumDecl],
        genericEnums: IRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> IRFunction {
        guard decl.body != nil else {
            throw unsupported("method '\(decl.name)' of '\(typeName)' has no body", at: decl.location)
        }
        guard decl.genericParams.isEmpty else {
            throw unsupported("generic method '\(decl.name)'", at: decl.location)
        }
        if isOwn, decl.params.first?.name == "self" {
            throw unsupported("own method '\(decl.name)' cannot declare self", at: decl.location)
        }
        // 多个返回槽折叠成一个元组值，契约与顶层函数相同。
        let returnType = try resolveReturnType(
            decl, userTypes: userTypes, subject: "'\(decl.name)'"
        )
        // 声明为 void 却返回值的方法，升级为有效返回类型；函数体返回与调用点都用它。
        let effectiveReturn =
            try effectiveReturnType(
                decl: decl, userTypes: userTypes, nominals: nominalTypes,
                selfTypeName: typeName
            ) ?? returnType
        var params: [IRFunction.IRParam] = isOwn ? [] : [IRFunction.IRParam(name: "self", type: selfType)]
        // 接收者也可能写成显式的前导 `self` 参数（trait 默认实现就是这样）。它是接收者标记而非参数：
        // 解释器、检查器和 trait 签名预扫描都会丢掉它，当成普通参数降载会让它显得没有类型标注。
        let declaredParams =
            decl.params.first?.name == "self"
            ? Array(decl.params.dropFirst()) : decl.params
        for param in declaredParams {
            guard let annotation = param.typeAnnotation,
                let type = resolveAnnotationType(annotation, userTypes: userTypes)
            else {
                throw unsupported(
                    "parameter '\(param.name)' of method '\(decl.name)' lacks a resolvable type",
                    at: decl.location
                )
            }
            params.append(IRFunction.IRParam(name: param.name, type: type, isUsing: param.isUsing))
        }
        let irName = isOwn
            ? IRName.ownMethod(decl.name, on: typeName)
            : "\(IRName.mangle(decl.name))__\(IRName.mangle(typeName))"
        var context = FunctionContext(
            functionName: irName,
            returnType: effectiveReturn,
            paramTypes: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.type) }),
            typeInference: typeInference,
            moduleSignatures: moduleSignatures,
            nominalTypes: nominalTypes,
            userTypes: userTypes,
            enums: enums,
            genericEnums: genericEnums,
            genericFuncTemplates: genericFuncTemplates,
            closureIds: closureIds,
            traitRegistry: traitRegistry,
            traitDefaultsCollector: traitDefaultsCollector
        )
        context.isAsync = decl.isAsync
        // 方法体内裸字段名按接收者的字段解析（trait 默认体里就写 `名字`，不带 `self.`）。
        // 发射时在标识符处走一次显式 self 装载加 fieldGet。
        if !isOwn, case .nominal(let selfTypeName, let selfIsObject) = selfType,
            let info = nominalTypes[selfTypeName]
        {
            var fieldTypes: [String: IRType] = [:]
            for field in info.fields {
                if let fieldType = resolveAnnotationType(field.typeAnnotation, userTypes: userTypes) {
                    fieldTypes[field.name] = fieldType
                }
            }
            context.selfFieldTypes = fieldTypes
            context.selfTypeNameLowered = selfTypeName
            context.selfIsObjectLowered = selfIsObject
        }
        /// 异步方法体不套 Result 形（与自由函数的 `bodyReturn` 不同），故只在同步方法上认尾表达式：
        /// 给异步方法一个非 Result 的期望类型，会把 `ok(...)` 之外的值也当成可交出的载荷。
        let body = try lowerBlock(
            decl.body!, into: &context, trailingValue: decl.isAsync ? nil : effectiveReturn)
        return IRFunction(
            name: irName, params: params, returnType: effectiveReturn, body: body,
            sourceFile: decl.location.fileName, givenReferenceNames: context.givenReferenceNames,
            calledFunctionNames: context.calledFunctionNames, displayName: "\(typeName).\(decl.name)")
    }

    /// 降载一个块。`trailingValue` 只在**函数体、方法体、闭包体**这一层给：值返回的体里，末句若是
    /// 普通表达式语句，它的值就是返回值（与解释侧的 `lastValue` 同一条规则）。控制流的体一律不给 ——
    /// 那些块的值没有任何人读。
    private static func lowerBlock(
        _ block: Block,
        into context: inout FunctionContext,
        trailingValue: IRType? = nil
    ) throws -> IRBlock {
        // 体嵌套深度：体那一层是 1，任何控制流的体都使之上浮一格。与发射层的同名计数含义相同，但两者是
        // 独立实现 —— 必须对同一条规则给出同一个答案，否则就回到两层口径差（见 `allowedAwaitLocation`）。
        context.bodyDepth += 1
        defer { context.bodyDepth -= 1 }
        context.heldScopes.append([])
        defer { context.heldScopes.removeLast() }
        // 块内声明的类型只在块内可见：退出时还原快照，避免同名局部把外层类型带进后续重推。
        let outerVariableTypes = context.variableTypes
        defer { context.variableTypes = outerVariableTypes }
        var statements: [IRStmt] = []
        var positions: [SourceLocation] = []
        for (index, statement) in block.statements.enumerated() {
            if let trailingValue, index == block.statements.count - 1 {
                context.trailingValueType = trailingValue
            }
            let lowered = try lowerStatement(statement, into: &context)
            // 末句不是普通表达式语句时没人消费它，这里兜底清掉，免得漏到后面的语句上。
            context.trailingValueType = nil
            statements.append(contentsOf: lowered)
            // 这条源语句降载出的每条 IR 语句都带它自己的位置。一条 `Block` 语句可以展开成
            // 多条 IR 语句（try-else 初始化给出分配加 try），它们都算这一行 —— 与解释器对同一段代码的报告一致。
            let location = statement.location
            positions.append(contentsOf: Array(repeating: location, count: lowered.count))
        }
        return IRBlock(statements, positions: positions)
    }

    // MARK: - 语句

    /// 一条语句根位置上被允许的可让出 `await` 的位置（`nil` = 没有这样的位置）。四类与运行时的让出计划同源
    /// （`IRExecutor.IRYieldPlan`）：裸表达式语句 · `var` 初值 · `match` 判别式 · try-else 的 operand。`try`
    /// 透明，剥掉包装再判；赋值与解构不放行。本函数只判句法形态，体深度由调用方合取判。
    private static func allowedAwaitLocation(in statement: Statement) -> SourceLocation? {
        var root: Expression?
        switch statement {
        case .expressionStmt(let expr, _):
            root = expr
        case .varDecl(_, _, let initializer, _, _):
            root = initializer
        case .matchStatement(let value, _, _):
            root = value
        default:
            root = nil
        }
        while case .tryExpression(let operand, _, _, _)? = root {
            root = operand
        }
        if case .join(_, let location, .awaits)? = root { return location }
        return nil
    }

    /// 降载一条源语句，返回它对应的 IR 语句。多数分支恰好产出一条；
    /// try-else 变量初始化会产出分配语句加 try 语句。
    private static func lowerStatement(
        _ statement: Statement,
        into context: inout FunctionContext
    ) throws -> [IRStmt] {
        // `await` 的位置判定：本次语句降载里，只有语句根表达式本身（剥掉 `try` 包装之后）算可让出位置。判定放在
        // 语句层而非表达式层 —— 「语句根」本就是语句的性质。且须落在体那一层：嵌在 `if` / `match` case / 循环体
        // 里的语句根不是可让出位置，续跑跳转只跳得回体那一层的块，那些值不支配续跑块。嵌套语句各自设置与恢复。
        let previousAllowedAwaitAt = context.allowedAwaitAt
        context.allowedAwaitAt = context.bodyDepth == 1 ? allowedAwaitLocation(in: statement) : nil
        defer { context.allowedAwaitAt = previousAllowedAwaitAt }

        switch statement {
        case .varDecl(let name, let annotation, let initializer, let isMutable, let location):
            return try lowerVarDecl(
                name: name, annotation: annotation, initializer: initializer,
                isMutable: isMutable, at: location, into: &context
            )

        case .varDestructure(let names, _, let initializer, let isMutable, let location):
            return try lowerVarDestructure(
                names: names, initializer: initializer,
                isMutable: isMutable, at: location, into: &context
            )

        case .assign(let target, let value, let location):
            // 下标写入走数组族的写路径；成员写入走名义类型的字段写路径。
            if case .subscript(let container, let index) = target {
                return [
                    try lowerSubscriptStore(
                        container: container, index: index, value: value, at: location, into: &context
                    )
                ]
            }
            if case .member(let base, let fieldName) = target {
                let loweredBase = unownedUnwrapped(try lowerExpr(base, expected: nil, into: &context))
                guard case .nominal = loweredBase.type else {
                    throw unsupported(
                        "field store on non-nominal base type '\(loweredBase.type)'",
                        at: location
                    )
                }
                guard let fieldType = nominalFieldType(of: loweredBase.type, field: fieldName, in: context) else {
                    throw unsupported(
                        "no field '\(fieldName)' on '\(loweredBase.type)'",
                        at: location
                    )
                }
                guard let fieldSlot = nominalFieldSlot(of: loweredBase.type, field: fieldName, in: context) else {
                    throw unsupported(
                        "no field slot for '\(fieldName)' on '\(loweredBase.type)'",
                        at: location
                    )
                }
                let loweredValue = try lowerExpr(value, expected: fieldType, into: &context)
                try requireAssignable(loweredValue.type, to: fieldType, at: location)
                return [
                    .fieldStore(
                        base: loweredBase.node, slot: fieldSlot,
                        value: loweredValue.node, fieldType: fieldType,
                        adopt: fieldType.adoption(of: loweredValue.node),
                        releaseOld: fieldType.holdsAShare
                    )
                ]
            }
            guard case .identifier(let name) = target else {
                throw unsupported(
                    "assignment to a non-identifier target (member stores are later grids)",
                    at: location
                )
            }
            guard let varType = context.variableTypes[name] else {
                throw unsupported("assignment to undeclared variable '\(name)'", at: location)
            }
            let lowered = try lowerExpr(value, expected: varType, into: &context)
            try requireAssignable(lowered.type, to: varType, at: location)
            return [
                .storeVar(
                    name: name, type: varType, value: lowered.node,
                    adopt: varType.adoption(of: lowered.node),
                    releaseOld: context.isHeld(name)
                )
            ]

        case .returnStatement(let value, let location):
            if let value = value {
                // 裸错误绑定（处理器里的 `return err`、`^e` 糖）：解释器把原始错误载荷流出去，
                // 这是已登记在案的语义缺口。void 函数丢掉值（静默返回）；非 void 直接门禁 ——
                // 类型擦除的 err 字无法当作有类型载荷流出，除非猜类型。
                if case .identifier(let name, _) = value, context.errorBindings.contains(name) {
                    if context.returnType == nil {
                        return [.returnStmt(value: nil, adopt: .none)]
                    }
                    throw unsupported(
                        "returning a bare error binding from '\(context.functionName)' is gated this grid: the interpreter returns the raw error payload (unboxed), which is a registered semantic hole",
                        at: location
                    )
                }
                guard let returnType = context.returnType else {
                    throw unsupported(
                        "return with a value from void function '\(context.functionName)'",
                        at: location
                    )
                }
                let lowered = try lowerExpr(value, expected: returnType, into: &context)
                try requireAssignable(lowered.type, to: returnType, at: location)
                return [.returnStmt(value: lowered.node, adopt: returnType.adoption(of: lowered.node))]
            }
            if context.isAsyncVoid, let returnType = context.returnType {
                // 异步 void 体的裸 `return` 就是 `return ok(())`：三槽 ABI 要求每条出口都写 Result，
                // 载荷没有值，占位槽给 0。
                return [.returnStmt(
                    value: .resultConstruct(
                        isOk: true, payload: .intConst(value: 0, type: .i32), errorBaseCode: 0,
                        errorTagged: false, errorCodes: nil,
                        type: returnType),
                    adopt: .none)]
            }
            guard context.returnType == nil else {
                throw unsupported(
                    "bare return from non-void function '\(context.functionName)'",
                    at: location
                )
            }
            return [.returnStmt(value: nil, adopt: .none)]

        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, _):
            let cond = try lowerExpr(condition, expected: .boolean, into: &context)
            guard cond.type == .boolean else {
                throw unsupported("if condition is not Bool", at: conditionLocation(condition))
            }
            // 带标签的 `if` 是可中断帧，故 `break 标签` 可以离开该块；它不是 `continue` 的目标
            // （`isLoop: false`）。这个帧覆盖所有分支 —— `then`、各 `elif` 与 `else` ——
            // 因为 AST 通道的 `executeIf` 把整个 `executeIfBody` 包在它的 catch 里。
            if let label = label {
                context.controlFrames.append(ControlFrame(label: label, isLoop: false))
            }
            defer { if label != nil { context.controlFrames.removeLast() } }
            let thenBody = try lowerBlock(thenBlock, into: &context)
            // elif 链降载成嵌套 if（保持树形结构）。链嵌在本帧之内，自身不带标签：
            // `elif` 体内 `break 某标签` 退的是整个 `if`，那正是 `executeIf` 的 catch 所在层。
            var chain: IRBlock? = nil
            if let elseBlock = elseBlock {
                chain = try lowerBlock(elseBlock, into: &context)
            }
            for branch in elifs.reversed() {
                let branchCond = try lowerExpr(branch.condition, expected: .boolean, into: &context)
                guard branchCond.type == .boolean else {
                    throw unsupported("elif condition is not Bool", at: conditionLocation(branch.condition))
                }
                let branchBody = try lowerBlock(branch.block, into: &context)
                chain = [.ifStmt(label: nil, condition: branchCond.node, thenBody: branchBody, elseBody: chain)]
            }
            return [.ifStmt(label: label, condition: cond.node, thenBody: thenBody, elseBody: chain)]

        case .whileStatement(let condition, let body, let step, let label, _):
            let cond = try lowerExpr(condition, expected: .boolean, into: &context)
            guard cond.type == .boolean else {
                throw unsupported("while condition is not Bool", at: conditionLocation(condition))
            }
            context.controlFrames.append(ControlFrame(label: label, isLoop: true))
            defer { context.controlFrames.removeLast() }
            let bodyStmts = try lowerBlock(body, into: &context)
            let stepStmts = try step.map { try lowerBlock($0, into: &context) }
            return [.whileStmt(condition: cond.node, body: bodyStmts, step: stepStmts)]

        case .forStatement(let pattern, let iterable, let body, let step, let label, let location):
            return [
                try lowerForIn(
                    pattern: pattern, iterable: iterable, body: body, step: step,
                    label: label, at: location, into: &context
                )
            ]

        case .breakStatement(let label, _):
            // 目标解析不出时运行期失败，与解释器一致 —— 信号穿过所有帧，在顶层报错。
            // 在降载期直接拒绝会把解释器能跑的程序挡掉。
            // 查找会走过沿途可中断的帧，故出口路径上的带标签 `if` 也算一个。
            guard
                let depth = resolveControlDepth(
                    label: label, target: .anyFrame, into: &context
                )
            else {
                return [.panicStmt(message: "Pini runtime error: break outside loop")]
            }
            return [.breakStmt(depth: depth)]

        case .continueStatement(let label, _):
            // `continue` 需要*循环*帧（`continue-stmt ::= 'continue' [IDENT]` 带注「仅循环标签有效」），
            // 故 `if` 标签在这里解析不出，尽管它对 `break` 算一个帧。
            guard
                let depth = resolveControlDepth(
                    label: label, target: .loopOnly, into: &context
                )
            else {
                return [.panicStmt(message: "Pini runtime error: continue outside loop")]
            }
            return [.continueStmt(depth: depth)]

        case .matchStatement(let value, let cases, let location):
            return [try lowerMatch(value: value, cases: cases, at: location, into: &context)]

        case .deferStatement(let wrapped, _):
            // `defer` 在外层块作用域正常结束时运行，同一作用域内多个 defer 逆序执行（发射器的块协议）。
            // `defer:` 带缩进体时解析成作用域块而非单条语句，于是被延后的是块体本身，走 `lowerBlock` ——
            // 它是真正的块，自带位置信息。
            if case .scopedBlock(_, let body, _) = wrapped {
                return [.deferStmt(body: try lowerBlock(body, into: &context))]
            }
            return [.deferStmt(body: .at(try lowerStatement(wrapped, into: &context), wrapped.location))]

        case .expressionStmt(let expr, let location):
            // 语句位置的 try-else：ok 值丢弃。
            if case .tryExpression(let operand, let errorVar, let handler, _) = expr {
                return [
                    try lowerTry(
                        operand: operand, errorVar: errorVar, handler: handler,
                        okTarget: nil, at: location, into: &context
                    )
                ]
            }
            // 语句位置的前缀 `++`/`--`：对目标读-改-写，值丢弃。
            if case .unary(let op, let target, let unaryLocation) = expr,
                op == .increment || op == .decrement
            {
                let lowered = try lowerIncDec(
                    op: op, target: target, at: unaryLocation, into: &context
                )
                return [lowered.statement]
            }
            // 复合赋值（`a[i] += k` / `x += 1`）解析成二元表达式；语句位置降载成一次写入。
            if case .binary(let left, let op, let right, let binaryLocation) = expr,
                let baseOp = IRBinaryOp(compound: op)
            {
                return [
                    try lowerCompoundAssign(
                        left: left, baseOp: baseOp, right: right,
                        at: binaryLocation, into: &context
                    )
                ]
            }
            // 尾表达式位：值返回的体末句就是返回值。类型对不上（末句是个 void 调用之类）就退回丢弃，
            // 与这条规则出现之前一样 —— 缺 return 的诊断属另一件事，不在这里顺手新造。
            if let trailing = context.trailingValueType {
                context.trailingValueType = nil
                let lowered = try lowerExpr(expr, expected: trailing, into: &context)
                guard lowered.type.isAssignable(to: trailing) else {
                    return [.exprStmt(lowered.node)]
                }
                return [.returnStmt(value: lowered.node, adopt: trailing.adoption(of: lowered.node))]
            }
            return [.exprStmt(try lowerExpr(expr, expected: nil, into: &context).node)]

        case .passStatement:
            // pass 是纯空操作；降载成无副作用的常量表达式语句，这样 `IRStmt` 保持完备而不必新增 case。
            // 尾位上它就是返回值：解释侧把这一句当普通表达式语句，读数是常量 0，两通道据此同值。
            if let trailing = context.trailingValueType, IRType.i32.isAssignable(to: trailing) {
                context.trailingValueType = nil
                return [.returnStmt(value: .intConst(value: 0, type: .i32), adopt: .none)]
            }
            return [.exprStmt(.intConst(value: 0, type: .i32))]

        case .captureStatement(let name, _):
            // 只是个标记 —— 捕获集合在闭包字面量创建处解析（自由变量分析），语句本身没有运行期效果。
            return [.captureMarker(name: name)]

        case .detachStatement(let expr, _):
            // `detach <expr>`：求值操作数，把它产出的任务从父任务里摘掉，父任务的返回就取消不了它 ——
            // fire-and-forget 的合法出口。操作数不是 future 时由引擎在运行期拒绝，与解释器的 detach 分支一致，
            // 不在降载期提前挡。
            let inner = try lowerExpr(expr, expected: nil, into: &context)
            return [.detachStmt(inner: inner.node)]

        default:
            throw unsupported(
                "statement '\(statement.kindName)' is not yet lowered to IR",
                at: statementLocation(statement)
            )
        }
    }

    /// 降载 `for (pattern,) in iterable: body [step:]`。可迭代表达式只降载一次；它的 IR 类型决定容器种类与
    /// 逐字段元素类型，后者必须与 pattern 元数对齐 —— 含 `_` 占位符，因为解释器要求字段数精确匹配。
    private static func lowerForIn(
        pattern: [String],
        iterable: Expression,
        body: Block,
        step: Block?,
        label: String?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        let lowered = try lowerExpr(iterable, expected: nil, into: &context)
        let kind: IRForIterableKind
        let elementTypes: [IRType]
        switch lowered.type {
        case .array(let element):
            kind = .array
            elementTypes = [element]
        case .set(let element):
            kind = .set
            elementTypes = [element]
        case .dict(let key, let value):
            kind = .dict
            elementTypes = [key, value]
        default:
            throw unsupported(
                "for-in over '\(lowered.type)' (iterable must be a collection)",
                at: location
            )
        }
        guard pattern.count == elementTypes.count else {
            throw unsupported(
                "for pattern has \(pattern.count) field(s) but the element has \(elementTypes.count)",
                at: location
            )
        }
        context.controlFrames.append(ControlFrame(label: label, isLoop: true))
        defer { context.controlFrames.removeLast() }
        // pattern 变量在 body 与 step 里都可见（对应发射器的循环作用域和解释器的每轮 Environment）。
        // `_` 占位符不绑定任何名字。
        let boundNames = pattern.enumerated().filter { $0.element != "_" }.map { $0.element }
        let previousTypes = boundNames.map { context.variableTypes[$0] }
        let previouslyHeld = boundNames.map { context.isHeld($0) }
        for (position, name) in pattern.enumerated() where name != "_" {
            context.variableTypes[name] = elementTypes[position]
            context.declareHeld(name)
        }
        defer {
            for (index, name) in boundNames.enumerated() {
                context.variableTypes[name] = previousTypes[index]
                if previouslyHeld[index] {
                    context.declareHeld(name)
                } else {
                    context.retractHeld(name)
                }
            }
        }
        let bodyStmts = try lowerBlock(body, into: &context)
        let stepStmts = try step.map { try lowerBlock($0, into: &context) }
        return .forInStmt(
            pattern: pattern, elementTypes: elementTypes, kind: kind,
            iterable: lowered.node, body: bodyStmts, step: stepStmts
        )
    }

    /// 信号被允许离开哪些帧。
    private enum ControlTarget {
        /// `break` —— 任意可中断帧（break 可定向任意带标签结构）。
        case anyFrame
        /// `continue` —— 只认循环（`continue-stmt` 带注「仅循环标签有效」）。
        case loopOnly
    }

    /// 把 break/continue 解析成展开深度：从最内层目标帧数起并含目标帧本身，即信号出栈时递减的层数。
    /// 不带标签的信号指向最内层循环，跨过带标签的 `if` 帧；找不到目标返回 `nil`，降载成运行期 panic。
    private static func resolveControlDepth(
        label: String?,
        target: ControlTarget,
        into context: inout FunctionContext
    ) -> Int? {
        let frames = context.controlFrames
        var index = frames.count - 1
        while index >= 0 {
            let frame = frames[index]
            let matches: Bool
            switch (label, target) {
            case (nil, _):
                matches = frame.isLoop
            case (let label?, .anyFrame):
                matches = frame.label == label
            case (let label?, .loopOnly):
                // `if` 块上的标签不满足 `continue`：那种写法非法，而不只是到不了
                // （break 可定向任意带标签结构）。
                matches = frame.isLoop && frame.label == label
            }
            // 由内向外：第一个既包住信号又能消费它的帧就是目标（内层同名标签遮蔽外层）。
            if matches { return frames.count - index }
            index -= 1
        }
        return nil
    }

    private static func lowerVarDecl(
        name: String,
        annotation: TypeAnnotation?,
        initializer: Expression?,
        isMutable: Bool,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [IRStmt] {
        // `var m = ++n`：初始化器会回写 n 并产出所写的值，故该语句展开成一次写入，
        // 加上消费该值的分配。写入值类型是 I32 —— `lowerIncDec` 只接受这一种目标类型。
        if case .unary(let op, let target, let unaryLocation)? = initializer,
            op == .increment || op == .decrement
        {
            if let annotation = annotation {
                guard IRType(from: annotation) == .i32 else {
                    throw unsupported(
                        "variable '\(name)': prefix '\(op)' yields I32, not '\(annotation)'",
                        at: location
                    )
                }
            }
            let lowered = try lowerIncDec(
                op: op, target: target, at: unaryLocation, into: &context
            )
            context.variableTypes[name] = lowered.type
            context.declareHeld(name)
            return [
                lowered.statement,
                .allocVar(
                    name: name, type: lowered.type, mutable: isMutable,
                    initializer: lowered.value,
                    adopt: lowered.type.adoption(of: lowered.value)
                ),
            ]
        }
        // `let x = try f() else ...`：try 把 ok 载荷解出给 x，故 x 的类型是 Result 的载荷类型，不是 Result。
        if case .tryExpression(let operand, let errorVar, let handler, _) = initializer {
            if let annotation = annotation {
                guard let declared = IRType(from: annotation), !isResultAnnotation(annotation) else {
                    throw unsupported(
                        "variable '\(name)': a try-else initializer unwraps the payload — annotate with the payload type, not a Result type",
                        at: location
                    )
                }
                let operandType = try resultType(of: operand, into: context)
                guard let okType = operandType.resultOkType, declared == okType else {
                    throw unsupported(
                        "variable '\(name)': annotation does not match the try operand's ok payload type",
                        at: location
                    )
                }
            }
            let operandType = try resultType(of: operand, into: context)
            guard let okType = operandType.resultOkType else {
                throw unsupported("try operand is not a Result", at: location)
            }
            let alloc = IRStmt.allocVar(name: name, type: okType, mutable: isMutable, initializer: nil, adopt: .none)
            let tryStmt = try lowerTry(
                operand: operand, errorVar: errorVar, handler: handler,
                okTarget: name, at: location, into: &context
            )
            context.variableTypes[name] = okType
            context.declareHeld(name)
            return [alloc, tryStmt]
        }

        let declaredType: IRType?
        if let annotation = annotation {
            guard let type = resolveAnnotationType(annotation, userTypes: context.userTypes) else {
                throw unsupported(
                    "variable '\(name)' has non-scalar annotation '\(annotation.simpleName ?? "(non-scalar)")'",
                    at: location
                )
            }
            declaredType = Self.carryingUsing(from: initializer, in: context, over: type)
        } else if let initializer = initializer {
            if let inferred = context.inferType(of: initializer),
                let type = IRType(from: inferred)
            {
                declaredType = type
            } else {
                // 检查器推断缺失（集合字面量、检查器不跟踪的标识符）：不带期望值先降载一次初始化器来取类型。
                // 结果丢弃；下面真正的降载会带着解析出的期望类型重做一遍。
                declaredType = try lowerExpr(initializer, expected: nil, into: &context).type
            }
        } else {
            throw unsupported(
                "variable '\(name)' has neither annotation nor initializer",
                at: location
            )
        }
        let varType = declaredType!
        let loweredInit: IRExpr?
        var initializerType: IRType?
        if let initializer = initializer {
            let lowered = try lowerExpr(initializer, expected: varType, into: &context)
            try requireAssignable(lowered.type, to: varType, at: location)
            loweredInit = lowered.node
            initializerType = lowered.type
        } else {
            loweredInit = nil
        }
        // 静态视图保留声明的名字（成员读取按它解析）；槽里存的是下面算出的类型。
        context.variableTypes[name] = varType
        context.declareHeld(name)
        let storedType = slotType(declared: varType, initializer: initializerType)
        return [
            .allocVar(
                name: name,
                type: storedType,
                mutable: isMutable,
                initializer: loweredInit,
                adopt: storedType.adoption(of: loweredInit)
            )
        ]
    }

    /// 标注给出参数与返回，函数值补上自己的调用约定（哪些参数位由给定块填）。取用位不进类型等价，
    /// 但它属于函数本身 —— 写标注不该把它切断：给定块类型在值位无法显式构造，切断后变量永远调不动。
    private static func carryingUsing(
        from initializer: Expression?, in context: FunctionContext, over type: IRType
    ) -> IRType {
        guard case .function(let params, let returnType, let marked) = type, marked.isEmpty,
            let initializer = initializer,
            let usingIndices = usingIndicesInValue(of: initializer, in: context),
            !usingIndices.isEmpty
        else { return type }
        return .function(params: params, returnType: returnType, usingIndices: usingIndices)
    }

    /// 值的取用位：具名函数查签名表，变量查变量表。
    private static func usingIndicesInValue(
        of expression: Expression, in context: FunctionContext
    ) -> Set<Int>? {
        guard case .identifier(let name, _) = expression else { return nil }
        if let signature = context.moduleSignatures[name] { return signature.usingParamIndices }
        if let variable = context.variableTypes[name],
            case .function(_, _, let usingIndices) = variable
        {
            return usingIndices
        }
        return nil
    }

    /// 绑定槽实际存储的类型。解释器只在两处给元组分量挂名字 —— 显式 `return` 与显式元组标注 ——
    /// 所以声明时照抄初始化器自身的类型毫无增益，标签一律落成全 `nil`：名字去掉，字段数保留。
    private static func slotType(declared: IRType, initializer: IRType?) -> IRType {
        guard case .tuple(let labels, let fieldTypes) = declared, !labels.isEmpty else {
            return declared
        }
        guard case .tuple(let valueLabels, _) = initializer, valueLabels == labels else {
            return declared
        }
        return .tuple(
            labels: Array(repeating: nil, count: fieldTypes.count),
            fieldTypes: fieldTypes
        )
    }

    /// 该节点是不是一个 err 槽的字（`try-else` 的 `errorVar`、`match` 的 `case err(e)` 绑定）。判据只有绑定表
    /// 一条：类型层把这些名字写作 `Error` / `CancelError`，IR 里却是 `.i64`，与整数同形 ⇒ 不能靠类型反推。
    private static func isErrorFaced(_ node: IRExpr, _ context: FunctionContext) -> Bool {
        guard case .load(let name, _) = node else { return false }
        return context.errorBindings.contains(name)
    }

    /// err 字 → 消息串。本层两处读（`print(e)` 与 `e.message`）共用它：
    /// 字里装的是运行时段的错误对象，取消息属运行时段， 行不通  本层不猜它的布局。
    private static func lowerErrorMessage(
        _ word: IRExpr, at location: SourceLocation
    ) -> LoweredExpr {
        LoweredExpr(
            node: .call(function: "pini.err.message", arguments: [word], returnType: .string),
            type: .string
        )
    }

    /// 降载 `let (a, b) = tupleExpr`。初始化器只求值一次，必须是元组，名字数须等于其元数；
    /// 随后每个非 `_` 名字从承载它的合成槽里 extractvalue 取值，带副作用的调用因此也只跑一次。
    /// 没有静态元组形状的解构在这里解析不出来。
    private static func lowerVarDestructure(
        names: [String],
        initializer: Expression?,
        isMutable: Bool,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [IRStmt] {
        guard let initializer = initializer else {
            throw unsupported("destructure declaration lacks an initializer", at: location)
        }
        let lowered = try lowerExpr(initializer, expected: nil, into: &context)
        guard case .tuple(_, let fieldTypes) = lowered.type else {
            throw unsupported(
                "destructuring needs a tuple value, got '\(lowered.type)'",
                at: location
            )
        }
        guard names.count == fieldTypes.count else {
            throw unsupported(
                "destructure pattern has \(names.count) name(s) but the value has \(fieldTypes.count) field(s)",
                at: location
            )
        }
        let tempName = "$destructure\(context.tempCounter)"
        context.tempCounter += 1
        context.declareHeld(tempName)
        var statements: [IRStmt] = [
            .allocVar(
                name: tempName, type: lowered.type, mutable: false, initializer: lowered.node,
                adopt: lowered.type.adoption(of: lowered.node))
        ]
        let base = IRExpr.load(name: tempName, type: lowered.type)
        for (index, name) in names.enumerated() where name != "_" {
            context.variableTypes[name] = fieldTypes[index]
            context.declareHeld(name)
            let element = IRExpr.tupleIndexGet(
                base: base, index: index, type: fieldTypes[index]
            )
            statements.append(
                .allocVar(
                    name: name, type: fieldTypes[index], mutable: isMutable, initializer: element,
                    adopt: fieldTypes[index].adoption(of: element))
            )
        }
        return statements
    }

    // MARK: - try-else 降载

    /// try 操作数的静态 Result 类型：注解可解析时按注解，否则取检查器推断（Result → params[0]）。
    private static func resultType(of operand: Expression, into context: FunctionContext) throws -> IRType {
        if let inferred = context.inferType(of: operand), let type = IRType(from: inferred) {
            return type
        }
        throw unsupported(
            "try operand type is not statically a Result (annotate the operand's source with ^T)",
            at: expressionLocation(operand)
        )
    }

    private static func isResultAnnotation(_ annotation: TypeAnnotation) -> Bool {
        if case .generic(let name, _, _) = annotation { return name == "Result" }
        return false
    }

    /// 降载 `try operand else errorVar: handler`。ABI 把 err 槽类型擦除成一个机器字（不存在静态 err 类型），
    /// 故绑定名携带 i64，且作用域只在 handler 内。handler 语句限于 return / pass；
    /// 表达式位置（`okTarget`）还要求以 return 结尾。
    private static func lowerTry(
        operand: Expression,
        errorVar: String,
        handler: Block,
        okTarget: String?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        // 裸 `ok(x)` / `err(x)` 操作数没有可采纳的期望 Result：`^T` 两个半边都不约束，
        // 通用的 ok/err 规则无从读取。`ok` 的载荷定住它那一半，故在此按该类型构造操作数；
        // `err` 则以 I32 顶上，这个值从不被读 —— 控制流归 handler。
        let loweredOperand: LoweredExpr
        if case .call(let callee, let arguments, _) = operand,
            case .identifier(let calleeName, _) = callee,
            calleeName == "ok" || calleeName == "err",
            arguments.count == 1
        {
            let payload = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
            let resultType = IRType.result(ok: calleeName == "ok" ? payload.type : .i32)
            let info = calleeName == "err"
                ? Self.errorCodeInfo(for: payload.type, in: context)
                : (base: Int32(0), tagged: false, codes: nil)
            loweredOperand = LoweredExpr(
                node: .resultConstruct(
                    isOk: calleeName == "ok", payload: payload.node, errorBaseCode: info.base,
                    errorTagged: info.tagged, errorCodes: info.codes,
                    type: resultType
                ),
                type: resultType
            )
        } else {
            loweredOperand = try lowerExpr(operand, expected: nil, into: &context)
        }
        guard case .result(let okType) = loweredOperand.type else {
            throw unsupported("try operand is not a Result", at: expressionLocation(operand))
        }
        guard !handler.statements.isEmpty else {
            throw unsupported("try-else handler is empty", at: location)
        }
        guard context.variableTypes[errorVar] == nil else {
            throw unsupported(
                "try-else error binding '\(errorVar)' shadows an existing variable",
                at: location
            )
        }
        let previousType = context.variableTypes[errorVar]
        context.variableTypes[errorVar] = .i64
        context.errorBindings.insert(errorVar)
        defer {
            if let previousType = previousType {
                context.variableTypes[errorVar] = previousType
            } else {
                context.variableTypes[errorVar] = nil
            }
            context.errorBindings.remove(errorVar)
        }

        var handlerStmts: [IRStmt] = []
        for statement in handler.statements {
            handlerStmts.append(contentsOf: try lowerStatement(statement, into: &context))
        }
        // 块形式必须以控制流语句结尾（try-else 错误传播的规定）；表达式位置（okTarget）
        // 另外禁掉 pass 终止符（它不带值）。
        if let last = handler.statements.last {
            switch last {
            case .returnStatement:
                break
            case .passStatement:
                guard okTarget == nil else {
                    throw unsupported(
                        "expression-position try-else handler cannot terminate with pass (no value)",
                        at: location
                    )
                }
            default:
                throw unsupported(
                    "try-else handler block must terminate with a control-flow statement (return this grid)",
                    at: location
                )
            }
        }
        return .tryStmt(
            operand: loweredOperand.node, errorVar: errorVar,
            handler: .at(handlerStmts, location), okTarget: okTarget, type: .result(ok: okType)
        )
    }

    // MARK: - 表达式

    private static func lowerExpr(
        _ expression: Expression,
        expected: IRType?,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        switch expression {
        case .integerLiteral(let value, _):
            // 整数字面量采纳期望的数值类型（默认 I32），与检查器对待无类型整数字面量的方式一致。
            let type = (expected?.isNumeric == true) ? expected! : .i32
            return LoweredExpr(node: .intConst(value: value, type: type), type: type)

        case .floatLiteral(let value, _):
            // 声明宽度对齐：整型槽里的浮点字面量折叠成截断的整常量。越界或非有限值走浮点路径，
            // 由 `requireAssignable` 报普通门禁错误；整型槽里的非字面量浮点表达式仍在运行期直接失败。
            if let expected, expected.isIntegerNumeric, value.isFinite,
                value >= -9.223372036854776e18, value <= 9.223372036854776e18
            {
                return LoweredExpr(
                    node: .intConst(value: Int(value), type: expected), type: expected
                )
            }
            return LoweredExpr(node: .floatConst(value: value), type: .f64)

        case .boolLiteral(let value, _):
            return LoweredExpr(node: .boolConst(value: value), type: .boolean)

        case .stringLiteral(let value, _):
            return LoweredExpr(node: .stringConst(value: value), type: .string)

        case .stringInterpolation(let segments, let location):
            // 每个表达式片段在发射时走值显示管线（字符串化口径与解释器通道对齐）。
            var parts: [IRExpr] = []
            for segment in segments {
                switch segment {
                case .literal(let text):
                    if !text.isEmpty {
                        parts.append(.stringConst(value: text))
                    }
                case .expression(let inner):
                    parts.append(try lowerExpr(inner, expected: nil, into: &context).node)
                }
            }
            if parts.allSatisfy({ if case .stringConst = $0 { return true } else { return false } }) {
                // 全为字面量：折叠成一个常量。
                let folded = parts.compactMap { part -> String? in
                    if case .stringConst(let v) = part { return v }
                    return nil
                }
                return LoweredExpr(node: .stringConst(value: folded.joined()), type: .string)
            }
            return LoweredExpr(node: .interpString(parts: parts), type: .string)

        case .arrayLiteral(let elements, let location):
            return try lowerArrayLiteral(elements, expected: expected, at: location, into: &context)

        case .subscript(let container, let index, let location):
            // 数组下标读：安全断言通道 —— 越界在运行期 panic，与解释器一致。String 下标在同一通道上
            // 产出单字符 String，负下标在两边都从尾部计数。宽容的 `.get` 通道归成员调用路径。
            let loweredContainer = try lowerExpr(container, expected: nil, into: &context)
            let elementType: IRType
            switch loweredContainer.type {
            case .array(let element): elementType = element
            case .dict(_, let value): elementType = value
            // `String` 的下标元素是 `Char` —— 这是窄化的三个构造点之一（`s[i]` / `chars` / `chr`），
            // 必须与运行时读策略 `SubscriptStrategies` 返回的 `.char` 同型，
            // 否则一个合法下标的**类型**会与它的**值**不符。
            case .string: elementType = .char
            default:
                throw unsupported(
                    "subscript on non-container type '\(loweredContainer.type)'",
                    at: location
                )
            }
            // 字典键携带声明的键类型；数组与字符串下标是 I32（负值从尾部计数）。
            let indexExpectation: IRType?
            var requireI32Index = false
            switch loweredContainer.type {
            case .dict(let keyType, _): indexExpectation = keyType
            case .array: indexExpectation = .i32; requireI32Index = true
            case .string: indexExpectation = .i32; requireI32Index = true
            default: indexExpectation = nil
            }
            let loweredIndex = try lowerExpr(index, expected: indexExpectation, into: &context)
            if requireI32Index {
                guard loweredIndex.type == .i32 else {
                    throw unsupported("subscript needs an I32 index", at: location)
                }
            }
            return LoweredExpr(
                node: .subscriptGet(container: loweredContainer.node, index: loweredIndex.node, type: elementType),
                type: elementType
            )

        case .identifier(let name, let location):
            if let type = context.variableTypes[name] {
                return LoweredExpr(node: .load(name: name, type: type), type: type)
            }
            // 宏常量：构建期已经算出，读它就是读那个字面量，没有存储可以让路。
            if let constant = context.foreignConstants[name] {
                switch constant.value {
                case .integer(let value):
                    return LoweredExpr(
                        node: .intConst(value: value, type: constant.type), type: constant.type)
                case .float(let value):
                    return LoweredExpr(node: .floatConst(value: value), type: .f64)
                }
            }
            // 声明过却没值的宏：check 应已报未求值；走到这里说明有通道漏判。
            if context.declaredMacros.contains(name) {
                throw unsupported(
                    "宏常量 '\(name)' 没有求值结果（check 应已报未求值）", at: location)
            }
            // 外部数据符号：读的是符号存储的当前值，不是声明处的任何初值。
            if let type = context.foreignData[name] {
                return LoweredExpr(
                    node: .pointerLoad(
                        pointer: .foreignDataAddress(name: name, type: type), type: type),
                    type: type)
            }
            // 内建值：裸名字直出常量。位置在变量表之后是刻意的 —— 用户声明了同名变量时读到的是用户那份，与预置
            // 声明的让位规则同向。那个常量恒为零，且不是一个可解引用的地址：含义是「这个句柄没有指向任何东西」，
            // 由类型层承重（它只被比较、不被解引用）。
            if let valueType = BuiltinRegistry.builtinValueType(named: name) {
                guard let irType = IRType(from: valueType) else {
                    throw unsupported("builtin value '\(name)' has no IR type", at: location)
                }
                return LoweredExpr(node: .intConst(value: 0, type: irType), type: irType)
            }
            // 方法体内的裸字段名（与解释器的 bindInstanceFields 口径一致）—— 按 `self.<field>` 降载。
            if let fieldType = context.selfFieldTypes[name] {
                let selfType = IRType.nominal(
                    name: context.selfTypeNameLowered ?? "", isObject: context.selfIsObjectLowered
                )
                guard let fieldSlot = nominalFieldSlot(of: selfType, field: name, in: context) else {
                    throw unsupported("no field slot for bare field '\(name)'", at: location)
                }
                return LoweredExpr(
                    node: .fieldGet(base: .load(name: "self", type: selfType), slot: fieldSlot, type: fieldType),
                    type: fieldType
                )
            }
            // 无载荷枚举 case 当裸标识符值（`取文本(plus)`）：按唯一的不带限定反查。
            if let constructed = try lowerBareEnumCase(name, at: location, into: &context) {
                return constructed
            }
            // 回调实参位：期望类型是 C 函数指针时，名字取的是函数地址本身，不是闭包胖指针。
            // 判据只看期望类型，不看被调方 —— `.function` 与 `.cFunction` 在 IR 里是两种表示。
            if case .cFunction = expected, let signature = context.moduleSignatures[name] {
                let type = IRType.cFunction(
                    params: signature.paramTypes, returnType: signature.returnType)
                return LoweredExpr(node: .cFunctionAddress(functionName: name, type: type), type: type)
            }
            // 具名顶层函数当值用（`应用(加倍, 21)`）：类型取自预扫描的签名表；
            // 发射时在使用点通过忽略环境的适配器胖指针走。
            if let signature = context.moduleSignatures[name] {
                let type = IRType.function(params: signature.paramTypes, returnType: signature.returnType, usingIndices: signature.usingParamIndices)
                return LoweredExpr(node: .functionValue(functionName: name, type: type), type: type)
            }
            throw unsupported("reference to undeclared variable '\(name)'", at: location)

        case .binary(let left, let op, let right, let location):
            // 逻辑与 / 逻辑或短路求值：左值定下结果时右操作数整个不求值，故不能落成二元节点。
            // 两侧都要求 Bool —— 类型检查只查了操作数彼此一致，没查它们是不是 Bool。
            if op == .and || op == .or {
                let lhs = try lowerExpr(left, expected: .boolean, into: &context)
                let rhs = try lowerExpr(right, expected: .boolean, into: &context)
                guard lhs.type == .boolean, rhs.type == .boolean else {
                    throw unsupported(
                        "logical '\(op)' needs Bool operands, got \(lhs.type) and \(rhs.type)",
                        at: location
                    )
                }
                let logicalOp: IRLogicalOp = (op == .and) ? .and : .or
                return LoweredExpr(
                    node: .shortCircuit(op: logicalOp, lhs: lhs.node, rhs: rhs.node, type: .boolean),
                    type: .boolean
                )
            }
            guard let irOp = IRBinaryOp(from: op) else {
                throw unsupported(
                    "binary operator '\(op)' is not yet lowered to IR",
                    at: location
                )
            }
            // 比较操作数不带标量期望类型降载；算术操作数采纳期望的数值类型。
            let operandExpectation: IRType? = irOp.isComparison ? nil : expected
            let lhs = try lowerExpr(left, expected: operandExpectation, into: &context)
            let rhs = try lowerExpr(right, expected: lhs.type, into: &context)
            if irOp.isComparison {
                // `Char` / `String` 是**相容对**（表示同构：Char 的表示与 String 同构）⇒
                // 「两操作数类型名必须字面相等」这条判据对这一对不适用。
                // 放宽只覆盖这一对；两侧同为 `Char` 或同为 `String` 的情形本就走通。
                guard lhs.type == rhs.type || lhs.type.formsCharStringPair(with: rhs.type) else {
                    throw unsupported(
                        "comparison operand types differ (\(lhs.type) vs \(rhs.type))",
                        at: location
                    )
                }
                return LoweredExpr(
                    node: .binary(op: irOp, lhs: lhs.node, rhs: rhs.node, type: .boolean),
                    type: .boolean
                )
            }
            // 字符串拼接 `s1 + s2`：defer 语义逐个拼串，concat 连接两个 C 串。判据是「两侧都是字符串面」而非「都是
            // `.string`」—— `Char` 与 `String` 表示同构（都是 `i8*`），拼接语义相同，结果取 `String`
            // （`c + c` 是两个字节，不是单个字素）。
            if irOp == .add, lhs.type.isStringFaced, rhs.type.isStringFaced {
                return LoweredExpr(
                    node: .stringConcat(lhs: lhs.node, rhs: rhs.node),
                    type: .string
                )
            }
            guard lhs.type == rhs.type, lhs.type.isNumeric else {
                throw unsupported(
                    "operator '\(op)' operand types differ (\(lhs.type) vs \(rhs.type))",
                    at: location
                )
            }
            return LoweredExpr(
                node: .binary(op: irOp, lhs: lhs.node, rhs: rhs.node, type: lhs.type),
                type: lhs.type
            )

        case .unary(let op, let operand, let location):
            // 前缀 `++`/`--` 是对可赋值目标的读-改-写，并产出写入的值。IR 里没有承载写入的表达式节点，
            // 故只在语句位置与变量初始化器里降载（见 `lowerIncDec`）。走到这条分支说明位置没覆盖。
            if op == .increment || op == .decrement {
                throw unsupported(
                    "prefix '\(op)' outside statement or variable-initializer position",
                    at: location
                )
            }
            // `+v` 是数值恒等：解释器的 `unaryValue` 原样返回操作数，故这里直接降载成操作数本身，
            // 不另造节点。下面的检查保住解释器对非数值抛出的那道拒绝。
            if op == .plus {
                let identity = try lowerExpr(operand, expected: nil, into: &context)
                guard identity.type.isNumeric else {
                    throw unsupported("unary plus on non-numeric operand", at: location)
                }
                return identity
            }
            let irOp: IRUnaryOp
            switch op {
            case .minus: irOp = .negate
            case .logicalNot, .not: irOp = .logicalNot
            case .bitwiseNot: irOp = .bitwiseNot
            default:
                throw unsupported("unary operator '\(op)' is not yet lowered to IR", at: location)
            }
            let lowered = try lowerExpr(operand, expected: nil, into: &context)
            switch irOp {
            case .negate:
                guard lowered.type.isNumeric else {
                    throw unsupported("unary minus on non-numeric operand", at: location)
                }
                return LoweredExpr(
                    node: .unary(op: .negate, operand: lowered.node, type: lowered.type),
                    type: lowered.type
                )
            case .logicalNot:
                guard lowered.type == .boolean else {
                    throw unsupported("logical not on non-Bool operand", at: location)
                }
                return LoweredExpr(
                    node: .unary(op: .logicalNot, operand: lowered.node, type: .boolean),
                    type: .boolean
                )
            case .bitwiseNot:
                guard lowered.type == .i32 else {
                    throw unsupported(
                        "bitwise not needs an I32 operand, got '\(lowered.type)'",
                        at: location
                    )
                }
                return LoweredExpr(
                    node: .unary(op: .bitwiseNot, operand: lowered.node, type: .i32),
                    type: .i32
                )
            case .abs:
                // 只有 abs 内建处理器会构造它；AST 的一元运算符路径从不产出。
                fatalError("IRLowerer: .abs outside the abs intrinsic handler")
            case .cast:
                // 转换由 `.cast` 表达式分支直接构造，不经一元运算符路径。
                fatalError("IRLowerer: .cast outside the cast handler")
            }

        case .selfKeyword(let location):
            // 方法的第一个 IR 参数就是 self。
            guard let type = context.variableTypes["self"] else {
                throw unsupported("self outside a method body", at: location)
            }
            return LoweredExpr(node: .load(name: "self", type: type), type: type)

        case .member(let object, let name, let location):
            // 切片语法里省略的边界以 `Optional.none`（Optional 类型名上的成员）到达 —— 降载成 none 字面量。
            if case .identifier("Optional", _) = object, name == "none" {
                return LoweredExpr(
                    node: .optionalConstruct(isSome: false, payload: nil, type: .optional(wrapped: .i32)),
                    type: .optional(wrapped: .i32)
                )
            }
            // 枚举型名限定的零参用例 `色彩.绿`：接收者是类型名、不是值，故必须在降载 receiver 之前拦截（否则按变量
            // 解析 ⇒ `reference to undeclared variable '色彩'`）。与限定构造支（`Enum.Case(实参)`）同一决议次序：
            // 先查枚举表、再看变量。
            if case .identifier(let enumTypeName, _) = object,
                let enumDecl = context.enums[enumTypeName],
                let enumCase = enumDecl.cases.first(where: { $0.name == name })
            {
                guard enumCase.payloadTypes.isEmpty else {
                    throw unsupported(
                        "case '\(name)' carries associated values — construct it as '\(enumTypeName).\(name)(…)'",
                        at: location
                    )
                }
                return LoweredExpr(
                    node: .enumConstruct(
                        enumName: enumDecl.name, caseName: enumCase.name, tag: enumCase.tag,
                        payloads: [], payloadTypes: [],
                        type: .enumeration(name: enumDecl.name)
                    ),
                    type: .enumeration(name: enumDecl.name)
                )
            }
            // 名义类型字段读：`base.field` / `self.field`。元组标签读：按下标 extractvalue。
            let loweredBase = try lowerExpr(object, expected: nil, into: &context)
            // err 字上的 `.message`：类型层把 `Error` / `CancelError` 都定义成带 `message`
            // 字段的结构体，而在 IR 里它只是**一个类型擦除的字** ⇒ 读消息要经运行时段，
            //  行不通  不是 GEP（对一个字做 GEP 只会得到无意义地址）。
            if name == "message", isErrorFaced(loweredBase.node, context) {
                return lowerErrorMessage(loweredBase.node, at: location)
            }
            /// 无主引用透传：解引用后按元素类型的成员继续；unsafe 门禁已由检查面把关。
            let base = unownedUnwrapped(loweredBase)
            // LazyRef 的 `.value` 读：`bk_lazyref_value(handle)` 返回缓存的元素盒，由调用方装载元素。
            if case .lazyRef(let element) = base.type, name == "value" {
                return LoweredExpr(
                    node: .lazyRefValue(handle: base.node, type: element),
                    type: element
                )
            }
            // 弱引用的值读：结果是 `Optional<T>`，目标销毁后为 `none`。
            if case .weakRef(let element) = base.type, name == "value" {
                let optional = IRType.optional(wrapped: element)
                return LoweredExpr(
                    node: .weakRefValue(handle: base.node, type: optional),
                    type: optional
                )
            }
            if case .tuple(let labels, let fieldTypes) = base.type {
                guard let index = labels.firstIndex(where: { $0 == name }) else {
                    throw unsupported("tuple has no field '\(name)'", at: location)
                }
                return LoweredExpr(
                    node: .tupleIndexGet(base: base.node, index: index, type: fieldTypes[index]),
                    type: fieldTypes[index]
                )
            }
            guard case .nominal = base.type else {
                throw unsupported("member access '.\(name)' outside the slice", at: location)
            }
            guard let fieldType = nominalFieldType(of: base.type, field: name, in: context) else {
                throw unsupported("no field '\(name)' on '\(base.type)'", at: location)
            }
            guard let fieldSlot = nominalFieldSlot(of: base.type, field: name, in: context) else {
                throw unsupported("no field slot for '\(name)' on '\(base.type)'", at: location)
            }
            return LoweredExpr(
                node: .fieldGet(base: base.node, slot: fieldSlot, type: fieldType),
                type: fieldType
            )

        case .tupleIndex(let object, let index, let location):
            // `.0` 按位置读：即上面标签成员读的数值版 —— 同一个 extractvalue 节点，
            // 下标取自语法而非标签查找。下标超出静态元数在这里就拒；
            // 解释器要到运行期才发现。
            let loweredBase = try lowerExpr(object, expected: nil, into: &context)
            guard case .tuple(_, let fieldTypes) = loweredBase.type else {
                throw unsupported("tuple index '.\(index)' on '\(loweredBase.type)'", at: location)
            }
            guard index >= 0 && index < fieldTypes.count else {
                throw unsupported(
                    "tuple index '.\(index)' is out of range for arity \(fieldTypes.count)",
                    at: location
                )
            }
            return LoweredExpr(
                node: .tupleIndexGet(base: loweredBase.node, index: index, type: fieldTypes[index]),
                type: fieldTypes[index]
            )

        case .genericConstruct(let typeName, let typeArgs, let arguments, let location):
            // `LazyRef<T>(closure)` 是内建惰性引用，不是用户泛型模板。放在模板分派之前判断，
            // 用户自建的同名 `LazyRef` 模板就压不住它 —— 内建名优先。
            if typeName == "LazyRef" {
                guard typeArgs.count == 1, let element = IRType(from: typeArgs[0]) else {
                    throw unsupported("LazyRef requires 1 resolvable type arg", at: location)
                }
                guard arguments.count == 1 else {
                    throw unsupported("LazyRef requires 1 argument (initializer closure)", at: location)
                }
                let loweredClosure = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
                guard case .function = loweredClosure.type else {
                    throw unsupported("LazyRef argument must be an initializer closure", at: location)
                }
                let type = IRType.lazyRef(element: element)
                return LoweredExpr(
                    node: .lazyRefConstruct(closure: loweredClosure.node, type: type),
                    type: type
                )
            }
            // `UnownedRef<T>(对象)`：显式类型实参形态，元素类型由实参表说定。
            if typeName == "UnownedRef" {
                guard typeArgs.count == 1,
                    let element = resolveAnnotationType(typeArgs[0], userTypes: context.userTypes)
                else {
                    throw unsupported("UnownedRef requires 1 resolvable type arg", at: location)
                }
                guard arguments.count == 1 else {
                    throw unsupported("UnownedRef expects exactly one object argument", at: location)
                }
                let loweredTarget = try lowerExpr(arguments[0].expression, expected: element, into: &context)
                let type = IRType.unownedRef(element: element)
                return LoweredExpr(
                    node: .unownedRefConstruct(target: loweredTarget.node, type: type),
                    type: type
                )
            }
            // 单态化构造：`盒<I32>()` 造特化结构体名义类型，`身份<I32>(x = 100)` 调特化函数。
            // 预扫描已登记两者，这里只做分派。
            if let template = context.genericFuncTemplates[typeName] {
                return try lowerGenericFuncCall(
                    template: template, typeArgs: typeArgs, arguments: arguments,
                    at: location, into: &context
                )
            }
            // 泛型枚举 case 的裸写法，case 名自带类型实参（`ok<I32, String>(42)`）。
            // 两张模板表都不收 case 名，所以落到这里。
            if let constructed = try lowerGenericEnumCaseConstruct(
                qualifier: typeName, caseName: typeName, typeArgs: typeArgs,
                arguments: arguments, at: location, into: &context
            ) {
                return constructed
            }
            if let info = context.nominalTypes[specializedSourceName(typeName, typeArgs: typeArgs)] {
                guard arguments.isEmpty else {
                    throw unsupported(
                        "constructor '\(typeName)<...>' arguments are not supported this grid",
                        at: location
                    )
                }
                let specializedName = specializedSourceName(typeName, typeArgs: typeArgs)
                let type = IRType.nominal(name: specializedName, isObject: info.isObject)
                return LoweredExpr(node: .construct(type: type), type: type)
            }
            if context.nominalTypes[typeName] != nil {
                throw unsupported(
                    "generic struct '\(typeName)' has no registered specialization for this use site",
                    at: location
                )
            }
            throw unsupported(
                "unknown generic '\(typeName)' (register a struct or function template)",
                at: location
            )

        case .dotCaseRef(let caseName, let location):
            // 无载荷 case 当点 case 值（`.plus`）；带载荷的要走调用形式构造。
            // 内建 Optional 上的 `.none` 就是空字面量。
            if caseName == "none" {
                return LoweredExpr(
                    node: .optionalConstruct(isSome: false, payload: nil, type: .optional(wrapped: .i32)),
                    type: .optional(wrapped: .i32)
                )
            }
            if let (enumDecl, enumCase) = try resolveEnumCase(caseName, at: location, in: context) {
                if enumCase.payloadTypes.isEmpty {
                    return LoweredExpr(
                        node: .enumConstruct(
                            enumName: enumDecl.name, caseName: enumCase.name, tag: enumCase.tag,
                            payloads: [], payloadTypes: [],
                            type: .enumeration(name: enumDecl.name)
                        ),
                        type: .enumeration(name: enumDecl.name)
                    )
                }
                throw unsupported(
                    "dot-case '.\(caseName)' carries associated values — use the call form with arguments",
                    at: location
                )
            }
            throw unsupported("undefined enum case '.\(caseName)'", at: location)

        case .dictionaryLiteral(let entries, let location):
            // 字典字面量 —— 键/值类型由降载后的条目推导（要求同质；检查器的推断只覆盖静态一侧）。
            var loweredEntries: [IRDictEntry] = []
            var keyType: IRType? = nil
            var valueType: IRType? = nil
            for entry in entries {
                let loweredKey = try lowerExpr(entry.key, expected: keyType, into: &context)
                if let known = keyType {
                    try requireAssignable(loweredKey.type, to: known, at: location)
                } else {
                    keyType = loweredKey.type
                }
                let loweredValue = try lowerExpr(entry.value, expected: valueType, into: &context)
                if let known = valueType {
                    try requireAssignable(loweredValue.type, to: known, at: location)
                } else {
                    valueType = loweredValue.type
                }
                loweredEntries.append(IRDictEntry(key: loweredKey.node, value: loweredValue.node))
            }
            guard let key = keyType, let value = valueType else {
                throw unsupported("empty dictionary literal needs an entry (annotate the variable)", at: location)
            }
            let dictType = IRType.dict(key: key, value: value)
            return LoweredExpr(node: .dictLiteral(entries: loweredEntries, type: dictType), type: dictType)

        case .setLiteral(let elements, let location):
            var loweredElements: [IRExpr] = []
            var elementType: IRType? = nil
            for element in elements {
                let lowered = try lowerExpr(element, expected: elementType, into: &context)
                if let known = elementType {
                    try requireAssignable(lowered.type, to: known, at: location)
                } else {
                    elementType = lowered.type
                }
                loweredElements.append(lowered.node)
            }
            guard let resolvedElement = elementType else {
                throw unsupported("empty set literal needs an element (annotate the variable)", at: location)
            }
            let setType = IRType.set(element: resolvedElement)
            return LoweredExpr(node: .setLiteral(elements: loweredElements, type: setType), type: setType)

        case .tuple(let labels, let elements, let location):
            var loweredElements: [IRExpr] = []
            var fieldTypes: [IRType] = []
            for element in elements {
                let lowered = try lowerExpr(element, expected: nil, into: &context)
                loweredElements.append(lowered.node)
                fieldTypes.append(lowered.type)
            }
            let tupleType = IRType.tuple(labels: labels, fieldTypes: fieldTypes)
            return LoweredExpr(node: .tupleConstruct(labels: labels, elements: loweredElements, type: tupleType), type: tupleType)

        case .call(let callee, let arguments, let location):
            // 成员调用：宽容读通道 `arr.get(i)` 与切片通道 `base.slice(start, end)`（语法糖脱糖）；
            // 其余方法调用仍门禁。点 case 构造 `.Case(args)` 是成员标记，按唯一的 case 名
            // 或期望类型解析，`.none` / `.some` 先归 Optional。
            if case .dotCaseRef(let dotName, _) = callee {
                if dotName == "none" {
                    return LoweredExpr(
                        node: .optionalConstruct(isSome: false, payload: nil, type: .optional(wrapped: .i32)),
                        type: .optional(wrapped: .i32)
                    )
                }
                if dotName == "some" {
                    guard arguments.count == 1 else {
                        throw unsupported("Optional.some expects exactly one argument", at: location)
                    }
                    let loweredPayload = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
                    let type = IRType.optional(wrapped: loweredPayload.type)
                    return LoweredExpr(
                        node: .optionalConstruct(isSome: true, payload: loweredPayload.node, type: type),
                        type: type
                    )
                }
                if let (enumDecl, enumCase) = try resolveEnumCase(dotName, at: location, in: context) {
                    return try lowerEnumCaseConstructor(
                        enumDecl: enumDecl, enumCase: enumCase, arguments: arguments,
                        at: location, into: &context
                    )
                }
                throw unsupported(
                    "dot-case construction '.\(dotName)' has no resolvable enum case",
                    at: location
                )
            }
            // 限定泛型枚举 case 构造（`结果<I32, String>.ok(42)`）以零实参泛型构造作成员的接收者到来：
            // 限定词点明枚举，父枚举与类型实参都写在源码里。
            // 那个空实参表正是它与「泛型值上的成员访问」的分界。
            if case .member(let object, let memberName, _) = callee,
                case .genericConstruct(let enumName, let enumTypeArgs, let enumArguments, _) = object,
                enumArguments.isEmpty,
                let constructed = try lowerGenericEnumCaseConstruct(
                    qualifier: enumName, caseName: memberName, typeArgs: enumTypeArgs,
                    arguments: arguments, at: location, into: &context
                )
            {
                return constructed
            }
            if case .member(let object, let memberName, _) = callee {
                return try lowerMemberCall(
                    object: object, memberName: memberName, arguments: arguments,
                    expected: expected, at: location, into: &context
                )
            }
            // 泛型调用 `身份<I32>(...)` 与结构体构造 `盒<I32>()` 以专门的 `.genericConstruct`
            // 表达式节点到达（解析器前瞻）—— 在下面它自己的 case 里处理。
            guard case .identifier(let functionName, _) = callee else {
                throw unsupported(
                    "call to a non-identifier callee (method calls are later grids)",
                    at: location
                )
            }
            let loweredArgs = try arguments.map { argument in
                try lowerExpr(argument.expression, expected: nil, into: &context)
            }
            // 指针内建 load/store：对应解释器的 registerPointerBuiltins 面
            // （与签名无关 —— 指针的元素类型决定解码/编码）。
            if functionName == "load" {
                guard loweredArgs.count == 1, case .pointer(let element) = loweredArgs[0].type else {
                    throw unsupported("load expects exactly one *T pointer argument", at: location)
                }
                return LoweredExpr(
                    node: .pointerLoad(pointer: loweredArgs[0].node, type: element),
                    type: element
                )
            }
            if functionName == "store" {
                guard arguments.count == 2,
                    case .pointer(let element) = loweredArgs[0].type
                else {
                    throw unsupported("store expects (pointer, value) arguments", at: location)
                }
                // 值会按指针的元素类型重新降载，无类型字面量因此采纳它（`*U8` 上 `store(p, 42)` 写 u8）。
                // 有声明类型的值保持自身类型 —— 编码会截断，I32 存进 `*U8` 写低字节，与解释器一致。
                let value = try lowerExpr(arguments[1].expression, expected: element, into: &context)
                return LoweredExpr(
                    node: .pointerStore(pointer: loweredArgs[0].node, value: value.node, type: element),
                    type: .i32
                )
            }
            // 取回：`*U8 → String`，与 `toCString` 反向。读法归运行时段，发射层只接一个调用名。
            if functionName == "fromCString" {
                guard loweredArgs.count == 1, case .pointer = loweredArgs[0].type else {
                    throw unsupported("fromCString expects one *U8 pointer argument", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: .string),
                    type: .string
                )
            }
            // 内建 `assert`：`assert(cond)` 或 `assert(cond, message)`。条件必须是 Bool，
            // 为假经运行时的 panic 路径终止；测试块从不被 harness 执行，但降载路径仍需存在。
            if functionName == "assert" {
                guard loweredArgs.count == 1 || loweredArgs.count == 2 else {
                    throw unsupported("assert expects (condition) or (condition, message)", at: location)
                }
                guard loweredArgs[0].type == .boolean else {
                    throw unsupported("assert condition must be Bool", at: location)
                }
                if loweredArgs.count == 2 {
                    guard loweredArgs[1].type == .string else {
                        throw unsupported("assert message must be String", at: location)
                    }
                }
                return LoweredExpr(
                    node: .assertCall(
                        condition: loweredArgs[0].node,
                        message: loweredArgs.count == 2 ? loweredArgs[1].node : nil
                    ),
                    type: .i32
                )
            }
            // 内建 `print`：单实参形式保留原有门禁；多实参形式逐个字符串化，用空格连成一行。
            // 那条路径上没有 Result 与名义类型的门禁 —— FFI 语料要打印标量、字符串和指针。
            if functionName == "print" {
                // 零实参形式就是一个换行：解释器把空实参表连接成空串交给 sink，
                // 无参的 `printMulti` 做的是同一件事。
                if loweredArgs.isEmpty {
                    return LoweredExpr(node: .printMulti(arguments: []), type: .i32)
                }
                if loweredArgs.count == 1 {
                    if isErrorFaced(loweredArgs[0].node, context) {
                        // err 绑定是一个字；`print` 打的是它的**消息**（与 `e.message` 同一个读口）。
                        let message = lowerErrorMessage(loweredArgs[0].node, at: location)
                        return LoweredExpr(node: .printCall(argument: message.node), type: .i32)
                    }
                    if case .result = loweredArgs[0].type {
                        throw unsupported("printing a Result value is outside the slice", at: location)
                    }
                    return LoweredExpr(node: .printCall(argument: loweredArgs[0].node), type: .i32)
                }
                return LoweredExpr(node: .printMulti(arguments: loweredArgs.map { $0.node }), type: .i32)
            }
            // 宿主环境查询内建：二者零参、由执行器按名回答，故降成同形的 `call`（与 `print` 一样不需要新节点）。
            // `argv` 取参数字符串数组，`moduleRoot` 取程序基准的绝对路径；值由运行时段给，本层不解析。
            if functionName == "argv" || functionName == "moduleRoot" {
                guard loweredArgs.isEmpty else {
                    throw unsupported("\(functionName) takes no arguments", at: location)
                }
                let queryType: IRType =
                    functionName == "argv"
                    ? .array(element: .string)
                    : .string
                return LoweredExpr(
                    node: .call(function: functionName, arguments: [], returnType: queryType),
                    type: queryType
                )
            }
            // 目录枚举内建：与上面两条同形 —— 降成既有 `call`，由执行器按名回答，不新增 IR 节点
            // （节点集与契约因此不动，覆盖检查不受影响）。路径由运行时段解释，本层只透传。
            if functionName == "listDir" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("listDir expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("listDir expects a String path", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: .array(element: .string)
                    ),
                    type: .array(element: .string)
                )
            }
            // 探测类内建：与 `listDir` 同形（降成既有 `call`， 行不通  不新增节点）。
            // 与操作类相反 —— 路径不存在是**正常答案**，故不 panic 且不改判 bool 面。
            if functionName == "exists" || functionName == "isDir" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("\(functionName) expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("\(functionName) expects a String path", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: .boolean
                    ),
                    type: .boolean
                )
            }
            // 建目录：与探测类同形（`call` 节点，不新增 IR 节点），差在无值 —— 发射时是
            // `call void`。`IRType` 没有 void 成员，返回类型照 `writeFile` 的成例记 `.i32` 占位，
            // 该字段对无值调用点不参与任何判定。
            if functionName == "ensureDir" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("ensureDir expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("ensureDir expects a String path", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: .i32
                    ),
                    type: .i32
                )
            }
            // 字符类内建。形状与其他内建相同 —— 降载成按名由执行器应答的 `call` ——
            // 而名单就是那张表本身，故不会出现这里降载了、那里无人应答的名字。
            if BuiltinSurface.character.contains(functionName) {
                guard loweredArgs.count == 1 else {
                    throw unsupported("\(functionName) expects exactly one argument", at: location)
                }
                let resultType: IRType
                switch functionName {
                // `chars` 的**元素**与 `chr` 的**结果**都是 `Char`（窄化的另两个构造点）；
                // `ord` 仍是 `I32`、其余三个谓词仍是 `Bool`。
                case "chars": resultType = .array(element: .char)
                case "tempUtf8Bytes": resultType = .array(element: .u8)
                case "tempByteToInt": resultType = .i32
                case "tempIntToByte": resultType = .u8
                case "chr": resultType = .char
                case "ord": resultType = .i32
                default: resultType = .boolean
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: resultType),
                    type: resultType
                )
            }

            // 普通调用能承载的并发内建：`sleep` 阻塞，`Error` / `CancelError` 造值。
            // 名单即那张表，故不会出现这里降载了、执行器却不应答的名字。
            // 与 `Future` 值打交道的名字不在此列：IR 还表达不了它。
            if BuiltinSurface.synchronousConcurrency.contains(functionName) {
                if functionName == "sleep" {
                    // 阻塞且不产出值，值被丢弃。无返回类型的 call 正是本降载器对 void 被调方发出的形状。
                    guard loweredArgs.count == 1, loweredArgs[0].type == .i32 else {
                        throw unsupported("sleep expects one I32 argument", at: location)
                    }
                    return LoweredExpr(
                        node: .call(
                            function: functionName,
                            arguments: loweredArgs.map { $0.node },
                            returnType: nil),
                        type: .i32
                    )
                }
                // `Error("msg")` / `CancelError("msg")`：一个 String 实参，产出的是名义值；
                // 两者除名字外没有别的共同点 —— 区分它们的是 `isCancel`，从不是载荷。
                guard loweredArgs.count == 1, loweredArgs[0].type == .string else {
                    throw unsupported("\(functionName) expects one String argument", at: location)
                }
                // 错误值的 IR 承载 = 一个 i64 字（err 槽是类型擦除的机器字）。不是名义类型指针：`%struct.Error*`
                // 从来没有类型定义，落到默认改名就是 `use of undefined type`。字里是什么由运行时段定义，本层读它
                // 只有两条路 —— `isCancel` 与 `e.message`（后者降成 `pini.err.message`）。
                let errorType = IRType.i64
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: errorType),
                    type: errorType
                )
            }
            // 产出 Future 的并发内建。它们不在共享表里，因为应答它们需要调度器与任务上下文，
            // 无状态表带不了；两边按名字逐一对应。IR 用异步调用返回的 `Result<T>` 表示 future ——
            // 节点类型就是它的 join 值。
            if functionName == "isCancel" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("isCancel expects exactly one argument", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: .boolean),
                    type: .boolean
                )
            }
            if functionName == "joinAll" {
                // 字面量与变量两种形态都接：前者由发射器排成连续句柄区，后者由运行时遍历数组盒。
                // 元素必须是 `Future` —— 不是就到此为止，不让发射器以 fatalError 兜底。
                guard loweredArgs.count == 1,
                    case .array(let element) = loweredArgs[0].type,
                    case .future(let memberOK) = element
                else {
                    throw unsupported("joinAll expects one array of futures", at: location)
                }
                /// 聚合结果是各成员 **ok 载荷** 的数组，不是句柄数组：`join` 之后元素已结算。
                let aggregated = IRType.result(ok: .array(element: memberOK))
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: aggregated),
                    type: aggregated
                )
            }
            if functionName == "joinWithin" {
                guard loweredArgs.count == 2, loweredArgs[1].type == .i32 else {
                    throw unsupported("joinWithin expects a future and an I32 timeout", at: location)
                }
                /// 与 `join` 同一条翻译：句柄进、`Result` 出。沿用实参类型会把 Future 当成站点类型，
                /// 而三槽装配要的是 Result。
                let bounded = loweredArgs[0].type.joinedResultType ?? loweredArgs[0].type
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: bounded),
                    type: bounded
                )
            }
            // `F64(x)`：数值构造函数。浮点直接通过，整数经一次 `call` 加宽（执行器按名应答），
            // 其余类型在这里就拒，与运行时自己的拒绝一致。
            if functionName == "F64" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("F64 expects exactly one argument", at: location)
                }
                switch loweredArgs[0].type {
                case .f64:
                    return loweredArgs[0]
                case .i32, .i64, .u64:
                    return LoweredExpr(
                        node: .call(
                            function: "F64",
                            arguments: loweredArgs.map { $0.node },
                            returnType: .f64),
                        type: .f64
                    )
                default:
                    throw unsupported("F64 expects a numeric argument (int or float)", at: location)
                }
            }
            // `LazyRef(closure)`：推断写法，与泛型构造分支降载的 `LazyRef<T>(closure)` 是同一物。
            // 元素类型取自初始化闭包自己的返回类型；读不出返回类型的闭包直接拒，不去猜。
            if functionName == "LazyRef" {
                guard loweredArgs.count == 1 else {
                    throw unsupported(
                        "LazyRef expects exactly one argument (initializer closure)", at: location
                    )
                }
                guard case .function(_, let closureReturn, _) = loweredArgs[0].type,
                    let element = closureReturn
                else {
                    throw unsupported(
                        "LazyRef argument must be an initializer closure with a readable return type",
                        at: location
                    )
                }
                let type = IRType.lazyRef(element: element)
                return LoweredExpr(
                    node: .lazyRefConstruct(closure: loweredArgs[0].node, type: type),
                    type: type
                )
            }
            // `UnownedRef(对象)`：省略类型实参的形态，元素类型取自实参。
            if functionName == "UnownedRef" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("UnownedRef expects exactly one object argument", at: location)
                }
                let type = IRType.unownedRef(element: loweredArgs[0].type)
                return LoweredExpr(
                    node: .unownedRefConstruct(target: loweredArgs[0].node, type: type),
                    type: type
                )
            }
            if functionName == "sqrt" {
                guard loweredArgs.count == 1, loweredArgs[0].type == .f64 else {
                    throw unsupported("sqrt expects exactly one F64 argument", at: location)
                }
                return LoweredExpr(
                    node: .call(function: "sqrt", arguments: loweredArgs.map { $0.node }, returnType: .f64),
                    type: .f64
                )
            }
            // 数学内建：sin/cos 走 llvm intrinsics，tan 展开为 sin/cos，abs/min/max 落在 I32。
            if functionName == "sin" || functionName == "cos" {
                guard loweredArgs.count == 1, loweredArgs[0].type == .f64 else {
                    throw unsupported("\(functionName) expects exactly one F64 argument", at: location)
                }
                return LoweredExpr(
                    node: .call(function: "llvm.\(functionName).f64", arguments: loweredArgs.map { $0.node }, returnType: .f64),
                    type: .f64
                )
            }
            if functionName == "tan" {
                guard loweredArgs.count == 1, loweredArgs[0].type == .f64 else {
                    throw unsupported("tan expects exactly one F64 argument", at: location)
                }
                let arg = loweredArgs[0].node
                return LoweredExpr(
                    node: .binary(
                        op: .divide,
                        lhs: .call(function: "llvm.sin.f64", arguments: [arg], returnType: .f64),
                        rhs: .call(function: "llvm.cos.f64", arguments: [arg], returnType: .f64),
                        type: .f64),
                    type: .f64
                )
            }
            if functionName == "abs" {
                guard loweredArgs.count == 1, loweredArgs[0].type == .i32 else {
                    throw unsupported("abs expects exactly one I32 argument", at: location)
                }
                return LoweredExpr(
                    node: .unary(op: .abs, operand: loweredArgs[0].node, type: .i32),
                    type: .i32
                )
            }
            if functionName == "min" || functionName == "max" {
                guard loweredArgs.count == 2, loweredArgs[0].type == .i32, loweredArgs[1].type == .i32 else {
                    throw unsupported("\(functionName) expects exactly two I32 arguments", at: location)
                }
                return LoweredExpr(
                    node: .binary(
                        op: functionName == "min" ? .minOf : .maxOf,
                        lhs: loweredArgs[0].node, rhs: loweredArgs[1].node, type: .i32),
                    type: .i32
                )
            }
            // 内建 len：数组/字典/集合走运行时句柄，字符串走内联 strlen 扫描。
            // 元组的元数是其类型的静态属性，故 len(tuple) 折叠成常量。
            if functionName == "len" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("len expects exactly one argument", at: location)
                }
                switch loweredArgs[0].type {
                case .array, .dict, .set, .string:
                    return LoweredExpr(node: .lenCall(argument: loweredArgs[0].node), type: .i32)
                case .tuple(_, let fieldTypes):
                    return LoweredExpr(
                        node: .intConst(value: fieldTypes.count, type: .i32), type: .i32
                    )
                default:
                    throw unsupported(
                        "len on '\(loweredArgs[0].type)' is outside this grid",
                        at: location
                    )
                }
            }
            // 文件 IO 内建 writeFile/readFile：路径不在这里解析 —— 发射器把程序基址注入运行时，
            // 两条通道按同一条规则解析相对路径（`RuntimeOps.resolveIOPath`）。
            // `writeFile` 不返回值却标成 `.i32`：`IRType` 没有 void 成员，这个字段也没人读。
            if functionName == "writeFile" {
                guard loweredArgs.count == 2 else {
                    throw unsupported("writeFile expects (path, content)", at: location)
                }
                guard loweredArgs[0].type == .string, loweredArgs[1].type == .string else {
                    throw unsupported("writeFile expects two String arguments", at: location)
                }
                return LoweredExpr(
                    node: .fileWrite(path: loweredArgs[0].node, content: loweredArgs[1].node),
                    type: .i32
                )
            }
            if functionName == "appendFile" {
                guard loweredArgs.count == 2 else {
                    throw unsupported("appendFile expects (path, content)", at: location)
                }
                guard loweredArgs[0].type == .string, loweredArgs[1].type == .string else {
                    throw unsupported("appendFile expects two String arguments", at: location)
                }
                return LoweredExpr(
                    node: .fileAppend(path: loweredArgs[0].node, content: loweredArgs[1].node),
                    type: .i32
                )
            }
            if functionName == "readFile" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("readFile expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("readFile expects a String path", at: location)
                }
                return LoweredExpr(node: .fileRead(path: loweredArgs[0].node), type: .string)
            }
            // 可接住的 IO：与上面三条**同一个操作、另一种失败形态**。判据是源码写的
            // 那个名字， 行不通  不是运行时开关 —— 一次调用只可能有一种失败形态。
            // 载荷：读是内容，写与追加是空元组（见 `IRNode` 那三个 case 的注释）。
            if functionName == "tryWriteFile" || functionName == "tryAppendFile" {
                guard loweredArgs.count == 2 else {
                    throw unsupported("\(functionName) expects (path, content)", at: location)
                }
                guard loweredArgs[0].type == .string, loweredArgs[1].type == .string else {
                    throw unsupported("\(functionName) expects two String arguments", at: location)
                }
                let node: IRExpr =
                    functionName == "tryWriteFile"
                    ? .fileTryWrite(
                        path: loweredArgs[0].node, content: loweredArgs[1].node)
                    : .fileTryAppend(
                        path: loweredArgs[0].node, content: loweredArgs[1].node)
                return LoweredExpr(
                    node: node, type: .result(ok: .tuple(labels: [], fieldTypes: [])))
            }
            if functionName == "tryReadFile" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("tryReadFile expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("tryReadFile expects a String path", at: location)
                }
                return LoweredExpr(
                    node: .fileTryRead(path: loweredArgs[0].node), type: .result(ok: .string))
            }
            // 门禁之下剩下的两个语料内建：`readLine()`（无参）与 `is_ascii_digit(s)`。
            if functionName == "readLine" {
                guard loweredArgs.isEmpty else {
                    throw unsupported("readLine expects no arguments", at: location)
                }
                return LoweredExpr(node: .readLine, type: .string)
            }
            if functionName == "is_ascii_digit" {
                // 参数面是 `Char`。判据取**字符串面**而非字面 `.char` —— 两者表示同构，
                // 且 `Char` 加宽到 `String` 合法，故两种都该收，
                // 否则一个本该合法的实参会在此被响亮拒绝。
                guard loweredArgs.count == 1, loweredArgs[0].type.isStringFaced else {
                    throw unsupported("is_ascii_digit expects one Char argument", at: location)
                }
                return LoweredExpr(
                    node: .isAsciiDigit(argument: loweredArgs[0].node), type: .boolean
                )
            }
            // Result case 构造（`ok` / `err`）：要求处在 Result 类型的上下文里（返回位置、
            // Result 类型赋值），静态 Result 类型才已知。`^T` 不约束错误类型，故 `err(e)` 采纳上下文的那一个。
            if functionName == "ok" || functionName == "err" {
                guard let contextType = expected, case .result(let okType) = contextType else {
                    throw unsupported(
                        "'\(functionName)' construction requires a Result-typed context this grid",
                        at: location
                    )
                }
                guard loweredArgs.count == 1 else {
                    throw unsupported("'\(functionName)' expects exactly one argument", at: location)
                }
                if functionName == "ok" {
                    try requireAssignable(loweredArgs[0].type, to: okType, at: location)
                }
                let info = functionName == "ok"
                    ? (base: Int32(0), tagged: false, codes: nil)
                    : Self.errorCodeInfo(for: loweredArgs[0].type, in: context)
                return LoweredExpr(
                    node: .resultConstruct(
                        isOk: functionName == "ok", payload: loweredArgs[0].node,
                        errorBaseCode: info.base, errorTagged: info.tagged,
                        errorCodes: info.codes,
                        type: contextType),
                    type: contextType
                )
            }
            // 经函数值间接调用：被调方是持有闭包或具名函数的变量（函数类型形参 `f(x)`、
            // 闭包变量 `sq(6)`）；using 位随该函数类型一起流动，省略的写法由实例节点补上。裸调用见下文。
            if let signature = context.variableTypes[functionName],
                case .function(let paramTypes, let functionReturn, let variableUsing) = signature
            {
                let mapping = try usingParamMapping(
                    callee: functionName, paramCount: paramTypes.count,
                    usingParamIndices: variableUsing, argumentCount: loweredArgs.count, at: location
                )
                for (index, argument) in loweredArgs.enumerated() {
                    try requireAssignable(argument.type, to: paramTypes[mapping[index]], at: location)
                }
                let nodes = try fillUsingArguments(
                    retypedArgs: loweredArgs, paramIndices: mapping, paramTypes: paramTypes,
                    usingParamIndices: variableUsing,
                    omittedForm: loweredArgs.count != paramTypes.count,
                    callee: functionName, at: location, into: &context
                )
                return LoweredExpr(
                    node: .indirectCall(
                        callee: .load(name: functionName, type: signature),
                        arguments: nodes,
                        returnType: functionReturn
                    ),
                    type: functionReturn ?? .i32
                )
            }
            // 内联闭包字面量上的直接调用 `sq(6)`：callee 是 `.funcLiteral`，没有具名符号。
            // 内联字面量的取用位**就在声明里**，比经变量更直接。
            if case .funcLiteral(let literalDecl, let literalLocation) = callee {
                let loweredCallee = try lowerFuncLiteral(
                    decl: literalDecl, expected: nil, at: literalLocation, into: &context
                )
                guard case .function(let literalParams, let literalReturn, _) = loweredCallee.type else {
                    throw unsupported("inline anonymous function resolved to a non-function type", at: location)
                }
                let literalUsing = usingParamIndices(literalDecl)
                let mapping = try usingParamMapping(
                    callee: "<anon>", paramCount: literalParams.count,
                    usingParamIndices: literalUsing, argumentCount: loweredArgs.count, at: location
                )
                for (index, argument) in loweredArgs.enumerated() {
                    try requireAssignable(argument.type, to: literalParams[mapping[index]], at: location)
                }
                let nodes = try fillUsingArguments(
                    retypedArgs: loweredArgs, paramIndices: mapping, paramTypes: literalParams,
                    usingParamIndices: literalUsing,
                    omittedForm: loweredArgs.count != literalParams.count,
                    callee: "<anon>", at: location, into: &context
                )
                return LoweredExpr(
                    node: .indirectCall(
                        callee: loweredCallee.node,
                        arguments: nodes,
                        returnType: literalReturn
                    ),
                    type: literalReturn ?? .i32
                )
            }
            // 枚举 case 构造 `圆(2.0)` / `identifier(text= "x")`：在函数签名表之前解析 ——
            // case 名与函数共用标识符命名空间。
            if case .identifier(let caseName, _) = callee,
                let (enumDecl, enumCase) = try resolveEnumCase(caseName, at: location, in: context)
            {
                if enumCase.payloadTypes.isEmpty && arguments.isEmpty {
                    return try lowerBareEnumCase(caseName, at: location, into: &context)!
                }
                return try lowerEnumCaseConstructor(
                    enumDecl: enumDecl, enumCase: enumCase, arguments: arguments,
                    at: location, into: &context
                )
            }
            // 名义类型构造 `名()`：字段取声明里的默认值；构造函数实参不在当前支持面内。
            if let info = context.nominalTypes[functionName] {
                guard loweredArgs.isEmpty else {
                    throw unsupported(
                        "constructor '\(functionName)' arguments are not supported this grid",
                        at: location
                    )
                }
                let type = IRType.nominal(name: functionName, isObject: info.isObject)
                return LoweredExpr(node: .construct(type: type), type: type)
            }
            guard let signature = context.moduleSignatures[functionName] else {
                throw unsupported(
                    "call to unknown function '\(functionName)' (intrinsics beyond print are later grids)",
                    at: location
                )
            }
            // 用每个形参的类型作为期望上下文逐位降载实参，无标注的整数字面量因此采用非 I32 的槽位（U64 形参下 64 是 u64）。
            // `using` 形参的实参可由编译器插入：先问实参对哪些形参位，再逐位降载，`using` 位在填充阶段补取用点。
            let argumentNodes: [IRExpr]
            if signature.isVariadic {
                // 变参放宽的是上限：固定前缀照签名逐位对，多出来的按默认实参提升口径接。
                argumentNodes = try lowerVariadicArguments(
                    callee: functionName, arguments: arguments, signature: signature,
                    at: location, into: &context)
            } else {
                let paramIndices = try usingParamMapping(
                    callee: functionName, paramCount: signature.paramTypes.count,
                    usingParamIndices: signature.usingParamIndices, argumentCount: arguments.count,
                    at: location)
                let retypedArgs = try zip(arguments, paramIndices).map { argument, paramIndex in
                    try lowerCallArgument(
                        argument.expression, paramIndex: paramIndex, signature: signature,
                        at: location, into: &context)
                }
                for (position, argument) in retypedArgs.enumerated()
                where !signature.untypedParamIndices.contains(paramIndices[position])
                    && !signature.handleParamIndices.contains(paramIndices[position])
                {
                    try requireAssignable(
                        argument.type, to: signature.paramTypes[paramIndices[position]], at: location)
                }
                argumentNodes = try fillUsingArguments(
                    retypedArgs: retypedArgs, paramIndices: paramIndices,
                    paramTypes: signature.paramTypes, usingParamIndices: signature.usingParamIndices,
                    omittedForm: arguments.count != signature.paramTypes.count,
                    callee: functionName, at: location, into: &context)
            }
            context.recordCall(functionName)
            return LoweredExpr(
                node: .call(
                    function: functionName,
                    arguments: argumentNodes,
                    returnType: signature.bodyReturnType
                ),
                type: signature.returnType ?? .i32
            )

        case .tryExpression(_, _, _, let location):
            throw unsupported(
                "try-else is only supported as a statement or a variable initializer this grid",
                at: location
            )

        case .funcLiteral(let decl, let location):
            return try lowerFuncLiteral(decl: decl, expected: expected, at: location, into: &context)

        case .cast(let operand, let target, let location):
            // `v as T`：结果类型取标注，源类型由操作数自身的 IR 类型给出。这里不把外层期望
            // 传给操作数 —— 那是转换**之后**的类型，传下去会把源侧的字面量定型带偏。
            guard let targetType = IRType(from: target) else {
                throw unsupported("`as` 的目标类型不在 IR 类型面", at: location)
            }
            let lowered = try lowerExpr(operand, expected: nil, into: &context)
            return LoweredExpr(
                node: .unary(op: .cast, operand: lowered.node, type: targetType),
                type: targetType)

        case .unsafe(let operand, _):
            // `unsafe (...)` 只是解析/检查层的标记：被包表达式照原样降载，
            // 因为安全断言的下标通道在发射时不需要区分 unsafe。
            return try lowerExpr(operand, expected: expected, into: &context)

        case .weakRef(let operand, let location):
            let lowered = try lowerExpr(operand, expected: nil, into: &context)
            guard case .nominal(_, let isObject) = lowered.type, isObject else {
                throw unsupported("weak 的操作数必须是对象，实得 \(lowered.type)", at: location)
            }
            let type = IRType.weakRef(element: lowered.type)
            return LoweredExpr(
                node: .weakRefConstruct(target: lowered.node, type: type),
                type: type)

        case .addressOf(let operand, let location):
            // `&x` 产出变量的存储地址。这里只接受标识符形式；指针的元素类型照抄变量类型，
            // 与解释器给其快照打上值的类型标签的做法一致。
            guard case .identifier(let name, _) = operand else {
                throw unsupported(
                    "address-of supports only a plain variable this grid",
                    at: location
                )
            }
            guard let varType = context.variableTypes[name] else {
                // `&外部符号` 取的是符号自身的存储地址，不是值快照 —— 这正是它和 `&局部变量` 的差别。
                if let foreignType = context.foreignData[name] {
                    return LoweredExpr(
                        node: .foreignDataAddress(name: name, type: foreignType),
                        type: .pointer(element: foreignType))
                }
                if context.foreignConstants[name] != nil {
                    throw unsupported(
                        "`&\(name)`：宏常量是构建期的值，没有地址可取", at: location)
                }
                throw unsupported("address-of on unknown variable '\(name)'", at: location)
            }
            return LoweredExpr(
                node: .addressOfVar(name: name, type: varType),
                type: .pointer(element: varType)
            )

        case .join(let inner, let joinLocation, let form):
            // `await` / `wait` 的上下文与位置判定。两个关键字各自绑定自己的上下文，`await` 还额外要求可让出位置：
            // 它承诺让出，只有在能兑现的地方才诚实。位置越界必须拒 —— 让出需要可恢复的体，语句根之外没有续跑点，
            // 同一个 `await` 就会有的让出、有的静默按阻塞处理。两种拒绝理由修法不同，故用两个码分开。
            switch form {
            case .awaits:
                guard context.isAsync else {
                    throw rejected(
                        "`await` 只能写在异步函数体（`=>`）里：这里不在异步体内。"
                            + "同步上下文里等待请写 `wait`",
                        code: Self.awaitOutsideAsyncBodyCode, at: joinLocation
                    )
                }
                guard let allowed = context.allowedAwaitAt, allowed == joinLocation else {
                    throw rejected(
                        "`await` 不能写在这个位置：它会让出当前任务，而这里没有可恢复的续跑点。"
                            + "把这次等待挪到**函数体那一层**的一条语句根部：`await f()` 独占一行 · "
                            + "`var x = await f()` · `try await f() else …` · `match await f():`；"
                            + "嵌在 `if` / 循环体 / `match` 的 case 体里的那几形同样不行 —— "
                            + "续跑跳不回嵌套块。",
                        code: Self.awaitUnrecoverablePositionCode, at: joinLocation
                    )
                }
            case .waits:
                guard !context.isAsync else {
                    throw rejected(
                        "`wait` 只能写在同步函数体（`->`）里：它会占住当前线程直到子任务结束，"
                            + "而异步体内这样写会让任务池里的槽位各等各自的子任务、"
                            + "子任务排不到线程。异步体里等待请写 `await`",
                        code: Self.awaitOutsideAsyncBodyCode, at: joinLocation
                    )
                }
            }

            // `await f` / `wait f`：操作数求值成句柄，本位置产出其 join 解构出的 `Result<T>` ——
            // 句柄进、结算值出，故意是两个不同的 IR 类型，后端才分得清异步调用与普通 Result。
            // 操作数不带期望类型：非 future 在运行期失败。
            let future = try lowerExpr(inner, expected: nil, into: &context)
            // 一个句柄进，一个结算值出。回退分支把非句柄操作数原样放过：
            // 检查器已拒过它，另一个引擎也只在运行期发现，在这里拒会把错误提前到这条通道之外。
            let siteType = future.type.joinedResultType ?? future.type
            return LoweredExpr(
                node: .join(future: future.node, type: siteType, form: form),
                type: siteType
            )

        default:
            throw unsupported(
                "expression '\(expression.kindName)' is not yet lowered to IR",
                at: expressionLocation(expression)
            )
        }
    }

    // MARK: - 闭包与高阶函数

    /// 按源码顺序收集 funcLiteral 的 id，键为「行:列」，每个字面量因此有稳定 id。
    /// 遍历会进入 funcLiteral 体：嵌套闭包的 id 外层先、内层后 ——
    /// 外层的 id 分配完，收集器才走进体里的语句。
    private static func precollectClosureIds(
        in statements: [Statement],
        counter: inout Int,
        into ids: inout [String: Int]
    ) {
        for statement in statements {
            precollectClosureIds(in: statement, counter: &counter, into: &ids)
        }
    }

    private static func precollectClosureIds(
        in statement: Statement,
        counter: inout Int,
        into ids: inout [String: Int]
    ) {
        switch statement {
        case .varDecl(_, _, let initializer, _, _):
            if let initializer = initializer {
                precollectClosureIds(in: initializer, counter: &counter, into: &ids)
            }
        case .assign(let target, let value, _):
            if case .identifier = target {}  // identifier targets carry no literals
            precollectClosureIds(in: value, counter: &counter, into: &ids)
        case .expressionStmt(let expr, _):
            precollectClosureIds(in: expr, counter: &counter, into: &ids)
        case .returnStatement(let expr, _):
            if let expr = expr { precollectClosureIds(in: expr, counter: &counter, into: &ids) }
        case .ifStatement(let cond, let thenBlock, let elifs, let elseBlock, _, _):
            precollectClosureIds(in: cond, counter: &counter, into: &ids)
            precollectClosureIds(in: thenBlock.statements, counter: &counter, into: &ids)
            for elif in elifs {
                precollectClosureIds(in: elif.condition, counter: &counter, into: &ids)
                precollectClosureIds(in: elif.block.statements, counter: &counter, into: &ids)
            }
            if let elseBlock = elseBlock {
                precollectClosureIds(in: elseBlock.statements, counter: &counter, into: &ids)
            }
        case .whileStatement(let cond, let body, _, _, _):
            precollectClosureIds(in: cond, counter: &counter, into: &ids)
            precollectClosureIds(in: body.statements, counter: &counter, into: &ids)
        case .deferStatement(let inner, _):
            precollectClosureIds(in: inner, counter: &counter, into: &ids)
        case .matchStatement(let scrutinee, let cases, _):
            precollectClosureIds(in: scrutinee, counter: &counter, into: &ids)
            for matchCase in cases {
                precollectClosureIds(in: matchCase.block.statements, counter: &counter, into: &ids)
            }
        default:
            break
        }
    }

    private static func precollectClosureIds(
        in expression: Expression,
        counter: inout Int,
        into ids: inout [String: Int]
    ) {
        if case .funcLiteral(let decl, let location) = expression {
            // 键里带源文件名 —— 合并多文件包时两个文件可能有同一行列上的字面量，
            // 共用一个 id 会把它们的捕获合并掉。
            let key = closureIdKey(location)
            if ids[key] == nil {
                ids[key] = counter
                counter += 1
            }
            // 体内嵌套的字面量也要编号（按源码顺序延后处理）。体是 Block，走它的语句。
            precollectClosureIds(in: decl.body?.statements ?? [], counter: &counter, into: &ids)
            return
        }
        switch expression {
        case .binary(let lhs, _, let rhs, _):
            precollectClosureIds(in: lhs, counter: &counter, into: &ids)
            precollectClosureIds(in: rhs, counter: &counter, into: &ids)
        case .unary(_, let operand, _):
            precollectClosureIds(in: operand, counter: &counter, into: &ids)
        case .call(let callee, let arguments, _):
            precollectClosureIds(in: callee, counter: &counter, into: &ids)
            for argument in arguments {
                precollectClosureIds(in: argument.expression, counter: &counter, into: &ids)
            }
        case .member(let base, _, _):
            precollectClosureIds(in: base, counter: &counter, into: &ids)
        case .tupleIndex(let base, _, _):
            precollectClosureIds(in: base, counter: &counter, into: &ids)
        case .tuple(_, let elements, _):
            for element in elements { precollectClosureIds(in: element, counter: &counter, into: &ids) }
        case .arrayLiteral(let elements, _):
            for element in elements { precollectClosureIds(in: element, counter: &counter, into: &ids) }
        case .tryExpression(let operand, _, let handler, _):
            precollectClosureIds(in: operand, counter: &counter, into: &ids)
            precollectClosureIds(in: handler.statements, counter: &counter, into: &ids)
        case .genericConstruct(_, _, let arguments, _):
            for argument in arguments {
                precollectClosureIds(in: argument.expression, counter: &counter, into: &ids)
            }
        default:
            break
        }
    }

    /// 降载一个 `func` 字面量：在创建点做捕获分析，然后在闭包自己的作用域里降载体
    /// （捕获预先塞进 `variableTypes`，自由引用才解析得出；`capture` 标记在此丢弃）。
    /// 参数类型按检查器的链路取：返回标注、期望类型、再到 I32。
    private static func lowerFuncLiteral(
        decl: FuncDecl,
        expected: IRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        let key = closureIdKey(location)
        guard let closureId = context.closureIds[key] else {
            throw unsupported("anonymous function was not pre-registered", at: location)
        }
        guard decl.body != nil else {
            throw unsupported("anonymous function has no body", at: location)
        }

        // 解析字面量的函数类型：走检查器的双向推断（标注 > 由体反推 > 期望 > 返回标注兜底 > 通配），
        // 再过一遍与声明签名相同的标注转换。
        let inferredAnnotation = context.inferType(of: .funcLiteral(decl: decl, location: location))
        let functionType: IRType
        if let annotation = inferredAnnotation,
            let mapped = resolvedFunctionType(annotation, userTypes: context.userTypes)
        {
            functionType = mapped
        } else if case .function(let expectedParams, let expectedReturn, let expectedUsing) = expected {
            functionType = .function(params: expectedParams, returnType: expectedReturn, usingIndices: expectedUsing)
        } else {
            throw unsupported(
                "anonymous function type could not be resolved (annotate the parameter or the variable)",
                at: location
            )
        }
        guard case .function(let paramTypes, let returnType, _) = functionType else {
            throw unsupported("anonymous function resolved to a non-function type", at: location)
        }
        guard decl.params.count == paramTypes.count else {
            throw unsupported(
                "anonymous function declares \(decl.params.count) parameters but resolves to \(paramTypes.count)",
                at: location
            )
        }

        // 捕获分析在创建点做：体内用到的标识符，去掉字面量自身的参数与本块声明的变量，
        // 再去掉指向顶层具名函数的函数类型引用（那些在使用点变成适配器）。
        // 捕获按引用：env 字段存变量的槽指针。
        let used = collectBodyIdentifiers(in: decl)
        let localBound = Set(decl.params.map { $0.name })
            .union(declaredLocalVars(in: decl.body?.statements ?? []))
        var captures: [IRCapture] = []
        var captureIndex: [String: Int] = [:]
        for name in used.sorted() where !localBound.contains(name) {
            // 顶层具名函数是函数值而非捕获（它们的适配器在使用点发射）。
            if context.moduleSignatures[name] != nil { continue }
            guard let type = context.variableTypes[name] else { continue }
            guard captureIndex[name] == nil else { continue }
            captureIndex[name] = captures.count
            captures.append(IRCapture(name: name, type: type))
        }

        // 在新作用域里降载体：参数与捕获预置好，自由引用才解析得出。
        // 外层函数的 variableTypes 绝不能透进来（同名外层变量会遮蔽参数）。
        var closureContext = FunctionContext(
            functionName: context.functionName,
            returnType: returnType,
            paramTypes: Dictionary(uniqueKeysWithValues: zip(decl.params.map { $0.name }, paramTypes)),
            typeInference: context.typeInference,
            moduleSignatures: context.moduleSignatures,
            nominalTypes: context.nominalTypes,
            userTypes: context.userTypes,
            enums: context.enums,
            genericFuncTemplates: context.genericFuncTemplates,
            closureIds: context.closureIds
        )
        closureContext.isAsync = decl.isAsync
        for capture in captures {
            closureContext.variableTypes[capture.name] = capture.type
        }
        let body = try lowerBlock(decl.body!, into: &closureContext, trailingValue: returnType)
        // 闭包与外层共用一个 functionName，故它体内的调用记到外层头上。物化期是否真调到这个闭包不在此判：
        // 静态检测不判可达性，代价是一条可能跑不出来的警告，收益是别把包在闭包里的环漏掉。
        context.calledFunctionNames.formUnion(closureContext.calledFunctionNames)

        return LoweredExpr(
            node: .closureLiteral(
                id: closureId, paramNames: decl.params.map { $0.name },
                paramTypes: paramTypes, returnType: returnType,
                captures: captures, body: body, type: functionType
            ),
            type: functionType
        )
    }

    /// 闭包体引用到的标识符（含 callee 名）。`funcLiteral` 子表达式**不透明**：
    /// 它们自己的捕获在各自的创建点结算。
    private static func collectBodyIdentifiers(in decl: FuncDecl) -> Set<String> {
        collectBodyIdentifiers(in: decl.body?.statements ?? [])
    }

    private static func collectBodyIdentifiers(in statements: [Statement]) -> Set<String> {
        statements.reduce(into: Set<String>()) { $0.formUnion(collectBodyIdentifiers(in: $1)) }
    }

    private static func collectBodyIdentifiers(in statement: Statement) -> Set<String> {
        switch statement {
        case .varDecl(let name, _, let initializer, _, _):
            var ids = initializer.map { collectBodyIdentifiers(in: $0) } ?? []
            ids.insert(name)
            return ids
        case .varDestructure(let names, _, let initializer, _, _):
            var ids = initializer.map { collectBodyIdentifiers(in: $0) } ?? []
            ids.formUnion(names.filter { $0 != "_" })
            return ids
        case .assign(let target, let value, _):
            var ids = collectBodyIdentifiers(in: value)
            switch target {
            case .identifier(let name): ids.insert(name)
            case .member(let object, _): ids.formUnion(collectBodyIdentifiers(in: object))
            case .subscript(let container, let index):
                ids.formUnion(collectBodyIdentifiers(in: container))
                ids.formUnion(collectBodyIdentifiers(in: index))
            }
            return ids
        case .expressionStmt(let expr, _):
            return collectBodyIdentifiers(in: expr)
        case .returnStatement(let expr, _):
            return expr.map { collectBodyIdentifiers(in: $0) } ?? []
        case .ifStatement(let cond, let thenBlock, let elifs, let elseBlock, _, _):
            var ids = collectBodyIdentifiers(in: cond)
            ids.formUnion(collectBodyIdentifiers(in: thenBlock.statements))
            for elif in elifs {
                ids.formUnion(collectBodyIdentifiers(in: elif.condition))
                ids.formUnion(collectBodyIdentifiers(in: elif.block.statements))
            }
            if let elseBlock = elseBlock {
                ids.formUnion(collectBodyIdentifiers(in: elseBlock.statements))
            }
            return ids
        case .whileStatement(let cond, let body, _, _, _):
            var ids = collectBodyIdentifiers(in: cond)
            ids.formUnion(collectBodyIdentifiers(in: body.statements))
            return ids
        case .matchStatement(let scrutinee, let cases, _):
            var ids = collectBodyIdentifiers(in: scrutinee)
            for matchCase in cases {
                ids.formUnion(collectBodyIdentifiers(in: matchCase.block.statements))
            }
            return ids
        case .deferStatement(let inner, _):
            return collectBodyIdentifiers(in: inner)
        case .captureStatement(let name, _):
            return [name]
        default:
            return []
        }
    }

    private static func collectBodyIdentifiers(in expression: Expression) -> Set<String> {
        switch expression {
        case .identifier(let name, _):
            return [name]
        case .binary(let lhs, _, let rhs, _):
            return collectBodyIdentifiers(in: lhs).union(collectBodyIdentifiers(in: rhs))
        case .unary(_, let operand, _):
            return collectBodyIdentifiers(in: operand)
        case .call(let callee, let arguments, _):
            var ids = collectBodyIdentifiers(in: callee)
            for argument in arguments {
                ids.formUnion(collectBodyIdentifiers(in: argument.expression))
            }
            return ids
        case .member(let base, _, _):
            return collectBodyIdentifiers(in: base)
        case .tupleIndex(let base, _, _):
            return collectBodyIdentifiers(in: base)
        case .tuple(_, let elements, _):
            return elements.reduce(into: Set<String>()) { $0.formUnion(collectBodyIdentifiers(in: $1)) }
        case .arrayLiteral(let elements, _):
            return elements.reduce(into: Set<String>()) { $0.formUnion(collectBodyIdentifiers(in: $1)) }
        case .tryExpression(let operand, _, let handler, _):
            var ids = collectBodyIdentifiers(in: operand)
            ids.formUnion(collectBodyIdentifiers(in: handler.statements))
            return ids
        default:
            return []
        }
    }

    /// 语句列表在块内声明的变量（它们的名字是局部定义，从不构成捕获）。
    private static func declaredLocalVars(in statements: [Statement]) -> Set<String> {
        statements.reduce(into: Set<String>()) {
            if case .varDecl(let name, _, _, _, _) = $1 { $0.insert(name) }
            if case .varDestructure(let names, _, _, _, _) = $1 { $0.formUnion(names.filter { $0 != "_" }) }
        }
    }

    // MARK: - 枚举族

    /// 降载泛型枚举 case 的两种写法。拼写没有指向泛型枚举时返回 `nil`，调用方可以继续往下走。
    /// 一旦指向了，缺特化就是错误：预扫描会登记它能看到的每个使用点，
    /// 走到这里说明使用点与登记对不上。
    private static func lowerGenericEnumCaseConstruct(
        qualifier: String,
        caseName: String,
        typeArgs: [TypeAnnotation],
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr? {
        let template: EnumDecl
        if let found = context.genericEnums.parentTemplate(qualifier: qualifier, caseName: caseName) {
            template = found
        } else if context.genericEnums.isAmbiguousCase(caseName) {
            // 裸写法只凭 case 名找父枚举，两个枚举共用该名时就分不开 —— 限定形式正是为此存在，
            // 报错信息必须点明该写哪种拼写。
            throw unsupported(
                "ambiguous generic enum case '\(caseName)' needs the qualified form "
                    + "(write 枚举名<实参…>.\(caseName)(…))",
                at: location
            )
        } else {
            return nil
        }
        guard template.cases.contains(where: { $0.name == caseName }) else {
            throw unsupported(
                "generic enum '\(template.name)' has no case '\(caseName)'", at: location
            )
        }
        guard typeArgs.count == template.genericParams.count else {
            throw unsupported(
                "generic enum '\(template.name)' expects \(template.genericParams.count) "
                    + "type argument(s), got \(typeArgs.count)",
                at: location
            )
        }
        let specializedName = specializedSourceName(template.name, typeArgs: typeArgs)
        guard let enumDecl = context.enums[specializedName],
            let enumCase = enumDecl.cases.first(where: { $0.name == caseName })
        else {
            throw unsupported(
                "generic enum '\(template.name)' has no registered specialization for this use site",
                at: location
            )
        }
        return try lowerEnumCaseConstructor(
            enumDecl: enumDecl, enumCase: enumCase, arguments: arguments,
            at: location, into: &context
        )
    }

    private static func resolveEnumCase(
        _ caseName: String,
        at location: SourceLocation?,
        in context: FunctionContext
    ) throws -> (IREnumDecl, IREnumCase)? {
        if let dotIndex = caseName.firstIndex(of: ".") {
            let enumName = String(caseName[..<dotIndex])
            let caseLeaf = String(caseName[caseName.index(after: dotIndex)...])
            guard let enumDecl = context.enums[enumName],
                let enumCase = enumDecl.cases.first(where: { $0.name == caseLeaf })
            else {
                return nil
            }
            return (enumDecl, enumCase)
        }
        let matches = context.enums.values.compactMap { enumDecl -> (IREnumDecl, IREnumCase)? in
            guard let enumCase = enumDecl.cases.first(where: { $0.name == caseName }) else {
                return nil
            }
            return (enumDecl, enumCase)
        }
        guard matches.count > 1 else { return matches.first }
        // 跨枚举的同类名 case：借检查器按期望类型登记的表做静态解析。
        if let location = location,
            let parent = BareCaseResolutionRegistry.parent(at: location),
            let hit = matches.first(where: { $0.0.name == parent })
        {
            return hit
        }
        throw unsupported(
            "ambiguous enum case '\(caseName)' needs the qualified form (use \(caseName) under its enum namespace)",
            at: location ?? SourceLocation(line: 0, column: 0, fileName: "")
        )
    }

    /// 无载荷枚举 case 当裸标识符（`plus`）；名字不是唯一的无载荷 case 时返回 nil。
    private static func lowerBareEnumCase(
        _ name: String,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr? {
        guard let (enumDecl, enumCase) = try resolveEnumCase(name, at: location, in: context),
            enumCase.payloadTypes.isEmpty
        else {
            return nil
        }
        return LoweredExpr(
            node: .enumConstruct(
                enumName: enumDecl.name, caseName: enumCase.name, tag: enumCase.tag,
                payloads: [], payloadTypes: [],
                type: .enumeration(name: enumDecl.name)
            ),
            type: .enumeration(name: enumDecl.name)
        )
    }

    /// 带关联值的枚举 case 构造：实参可位置可带标签（`text= "x"`），按 case 的参数名解析。
    /// 缺的实参回落到声明里的默认表达式。
    private static func lowerEnumCaseConstructor(
        enumDecl: IREnumDecl,
        enumCase: IREnumCase,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        guard arguments.count <= enumCase.payloadTypes.count else {
            throw unsupported(
                "case '\(enumCase.name)' expects at most \(enumCase.payloadTypes.count) associated values",
                at: location
            )
        }
        var payloads: [IRExpr?] = Array(repeating: nil, count: enumCase.payloadTypes.count)
        for (index, argument) in arguments.enumerated() {
            var slot = index
            if let label = argument.label {
                guard let namedIndex = enumCase.paramNames.firstIndex(where: { $0 == label }) else {
                    throw unsupported(
                        "case '\(enumCase.name)' has no associated value labeled '\(label)'",
                        at: location
                    )
                }
                slot = namedIndex
            }
            guard payloads[slot] == nil else {
                throw unsupported(
                    "duplicate associated value at position \(slot + 1) of '\(enumCase.name)'",
                    at: location
                )
            }
            let lowered = try lowerExpr(argument.expression, expected: enumCase.payloadTypes[slot], into: &context)
            try requireAssignable(lowered.type, to: enumCase.payloadTypes[slot], at: location)
            payloads[slot] = lowered.node
        }
        var loweredPayloads: [IRExpr] = []
        for (index, slot) in payloads.enumerated() {
            guard let node = slot else {
                throw unsupported(
                    "case '\(enumCase.name)' is missing associated value \(index + 1) (declared defaults are a later grid)",
                    at: location
                )
            }
            loweredPayloads.append(node)
        }
        return LoweredExpr(
            node: .enumConstruct(
                enumName: enumDecl.name, caseName: enumCase.name, tag: enumCase.tag,
                payloads: loweredPayloads, payloadTypes: enumCase.payloadTypes,
                type: .enumeration(name: enumDecl.name)
            ),
            type: .enumeration(name: enumDecl.name)
        )
    }

    // MARK: - 成员 .get 与 match

    /// String 成员方法：语料里的五种表面形式，加上 trim/index 三件套（去掉首尾 ASCII 空格、
    /// 按字形簇下标找首次出现）。`split` 产出真正的 `Array<String>`，与解释器一致；
    /// `slice` / `get` 落到宽容读通道。
    private static func lowerStringMethod(
        receiver: LoweredExpr,
        memberName: String,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        switch memberName {
        case "upper", "lower":
            guard arguments.isEmpty else {
                throw unsupported("\(memberName) expects no arguments", at: location)
            }
            return LoweredExpr(
                node: .stringCase(isUpper: memberName == "upper", receiver: receiver.node),
                type: .string
            )
        case "contains":
            guard arguments.count == 1 else {
                throw unsupported("contains expects exactly one argument", at: location)
            }
            let needle = try lowerExpr(arguments[0].expression, expected: .string, into: &context)
            return LoweredExpr(
                node: .stringContains(receiver: receiver.node, needle: needle.node),
                type: .boolean
            )
        case "substring":
            guard arguments.count == 2 else {
                throw unsupported("substring expects exactly two arguments", at: location)
            }
            let start = try lowerExpr(arguments[0].expression, expected: .i32, into: &context)
            let length = try lowerExpr(arguments[1].expression, expected: .i32, into: &context)
            return LoweredExpr(
                node: .stringSubstring(receiver: receiver.node, start: start.node, length: length.node),
                type: .string
            )
        case "split":
            guard arguments.count == 1 else {
                throw unsupported("split expects exactly one argument", at: location)
            }
            let delim = try lowerExpr(arguments[0].expression, expected: .string, into: &context)
            let arrayType = IRType.array(element: .string)
            return LoweredExpr(
                node: .stringSplit(receiver: receiver.node, delim: delim.node, type: arrayType),
                type: arrayType
            )
        case "trimLeft":
            guard arguments.isEmpty else {
                throw unsupported("trimLeft expects no arguments", at: location)
            }
            return LoweredExpr(
                node: .stringTrimLeft(receiver: receiver.node),
                type: .string
            )
        case "trimRight":
            guard arguments.isEmpty else {
                throw unsupported("trimRight expects no arguments", at: location)
            }
            return LoweredExpr(
                node: .stringTrimRight(receiver: receiver.node),
                type: .string
            )
        case "indexOf":
            guard arguments.count == 1 else {
                throw unsupported("indexOf expects exactly one argument", at: location)
            }
            let needle = try lowerExpr(arguments[0].expression, expected: .string, into: &context)
            return LoweredExpr(
                node: .stringIndexOf(receiver: receiver.node, needle: needle.node),
                type: .i32
            )
        default:
            throw unsupported("string method '\(memberName)' is outside this grid", at: location)
        }
    }

    /// 降低 `别名.符号(…)`：它本就是签名表里的具名函数，故形状与 `lowerCall` 的
    /// 具名分支**逐字同构**（参数按签名逐个给期望类型）。
    private static func lowerModuleQualifiedCall(
        functionName: String,
        signature: IRLowererSignatureInfo,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        /// 与具名分支共用同一份映射与填充助手：两条路径必须同口径，否则同一个函数
        /// 经裸名与经别名调用会得到不同的实参个数。
        let paramIndices = try usingParamMapping(
            callee: functionName, paramCount: signature.paramTypes.count,
            usingParamIndices: signature.usingParamIndices, argumentCount: arguments.count,
            at: location)
        let retypedArgs = try zip(arguments, paramIndices).map { argument, paramIndex in
            try lowerExpr(argument.expression, expected: signature.paramTypes[paramIndex], into: &context)
        }
        for (position, argument) in retypedArgs.enumerated()
        where !signature.untypedParamIndices.contains(paramIndices[position]) {
            try requireAssignable(
                argument.type, to: signature.paramTypes[paramIndices[position]], at: location)
        }
        let argumentNodes = try fillUsingArguments(
            retypedArgs: retypedArgs, paramIndices: paramIndices,
            paramTypes: signature.paramTypes, usingParamIndices: signature.usingParamIndices,
            omittedForm: arguments.count != signature.paramTypes.count,
            callee: functionName, at: location, into: &context)
        context.recordCall(functionName)
        return LoweredExpr(
            node: .call(
                function: functionName,
                arguments: argumentNodes,
                returnType: signature.returnType
            ),
            type: signature.returnType ?? .i32
        )
    }

    /// 内建接收者类型名 → `IRType`。`Array` 在扩展块里不署名元素类型 ⇒ 取 i32 占位；这个值只用于登记扩展
    /// 方法（`lowerMethod` 需要一个 self 类型），调用点的接收者类型由实际值决定，故占位不参与语义。
    private static func builtinReceiverType(named name: String) -> IRType? {
        switch name {
        case "String": return .string
        case "Array": return .array(element: .i32)
        default: return nil
        }
    }

    /// 反向映射：接收者类型 → 内建类型名（查扩展方法表用）。
    private static func builtinReceiverName(of type: IRType) -> String? {
        switch type {
        case .string: return "String"
        case .array: return "Array"
        default: return nil
        }
    }

    /// 无主引用透传：解引用后按元素类型继续；存活检查按规范不在编译通道做。
    private static func unownedUnwrapped(_ base: LoweredExpr) -> LoweredExpr {
        if case .unownedRef(let element) = base.type {
            return LoweredExpr(
                node: .unownedRefValue(handle: base.node, type: element), type: element)
        }
        return base
    }

    private static func lowerMemberCall(
        object: Expression,
        memberName: String,
        arguments: [CallArgument],
        expected: IRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        // 跨模块限定调用 `别名.符号(…)`：receiver 是 import 别名、**不是变量**，
        // 故必须在 lower receiver 之前拦截（否则会按变量解析并报「未声明变量」）。
        if case .identifier(let aliasName, _) = object,
            let signature = context.moduleSignatures["\(aliasName).\(memberName)"]
        {
            return try lowerModuleQualifiedCall(
                functionName: memberName, signature: signature,
                arguments: arguments, at: location, into: &context
            )
        }

        // 本型方法以类型名为接收者：先于枚举用例构造决议，receiver 不是值故不降载。
        if case .identifier(let typeName, _) = object,
            let sig = context.typeInference?.environment?.lookupOwnMethod(
                typeName: typeName, methodName: memberName)
        {
            guard sig.returns.count <= 1 else {
                throw unsupported(
                    "own method '\(memberName)' with multiple return slots is not supported",
                    at: location)
            }
            let returnType = sig.returns.first.flatMap {
                resolveAnnotationType($0, userTypes: context.userTypes)
            }
            let loweredArgs = try arguments.map {
                try lowerExpr($0.expression, expected: nil, into: &context)
            }
            let irName = IRName.ownMethod(memberName, on: typeName)
            context.recordCall(irName)
            return LoweredExpr(
                node: .call(function: irName, arguments: loweredArgs.map(\.node), returnType: returnType),
                type: returnType ?? .i32
            )
        }

        // 限定 case 构造 `Enum.Case(args)`：接收者是用户**类型名**，不是变量。
        if case .identifier(let typeName, _) = object, let enumDecl = context.enums[typeName],
            let enumCase = enumDecl.cases.first(where: { $0.name == memberName })
        {
            return try lowerEnumCaseConstructor(
                enumDecl: enumDecl, enumCase: enumCase, arguments: arguments,
                at: location, into: &context
            )
        }

        // Optional 类型名上的成员调用：`Optional.some(v)` 直接构造 some；
        // `Optional.none`（不带调用）在上面 `.member` 分支里处理。
        if case .identifier("Optional", _) = object, memberName == "some" {
            guard arguments.count == 1 else {
                throw unsupported("Optional.some expects exactly one argument", at: location)
            }
            let payloadExpected = expected?.optionalWrapped
            let loweredPayload = try lowerExpr(arguments[0].expression, expected: payloadExpected, into: &context)
            let type = IRType.optional(wrapped: loweredPayload.type)
            if let payloadExpected = payloadExpected {
                try requireAssignable(loweredPayload.type, to: payloadExpected, at: location)
            }
            return LoweredExpr(
                node: .optionalConstruct(isSome: true, payload: loweredPayload.node, type: type),
                type: type
            )
        }

        var loweredObject = try lowerExpr(object, expected: nil, into: &context)
        // 无主引用透传：接收者先解引用，方法在元素类型上派发；unsafe 门禁由检查面把关。
        if case .unownedRef(let element) = loweredObject.type {
            loweredObject = LoweredExpr(
                node: .unownedRefValue(handle: loweredObject.node, type: element), type: element)
        }
        let objectType = loweredObject.type

        // 三级派发的第一级：内建类型（`String` / `Array`）的用户扩展方法排在语言内标准库（下面按名硬编码的
        // 分支）与宿主原生之前。缺这一支时，新增方法会落到尾部兜底报「未支持」，覆盖同名成员则直接读到
        // 内建结果 —— 用户实现被静默压过。
        if let receiverName = builtinReceiverName(of: objectType),
            let ext = context.builtinExtensionMethods[receiverName]?[memberName]
        {
            let loweredArgs = try arguments.map {
                try lowerExpr($0.expression, expected: nil, into: &context)
            }
            context.recordCall(ext.irName)
            return LoweredExpr(
                node: .call(
                    function: ext.irName,
                    arguments: [loweredObject.node] + loweredArgs.map(\.node),
                    returnType: ext.returnType
                ),
                type: ext.returnType
            )
        }

        // String 成员方法：upper/lower/contains/substring/split，加上 trim/index 三件套
        // （去掉首尾 ASCII 空格、按字形簇下标找首次出现）。`slice` / `get` 落到宽容读通道。
        if case .string = objectType,
            ["upper", "lower", "contains", "substring", "split",
             "trimLeft", "trimRight", "indexOf"].contains(memberName)
        {
            return try lowerStringMethod(
                receiver: loweredObject, memberName: memberName, arguments: arguments,
                at: location, into: &context
            )
        }
        // 数组成员方法 `join`：节点把每个元素字符串化并插入分隔符，
        // 解释器的 `join` 分支对数组里装什么都这么干 —— 故元素类型不必是字符串。
        if case .array = objectType, memberName == "join" {
            guard arguments.count == 1 else {
                throw unsupported("join expects exactly one argument", at: location)
            }
            let loweredSep = try lowerExpr(arguments[0].expression, expected: .string, into: &context)
            return LoweredExpr(
                node: .arrayJoin(receiver: loweredObject.node, separator: loweredSep.node),
                type: .string
            )
        }

        // LazyRef `.value` 的调用形式 `r.value()` —— 与字段形式同一个节点；
        // 只接受零实参（与解释器的属性式读法一致）。
        if case .lazyRef(let element) = objectType, memberName == "value" {
            guard arguments.isEmpty else {
                throw unsupported("LazyRef .value takes no arguments", at: location)
            }
            return LoweredExpr(
                node: .lazyRefValue(handle: loweredObject.node, type: element),
                type: element
            )
        }

        // 名义方法派发：接收者是隐式第一个实参，被调方是 mangled 的 IR 名 `方法__类型`。
        // 该名义类型没有同名自有或扩展方法时，回退到已实现 trait 的默认体，
        // 并按接收者类型特化。
        if case .nominal(let typeName, _) = objectType {
            let dispatchInfo = context.nominalTypes[typeName]
            if let method = dispatchInfo?.methods.first(where: { $0.name == memberName }) {
                /// 方法位与自由函数位同规 —— `using` 形参可省略，
                /// 实参由编译器在该位插入默认实例取用。
                let methodParamTypes: [IRType] = try method.params.map { parameter -> IRType in
                    guard let annotation = parameter.typeAnnotation,
                        let paramType = resolveUsingParamType(annotation, userTypes: context.userTypes)
                    else {
                        throw unsupported(
                            "parameter '\(parameter.name)' of '\(memberName)' lacks a resolvable type",
                            at: location
                        )
                    }
                    return paramType
                }
                let methodUsingIndices = usingParamIndices(method)
                let methodParamIndices = try usingParamMapping(
                    callee: memberName, paramCount: methodParamTypes.count,
                    usingParamIndices: methodUsingIndices, argumentCount: arguments.count,
                    at: location)
                // 调用点用方法的有效返回类型：声明为 void 而体返回值的，升级到那个类型，与定义侧一致。
                // 回退走宽的 `resolveReturnType` —— 窄的 `IRType(from:)` 拒用户声明类型 ——
                // 于是多返回槽折叠成元组。
                let returnType =
                    try effectiveReturnType(
                        decl: method, userTypes: context.userTypes,
                        nominals: context.nominalTypesMap, selfTypeName: typeName
                    )
                    ?? resolveReturnType(
                        method, userTypes: context.userTypes,
                        subject: "method '\(memberName)'"
                    )
                var retypedArgs: [LoweredExpr] = []
                for (position, argument) in arguments.enumerated() {
                    let paramType = methodParamTypes[methodParamIndices[position]]
                    let loweredArg = try lowerExpr(argument.expression, expected: paramType, into: &context)
                    try requireAssignable(loweredArg.type, to: paramType, at: location)
                    retypedArgs.append(loweredArg)
                }
                var arguments_ir = [loweredObject.node]
                arguments_ir.append(
                    contentsOf: try fillUsingArguments(
                        retypedArgs: retypedArgs, paramIndices: methodParamIndices,
                        paramTypes: methodParamTypes, usingParamIndices: methodUsingIndices,
                        omittedForm: arguments.count != methodParamTypes.count,
                        callee: memberName, at: location, into: &context))
                let irName = "\(IRName.mangle(memberName))__\(IRName.mangle(typeName))"
                context.recordCall(irName)
                return LoweredExpr(
                    node: .call(function: irName, arguments: arguments_ir, returnType: returnType),
                    type: returnType ?? .i32
                )
            }
            // trait 默认回退：自身与扩展方法都没命中后，沿接收者类型的 trait 列表找同名默认体。
            // 体以接收者的名义类型为 self 重新降载，于是看得到接收者的字段 ——
            // 自身方法优先，其次 trait 默认，与解释器一致。
            if let traitNames = context.traitRegistry.typeTraits[typeName] {
                for traitName in traitNames {
                    guard let trait = context.traitRegistry.traits[traitName],
                        let defaultMethod = trait.signatures.first(where: {
                            $0.name == memberName && $0.body != nil
                        })
                    else { continue }
                    let loweredCall = try lowerTraitDefaultCall(
                        defaultMethod, receiver: loweredObject.node, receiverType: objectType,
                        arguments: arguments, at: location, into: &context
                    )
                    return loweredCall
                }
            }
            throw unsupported(
                "undefined method '\(memberName)' on '\(objectType)'",
                at: location
            )
        }

        if memberName == "get" {
            guard arguments.count == 1 else {
                throw unsupported("get expects exactly one argument", at: location)
            }
            // 字典的 `.get` 按字典接受的任意键取值，故下标期望跟随键类型；
            // I32 的要求只属于 Array/String 那条分支。
            let wrapped: IRType
            let indexExpectation: IRType?
            var requireI32Index = false
            switch objectType {
            case .array(let element): wrapped = element; indexExpectation = .i32; requireI32Index = true
            // `String` 的 `.get(i)` 取的是**元素**，与 `s[i]` 同物 ⇒ 元素类型同为 `Char`。
            // 留成 `.string` 会让这个通道的**声明类型**与它实际取到的**值**不符（读策略返回 `.char`）。
            case .string: wrapped = .char; indexExpectation = .i32; requireI32Index = true
            case .dict(let key, let value): wrapped = value; indexExpectation = key
            default:
                throw unsupported(
                    ".get on type '\(objectType)' outside this grid (Array/String/Dict)",
                    at: location
                )
            }
            let loweredIndex = try lowerExpr(arguments[0].expression, expected: indexExpectation, into: &context)
            if requireI32Index, loweredIndex.type != .i32 {
                throw unsupported("get index must be I32", at: location)
            }
            return LoweredExpr(
                node: .optionalGet(
                    container: loweredObject.node, index: loweredIndex.node,
                    type: .optional(wrapped: wrapped)
                ),
                type: .optional(wrapped: wrapped)
            )
        }

        // `.getUnchecked(i)` 与下标读同物：安全断言通道，越界与缺失键都在运行时段终止。
        // 元素类型推导也共用一套 —— 分开写会让三条容器路径各自漂。
        if memberName == "getUnchecked" {
            guard arguments.count == 1 else {
                throw unsupported("getUnchecked expects exactly one argument", at: location)
            }
            let elementType: IRType
            let indexExpectation: IRType?
            var requireI32Index = false
            switch objectType {
            case .array(let element): elementType = element; indexExpectation = .i32; requireI32Index = true
            case .dict(let key, let value): elementType = value; indexExpectation = key
            case .string: elementType = .char; indexExpectation = .i32; requireI32Index = true
            default:
                throw unsupported(
                    ".getUnchecked on type '\(objectType)' outside this grid (Array/String/Dict)",
                    at: location
                )
            }
            let loweredIndex = try lowerExpr(
                arguments[0].expression, expected: indexExpectation, into: &context)
            if requireI32Index, loweredIndex.type != .i32 {
                throw unsupported("getUnchecked index must be I32", at: location)
            }
            return LoweredExpr(
                node: .subscriptGet(
                    container: loweredObject.node, index: loweredIndex.node, type: elementType),
                type: elementType
            )
        }

        if memberName == "slice" {
            guard arguments.count == 2 else {
                throw unsupported("slice expects exactly two arguments", at: location)
            }
            guard objectType.isArray || objectType == .string else {
                throw unsupported(".slice on type '\(objectType)' outside this grid (Array/String)", at: location)
            }
            var loweredBounds: [IRExpr] = []
            for argument in arguments {
                let lowered = try lowerExpr(argument.expression, expected: nil, into: &context)
                let boundIsValid: Bool
                if case .optionalConstruct(let isSome, _, _) = lowered.node {
                    boundIsValid = !isSome
                } else {
                    boundIsValid = lowered.type == .i32
                }
                guard boundIsValid else {
                    throw unsupported(
                        "slice bounds must be integers or the open-bound none literal",
                        at: location
                    )
                }
                loweredBounds.append(lowered.node)
            }
            return LoweredExpr(
                node: .sliceCall(
                    container: loweredObject.node, start: loweredBounds[0], end: loweredBounds[1],
                    type: objectType
                ),
                type: objectType
            )
        }

        // Array 成员面的其余部分：append / pop / last，降载成执行器按名应答的 `call`，不新造节点。
        // 静态类型跟着元素走：last 产出元素，pop 产出 (arrayWithoutLast, last) 对。
        // 空接收者在运行期得到 null —— 没有类型名能描述它。
        if case .array(let element) = objectType,
            memberName == "append" || memberName == "last" || memberName == "pop"
        {
            let callName = "Array.\(memberName)"
            switch memberName {
            case "append":
                guard arguments.count == 1 else {
                    throw unsupported("append expects exactly one argument", at: location)
                }
                let loweredValue = try lowerExpr(
                    arguments[0].expression, expected: element, into: &context
                )
                try requireAssignable(loweredValue.type, to: element, at: location)
                let appended = IRType.array(element: element)
                return LoweredExpr(
                    node: .call(
                        function: callName,
                        arguments: [loweredObject.node, loweredValue.node],
                        returnType: appended),
                    type: appended
                )
            case "last":
                guard arguments.isEmpty else {
                    throw unsupported("last takes no arguments", at: location)
                }
                return LoweredExpr(
                    node: .call(
                        function: callName, arguments: [loweredObject.node],
                        returnType: element),
                    type: element
                )
            default:
                guard arguments.isEmpty else {
                    throw unsupported("pop takes no arguments", at: location)
                }
                let pair = IRType.tuple(
                    labels: [nil, nil],
                    fieldTypes: [
                        .array(element: element),
                        element,
                    ])
                return LoweredExpr(
                    node: .call(
                        function: callName, arguments: [loweredObject.node],
                        returnType: pair),
                    type: pair
                )
            }
        }

        // `t.cancel()`：语料里唯一用到的 Future 成员。接收者作为第一个实参传入，与数组成员面一致；
        // 结果丢弃（解释器的 cancel 返回 null）。
        if memberName == "cancel" {
            guard arguments.isEmpty else {
                throw unsupported("cancel takes no arguments", at: location)
            }
            return LoweredExpr(
                node: .call(function: "cancel", arguments: [loweredObject.node], returnType: nil),
                type: .i32
            )
        }

        throw unsupported("method '\(memberName)' calls are later grids", at: location)
    }

    /// `match scrutinee: case name(binding): body ...` —— 通用的 case 骨架。scrutinee 的类型决定分支族：
    /// Optional（some/none，`none` 即语言层的 nil）、枚举、Result，或裸值路径。
    /// 各族都发同一个 `matchStmt` 节点，差别只在 scrutinee 与 case 的类型。
    private static func lowerMatch(
        value: Expression,
        cases: [MatchCase],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        let loweredValue = try lowerExpr(value, expected: nil, into: &context)
        switch loweredValue.type {
        case .optional(let wrapped):
            let irCases = try lowerOptionalCases(cases, wrapped: wrapped, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: irCases, scrutineeType: loweredValue.type)
        case .enumeration(let enumName):
            guard let enumDecl = context.enums[enumName] else {
                throw unsupported("match scrutinee enum '\(enumName)' not registered", at: location)
            }
            let irCases = try lowerEnumCases(cases, enumDecl: enumDecl, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: irCases, scrutineeType: loweredValue.type)
        case .result(let okType):
            // Result scrutinee：少了这条分支就落到下面的 `default`，那里的绑定采纳 scrutinee 类型 ——
            // `case ok(v)` 会把 `v` 绑成 Result，之后每次使用（print、算术、有类型拷贝）
            // 都会被一个源码里从未出现的类型挡住。
            let irCases = try lowerResultCases(cases, okType: okType, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: irCases, scrutineeType: loweredValue.type)
        default:
            // 裸 scrutinee —— 既非 Optional 也非枚举（直接下标读得到的就是普通值）。字面量分支
            // （`case 1:`）按值比较分派；枚举 case 分支不行：那个名字不属于 scrutinee 的任何枚举，
            // 故在此就拒，不让它变成永不会执行的分支。
            for matchCase in cases {
                if case .enumCase(let name) = matchCase.pattern {
                    throw SemanticError.unknownMatchCase(caseName: name, location: matchCase.location)
                }
            }
            var irCases: [IRMatchCase] = []
            for matchCase in cases {
                let body = try lowerBareScrutineeArmBody(matchCase, bindingType: loweredValue.type, into: &context)
                irCases.append(
                    IRMatchCase(
                        caseName: matchCase.pattern.description,
                        literal: literalOperand(of: matchCase.pattern),
                        bindings: matchCase.bindings.map { $0.varName },
                        body: body
                    ))
            }
            return .matchStmt(scrutinee: loweredValue.node, cases: irCases, scrutineeType: loweredValue.type)
        }
    }

    /// 交给发射器的字面量模式操作数；枚举 case 与通配模式返回 nil，它们的分派不按值。
    private static func literalOperand(of pattern: MatchPattern) -> IRMatchLiteral? {
        switch pattern {
        case .intLiteral(let n, _): return .int(n)
        case .floatLiteral(let f, _): return .float(f)
        case .stringLiteral(let s): return .string(s)
        case .boolLiteral(let b): return .boolean(b)
        case .enumCase, .wildcard: return nil
        }
    }

    /// scrutinee 既非 Optional 也非枚举时的一条 match 分支体（见 `lowerMatch`）。体照常降载，
    /// 其绑定才作用域可解析；分支在发射时分不分派取决于模式 —— 字面量分支分派，枚举 case 分支不能。
    /// 每个绑定采纳 scrutinee 类型，通配/none 分支不绑定任何名字。
    private static func lowerBareScrutineeArmBody(
        _ matchCase: MatchCase,
        bindingType: IRType,
        into context: inout FunctionContext
    ) throws -> IRBlock {
        let bindingNames = matchCase.bindings.map { $0.varName }
        let previousTypes = bindingNames.map { context.variableTypes[$0] }
        for (index, name) in bindingNames.enumerated() where name != "_" {
            context.variableTypes[name] = bindingType
        }
        defer {
            for (index, name) in bindingNames.enumerated() where name != "_" {
                context.variableTypes[name] = previousTypes[index]
            }
        }
        return try lowerBlock(matchCase.block, into: &context)
    }

    /// Optional scrutinee 的分支：some/none（none 是 nil 的别名），单个位置绑定，类型由包裹的载荷定。
    private static func lowerOptionalCases(
        _ cases: [MatchCase],
        wrapped: IRType,
        into context: inout FunctionContext
    ) throws -> [IRMatchCase] {
        var irCases: [IRMatchCase] = []
        for matchCase in cases {
            switch matchCase.pattern {
            case .enumCase(let rawCaseName):
                let caseName = rawCaseName == "nil" ? "none" : rawCaseName
                guard caseName == "some" || caseName == "none" else {
                    throw unsupported(
                        "match case '\(caseName)' outside this grid (Optional scrutinee: some/none)",
                        at: matchCase.location
                    )
                }
                var bindingName: String? = nil
                if !matchCase.bindings.isEmpty {
                    guard caseName == "some", matchCase.bindings.count == 1,
                        matchCase.bindings[0].paramName == nil,
                        matchCase.bindings[0].varName != "_"
                    else {
                        throw unsupported(
                            "match case bindings outside this grid (single positional binding on some)",
                            at: matchCase.location
                        )
                    }
                    bindingName = matchCase.bindings[0].varName
                }
                let previousType = bindingName.flatMap { context.variableTypes[$0] }
                if let bindingName = bindingName {
                    context.variableTypes[bindingName] = wrapped
                }
                let body = try lowerBlock(matchCase.block, into: &context)
                if let bindingName = bindingName {
                    context.variableTypes[bindingName] = previousType
                }
                irCases.append(IRMatchCase(caseName: caseName, bindings: bindingName.map { [$0] } ?? [], body: body))
            default:
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
        }
        return irCases
    }

    /// Result scrutinee 的分支：ok/err，单个位置绑定。不对称正是重点：ok 绑定取载荷类型
    /// （这层窄化让 print、算术操作数、有类型拷贝合法），err 绑定则是 try-else 已在用的
    /// 类型擦除机器字，只能经 `pini.err.message` 读取。
    private static func lowerResultCases(
        _ cases: [MatchCase],
        okType: IRType,
        into context: inout FunctionContext
    ) throws -> [IRMatchCase] {
        var irCases: [IRMatchCase] = []
        for matchCase in cases {
            switch matchCase.pattern {
            case .enumCase(let rawCaseName):
                // 限定写法（`Result.ok`）指向同一个叶子。
                let caseName =
                    rawCaseName.contains(".")
                    ? String(rawCaseName.split(separator: ".").last!)
                    : rawCaseName
                guard caseName == "ok" || caseName == "err" else {
                    throw unsupported(
                        "match case '\(caseName)' outside this grid (Result scrutinee: ok/err)",
                        at: matchCase.location
                    )
                }
                var bindingName: String? = nil
                if !matchCase.bindings.isEmpty {
                    guard matchCase.bindings.count == 1,
                        matchCase.bindings[0].paramName == nil,
                        matchCase.bindings[0].varName != "_"
                    else {
                        throw unsupported(
                            "match case bindings outside this grid (single positional binding on ok/err)",
                            at: matchCase.location
                        )
                    }
                    bindingName = matchCase.bindings[0].varName
                }
                let isOk = caseName == "ok"
                let previousType = bindingName.flatMap { context.variableTypes[$0] }
                let wasErrorBinding =
                    bindingName.map { context.errorBindings.contains($0) } ?? false
                if let bindingName = bindingName {
                    context.variableTypes[bindingName] = isOk ? okType : .i64
                    if !isOk { context.errorBindings.insert(bindingName) }
                }
                let body = try lowerBlock(matchCase.block, into: &context)
                if let bindingName = bindingName {
                    context.variableTypes[bindingName] = previousType
                    // 只撤销自己插入的那条 —— 同名的外层错误绑定必须活过这条分支。
                    if !isOk && !wasErrorBinding { context.errorBindings.remove(bindingName) }
                }
                irCases.append(IRMatchCase(caseName: caseName, bindings: bindingName.map { [$0] } ?? [], body: body))
            default:
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
        }
        return irCases
    }

    /// 枚举 scrutinee 的分支：经通用骨架按 tag 分派；绑定按 case 的载荷表按位置取，
    /// `_` 占位符跳过，带名标签（`text: s`）按声明的名字解析。
    private static func lowerEnumCases(
        _ cases: [MatchCase],
        enumDecl: IREnumDecl,
        into context: inout FunctionContext
    ) throws -> [IRMatchCase] {
        var irCases: [IRMatchCase] = []
        for (caseOrder, matchCase) in cases.enumerated() {
            // 通配 `case _:` 匹配一切 —— 只能作最后一条分支。
            if case .wildcard = matchCase.pattern {
                guard caseOrder == cases.count - 1 else {
                    throw unsupported(
                        "wildcard case must be the last case this grid",
                        at: matchCase.location
                    )
                }
                irCases.append(IRMatchCase(caseName: "_", bindings: [], body: try lowerBlock(matchCase.block, into: &context)))
                continue
            }
            guard case .enumCase(let rawCaseName) = matchCase.pattern else {
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
            let leafName =
                rawCaseName.contains(".")
                ? String(rawCaseName.split(separator: ".").last!)
                : rawCaseName
            guard let enumCase = enumDecl.cases.first(where: { $0.name == leafName }) else {
                throw unsupported(
                    "match case '\(rawCaseName)' is not a case of '\(enumDecl.name)'",
                    at: matchCase.location
                )
            }
            guard matchCase.bindings.count == enumCase.payloadTypes.count else {
                throw unsupported(
                    "case '\(enumCase.name)' expects \(enumCase.payloadTypes.count) bindings, got \(matchCase.bindings.count)",
                    at: matchCase.location
                )
            }
            var bindingNames: [String?] = []
            var scoped: [(String, IRType, IRType?)] = []
            for (index, binding) in matchCase.bindings.enumerated() {
                if binding.varName == "_" {
                    bindingNames.append(nil)
                    continue
                }
                if let paramName = binding.paramName {
                    guard let declaredIndex = enumCase.paramNames.firstIndex(where: { $0 == paramName }) else {
                        throw unsupported(
                            "case '\(enumCase.name)' has no associated value labeled '\(paramName)'",
                            at: matchCase.location
                        )
                    }
                    guard declaredIndex == index else {
                        throw unsupported(
                            "labeled binding '\(paramName)' out of order in '\(enumCase.name)'",
                            at: matchCase.location
                        )
                    }
                }
                bindingNames.append(binding.varName)
                scoped.append((binding.varName, enumCase.payloadTypes[index], context.variableTypes[binding.varName]))
            }
            for (bindingName, bindingType, _) in scoped {
                context.variableTypes[bindingName] = bindingType
            }
            let body = try lowerBlock(matchCase.block, into: &context)
            for (bindingName, _, previousType) in scoped {
                context.variableTypes[bindingName] = previousType
            }
            irCases.append(IRMatchCase(caseName: enumCase.name, bindings: bindingNames, body: body))
        }
        return irCases
    }

    // MARK: - 前缀自增 / 自减

    /// 把前缀 `++`/`--` 降载成读-改-写：读、加一或减一、写回、产出写入的值 —— 只支持 I32，
    /// 目标可以是变量、字段与下标，与 `evaluateIncDec` 的定义一致。语句位置与 `var m = ++n`
    /// 共用这一个助手，返回值就是写入所存的那个节点。
    private static func lowerIncDec(
        op: UnaryOperator,
        target: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> (statement: IRStmt, value: IRExpr, type: IRType) {
        // 方向在运算符里，不在常量里：`--` 是减一，不是加负一。
        let baseOp: IRBinaryOp = op == .increment ? .add : .subtract
        let one = IRExpr.intConst(value: 1, type: .i32)
        switch target {
        case .identifier(let name, _):
            guard let varType = context.variableTypes[name] else {
                throw unsupported("prefix '\(op)' on undeclared variable '\(name)'", at: location)
            }
            guard varType == .i32 else {
                throw unsupported(
                    "prefix '\(op)' target must be I32, got '\(varType)'", at: location
                )
            }
            let value = IRExpr.binary(
                op: baseOp, lhs: .load(name: name, type: varType),
                rhs: one, type: varType
            )
            // 读回的就是写入刚留下的值。解释器返回它算出的值；这里接受的 I32 目标上两者相等，
            // 而读回让 `var m = ++n` 不必把算术跑两遍。
            let readBack = IRExpr.load(name: name, type: varType)
            return (
                .storeVar(
                    name: name, type: varType, value: value,
                    adopt: varType.adoption(of: value), releaseOld: context.isHeld(name)
                ),
                readBack, varType
            )

        case .member(let base, let fieldName, _):
            let loweredBase = unownedUnwrapped(try lowerExpr(base, expected: nil, into: &context))
            guard case .nominal = loweredBase.type,
                let fieldType = nominalFieldType(
                    of: loweredBase.type, field: fieldName, in: context
                )
            else {
                throw unsupported(
                    "prefix '\(op)' target must be a field of a known nominal type",
                    at: location
                )
            }
            guard fieldType == .i32 else {
                throw unsupported(
                    "prefix '\(op)' target must be I32, got '\(fieldType)'", at: location
                )
            }
            guard let fieldSlot = nominalFieldSlot(of: loweredBase.type, field: fieldName, in: context) else {
                throw unsupported("prefix '\(op)' target has no field slot", at: location)
            }
            let value = IRExpr.binary(
                op: baseOp,
                lhs: .fieldGet(base: loweredBase.node, slot: fieldSlot, type: fieldType),
                rhs: one, type: fieldType
            )
            return (
                .fieldStore(
                    base: loweredBase.node, slot: fieldSlot,
                    value: value, fieldType: fieldType,
                    adopt: fieldType.adoption(of: value), releaseOld: fieldType.holdsAShare
                ),
                .fieldGet(base: loweredBase.node, slot: fieldSlot, type: fieldType),
                fieldType
            )

        case .subscript:
            let read = try lowerExpr(target, expected: nil, into: &context)
            guard read.type == .i32, case .subscriptGet(let container, let index, _) = read.node else {
                throw unsupported(
                    "prefix '\(op)' subscript target must be an I32 array element",
                    at: location
                )
            }
            let value = IRExpr.binary(
                op: baseOp, lhs: read.node, rhs: one, type: .i32
            )
            return (
                .subscriptStore(
                    container: container, index: index, value: value, elementType: .i32,
                    adopt: IRType.i32.adoption(of: value)
                ),
                .subscriptGet(container: container, index: index, type: .i32),
                .i32
            )

        default:
            throw unsupported(
                "prefix '\(op)' target must be a variable, a field or a subscript",
                at: location
            )
        }
    }

    // MARK: - 数组写入与复合赋值

    /// 为数组容器降载 `container[index] = value`。读路径门禁容器类型；值采纳元素类型。
    private static func lowerSubscriptStore(
        container: Expression,
        index: Expression,
        value: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        let loweredContainer = try lowerExpr(container, expected: nil, into: &context)
        let elementType: IRType
        switch loweredContainer.type {
        case .array(let element): elementType = element
        case .dict(_, let value): elementType = value
        default:
            throw unsupported(
                "subscript store on non-container type '\(loweredContainer.type)'",
                at: location
            )
        }
        let indexExpectation: IRType?
        var requireI32Index = false
        switch loweredContainer.type {
        case .dict(let keyType, _): indexExpectation = keyType
        case .array: indexExpectation = .i32; requireI32Index = true
        default: indexExpectation = .i32; requireI32Index = true
        }
        let loweredIndex = try lowerExpr(index, expected: indexExpectation, into: &context)
        if requireI32Index {
            guard loweredIndex.type == .i32 else {
                throw unsupported("subscript needs an I32 index", at: location)
            }
        }
        let loweredValue = try lowerExpr(value, expected: elementType, into: &context)
        try requireAssignable(loweredValue.type, to: elementType, at: location)
        return .subscriptStore(
            container: loweredContainer.node, index: loweredIndex.node,
            value: loweredValue.node, elementType: elementType,
            adopt: elementType.adoption(of: loweredValue.node, sharingStructs: true)
        )
    }

    /// 语句位置降载 `target op= value`：读-改-写。下标目标复用读路径的容器与下标节点，
    /// 故容器会发两次（读 + 写）。
    private static func lowerCompoundAssign(
        left: Expression,
        baseOp: IRBinaryOp,
        right: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        if case .identifier(let name, _) = left {
            guard let varType = context.variableTypes[name] else {
                throw unsupported("assignment to undeclared variable '\(name)'", at: location)
            }
            guard varType.isNumeric else {
                throw unsupported("compound assignment on non-numeric variable '\(name)'", at: location)
            }
            let rhs = try lowerExpr(right, expected: varType, into: &context)
            let combined = IRExpr.binary(
                op: baseOp, lhs: .load(name: name, type: varType), rhs: rhs.node, type: varType
            )
            return .storeVar(
                name: name, type: varType, value: combined,
                adopt: varType.adoption(of: combined), releaseOld: context.isHeld(name)
            )
        }
        if case .subscript = left {
            let read = try lowerExpr(left, expected: nil, into: &context)
            guard read.type.isNumeric else {
                throw unsupported(
                    "compound assignment on non-numeric element type '\(read.type)'",
                    at: location
                )
            }
            let rhs = try lowerExpr(right, expected: read.type, into: &context)
            let combined = IRExpr.binary(op: baseOp, lhs: read.node, rhs: rhs.node, type: read.type)
            guard case .subscriptGet(let containerNode, let indexNode, _) = read.node else {
                throw unsupported("subscript read did not produce a subscript node", at: location)
            }
            return .subscriptStore(
                container: containerNode, index: indexNode,
                value: combined, elementType: read.type,
                adopt: read.type.adoption(of: combined)
            )
        }
        throw unsupported(
            "compound assignment target outside this grid (identifier or array subscript)",
            at: location
        )
    }

    // MARK: - 数组字面量

    /// 降载数组字面量。检查器在静态侧推断 `Array<T>`；这里元素类型取自降载后的元素，
    /// 因为 IR 存的就是它们，且各元素必须一致。期望的 `.array(element:)` 上下文驱动
    /// 空字面量与整数字面量的采纳。
    private static func lowerArrayLiteral(
        _ elements: [Expression],
        expected: IRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        let elementExpected = expected?.arrayElementType
        // 空字面量且没有期望元素类型时采纳 I32。运行期构造与元素类型无关 ——
        // `[]` 降载成空句柄 —— 所以这个选择只定住之后读写时的静态元素类型；
        // I32 是语言的默认数值类型。
        if elements.isEmpty {
            let element = elementExpected ?? .i32
            return LoweredExpr(
                node: .arrayLiteral(elements: [], type: .array(element: element)),
                type: .array(element: element)
            )
        }
        var loweredElements: [IRExpr] = []
        var elementType: IRType? = elementExpected
        for element in elements {
            let lowered = try lowerExpr(element, expected: elementType, into: &context)
            if let known = elementType {
                guard lowered.type == known else {
                    throw unsupported(
                        "heterogeneous array literal (\(lowered.type) vs \(known))",
                        at: location
                    )
                }
            } else {
                elementType = lowered.type
            }
            loweredElements.append(lowered.node)
        }
        guard let resolvedElement = elementType else {
            throw unsupported("array literal has no resolvable element type", at: location)
        }
        return LoweredExpr(
            node: .arrayLiteral(elements: loweredElements, type: .array(element: resolvedElement)),
            type: .array(element: resolvedElement)
        )
    }

    // MARK: - trait 默认分派

    /// 经已实现的 trait 默认体降载成员调用：体按接收者类型特化成名为 `方法__类型` 的方法
    /// （self = 接收者），排进 `pendingTraitDefaults` 待模块发射，
    /// 调用点以接收者作隐式第一个实参调用它。
    private static func lowerTraitDefaultCall(
        _ defaultMethod: FuncDecl,
        receiver: IRExpr,
        receiverType: IRType,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        guard case .nominal(let typeName, _) = receiverType else {
            throw unsupported(
                "trait default dispatch requires a nominal receiver, got '\(receiverType)'",
                at: location
            )
        }
        let bodyParams =
            defaultMethod.params.first?.name == "self"
            ? Array(defaultMethod.params.dropFirst()) : defaultMethod.params
        guard arguments.count == bodyParams.count else {
            throw unsupported(
                "trait default '\(defaultMethod.name)' expects \(bodyParams.count) arguments, got \(arguments.count)",
                at: location
            )
        }
        let returnType = try defaultMethod.returnTypes.first.map { annotation -> IRType in
            guard let type = resolveAnnotationType(annotation, userTypes: context.userTypes) else {
                throw unsupported(
                    "return type of trait default '\(defaultMethod.name)' is not resolvable",
                    at: location
                )
            }
            return type
        }
        var loweredArgs: [LoweredExpr] = []
        for (index, argument) in arguments.enumerated() {
            guard let annotation = bodyParams[index].typeAnnotation,
                let paramType = resolveAnnotationType(annotation, userTypes: context.userTypes)
            else {
                throw unsupported(
                    "parameter '\(bodyParams[index].name)' of trait default '\(defaultMethod.name)' lacks a resolvable type",
                    at: location
                )
            }
            let loweredArg = try lowerExpr(argument.expression, expected: paramType, into: &context)
            try requireAssignable(loweredArg.type, to: paramType, at: location)
            loweredArgs.append(loweredArg)
        }
        // 为这个接收者类型特化默认体（与 lowerMethod 同形：self = 接收者名义类型 + 声明的参数）。
        // 按 IR 名去重，重复的调用点共用一份函数。
        let irName = "\(IRName.mangle(defaultMethod.name))__\(IRName.mangle(typeName))"
        context.traitDefaultsCollector.add(
            try lowerMethod(
                defaultMethod, typeName: typeName, selfType: receiverType,
                typeInference: context.typeInference, moduleSignatures: context.moduleSignatures,
                nominalTypes: context.nominalTypes, userTypes: context.userTypes,
                enums: context.enums, genericFuncTemplates: context.genericFuncTemplates,
                closureIds: context.closureIds
            ))
        context.recordCall(irName)
        return LoweredExpr(
            node: .call(
                function: irName,
                arguments: [receiver] + loweredArgs.map { $0.node },
                returnType: returnType
            ),
            type: returnType ?? .i32
        )
    }

    // MARK: - 类型一致性

    /// 名义字段的 IR 类型，经登记表解析。
    private static func nominalFieldType(of type: IRType, field: String, in context: FunctionContext) -> IRType? {
        guard case .nominal(let name, _) = type,
            let info = context.nominalTypes[name],
            let fieldDecl = info.fields.first(where: { $0.name == field })
        else {
            return nil
        }
        return resolveAnnotationType(fieldDecl.typeAnnotation, userTypes: context.userTypes)
    }

    /// 字段槽：字段在声明序里的位置。槽是 IR 里唯一的字段身份，名字只在降载期当查找键；
    /// 后端因此不必自己数序号，也不会与 §6 的槽位基准分家。
    private static func nominalFieldSlot(of type: IRType, field: String, in context: FunctionContext) -> Int? {
        guard case .nominal(let name, _) = type,
            let info = context.nominalTypes[name],
            let index = info.fields.firstIndex(where: { $0.name == field })
        else {
            return nil
        }
        return index
    }

    /// 可赋值集合：只认精确相等，外加 `Char → String`（共享 ABI，不是强制转换）；该规则挂在
    /// `IRType.isAssignable(to:)` 上，校验器判值槽时用的是同一把尺。消息里的类型取自 `describe()`：
    /// `IRType` 没有自定义描述，`"\(type)"` 会漏出 `Set([0])`。
    private static func requireAssignable(_ from: IRType, to: IRType, at location: SourceLocation) throws {
        guard from.isAssignable(to: to) else {
            throw IRLoweringError(
                message: "\(from.describe()) is not assignable to \(to.describe())",
                location: location,
                code: typeMismatchCode,
                expected: to.describe(),
                got: from.describe()
            )
        }
    }

    /// 声明绑定的顶层名字，供 import 合并做重名检查。不绑定名字的声明（import、export）返回 nil；
    /// 扩展挂到别处已命名的类型上。
    private static func topLevelName(of decl: TopLevelDecl) -> String? {
        switch decl {
        case .funcDecl(let funcDecl): return funcDecl.name
        case .structDecl(let structDecl): return structDecl.name
        case .objectDecl(let objectDecl): return objectDecl.name
        case .givenDecl(let givenDecl): return givenDecl.name
        case .enumDecl(let enumDecl): return enumDecl.name
        case .traitDecl(let traitDecl): return traitDecl.name
        case .foreignDecl(let foreignDecl): return foreignDecl.name
        case .extensionDecl(let extensionDecl): return extensionDecl.targetType
        case .varDecl(let statement), .statement(let statement):
            if case .varDecl(let name, _, _, _, _) = statement { return name }
            return nil
        case .importDecl, .exportDecl: return nil
        }
    }

    /// 预置声明里名字未被本模块占用的那些 —— 让位规则的唯一落点。规则本身（什么算占用、什么刻意不算）住在
    /// 预置声明的出处，此处不另写一份：类型层那条「给定块类型名不是值」的诊断问的是同一个问题，两处各写一份
    /// 必然漂，而漂的那一刻不会有一条判据变红。
    private static func visiblePredefined(in module: Module) -> [TopLevelDecl] {
        PredefinedDecls.effective(in: module.declarations)
    }

    private static func unsupported(_ message: String, at location: SourceLocation) -> IRLoweringError {
        IRLoweringError(message: message, location: location)
    }

    /// 赋值位置的类型不匹配：程序写错了，不是「编译器还没做」。与 E6-004 分桶，CLI 才不会把
    /// 「该改程序」读成「等它做完」；模板按 `{expected}` / `{got}` 两槽填，故构造时两值都要给。
    private static let typeMismatchCode = "\(DiagnosticDomain.irgen.rawValue)-005"

    /// 默认实例相关的用户错误（不是「还没做」）。与「不支持的特性」那条码分开是刻意的 —— 后者意思是「语言
    /// 有了、编译器还没做」，这里说的是「程序写错了」；混在一个码里，CLI 上就分不开「该改程序」与「等它做完」。
    private static let noDefaultInstanceCode = "\(DiagnosticDomain.irgen.rawValue)-007"

    /// `await` / `wait` 与所在体不匹配。与下面那条位置码分开是刻意的：两者修法不同 —— 上下文不符要改函数
    /// 签名或换关键字，位置越界要改写法。
    private static let awaitOutsideAsyncBodyCode = "\(DiagnosticDomain.irgen.rawValue)-009"

    /// `await` 落在没有可恢复续跑点的位置。
    private static let awaitUnrecoverablePositionCode = "\(DiagnosticDomain.irgen.rawValue)-010"

    private static func rejected(
        _ message: String, code: String, at location: SourceLocation
    ) -> IRLoweringError {
        IRLoweringError(message: message, location: location, code: code)
    }

    /// 稳定的 funcLiteral 身份：文件 + 行 + 列。只取「行:列」会让合并多文件包时
    /// 两个文件的字面量撞车，故文件这一段显式写上。
    private static func closureIdKey(_ location: SourceLocation) -> String {
        "\(location.fileName):\(location.line):\(location.column)"
    }

    // MARK: - 有效返回类型

    /// 扫描函数体里的 `return <expr>`，返回第一个返回值在无完整降载时的类型。
    /// 解释器在运行期把 void 声明的方法的值流出去，而 LLVM ABI 在定义处需要一个具体返回类型 ——
    /// 有效类型负责升级声明的签名。
    private static func effectiveReturnType(
        decl: FuncDecl,
        userTypes: [String: IRType],
        nominals: [String: NominalInfo],
        selfTypeName: String? = nil
    ) throws -> IRType? {
        // 已声明非 void：无需升级。
        if decl.returnTypes.first != nil { return nil }
        for statement in decl.body?.statements ?? [] {
            guard case .returnStatement(let value, _) = statement, let value = value else {
                continue
            }
            // void 函数的错误绑定返回在这之前就已丢弃（`returnStmt(value: nil)`）；
            // 带值的普通 return 才升级类型。
            switch inferIRType(
                of: value, userTypes: userTypes, nominals: nominals,
                selfTypeName: selfTypeName)
            {
            case .some(let type):
                return type
            case .none:
                throw unsupported(
                    "void function '\(decl.name)' returns a value whose type is not statically resolvable",
                    at: decl.location
                )
            }
        }
        return nil
    }

    /// 有效返回预扫描用的类型解析。等价于标注解析器，加上语料用到的
    /// 名义字段读与零参方法调用形态；字面量直接解析。
    private static func inferIRType(
        of expression: Expression,
        userTypes: [String: IRType],
        nominals: [String: NominalInfo],
        selfTypeName: String? = nil
    ) -> IRType? {
        switch expression {
        case .integerLiteral: return .i32
        case .floatLiteral: return .f64
        case .stringLiteral: return .string
        case .boolLiteral: return .boolean
        case .identifier(let name, _):
            return userTypes[name]
        case .selfKeyword:
            return selfTypeName.flatMap { userTypes[$0] }
        case .member(let object, let fieldName, _):
            guard let baseType = inferIRType(of: object, userTypes: userTypes, nominals: nominals, selfTypeName: selfTypeName),
                case .nominal(let typeName, _) = baseType,
                let info = nominals[typeName],
                let field = info.fields.first(where: { $0.name == fieldName })
            else {
                return nil
            }
            return IRType(from: field.typeAnnotation)
        case .call(let callee, let arguments, _):
            // 零参方法调用 `self.方法()` —— 值的有效类型取方法声明的返回标注。
            guard arguments.isEmpty,
                case .member(let object, let methodName, _) = callee,
                let baseType = inferIRType(of: object, userTypes: userTypes, nominals: nominals, selfTypeName: selfTypeName),
                case .nominal(let typeName, _) = baseType,
                let info = nominals[typeName],
                let method = info.methods.first(where: { $0.name == methodName })
            else {
                return nil
            }
            return method.returnTypes.first.flatMap { IRType(from: $0) }
        default:
            return nil
        }
    }

    // MARK: - 位置辅助（门禁错误尽量给准源位置）

    private static func conditionLocation(_ expression: Expression) -> SourceLocation {
        expressionLocation(expression)
    }

    private static func expressionLocation(_ expression: Expression) -> SourceLocation {
        switch expression {
        case .identifier(_, let loc): return loc
        case .integerLiteral(_, let loc): return loc
        case .floatLiteral(_, let loc): return loc
        case .stringLiteral(_, let loc): return loc
        case .boolLiteral(_, let loc): return loc
        case .binary(_, _, _, let loc): return loc
        case .unary(_, _, let loc): return loc
        case .call(_, _, let loc): return loc
        default: return SourceLocation(line: 0, column: 0, fileName: "")
        }
    }

    private static func statementLocation(_ statement: Statement) -> SourceLocation {
        switch statement {
        case .varDecl(_, _, _, _, let loc): return loc
        case .assign(_, _, let loc): return loc
        case .returnStatement(_, let loc): return loc
        case .ifStatement(_, _, _, _, _, let loc): return loc
        case .whileStatement(_, _, _, _, let loc): return loc
        case .expressionStmt(_, let loc): return loc
        case .matchStatement(_, _, let loc): return loc
        case .forStatement(_, _, _, _, _, let loc): return loc
        case .passStatement(let loc): return loc
        default: return SourceLocation(line: 0, column: 0, fileName: "")
        }
    }
}

extension IRType {
    /// 把 `TypeAnnotation` 归一化进标量切片集合；落在集合外返回 nil（调用方把 nil 变成门禁错误）。
    init?(from annotation: TypeAnnotation) {
        switch annotation {
        case .simple(let name, _):
            switch name {
            case "I8": self = .i8
            case "U8": self = .u8
            case "I32": self = .i32
            case "I64": self = .i64
            case "U64": self = .u64
            case "F64": self = .f64
            case "Bool": self = .boolean
            case "String": self = .string
            case "Char": self = .char
            /// 句柄只该出现在 C 面上：语义层已把普通代码里的这个名字拦下，这里认它是为了让
            /// `|c` 导出函数的签名与 `[..|foreign]` 声明解析得出来。
            case "StringHandle": self = .stringHandle
            default: return nil
            }
        case .generic(let name, let params, _):
            // `^T` 源形态（Result 类型的糖）：钉住 ok 载荷；错误槽在 IR ABI 里类型擦除。
            if name == "Result", let first = params.first,
                let ok = IRType(from: first)
            {
                self = .result(ok: ok)
                return
            }
            // `Array<T>`：泛型嵌套，元素递归解析。
            if name == "Array", params.count == 1, let element = IRType(from: params[0]) {
                self = .array(element: element)
                return
            }
            // `Optional<T>`：也覆盖 `?T` 糖 —— 解析器把 `?T` 映射成同一个 Optional 泛型标注。
            if name == "Optional", params.count == 1, let wrapped = IRType(from: params[0]) {
                self = .optional(wrapped: wrapped)
                return
            }
            // `LazyRef<T>`：只求值一次的不可见句柄；元素类型随行，
            // 供装箱 ABI 与 `.value` 装载使用。
            if name == "LazyRef", params.count == 1, let element = IRType(from: params[0]) {
                self = .lazyRef(element: element)
                return
            }
            // `WeakRef<T>`：不增加强计数的弱引用句柄；元素是目标对象类型。
            if name == "WeakRef", params.count == 1, let element = IRType(from: params[0]) {
                self = .weakRef(element: element)
                return
            }
            // `UnownedRef<T>`：无主引用，表示就是对象指针。
            if name == "UnownedRef", params.count == 1, let element = IRType(from: params[0]) {
                self = .unownedRef(element: element)
                return
            }
            return nil
        case .pointer(let element, _):
            // `*T`（FFI 子系统）：元素递归解析；指针本身在 IR ABI 里是不透明的 `ptr`。
            guard let elementType = IRType(from: element) else { return nil }
            self = .pointer(element: elementType)
        case .tuple(let labels, let elements, _):
            // `(a: I32, b: F64,)`：字段递归解析，标签随行。
            var fieldTypes: [IRType] = []
            for element in elements {
                guard let fieldType = IRType(from: element) else { return nil }
                fieldTypes.append(fieldType)
            }
            // 标注层对全位置的元素表写 `labels: []`（调用点推断与检查器的载荷形状都是如此）。
            // IR 要求标签与字段类型按下标对齐，故空表展开成全 nil；真正只写了部分标签的表原样通过。
            let resolvedLabels =
                labels.isEmpty && !fieldTypes.isEmpty
                ? [String?](repeating: nil, count: fieldTypes.count)
                : labels
            self = .tuple(labels: resolvedLabels, fieldTypes: fieldTypes)
        case .function(let params, let returns, _, let usingIndices, _):
            // `(I32,) -> (I32,)`：胖指针 ABI 统一，形状随行供一致性检查。
            // 单个返回值是当前支持面；零返回即 void。
            guard returns.count <= 1 else { return nil }
            var paramTypes: [IRType] = []
            for param in params {
                guard let paramType = IRType(from: param) else { return nil }
                paramTypes.append(paramType)
            }
            var returnType: IRType?
            if let firstReturn = returns.first {
                guard let resolved = IRType(from: firstReturn) else { return nil }
                returnType = resolved
            }
            self = .function(params: paramTypes, returnType: returnType, usingIndices: usingIndices)
        default:
            return nil
        }
    }
}

extension TypeAnnotation {
    var simpleName: String? {
        if case .simple(let name, _) = self { return name }
        return nil
    }
}

extension IRBinaryOp {
    /// 把复合赋值 AST 运算符映射到它的基础 IR 运算符；集合外的（位运算/移位复合）返回 nil。
    init?(compound op: BinaryOperator) {
        switch op {
        case .plusAssign: self = .add
        case .minusAssign: self = .subtract
        case .multiplyAssign: self = .multiply
        case .divideAssign: self = .divide
        case .moduloAssign: self = .modulo
        case .andAssign: self = .bitwiseAnd
        case .orAssign: self = .bitwiseOr
        case .xorAssign: self = .bitwiseXor
        case .leftShiftAssign: self = .leftShift
        case .rightShiftAssign: self = .rightShift
        default: return nil
        }
    }

    /// 把 AST 二元运算符映射进支持集合；集合外返回 nil。位运算与移位在内，
    /// 但单竖线 `|` 的按位或没有解析路径 —— 它被词法器读成 pipe、orAssign 或 logicalOr。
    init?(from op: BinaryOperator) {
        switch op {
        case .plus: self = .add
        case .minus: self = .subtract
        case .multiply: self = .multiply
        case .divide: self = .divide
        case .modulo: self = .modulo
        case .equal: self = .equal
        case .notEqual: self = .notEqual
        case .lessThan: self = .lessThan
        case .lessThanOrEqual: self = .lessThanOrEqual
        case .greaterThan: self = .greaterThan
        case .greaterThanOrEqual: self = .greaterThanOrEqual
        case .bitwiseAnd: self = .bitwiseAnd
        case .bitwiseOr: self = .bitwiseOr
        case .bitwiseXor: self = .bitwiseXor
        case .leftShift: self = .leftShift
        case .rightShift: self = .rightShift
        default: return nil
        }
    }
}

extension Expression {
    /// 节点种类的短名，用于门禁错误消息。
    var kindName: String {
        switch self {
        case .identifier: return "identifier"
        case .integerLiteral: return "integer literal"
        case .floatLiteral: return "float literal"
        case .stringLiteral: return "string literal"
        case .stringInterpolation: return "string interpolation"
        case .boolLiteral: return "bool literal"
        case .binary: return "binary"
        case .unary: return "unary"
        case .call: return "call"
        case .member: return "member access"
        case .tupleIndex: return "tuple index"
        case .tuple: return "tuple"
        case .arrayLiteral: return "array literal"
        case .dictionaryLiteral: return "dictionary literal"
        case .setLiteral: return "set literal"
        case .subscript: return "subscript"
        case .funcLiteral: return "lambda"
        case .selfKeyword: return "self"
        case .selfTypeKeyword: return "Self"
        case .genericConstruct: return "generic construct"
        case .join: return "join"
        case .tryExpression: return "try-else expression"
        case .unsafe: return "unsafe"
        case .addressOf: return "addressof"
        case .dotCaseRef: return "dot case ref"
        default: return "expression"
        }
    }
}

extension Statement {
    /// 语句的源位置。每个 `Statement` case 都带位置，这个 switch 故意不写 `default:` ——
    /// 新增语句 case 会在这里编译失败，于是不会有语句在没有位置的情况下进入降载。
    var location: SourceLocation {
        switch self {
        case .varDecl(_, _, _, _, let l): return l
        case .varDestructure(_, _, _, _, let l): return l
        case .assign(_, _, let l): return l
        case .returnStatement(_, let l): return l
        case .breakStatement(_, let l): return l
        case .continueStatement(_, let l): return l
        case .ifStatement(_, _, _, _, _, let l): return l
        case .whileStatement(_, _, _, _, let l): return l
        case .forStatement(_, _, _, _, _, let l): return l
        case .unrollStatement(_, _, _, let l): return l
        case .matchStatement(_, _, let l): return l
        case .detachStatement(_, let l): return l
        case .expressionStmt(_, let l): return l
        case .deferStatement(_, let l): return l
        case .passStatement(let l): return l
        case .captureStatement(_, let l): return l
        case .scopedBlock(_, _, let l): return l
        }
    }

    /// 节点种类的短名，用于门禁错误消息。
    var kindName: String {
        switch self {
        case .varDecl: return "variable declaration"
        case .varDestructure: return "destructure declaration"
        case .assign: return "assignment"
        case .returnStatement: return "return"
        case .breakStatement: return "break"
        case .continueStatement: return "continue"
        case .ifStatement: return "if"
        case .whileStatement: return "while"
        case .forStatement: return "for-in"
        case .unrollStatement: return "unroll"
        case .matchStatement: return "match"
        case .scopedBlock: return "scoped block"
        case .detachStatement: return "detach"
        case .expressionStmt: return "expression statement"
        case .deferStatement: return "defer"
        case .passStatement: return "pass"
        case .captureStatement: return "capture"
        }
    }
}

/// 预扫描捕获的模块级函数签名，让函数体可以调用文件里后面才声明的函数。
struct IRLowererSignatureInfo {
    let paramTypes: [IRType]
    /// 该函数的调用方看到的类型。对异步（`=>`）函数是 `future(ok:)` —— 一个运行中进程的句柄 ——
    /// 故两者恰好只在后端必须区别对待的调用处分岔；其余地方默认值让它们相等。
    let returnType: IRType?
    /// 发到 `.call` 节点上的类型：被调方函数体实际产出的值，异步函数也是 `ok(v)` / `err(e)` 的 Result。
    /// 与 `returnType` 分开，是因为值的类型决定后端怎么搬，而 call 节点的协议才是被调方真正返回什么。
    let bodyReturnType: IRType?
    /// 未写类型标注的参数位置。检查器让这些位置走推断、在函数体检查里跳过它们，
    /// 调用点因此也不能拒 —— `greet(name,)` 合法，`name` 可以是字符串。
    /// 槽仍然取声明的回退类型，只跳过比对。
    let untypedParamIndices: Set<Int>
    /// `using` 形参的位置（0 基）。与检查器的 `FunctionSignature.usingParamIndices` 同一口径：调用点按「实参
    /// 个数 == 形参个数 − using 个数」认省略式调用，并把实参按非 using 形参逐位对上；空集即无 `using` 形参。
    let usingParamIndices: Set<Int>
    /// C 变参：`paramTypes` 是固定前缀，调用点可以多传。放宽的是上限，不是下限。
    let isVariadic: Bool
    /// 声明成 `StringHandle` 的形参位置（0 基）。实参是 Pini 串时，调用点在这一位包一次
    /// `bk_str_handle_new` —— 句柄的创建即复制只发生在边界上，别处没有这条路。
    let handleParamIndices: Set<Int>

    init(
        paramTypes: [IRType], returnType: IRType?, bodyReturnType: IRType? = nil,
        untypedParamIndices: Set<Int> = [], usingParamIndices: Set<Int> = [],
        isVariadic: Bool = false, handleParamIndices: Set<Int> = []
    ) {
        self.paramTypes = paramTypes
        self.returnType = returnType
        // 给默认值而非必填：凡是没话可说的调用点就都继续不说，
        // 而在不是异步分派的调用协议处，这两个类型本就一致。
        self.bodyReturnType = bodyReturnType ?? returnType
        self.untypedParamIndices = untypedParamIndices
        self.usingParamIndices = usingParamIndices
        self.isVariadic = isVariadic
        self.handleParamIndices = handleParamIndices
    }
}

/// 模块的泛型枚举模板，加上 case → 归属枚举的索引。限定写法
/// （`结果<I32, String>.ok(42)`）点明枚举，只查 `templates`；裸写法（`ok<I32, String>(42)`）
/// 只有 case 名，靠 `caseOwners` 找父枚举 —— 一个归属即定，多个即歧义。
private struct IRGenericEnumIndex {
    let templates: [String: EnumDecl]
    let caseOwners: [String: [String]]

    static let empty = IRGenericEnumIndex(templates: [:], caseOwners: [:])

    /// 某个构造拼写所属的模板。`qualifier` 在限定形式里是枚举名、在裸形式里是 case 名；
    /// `caseName` 两种形式里都是 case。
    func parentTemplate(qualifier: String, caseName: String) -> EnumDecl? {
        if let template = templates[qualifier] { return template }
        guard let owners = caseOwners[caseName], owners.count == 1 else { return nil }
        return templates[owners[0]]
    }

    /// 两个以上的泛型枚举声明了这个 case 名，裸写法无法定位，只能走裸名 case 消歧的第三档。
    func isAmbiguousCase(_ caseName: String) -> Bool {
        (caseOwners[caseName]?.count ?? 0) > 1
    }
}

/// 一个 `break` / `continue` 可以离开的外层构造。循环也是 `continue` 的目标；
/// 带标签的 `if` 块不是 —— 只有循环标签满足 `continue`，而 `break` 接受任意带标签的帧。
private struct ControlFrame {
    let label: String?
    let isLoop: Bool
}

private struct FunctionContext {
    let functionName: String
    let returnType: IRType?
    let typeInference: TypeInference?
    var variableTypes: [String: IRType]
    /// 函数体里取用过的给定块类型（见 `IRFunction.givenReferenceNames`）。
    /// 值字段即可 —— 调用点全都在**同一个**函数的 `context` 上写，不需要跨函数共享。
    var givenReferenceNames: Set<String> = []
    /// 函数体里直接调用的函数名（见 `IRFunction.calledFunctionNames`），含方法：方法落的是 mangle 过的
    /// `方法__类型`，与它自己的 `IRFunction.name` 同一个串。呈现时由 `IRModule.displayNames` 翻回源码写法。
    var calledFunctionNames: Set<String> = []

    /// 记一条调用边。具名调用的三条路径都要过这里 —— 漏一处，该路径上的间接环就看不见了。
    mutating func recordCall(_ name: String) { calledFunctionNames.insert(name) }
    let moduleSignatures: [String: IRLowererSignatureInfo]
    let nominalTypes: [String: IRLowerer.NominalInfo]
    let userTypes: [String: IRType]
    let enums: [String: IREnumDecl]
    /// 模块的泛型枚举模板 + case → 属主索引：给泛型枚举构造定形，
    /// 并找到前处理登记的专用体。
    let genericEnums: IRGenericEnumIndex
    /// 按源名索引的泛型函数模板，供调用点分派 `身份<I32>(...)`
    /// （特化体本身在单态化预扫描时已登记）。
    let genericFuncTemplates: [String: FuncDecl]
    /// 闭包字面量 id，键为 `funcLiteral.location` 的 "行:列" —— AST 节点级稳定身份。
    /// 由模块级前处理统一分配，故发射顺序与源码顺序一致。
    let closureIds: [String: Int]
    /// trait 注册表：按名的 trait 体 + 每类型的 trait 列表。降载期只读，
    /// 供成员调用在无具体实现时回落到 trait 默认方法。
    let traitRegistry: IRLowerer.TraitRegistry
    /// 在派发点特化的 trait 默认体（IR 名 `方法__类型`），收集在此供模块发射。
    /// 引用类型，故嵌套 FunctionContext 里的追加能传到 `lower()`。
    let traitDefaultsCollector: IRLowerer.TraitDefaultCollector
    /// 三级派发的第一级：内建类型（`String` / `Array`）的**用户扩展方法**。
    /// 接收者类型名 → 方法名 → （降载后的 IR 函数名, 返回类型）。由模块级预扫描填
    /// （见 `lower(module:)` 的扩展块分支）；空表即「本模块没有内建扩展」。
    var builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:]
    /// 尾表达式位：值返回的体，最后一句若是普通表达式语句，那一句的值就是返回值。
    /// 只由 `lowerBlock` 为末句置位、被 `.exprStmt` 那一支消费；别处读到 nil 即「不是尾位」。
    /// 取用后立刻清空，故嵌套语句里的表达式不会误继承这个位置。
    var trailingValueType: IRType?
    /// 外部数据符号的类型表：标识符与 `&` 命中它时走符号地址，不走变量槽。
    /// 空表即「本模块没有外部数据符号」，此时命中不了任何名字。
    var foreignData: [String: IRType] = [:]
    /// 宏常量的构建期值：标识符命中它时直接出字面量，不产生任何存储访问。
    var foreignConstants: [String: IRForeignConstant] = [:]
    /// 声明过但没值的宏名：check 应已报未求值；命中即说明有通道漏判，给条明确兜底。
    var declaredMacros: Set<String> = []
    /// 错误类型名 → 码基址。`err(...)` 按载荷类型查它，查不到按未归类 `1`。
    var errorCodeByType: [String: Int32] = [:]
    /// 稳定码类型 → 按用例 tag 索引的码表。查得到就压过「基址 | tag」。
    var hashedErrorCodes: [String: [Int32]] = [:]
    /// 方法体内裸名解析用的接收者字段类型（与解释器的 bindInstanceFields 口径一致）。方法外为空。
    var selfFieldTypes: [String: IRType] = [:]
    var selfTypeNameLowered: String?
    var selfIsObjectLowered: Bool = false
    var errorBindings: Set<String> = []

    /// 作用域内的**持有者**名字：由 `allocVar` 或 `for` 绑定引入的局部。参数 · `match` 绑定 · `try` 的
    /// 错误名不在此列 —— 它们借自别处，覆盖时不得释放旧值。逐块压栈以跟随遮蔽。
    var heldScopes: [Set<String>] = []

    /// 这个名字是否由本函数的某层作用域持有（可释放）。
    func isHeld(_ name: String) -> Bool {
        heldScopes.contains { $0.contains(name) }
    }

    /// 登记一个持有者；调用点在其初始化式求值**之后**，与发射层的登记时序一致。
    mutating func declareHeld(_ name: String) {
        if heldScopes.isEmpty { heldScopes.append([]) }
        heldScopes[heldScopes.count - 1].insert(name)
    }

    /// 撤销本层登记（`for` 绑定用完即还时用）：只动最内层，外层同名的持有者不受影响。
    mutating func retractHeld(_ name: String) {
        guard !heldScopes.isEmpty else { return }
        heldScopes[heldScopes.count - 1].remove(name)
    }

    /// 外层可中断帧，最内层在末尾（`nil` = 无标签循环）。驱动带标签 break/continue 的
    /// 深度解析：标签匹配最近的携带该标签的外层帧。
    var controlFrames: [ControlFrame] = []

    /// 合成槽名的计数器（`$destructureN`），同一函数里的多个解构因此不会共用槽。
    /// `$` 不是源标识符字符，故不会与用户名字相撞；它又能在未加引号的 LLVM 局部名里用。
    var tempCounter: Int = 0

    /// `await` / `wait` 的上下文判定：最近的体是否异步。「最近的体」而非整条链是刻意的 —— 同步闭包嵌在
    /// `=>` 体里时，闭包体自己没有可让出的任务，`await` 写在那里兑现不了（帧栈是一个任务一个，穿透闭包挂起
    /// 会打破这个前提）。故每个体各判各的，闭包体用自己的 `isAsync` 覆盖。
    var isAsync: Bool = false

    /// 本体的声明是 `=> ()`（异步且无载荷）。`returnType` 已被占位成 `Result<i32>`，
    /// 单看它分不出「真返回 i32」与「void 占位」⇒ 裸 `return` 的合法性只能靠这一位。
    var isAsyncVoid: Bool = false

    /// 本次语句降载里唯一被允许出现可让出 `await` 的位置（`nil` = 这条语句不允许）。用位置而非布尔标志：
    /// 标志要么在表达式入口一次性消费（`try` 包装位会被误伤），要么得改遍每个表达式分支才能正确传播（漏
    /// 一个就静默放行）。位置比较不必碰任何分支 —— 子表达式里的 `await` 位置天然不同。
    var allowedAwaitAt: SourceLocation?

    /// 体嵌套深度：函数 / 闭包体的那一层是 1，每进一层控制流的体加一。它只用于与 `allowedAwaitLocation` 的
    /// 句法判定合取，把可让出位置收到体那一层。与发射层的同名计数同一含义但不是同一个变量：两者是独立实现，
    /// 必须对同一条规则给出同一个答案，答案一旦分叉就会出现「降载层放行、发射层拒绝」。
    var bodyDepth: Int = 0

    /// 有效返回预扫描的别名（同一份字典，调用点名字更短）。
    fileprivate var nominalTypesMap: [String: IRLowerer.NominalInfo] { nominalTypes }

    init(
        functionName: String,
        returnType: IRType?,
        paramTypes: [String: IRType],
        typeInference: TypeInference?,
        moduleSignatures: [String: IRLowererSignatureInfo],
        nominalTypes: [String: IRLowerer.NominalInfo] = [:],
        userTypes: [String: IRType] = [:],
        enums: [String: IREnumDecl] = [:],
        genericEnums: IRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: IRLowerer.TraitRegistry = IRLowerer.TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: IRLowerer.TraitDefaultCollector = IRLowerer.TraitDefaultCollector(),
        builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:],
        isAsync: Bool = false
    ) {
        self.functionName = functionName
        self.returnType = returnType
        self.variableTypes = paramTypes
        self.typeInference = typeInference
        self.moduleSignatures = moduleSignatures
        self.nominalTypes = nominalTypes
        self.userTypes = userTypes
        self.enums = enums
        self.genericEnums = genericEnums
        self.genericFuncTemplates = genericFuncTemplates
        self.closureIds = closureIds
        self.traitRegistry = traitRegistry
        self.traitDefaultsCollector = traitDefaultsCollector
        self.builtinExtensionMethods = builtinExtensionMethods
        self.isAsync = isAsync
    }

    func inferType(of expression: Expression) -> TypeAnnotation? {
        guard let knowledge = typeInference else { return nil }
        // 重推前把本函数已定型的变量交给类型环境：持久表按裸名共享，另一个函数的同名局部
        // 会顶替这里的类型。降载按语句推进，故表里是「此刻已声明」的那一批 —— 与词法位置一致。
        let environment = knowledge.environment
        let previous = environment?.codegenLocals
        environment?.codegenLocals = variableTypes.compactMapValues { $0.typeAnnotation }
        defer {
            if let environment = environment { environment.codegenLocals = previous ?? [:] }
        }
        return knowledge.infer(expression: expression)
    }
}
