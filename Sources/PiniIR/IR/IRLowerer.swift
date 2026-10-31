import Foundation
import PiniSyntax
import PiniSemantics

/// Lowers a type-checked `Module` plus the checker's `TypeInference` into a typed `IRModule`.
/// Every backend's type decisions are made here, and this is the only place allowed to say
/// "unsupported": each capability gap throws one `IRLoweringError` from this file.
public enum IRLowerer {

    /// The single capability-gate error: free-form detail plus the position of the construct rejected.
    /// Every gate shares one diagnostic code (the unsupported-feature bucket); the resource layer
    /// dispatches on code and position, not message text. `LocalizedError` stays for callers without it.
    public struct IRLoweringError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public let location: SourceLocation
        /// Diagnostic code，默认落在 E6「不支持特性」桶。
        /// 域枚举与生成器取码同源，故换管线不改变 code 的取值域。
        public var code: String = "\(DiagnosticDomain.irgen.rawValue)-004"

        public var description: String {
            "IR lowering error at \(location.line):\(location.column): \(message)"
        }

        public var errorDescription: String? { description }
    }

    /// A lowered expression plus its resolved type. The IR nodes already
    /// carry their own types where the emitter needs them; this wrapper keeps
    /// the lowering-time type decisions explicit and uniform.
    private struct LoweredExpr {
        let node: IRExpr
        let type: IRType
    }

    /// Monomorphization scratch: one specialization per concrete type-argument combination, keyed by
    /// the specialized source name (`盒_I32`, `身份_I32`). Struct instances carry their substitution map
    /// so extension methods can be re-specialized per instance.
    fileprivate struct G10SpecializationState {
        var structSpecializations: [String: StructDecl] = [:]
        /// 泛型**给定块**的特化体（按特化名键，形如 `匣_I32`）。
        /// 与结构体那一格分开：给定块不是 `StructDecl`，且它还要驱动默认实例的取用。
        var givenSpecializations: [String: GivenDecl] = [:]
        var funcSpecializations: [String: FuncDecl] = [:]
        /// Specialized-name -> substitution used for that struct instance
        /// (generic param name -> concrete annotation).
        var structSubstitutions: [String: [String: TypeAnnotation]] = [:]
        /// Specialized generic-enum bodies, keyed the same way
        /// (`结果_I32_String`).
        var enumSpecializations: [String: EnumDecl] = [:]
        /// What the pre-pass resolves enum construction sites against. Carried inside the state rather than
        /// threaded through every recursive call of `precollectGenericUses`, which already passes the state
        /// everywhere; a separate by-value table would have to be added at each of its call sites.
        var genericEnums: IRGenericEnumIndex = .empty
    }

    /// Specialized source name for a generic instantiation: `盒` + ["I32"]
    /// -> `盒_I32`. Distinct from the `方法__类型` method separator so the
    /// two manglings never alias.
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

    /// G3 nominal registry entry: the AST declaration of a struct/object
    /// plus methods merged in from `((T))`/`{{T}}` extension blocks
    /// (data/logic separation — the parser puts methods in extensions).
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
            return Self.merging(own: own, extensions: extensionMethods)
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

        /// Rebuild this entry with merged fields/methods (composition flattening result). The full merged
        /// list (own + extension + inherited) goes back in as extension methods, so `methods` keeps its
        /// "own + extension" shape and mangling stays child-side.
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

    /// Resolve struct composition: merge the composed parent's fields/methods into the child nominal —
    /// child members first, then the parent's non-overridden ones. Nested composition recurses under a
    /// `visited` cycle guard; only structs carry `composedType`, so object parents never reach here.
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

    /// Module-level trait registry. Trait default bodies lower once
    /// per implementing type at the dispatch site; abstract signatures are
    /// skipped (conformance is the checker's contract).
    struct TraitRegistry {
        let traits: [String: TraitDecl]
        let typeTraits: [String: [String]]
    }

    /// Collector for trait default bodies specialized at dispatch
    /// sites. Reference type — appends from nested contexts (function bodies
    /// inside main) reach the module assembly in `lower()`.
    final class TraitDefaultCollector {
        private(set) var functions: [IRFunction] = []
        private var seen: Set<String> = []

        func add(_ function: IRFunction) {
            guard seen.insert(function.name).inserted else { return }
            functions.append(function)
        }
    }

    /// Lower a checked multi-file package: callers must run the package-level semantic and type-check
    /// passes first. All files merge into one virtual module, so every pre-pass becomes a global scan and
    /// cross-file references resolve like forward references; file order (name ascending) keeps it stable.
    public static func lower(
        package: Package, typeInference: TypeInference?,
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
            moduleAliases: aliasMap, requiresMain: requiresMain)
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
        // Which module supplied each merged top-level name. Flat merging gives all imported modules one
        // namespace, so two of them exporting the same public name would collapse into whichever arrived
        // last — a wrong value rather than a missing one. Tracking the supplier lets the merge refuse instead.
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

    /// Lower a checked module; `typeInference` is the checker's output, so callers must run the checker first.
    /// - Parameter requiresMain: `pini test` passes `false` for test-only files, which are legitimate
    ///   modules without `main`; the requirement belongs to the runner, not to the IR.
    public static func lower(
        module: Module, typeInference: TypeInference?,
        moduleAliases: [String: Set<String>] = [:],
        requiresMain: Bool = true
    ) throws -> IRModule {
        // Trait registry pre-pass: default-implementation bodies (signatures with a body) join the signature
        // table like any named function; abstract signatures are skipped since the checker already verified
        // conformance. Both tables are module-wide.
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
        // G3 pre-pass: nominal type registry (structs/objects), with methods
        // merged in from extension blocks ((T)) / {{T}}.
        var nominals: [String: NominalInfo] = [:]
        var genericStructTemplates: [String: StructDecl] = [:]
        var genericFuncTemplates: [String: FuncDecl] = [:]
        // Generic enum templates, plus the case -> owner index that the
        // bare construction spelling resolves through (泛型枚举构造形态). The qualified
        // spelling names the enum itself, so it needs no index.
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
        // 三形扩展的目标按实际注册类别分三类处置。放过但不归并的名单 = 已声明、却不在 `nominals` 里的
        // 类型名：枚举（含泛型枚举）无归并路径；泛型结构模板在特化段落按 `盒_<实参>` 另行归并。
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
            // kind 本身。三类处置：在 `nominals` 里 ⇒ 归并；在 `toleratedExtensionTargets` 里（枚举 / 泛型
            // 模板）⇒ 放过；其余（未知名，或指向特征）⇒ 响亮拒绝 —— 静默丢弃会让写对却没效果无从定位。
            if case .extensionDecl(let ext) = decl,
                ext.kind == .structExt || ext.kind == .objectExt || ext.kind == .bracketExt
            {
                if nominals[ext.targetType] != nil {
                    nominals[ext.targetType]!.extensionMethods.append(contentsOf: ext.methods)
                } else if !toleratedExtensionTargets.contains(ext.targetType) {
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

        // Struct composition flattening: a struct body whose first line is a bare parent type name embeds that
        // parent — child fields/methods first, then the parent's non-overridden ones appended. Parent methods
        // are re-lowered with the child's self type, so the flattened name is `方法__子类型`.
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

        // Monomorphization pre-pass: scan the module for generic construction / call sites (`盒<I32>()`),
        // register a specialized nominal (fields substituted) or function decl per type-argument combination,
        // and merge them into the registries so the rest of lowering sees only concrete types.
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
            // `((盒<T>))` parses with targetType `盒` (type params stripped) while the instance is `盒_I32`, so the
            // template is matched by prefix `盒_` or exact name `盒`; a non-generic struct of the same name cannot
            // coexist with the template.
            for decl in module.declarations {
                if case .extensionDecl(let ext) = decl, ext.kind == .structExt,
                    specializedName == ext.targetType || specializedName.hasPrefix("\(ext.targetType)_")
                {
                    // Methods of a generic struct template arrive through
                    // ((盒<T>)) extensions; re-specialize them per instance.
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

        // Enum registry plus the user-type table used for annotation resolution: names collect first, payload
        // annotations second (they may reference other user types). A generic enum is a template, not a type —
        // its payloads name type parameters — so only its specializations are registered, not the template.
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
        // The specialized bodies are ordinary enums by now (no type parameters left), so they resolve through
        // the same call. Iteration uses `.sorted()`: this dictionary's key order is hash-random too and these
        // names go to the tail of `IRModule.enums`, so an unsorted walk would again be irreproducible.
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
                        // 可解析）。`isObject: false` 与 `P1b` 一致。
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

        /// Signature info for a trait default implementation. The
        /// leading `self` parameter (annotation nil — trait bodies do not
        /// annotate it) is stripped; remaining parameters resolve normally.
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
                // Default-implementation bodies enter the signature
                // table (bodies may call top-level functions declared
                // later); abstract signatures are skipped.
                for sig in td.signatures where sig.body != nil && sig.genericParams.isEmpty {
                    signatures[sig.name] = try traitSignatureInfo(sig, userTypes: userTypes)
                }
            case .funcDecl(let funcDecl):
                // Generic templates never lower directly — only their
                // specializations do (G10). Template param annotations
                // reference type parameters and would not resolve here.
                guard funcDecl.genericParams.isEmpty else { continue }
                let paramTypes = try resolveParamTypes(funcDecl, userTypes: userTypes)
                let returnType = try resolveReturnType(
                    funcDecl, userTypes: userTypes, subject: "'\(funcDecl.name)'"
                )
                // Effective return for void-declared top-level functions that actually return a value: the signature
                // table drives call sites, so it must agree with the definition side's upgrade.
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
                // Foreign block signatures join the shared table so
                // call sites resolve them like any top-level function.
                for funcDecl in foreignDecl.funcs {
                    let paramTypes = try funcDecl.params.map { parameter -> IRType in
                        guard let annotation = parameter.typeAnnotation,
                            let type = resolveAnnotationType(annotation, userTypes: userTypes)
                        else {
                            throw unsupported(
                                "parameter '\(parameter.name)' of foreign '\(funcDecl.name)' lacks a resolvable type",
                                at: funcDecl.location
                            )
                        }
                        return type
                    }
                    let returnType = try resolveReturnType(
                        funcDecl, userTypes: userTypes, subject: "foreign '\(funcDecl.name)'"
                    )
                    signatures[funcDecl.name] = IRLowererSignatureInfo(
                        paramTypes: paramTypes, returnType: returnType
                    )
                }
            default: break
            }
        }
        // Specialized generic functions join the signature table (their
        // bodies reference only concrete types now).
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

        /// 跨模块限定名键：`别名.符号` 与裸名共用同一份签名，只在键上带别名前缀。
        /// 于是限定调用不必另开解析路径，也不会与变量的成员访问混淆 ——
        /// 变量 `a.b(...)` 的键永远不会出现在签名表里。
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

        for decl in module.declarations {
            switch decl {
            case .funcDecl(let funcDecl):
                // Generic templates are not emitted — only their
                // specializations are (G10 monomorphization).
                guard funcDecl.genericParams.isEmpty else { continue }
                functions.append(
                    try lowerFunction(
                        funcDecl, typeInference: typeInference, moduleSignatures: signatures,
                        nominalTypes: nominals, userTypes: userTypes, enums: enums, genericEnums: genericEnums,
                        genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                        traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector,
                        builtinExtensionMethods: builtinExtensionMethods)
                )
            case .traitDecl, .structDecl, .objectDecl, .extensionDecl, .enumDecl:
                // Handled by the nominal-type / enum passes below; trait
                // default bodies specialize at their dispatch sites (G12).
                continue
            case .foreignDecl:
                // Declare-only surface — lowered into `foreigns` below,
                // no function body to emit.
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
        // Emit the specialized generic function bodies.
        for (_, specialized) in specializationState.funcSpecializations {
            functions.append(
                try lowerFunction(
                    specialized, typeInference: typeInference, moduleSignatures: signatures,
                    nominalTypes: nominals, userTypes: userTypes, enums: enums, genericEnums: genericEnums,
                    genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                    traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector,
                    builtinExtensionMethods: builtinExtensionMethods)
            )
        }
        if requiresMain {
            guard functions.contains(where: { $0.name == "main" }) else {
                throw unsupported("no 'main' function found", at: module.location)
            }
        }

        // Lower nominal type declarations: field defaults via a scratch context, methods as self-parameterized
        // functions with IR names `方法__类型` so they cannot collide with top-level functions. Fields come from
        // the registry, not the raw declaration — composition flattening already merged inherited members there.
        var typeDecls: [IRTypeDecl] = []
        // 预置声明（宿主提供）也进本表：名义表只让类型名可解析，本表才是执行器建类型表并物化默认实例的
        // 来源 —— 只进名义表会让实例「类型上存在、字段上空」。用同一份 `predefined`：本表是数组，两条同名项
        // 会让下游拿到两份定义（执行器后者胜、发射器发两份）⇒ 在入口处消歧。
        for decl in predefined + module.declarations {
            switch decl {
            case .structDecl(let sd):
                // Generic templates emit no typeDecl — specializations do
                // (registered as nominals, emitted below from the registry).
                guard sd.genericParams.isEmpty else { continue }
                let info = nominals[sd.name]!
                typeDecls.append(
                    try lowerNominal(
                        name: sd.name, isObject: false, fields: info.fields,
                        methods: info.methods,
                        typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                        userTypes: userTypes, enums: enums, genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
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
                        userTypes: userTypes, enums: enums, genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
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
                        userTypes: userTypes, enums: enums, genericEnums: genericEnums,
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
                    userTypes: userTypes, enums: enums, genericEnums: genericEnums,
                    genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds
                ))
        }

        // Emit typeDecls for specialized struct instances (fields +
        // re-specialized extension methods, both registered in `nominals`).
        for specializedName in specializationState.structSpecializations.keys {
            let info = nominals[specializedName]!
            guard case .structDecl(let sd) = info.decl else { continue }
            typeDecls.append(
                try lowerNominal(
                    name: specializedName, isObject: false, fields: sd.fields,
                    methods: info.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                    userTypes: userTypes, enums: enums, genericEnums: genericEnums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds
                ))
        }
        // Trait default bodies specialized at dispatch sites join the
        // function list (dedup by IR name already applied at the dispatch).
        functions.append(contentsOf: traitDefaultsCollector.functions)

        // Lower foreign blocks into the declare-only surface.
        var foreigns: [IRForeignBlock] = []
        for decl in module.declarations {
            guard case .foreignDecl(let foreignDecl) = decl else { continue }
            var foreignFuncs: [IRForeignFunction] = []
            for funcDecl in foreignDecl.funcs {
                let paramTypes = try funcDecl.params.map { parameter -> IRType in
                    guard let annotation = parameter.typeAnnotation,
                        let type = resolveAnnotationType(annotation, userTypes: userTypes)
                    else {
                        throw unsupported(
                            "parameter '\(parameter.name)' of foreign '\(funcDecl.name)' lacks a resolvable type",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                let returnType: IRType? = try funcDecl.returnTypes.first.map { annotation in
                    guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                        throw unsupported(
                            "return type '\(annotation.simpleName ?? "(non-scalar)")' of foreign '\(funcDecl.name)'",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                foreignFuncs.append(
                    IRForeignFunction(
                        name: funcDecl.name, paramTypes: paramTypes, returnType: returnType
                    ))
            }
            foreigns.append(IRForeignBlock(name: foreignDecl.name, funcs: foreignFuncs))
        }

        return IRModule(
            functions: functions, types: typeDecls,
            enums: enumOrder.compactMap { enums[$0] },
            foreigns: foreigns,
            /// 物化依赖留痕：这里**不产诊断**。环检测是后置的，此表只保证后置检测
            /// 加一条遍历即可，不必重扫降载结果。
            givenReferences: Self.givenReferences(of: functions))
    }

    // MARK: - G10 monomorphization

    /// Whole-module scan for generic construction / call sites that registers specializations (structs,
    /// enums and functions). Idempotent: the state deduplicates by the specialized source name.
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
            // A generic enum's case carries its type arguments in the bare spelling (`ok<I32, String>(42)`), which
            // matches neither branch above, so the case-name lookup happens here. The qualified spelling
            // (`结果<I32, String>.ok(42)`) reaches the same branch through the member's receiver.
            if genericStructTemplates[typeName] == nil, genericFuncTemplates[typeName] == nil,
                let enumTemplate = state.genericEnums.parentTemplate(qualifier: typeName, caseName: typeName)
            {
                registerEnumSpecialization(enumTemplate, typeArgs: typeArgs, state: &state)
            }
        case .call(let callee, let arguments, _):
            precollectGenericUses(
                in: callee, genericStructTemplates: genericStructTemplates,
                genericFuncTemplates: genericFuncTemplates, state: &state)
            // `身份<I32>(...)` arrives as a genericConstruct callee inside a
            // call — the callee scan above already registers it.
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

    /// Register a specialized function decl (`身份<I32>` -> `身份_I32`)
    /// with type parameters substituted in params/returns. Idempotent.
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
            if case .simple(let name, _) = annotation, let sub = substitution[name] {
                return sub
            }
            return annotation
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

    /// Register a specialized struct decl (fields substituted) if this
    /// type-argument combination has not been seen yet.
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

    /// One specialized enum body per concrete type-argument combination (`结果` + [I32, String] ->
    /// `结果_I32_String`), every payload replaced by the same substitution the struct path uses. Case order,
    /// and hence every tag, is inherited unchanged — which is what lets value-based `match` keep working.
    private static func registerEnumSpecialization(
        _ template: EnumDecl,
        typeArgs: [TypeAnnotation],
        state: inout G10SpecializationState
    ) {
        // Arity is checked at the construction site, where the source spelling
        // is available for the message. Registering nothing here keeps the
        // site's own error the one the user sees.
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
            location: template.location
        )
    }

    /// Re-specialize one ((盒<T>)) extension method for a concrete instance:
    /// type parameters substituted, name kept (the nominal dispatch binds it
    /// to the specialized type through the receiver).
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

    /// Dispatch `身份<I32>(x = 100)` to the pre-registered specialization
    /// `身份_I32`. Type-argument count must match the template; argument
    /// types are checked against the specialized signature.
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
        // Argument lowering: positional order first (labels were already
        // validated by the parser against the parameter names).
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
        return LoweredExpr(
            node: .call(
                function: specializedName,
                arguments: loweredArgs.map { $0.node },
                returnType: signature.bodyReturnType
            ),
            type: signature.returnType ?? .i32
        )
    }

    // MARK: - Functions

    /// The type an async (`=>`) body hands to its caller's join: the body's own return type, the one its
    /// `return ok(v)` / `return err(e)` sites are checked against (the checker requires `Result<T, Error>`
    /// there, and a bare `=> ()` keeps the void path). Callers see `asyncSignatureReturnType` instead.
    private static func asyncBodyReturnType(
        declared: IRType?, isAsync: Bool
    ) -> IRType? {
        guard isAsync, let ok = declared else { return declared }
        return .result(ok: ok)
    }

    /// The type a caller sees for an async (`=>`) function: a handle to a running process, not the value it
    /// will settle on. It must be a distinct IR type — a backend moves a value by its type, so typing both
    /// positions as a Result leaves a fork-to-worker call indistinguishable from an ordinary one.
    private static func asyncSignatureReturnType(
        declared: IRType?, isAsync: Bool
    ) -> IRType? {
        guard isAsync, let ok = declared else { return declared }
        return .future(ok: ok)
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
        builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:]
    ) throws -> IRFunction {
        guard decl.body != nil else {
            throw unsupported("function '\(decl.name)' has no body", at: decl.location)
        }
        guard decl.genericParams.isEmpty else {
            throw unsupported("generic function '\(decl.name)'", at: decl.location)
        }
        // Multiple return slots collapse into a tuple value (D7) — see
        // resolveReturnType.
        let returnType = try resolveReturnType(
            decl, userTypes: userTypes, subject: "'\(decl.name)'"
        )
        // G13 batch 2: effective return for void-declared functions that
        // return a value (must match the signature-table upgrade so call
        // sites and the definition agree).
        let effectiveReturn =
            try effectiveReturnType(
                decl: decl, userTypes: userTypes, nominals: nominalTypes
            ) ?? returnType

        // The definition and the signature table must state the same return
        // type (see effectiveReturnType), including the async Result shape.
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
        context.isAsync = decl.isAsync
        let body = try lowerBlock(decl.body!, into: &context)
        return IRFunction(
            name: decl.name, params: params, returnType: bodyReturn, body: body,
            isAsync: decl.isAsync,
            // `|test` arrives as a modifier string; the lexer already reduced the
            // block's keyword to this canonical spelling (Token.swift).
            isTest: decl.modifiers.contains("test"),
            sourceFile: decl.location.fileName,
            givenReferenceNames: context.givenReferenceNames
        )
    }

    // MARK: - Annotation resolution (G3/G4 user types)

    /// Build the IR enum registry entry for one enum declaration whose payload annotations are expected to
    /// resolve. Shared by the module's own non-generic enums and by specialized generic bodies, which are
    /// indistinguishable from the former by the time they reach here.
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
        if let builtin = IRType(from: annotation) { return builtin }
        if case .simple(let name, _) = annotation {
            return userTypes[name]
        }
        return nil
    }

    /// Positions of parameters declared without a type annotation. One source for the call-site rule: the
    /// signature builders record these, and the call-site comparison skips exactly these positions. Their slot
    /// type still comes from the declaration's fallback (single declared return type, else I32).
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
        case .foreignDecl(let fd): return fd.funcs.map(\.params)
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
            /// 走 `resolveUsingParamType`：它比 `resolveAnnotationType` 多一条**泛型给定块
            /// 特化**的路（`using 箱: 匣<I32>` 的类型标注是泛型形，通用解析只吃简单名）。
            /// 非泛型标注两条路等价，故这只是放宽。
            guard let type = resolveUsingParamType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "parameter '\(parameter.name)' of '\(decl.name)' lacks a resolvable scalar type",
                    at: decl.location
                )
            }
            return type
        }
    }

    /// Declared return type in IR terms. Several return slots (`-> (I32, I32,)`) collapse into one tuple
    /// value — the representation `-> ((I32, I32,),)` already uses — so call sites, the return statement and
    /// the ABI need no second path. Elements are positional, hence all-nil labels; `subject` names the kind.
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
            // The declared component names ride along: `-> (商: I32, 余: I32,)` is not decoration. The interpreter
            // relabels from `decl.returnLabels` at the boundary, the executor does so off this type, and the emitter
            // prints a tuple's labels straight from it. Only a genuinely named signature switches this on.
            let named = decl.returnLabels.contains { $0 != nil }
            return .tuple(
                labels: named && decl.returnLabels.count == fieldTypes.count
                    ? decl.returnLabels
                    : Array(repeating: nil, count: fieldTypes.count),
                fieldTypes: fieldTypes
            )
        }
    }

    // MARK: - Nominal types (G3)

    /// Lower one struct/object declaration: field defaults via a scratch context, methods as
    /// self-parameterized `IRFunction`s named `方法__类型` (the double-underscore separator cannot collide
    /// with mangle output, which never emits underscores for ASCII names).
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
        return IRTypeDecl(name: name, isObject: isObject, fields: loweredFields, methods: loweredMethods)
    }

    /// Lower one method: IR name `方法__类型`, params = [self] + declared.
    private static func lowerMethod(
        _ decl: FuncDecl,
        typeName: String,
        selfType: IRType,
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
        // Multiple return slots collapse into a tuple value (D7) — same
        // contract as a top-level function.
        let returnType = try resolveReturnType(
            decl, userTypes: userTypes, subject: "'\(decl.name)'"
        )
        // A void-declared method whose body returns a value upgrades to the effective return type; body returns
        // and call sites both use it.
        let effectiveReturn =
            try effectiveReturnType(
                decl: decl, userTypes: userTypes, nominals: nominalTypes,
                selfTypeName: typeName
            ) ?? returnType
        var params = [IRFunction.IRParam(name: "self", type: selfType)]
        // The receiver may also be written as an explicit leading `self` parameter (trait default bodies are).
        // It is the receiver marker, not a parameter: the interpreter, the checker and the trait signature
        // pre-pass all drop it, and lowering it as an ordinary one would make it look unannotated.
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
        let irName = "\(IRName.mangle(decl.name))__\(IRName.mangle(typeName))"
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
        // Bare field names resolve against the receiver's fields inside method bodies (trait default bodies read
        // `名字` without a `self.` prefix). Emission goes through an explicit self load + fieldGet at the
        // identifier site.
        if case .nominal(let selfTypeName, let selfIsObject) = selfType,
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
        let body = try lowerBlock(decl.body!, into: &context)
        return IRFunction(
            name: irName, params: params, returnType: effectiveReturn, body: body,
            sourceFile: decl.location.fileName, givenReferenceNames: context.givenReferenceNames)
    }

    private static func lowerBlock(
        _ block: Block,
        into context: inout FunctionContext
    ) throws -> IRBlock {
        // 体嵌套深度：体那一层是 1，任何控制流的体都使之上浮一格。与发射层的同名计数含义相同，但两者是
        // 独立实现 —— 必须对同一条规则给出同一个答案，否则就回到两层口径差（见 `allowedAwaitLocation`）。
        context.bodyDepth += 1
        defer { context.bodyDepth -= 1 }
        context.heldScopes.append([])
        defer { context.heldScopes.removeLast() }
        var statements: [IRStmt] = []
        var positions: [SourceLocation] = []
        for statement in block.statements {
            let lowered = try lowerStatement(statement, into: &context)
            statements.append(contentsOf: lowered)
            // Every statement this source statement lowered to carries that statement's own position. One `Block`
            // statement can expand into several IR statements (a try-else initializer yields the allocation plus the
            // try), and all of them are this line — which is what the interpreter reports for the same code.
            let location = statement.location
            positions.append(contentsOf: Array(repeating: location, count: lowered.count))
        }
        return IRBlock(statements, positions: positions)
    }

    // MARK: - Statements

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

    /// Returns the lowered statements for one source statement. Most cases
    /// produce exactly one; a try-else variable initializer produces the
    /// allocation plus the try statement.
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
            // Subscript stores are the G2 write path (array family); member
            // stores are the G3 write path (nominal field store).
            if case .subscript(let container, let index) = target {
                return [
                    try lowerSubscriptStore(
                        container: container, index: index, value: value, at: location, into: &context
                    )
                ]
            }
            if case .member(let base, let fieldName) = target {
                let loweredBase = try lowerExpr(base, expected: nil, into: &context)
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
                let loweredValue = try lowerExpr(value, expected: fieldType, into: &context)
                try requireAssignable(loweredValue.type, to: fieldType, at: location)
                return [
                    .fieldStore(
                        base: loweredBase.node, field: fieldName,
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
                // A bare error binding (`return err` in a handler, the `^e` sugar): the interpreter flows the raw error
                // payload out, which is a registered semantic hole. Void functions drop the value (silent return);
                // non-void returns are gated — the type-erased err word cannot flow out as a typed payload without guessing.
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
            // A labeled `if` is an interruptible frame, so `break 标签` may leave the block; it is not a `continue`
            // target (`isLoop: false`). The frame covers every branch — `then`, each `elif` and `else` — because the
            // AST channel's `executeIf` wraps the whole of `executeIfBody` in its catch.
            if let label = label {
                context.controlFrames.append(ControlFrame(label: label, isLoop: false))
            }
            defer { if label != nil { context.controlFrames.removeLast() } }
            let thenBody = try lowerBlock(thenBlock, into: &context)
            // Elif chains lower to nested ifs (tree shape keeps them structural). The chain is nested inside this
            // frame and carries no label of its own: `break label` in an `elif` body leaves the whole `if`, which is
            // where `executeIf`'s catch sits.
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
            // Unresolvable target: fail loud at run time, exactly like the interpreter — the signal escapes past every
            // frame and errors at the top level. Lowering it hard here would reject programs the interpreter accepts.
            // The lookup walks enclosing interruptible frames, so a labeled `if` on the way out counts as one.
            guard
                let depth = resolveControlDepth(
                    label: label, target: .anyFrame, into: &context
                )
            else {
                return [.panicStmt(message: "Pini runtime error: break outside loop")]
            }
            return [.breakStmt(depth: depth)]

        case .continueStatement(let label, _):
            // `continue` needs a *loop* frame (`continue-stmt ::= 'continue'
            // [IDENT]` carries the note *仅循环标签有效*), so an `if` label is
            // unresolvable here even though it is a frame for `break`.
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
            // `defer` runs at the enclosing block scope's normal end, LIFO across that scope's defers (emitter block
            // protocol). `defer:` with an indented body parses as a scoped block, not a single statement, so the body
            // itself is deferred and it lowers through `lowerBlock` — it is a real block and carries its own positions.
            if case .scopedBlock(_, let body, _) = wrapped {
                return [.deferStmt(body: try lowerBlock(body, into: &context))]
            }
            return [.deferStmt(body: .at(try lowerStatement(wrapped, into: &context), wrapped.location))]

        case .expressionStmt(let expr, let location):
            // Statement-position try-else: ok value discarded (try-else 迁移).
            if case .tryExpression(let operand, let errorVar, let handler, _) = expr {
                return [
                    try lowerTry(
                        operand: operand, errorVar: errorVar, handler: handler,
                        okTarget: nil, at: location, into: &context
                    )
                ]
            }
            // Prefix `++`/`--` in statement position: read-modify-write on the
            // target, value discarded (G-2c).
            if case .unary(let op, let target, let unaryLocation) = expr,
                op == .increment || op == .decrement
            {
                let lowered = try lowerIncDec(
                    op: op, target: target, at: unaryLocation, into: &context
                )
                return [lowered.statement]
            }
            // Compound assignment (`a[i] += k` / `x += 1`) parses as a binary
            // expression; statement position lowers it to a store (G2).
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
            return [.exprStmt(try lowerExpr(expr, expected: nil, into: &context).node)]

        case .passStatement:
            // pass is a pure no-op; lower to a side-effect-free constant
            // expression statement so IRStmt stays total without a new case.
            return [.exprStmt(.intConst(value: 0, type: .i32))]

        case .captureStatement(let name, _):
            // Marker only — the capture set is resolved at the enclosing
            // closure literal's creation point (free-variable analysis); the
            // statement itself carries no runtime effect.
            return [.captureMarker(name: name)]

        case .detachStatement(let expr, _):
            // `detach <expr>`: evaluate the operand and prune the task it yields from its parent, so the parent's
            // return cannot cancel it — fire-and-forget's sanctioned exit. A non-future operand is refused by the
            // engine at run time, matching the interpreter's detach arm rather than rejecting earlier here.
            let inner = try lowerExpr(expr, expected: nil, into: &context)
            return [.detachStmt(inner: inner.node)]

        default:
            throw unsupported(
                "statement '\(statement.kindName)' is not yet lowered to IR",
                at: statementLocation(statement)
            )
        }
    }

    /// Lower `for (pattern,) in iterable: body [step:]`. The iterable is lowered once; its IR type decides the
    /// container kind and the per-field element types, which must line up with the pattern arity — `_`
    /// placeholders included, since the interpreter requires an exact field-count match.
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
        // Pattern variables are in scope for body AND step (mirroring the
        // emitter's loop scope and the interpreter's per-iteration
        // Environment). `_` placeholders bind nothing.
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

    /// Which frames a signal is allowed to leave.
    private enum ControlTarget {
        /// `break` — any interruptible frame (break 可定向任意带标签结构).
        case anyFrame
        /// `continue` — a loop only (`continue-stmt`'s *仅循环标签有效*).
        case loopOnly
    }

    /// Resolve a break/continue to its unwind depth, counting frames from the innermost one with the target
    /// included — the number of decrements the signal makes on its way out. An unlabeled signal targets the
    /// innermost loop, stepping over labeled `if` frames; no match returns `nil`, lowered to a runtime panic.
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
                // A label on an `if` block does not satisfy a `continue`: that
                // form is invalid, not merely unreachable (break 可定向任意带标签结构).
                matches = frame.isLoop && frame.label == label
            }
            // Innermost-first: the nearest frame that both encloses the signal
            // and can consume it is the target (内层同名标签遮蔽外层).
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
        // `var m = ++n`: the initializer writes back to n and yields the value it wrote, so the statement expands
        // to the write followed by the allocation that consumes it. The written value is I32, the only target type
        // `lowerIncDec` accepts.
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
        // `let x = try f() else ...`: the try unwraps the ok payload into x,
        // so x's type is the Result's payload type, not a Result itself.
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
            declaredType = type
        } else if let initializer = initializer {
            if let inferred = context.inferType(of: initializer),
                let type = IRType(from: inferred)
            {
                declaredType = type
            } else {
                // Checker inference miss (collection literals, checker-untracked identifiers): derive the type by lowering
                // the initializer without an expectation. The result is discarded; the real lowering below re-lowers with
                // the resolved expectation.
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
        // The static view keeps the declared names (member reads resolve
        // against it); the slot itself stores the type computed below.
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

    /// The type a binding's slot actually stores. The interpreter attaches tuple component names at two points
    /// only — an explicit `return` and an explicit tuple annotation — so a declaration naming the initializer's
    /// own type adds nothing and is relabelled with an all-`nil` list: names go, field count stays.
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

    /// Lower `let (a, b) = tupleExpr`. The initializer is evaluated once, must be a tuple, and the name count
    /// must equal its arity; each non-`_` name then binds an extractvalue off a synthetic slot holding it, so a
    /// call with side effects still runs once. A destructure with no static tuple shape is not resolvable here.
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

    // MARK: - Try-else (try-else 迁移, G1)

    /// The static Result type of a try operand: annotation-derived when
    /// resolvable, otherwise via the checker's inference (Result -> params[0]).
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

    /// Lower `try operand else errorVar: handler`. The ABI type-erases the err slot to a machine word (no static
    /// err type exists), so the bound name carries i64 and scopes to the handler only. Handler statements are
    /// restricted to return/pass; expression position (`okTarget`) additionally requires an ending return.
    private static func lowerTry(
        operand: Expression,
        errorVar: String,
        handler: Block,
        okTarget: String?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> IRStmt {
        // A bare `ok(x)` / `err(x)` operand has no expected Result to adopt: `^T` constrains neither half, so the
        // general ok/err rule has nothing to read. `ok`'s payload fixes its half, so the operand is built here with
        // that type; for `err` I32 stands in and is never read, since the handler owns control flow.
        let loweredOperand: LoweredExpr
        if case .call(let callee, let arguments, _) = operand,
            case .identifier(let calleeName, _) = callee,
            calleeName == "ok" || calleeName == "err",
            arguments.count == 1
        {
            let payload = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
            let resultType = IRType.result(ok: calleeName == "ok" ? payload.type : .i32)
            loweredOperand = LoweredExpr(
                node: .resultConstruct(
                    isOk: calleeName == "ok", payload: payload.node, type: resultType
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
        // Block form must terminate with a control-flow statement (spec
        // "try-else error propagation" note); expression position (okTarget)
        // additionally forbids the pass terminator (no value).
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

    // MARK: - Expressions

    private static func lowerExpr(
        _ expression: Expression,
        expected: IRType?,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        switch expression {
        case .integerLiteral(let value, _):
            // Int literals adopt the expected numeric type (I32 by default),
            // mirroring how the checker treats untyped integer literals.
            let type = (expected?.isNumeric == true) ? expected! : .i32
            return LoweredExpr(node: .intConst(value: value, type: type), type: type)

        case .floatLiteral(let value, _):
            // Declaration width alignment: a float literal in an integer-typed slot folds to the truncated integer
            // constant. Out-of-range or non-finite ones fall through to the float path, where `requireAssignable`
            // reports an ordinary gate error; non-literal float expressions in integer slots stay fail-loud.
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
            // Each expression part goes through the value display
            // pipeline at emission (stringify parity, interpreter channel).
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
                // All-literal: fold to a single constant.
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
            // Array subscript read: the safe-assert channel — out of bounds panics at run time, matching the
            // interpreter. A String subscript yields the single character as a String on the same channel, and negative
            // indices tail-count in both. The tolerant `.get` channel belongs to the member-call path.
            let loweredContainer = try lowerExpr(container, expected: nil, into: &context)
            let elementType: IRType
            switch loweredContainer.type {
            case .array(let element): elementType = element
            case .dict(_, let value): elementType = value
            // G67（P0d）：`String` 的下标元素是 `Char` —— 这是窄化的三个构造点
            // 之一（`s[i]` / `chars` / `chr`），与运行时读策略 `SubscriptStrategies`
            // 返回的 `.char` 必须同型，否则一个合法下标的**类型**会与它的**值**不符。
            case .string: elementType = .char
            default:
                throw unsupported(
                    "subscript on non-container type '\(loweredContainer.type)'",
                    at: location
                )
            }
            // Dict keys carry the declared key type; array/string indices
            // are I32 (tail-counted on the negative side).
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
            // 内建值：裸名字直出常量。位置在变量表之后是刻意的 —— 用户声明了同名变量时读到的是用户那份，与预置
            // 声明的让位规则同向。那个常量恒为零，且不是一个可解引用的地址：含义是「这个句柄没有指向任何东西」，
            // 由类型层承重（它只被比较、不被解引用）。
            if let valueType = BuiltinRegistry.builtinValueType(named: name) {
                guard let irType = IRType(from: valueType) else {
                    throw unsupported("builtin value '\(name)' has no IR type", at: location)
                }
                return LoweredExpr(node: .intConst(value: 0, type: irType), type: irType)
            }
            // Bare field name inside a method body (interpreter
            // bindInstanceFields parity) — lower as `self.<field>`.
            if let fieldType = context.selfFieldTypes[name] {
                let selfType = IRType.nominal(
                    name: context.selfTypeNameLowered ?? "", isObject: context.selfIsObjectLowered
                )
                return LoweredExpr(
                    node: .fieldGet(base: .load(name: "self", type: selfType), field: name, type: fieldType),
                    type: fieldType
                )
            }
            // Zero-payload enum case as a bare identifier value (G4):
            // `取文本(plus)` — unique unqualified reverse lookup.
            if let constructed = try lowerBareEnumCase(name, at: location, into: &context) {
                return constructed
            }
            // Named top-level function used as a value (G6): `应用(加倍, 21)`.
            // The type comes from the pre-pass signature table; emission goes
            // through an env-ignoring adapter fat pointer at the use site.
            if let signature = context.moduleSignatures[name] {
                let type = IRType.function(params: signature.paramTypes, returnType: signature.returnType, usingIndices: signature.usingParamIndices)
                return LoweredExpr(node: .functionValue(functionName: name, type: type), type: type)
            }
            throw unsupported("reference to undeclared variable '\(name)'", at: location)

        case .binary(let left, let op, let right, let location):
            guard let irOp = IRBinaryOp(from: op) else {
                throw unsupported(
                    "binary operator '\(op)' is not yet lowered to IR",
                    at: location
                )
            }
            // Comparison operands are lowered without scalar expectation;
            // arithmetic operands adopt the expected numeric type.
            let operandExpectation: IRType? = irOp.isComparison ? nil : expected
            let lhs = try lowerExpr(left, expected: operandExpectation, into: &context)
            let rhs = try lowerExpr(right, expected: lhs.type, into: &context)
            if irOp.isComparison {
                // G68（P0d-D）：`Char` / `String` 是**相容对**（表示同构，Char 表示与 String 同构
                // 方案 A）⇒「两操作数类型名必须字面相等」这条判据对这一对不适用。
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
            // Prefix `++`/`--` are read-modify-write on an assignable target and yield the value written. A store
            // cannot live inside an expression node (the IR declares none), so statement position and variable
            // initializers lower them — see `lowerIncDec`. Reaching here means an uncovered expression position.
            if op == .increment || op == .decrement {
                throw unsupported(
                    "prefix '\(op)' outside statement or variable-initializer position",
                    at: location
                )
            }
            // `+v` is the numeric identity: the interpreter's `unaryValue` hands back the operand unchanged, so this
            // lowers to the operand itself rather than to a node of its own. The guard keeps the rejection the
            // interpreter raises for non-numbers.
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
                // Constructed only by the abs intrinsic handler (G9); the
                // AST unary-operator path never produces it.
                fatalError("IRLowerer: .abs outside the abs intrinsic handler")
            }

        case .selfKeyword(let location):
            // Methods carry self as their first IR param (G3).
            guard let type = context.variableTypes["self"] else {
                throw unsupported("self outside a method body", at: location)
            }
            return LoweredExpr(node: .load(name: "self", type: type), type: type)

        case .member(let object, let name, let location):
            // The slice-sugar open bound arrives as `Optional.none` (a member
            // on the Optional type name) — lower it to the none literal.
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
            // Nominal field read (G3): `base.field` / `self.field`.
            // Tuple label read (G5 minimal slice): extractvalue by index.
            let loweredBase = try lowerExpr(object, expected: nil, into: &context)
            // err 字上的 `.message`：类型层把 `Error` / `CancelError` 都定义成带 `message`
            // 字段的结构体，而在 IR 里它只是**一个类型擦除的字** ⇒ 读消息要经运行时段，
            //  行不通  不是 GEP（对一个字做 GEP 只会得到无意义地址）。
            if name == "message", isErrorFaced(loweredBase.node, context) {
                return lowerErrorMessage(loweredBase.node, at: location)
            }
            // LazyRef `.value` read (G13 batch 1): `bk_lazyref_value(handle)`
            // returns the cached element box; the caller loads the element.
            if case .lazyRef(let element) = loweredBase.type, name == "value" {
                return LoweredExpr(
                    node: .lazyRefValue(handle: loweredBase.node, type: element),
                    type: element
                )
            }
            if case .tuple(let labels, let fieldTypes) = loweredBase.type {
                guard let index = labels.firstIndex(where: { $0 == name }) else {
                    throw unsupported("tuple has no field '\(name)'", at: location)
                }
                return LoweredExpr(
                    node: .tupleIndexGet(base: loweredBase.node, index: index, type: fieldTypes[index]),
                    type: fieldTypes[index]
                )
            }
            guard case .nominal = loweredBase.type else {
                throw unsupported("member access '.\(name)' outside the slice", at: location)
            }
            guard let fieldType = nominalFieldType(of: loweredBase.type, field: name, in: context) else {
                throw unsupported("no field '\(name)' on '\(loweredBase.type)'", at: location)
            }
            return LoweredExpr(
                node: .fieldGet(base: loweredBase.node, field: name, type: fieldType),
                type: fieldType
            )

        case .tupleIndex(let object, let index, let location):
            // `.0` positional read: the numeric counterpart of the labelled member read above — same extractvalue
            // node, index taken from the syntax instead of a label lookup. An index outside the static arity is
            // refused here; the interpreter only discovers it at run time.
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
            // `LazyRef<T>(closure)` is a built-in lazy reference, not a user generic template. Checked before the
            // template dispatch so a user `LazyRef` template cannot shadow it — builtin names win.
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
            // Monomorphized construction: `盒<I32>()` builds the specialized struct nominal, `身份<I32>(x = 100)`
            // calls the specialized function. The pre-pass has registered both; this only dispatches.
            if let template = context.genericFuncTemplates[typeName] {
                return try lowerGenericFuncCall(
                    template: template, typeArgs: typeArgs, arguments: arguments,
                    at: location, into: &context
                )
            }
            // Generic enum case in the bare spelling, where the case name carries the type arguments
            // (`ok<I32, String>(42)`). Neither template table holds a case name, which is why it lands here.
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
            // Zero-payload case as a dot-case value (`.plus`); cases with
            // payloads are constructed through the call form. `.none` on the
            // built-in Optional is the nil literal.
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
            // Dict literal — key/value types derived from the lowered
            // first entry (homogeneity required, checker does not infer).
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
            // Member calls: the tolerant read channel `arr.get(i)` and the slice channel `base.slice(start, end)`
            // (sugar desugaring); other method calls stay gated. Dot-case construction `.Case(args)` is a member
            // marker resolved by unique case name or expected type, with `.none` / `.some` going to Optional first.
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
            // Qualified generic enum case construction (`结果<I32, String>.ok(42)`) arrives as a member call on a
            // no-argument generic construct: the qualifier names the enum, so parent and type arguments are both
            // written down. That empty argument list is what separates it from member access on a generic value.
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
            // Generic calls `身份<I32>(...)` / struct constructions `盒<I32>()`
            // arrive as the dedicated `.genericConstruct` expression node
            // (parser lookahead) — handled in its own case below.
            guard case .identifier(let functionName, _) = callee else {
                throw unsupported(
                    "call to a non-identifier callee (method calls are later grids)",
                    at: location
                )
            }
            let loweredArgs = try arguments.map { argument in
                try lowerExpr(argument.expression, expected: nil, into: &context)
            }
            // G14 pointer builtins: load/store mirror the interpreter's
            // registerPointerBuiltins surface (signature-agnostic — the
            // pointer's element type drives decode/encode).
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
                // The value re-lowers against the pointer's element type so untyped literals adopt it (`store(p, 42)` on
                // `*U8` writes a u8). A declared-typed value keeps its own type — encoding truncates, so an I32 stored
                // into `*U8` writes the low byte, as the interpreter does.
                let value = try lowerExpr(arguments[1].expression, expected: element, into: &context)
                return LoweredExpr(
                    node: .pointerStore(pointer: loweredArgs[0].node, value: value.node, type: element),
                    type: .i32
                )
            }
            // Intrinsic `assert`: `assert(cond)` or `assert(cond, message)`. The condition must be Bool and a false
            // one traps through the runtime's panic path; test blocks are never run by the harness, but the lowering
            // must still exist.
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
            // Intrinsic `print`: the single-argument form keeps its gates; the multi-argument form stringifies each
            // argument and joins them with spaces on one line. There are no Result or nominal gates on that path —
            // the FFI corpus prints scalars, strings and pointers.
            if functionName == "print" {
                // The zero-argument form is a bare newline: the interpreter
                // joins an empty argument list and hands the empty string to
                // the sink, and `printMulti` with no arguments does the same.
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
            // The character builtins. Same shape as the other intrinsics — lowered to a `call` the executor answers
            // by name — and the name whitelist is the table itself, so a builtin cannot be lowered here and then
            // go unanswered there.
            if BuiltinSurface.character.contains(functionName) {
                guard loweredArgs.count == 1 else {
                    throw unsupported("\(functionName) expects exactly one argument", at: location)
                }
                let resultType: IRType
                switch functionName {
                // G67（P0d）：`chars` 的**元素**与 `chr` 的**结果**都是 `Char`
                // （窄化的三个构造点之二）；`ord` 仍是 `I32`、其余三个谓词仍是 `Bool`。
                case "chars": resultType = .array(element: .char)
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

            // The concurrency builtins a plain call can carry: `sleep` blocks, `Error` / `CancelError` build a
            // value. The whitelist is the table, so a name cannot be lowered here and go unanswered by the executor.
            // Names that traffic in `Future` values stay out: the IR cannot represent one yet.
            if BuiltinSurface.synchronousConcurrency.contains(functionName) {
                if functionName == "sleep" {
                    // Blocks and yields nothing; the value is discarded. A call with
                    // no return type is the shape this lowerer already emits for a
                    // void callee.
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
                // `Error("msg")` / `CancelError("msg")`: one String, and the value is a
                // nominal the two types share nothing else with -- `isCancel` is what
                // tells them apart, never the payload.
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
            // The Future-valued concurrency builtins. They stay out of the shared table because answering them needs
            // a scheduler and a task context a stateless table cannot carry; both sides match the names side by
            // side. The IR denotes a future by the `Result<T>` an async call returns — the node type is its join value.
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
                guard loweredArgs.count == 1, case .array(let element) = loweredArgs[0].type else {
                    throw unsupported("joinAll expects one array of futures", at: location)
                }
                let aggregated = IRType.result(ok: .array(element: element))
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
                /// 与 `wait` 同一条翻译：句柄进、`Result` 出。沿用实参类型会把 Future 当成站点类型，
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
            // `F64(x)`: the numeric value constructor. A float passes through, an integer widens through one `call`
            // the executor answers by name, and anything else is refused here, matching the runtime's own refusal.
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
            // `LazyRef(closure)`: the inferred spelling, sibling of `LazyRef<T>(closure)` lowered by the
            // generic-construct arm. The element type is read off the initializer closure's own return type; a
            // closure whose return type cannot be read is refused rather than guessed.
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
            if functionName == "sqrt" {
                guard loweredArgs.count == 1, loweredArgs[0].type == .f64 else {
                    throw unsupported("sqrt expects exactly one F64 argument", at: location)
                }
                return LoweredExpr(
                    node: .call(function: "sqrt", arguments: loweredArgs.map { $0.node }, returnType: .f64),
                    type: .f64
                )
            }
            /// 数学内建：sin/cos 走 llvm intrinsics，tan 展开为 sin/cos，abs/min/max 落在 I32。
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
            // Intrinsic len: arrays/dicts/sets through the runtime handles,
            // strings via the inline strlen scan. A tuple's arity is a static
            // property of its type, so len(tuple) folds to a constant.
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
            // File IO intrinsics: writeFile/readFile. Paths are not resolved here — the emitter injects the program
            // base into the runtime, and both channels resolve relative paths by one rule (`RuntimeOps.resolveIOPath`).
            // `writeFile` returns nothing yet is typed `.i32`: `IRType` has no void member and the field is unused.
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
            // The two remaining corpus builtins below the intrinsic
            // gate — `readLine()` (no arguments) and `is_ascii_digit(s)`.
            if functionName == "readLine" {
                guard loweredArgs.isEmpty else {
                    throw unsupported("readLine expects no arguments", at: location)
                }
                return LoweredExpr(node: .readLine, type: .string)
            }
            if functionName == "is_ascii_digit" {
                // G67（P0d）：参数面由 `String` 迁到 `Char`。判据取**字符串面**
                // 而非字面 `.char` —— 两者表示同构，且 `Char` 加宽到 `String` 合法
                // （G68），故两种都应收，否则一个本该合法实参会在此响亮被拒。
                guard loweredArgs.count == 1, loweredArgs[0].type.isStringFaced else {
                    throw unsupported("is_ascii_digit expects one Char argument", at: location)
                }
                return LoweredExpr(
                    node: .isAsciiDigit(argument: loweredArgs[0].node), type: .boolean
                )
            }
            // Result case construction (`ok` / `err`): requires a Result-typed context (return position, Result-typed
            // assignment) so the static Result type is known. `^T` leaves the error type unconstrained, so `err(e)`
            // adopts the context's.
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
                return LoweredExpr(
                    node: .resultConstruct(isOk: functionName == "ok", payload: loweredArgs[0].node, type: contextType),
                    type: contextType
                )
            }
            // Indirect call through a function value: the callee is a variable holding a closure or named function
            // (function-typed parameter `f(x)`, closure variable `sq(6)`); the using positions travel with that
            // function type, so the omitted spelling has them filled with instance nodes. Bare calls go below.
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
            /// 内联闭包字面量上的直接调用 `sq(6)`：callee 是 `.funcLiteral`，没有具名符号。
            /// 内联字面量的取用位**就在声明里**，比经变量更直接。
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
            // Enum case construction `圆(2.0)` / `identifier(text= "x")` (G4):
            // resolved before the function-signature table — case names share
            // the identifier namespace with functions.
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
            // Nominal constructor `名()` (G3): fields take declared defaults;
            // constructor arguments are not part of this grid's surface.
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

        case .unsafe(let operand, _):
            // `unsafe (...)` is a parse/check-level marker only: the wrapped expression lowers identically, since the
            // safe-assert subscript channel needs no unsafe distinction at emission.
            return try lowerExpr(operand, expected: expected, into: &context)

        case .addressOf(let operand, let location):
            // `&x` yields the variable's storage address. Only the identifier form is accepted here; the pointer
            // element type mirrors the variable's type, the way the interpreter labels its snapshot with the value's
            // type.
            guard case .identifier(let name, _) = operand else {
                throw unsupported(
                    "address-of supports only a plain variable this grid",
                    at: location
                )
            }
            guard let varType = context.variableTypes[name] else {
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

            // `await f` / `wait f`: the operand evaluates to a handle and the site yields the `Result<T>` its join
            // deconstructs — handle in, settled value out, two distinct IR types on purpose so a backend can tell an
            // async call from an ordinary Result one. The operand takes no expectation: a non-future fails at run time.
            let future = try lowerExpr(inner, expected: nil, into: &context)
            // One handle in, one settled value out. The fallback passes a non-handle operand through unchanged: the
            // checker already rejects it and the other engine notices only at run time, so refusing here would move
            // the error earlier than the channel this is kept equal to.
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

    // MARK: - Closures / higher-order functions (G6)

    /// Collect funcLiteral ids in source order, keyed by "行:列" so every literal gets a stable id. Traversal
    /// does descend into funcLiteral bodies: nested closure ids are assigned outer-first, inner-after, because
    /// the collector visits the literal node and returns.
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
            // G13 batch 2: key includes the source file — in a merged
            // multi-file package, two files can hold literals at the same
            // line:column, and one shared id would merge their captures.
            let key = closureIdKey(location)
            if ids[key] == nil {
                ids[key] = counter
                counter += 1
            }
            // Nested literals inside the body get ids too (deferred in source
            // order). The body is a Block; walk its statements.
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

    /// Lower a `func` literal: capture analysis at the creation point, then the body in the closure's own
    /// scope (captures pre-seeded into `variableTypes` so free references resolve; `capture` markers drop
    /// out). Param types come from the checker's chain: return annotation, then expected type, then I32.
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

        // Resolve the literal's function type: the checker's bidirectional inference (annotations > body inversion
        // > expected > return-annotation fallback > wildcard) mapped through the same annotation conversion as
        // declared signatures.
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

        // Capture analysis at the creation point: identifiers used in the body, minus the literal's own params and
        // block-declared vars, minus function-typed references to named top-level functions (those become adapters
        // at the use site). Captures are by reference: the env field holds the variable's slot pointer.
        let used = collectBodyIdentifiers(in: decl)
        let localBound = Set(decl.params.map { $0.name })
            .union(declaredLocalVars(in: decl.body?.statements ?? []))
        var captures: [IRCapture] = []
        var captureIndex: [String: Int] = [:]
        for name in used.sorted() where !localBound.contains(name) {
            // Named top-level functions are function values, not captures
            // (their adapters are emitted at the use site).
            if context.moduleSignatures[name] != nil { continue }
            guard let type = context.variableTypes[name] else { continue }
            guard captureIndex[name] == nil else { continue }
            captureIndex[name] = captures.count
            captures.append(IRCapture(name: name, type: type))
        }

        // Lower the body in a fresh scope: params + captures pre-seeded so
        // free references resolve. The enclosing function's variableTypes
        // must NOT leak in (a same-named outer var would shadow the param).
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
        let body = try lowerBlock(decl.body!, into: &closureContext)

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

    /// Variables block-declared by a statement list (their names are local
    /// definitions, never captures).
    private static func declaredLocalVars(in statements: [Statement]) -> Set<String> {
        statements.reduce(into: Set<String>()) {
            if case .varDecl(let name, _, _, _, _) = $1 { $0.insert(name) }
            if case .varDestructure(let names, _, _, _, _) = $1 { $0.formUnion(names.filter { $0 != "_" }) }
        }
    }

    // MARK: - Enum family (G4)

    /// Lower a generic enum case construction in either spelling. Returns `nil` when the spelling names no
    /// generic enum, so callers can fall through. Once it does name one, a missing specialization is an error:
    /// the pre-pass registers every use site it can see, so the site and the registration disagree.
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
            // The bare spelling resolves its parent by case name alone, so two enums sharing that name cannot be told
            // apart — the qualified form exists for exactly this, and the message must say which spelling to write.
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
        // Cross-enum same-name case (P5-5): static resolution via the
        // checker's expected-type registry.
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

    /// Zero-payload enum case as a bare identifier (`plus`); nil when the
    /// name is not a unique zero-payload case.
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

    /// Enum case construction with associated values: positional or labeled (`text= "x"`) arguments, resolved
    /// against the case's parameter names. Missing arguments fall back to declared default expressions.
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

    // MARK: - Member .get & match (G2 batch 3)

    /// String member methods: the five corpus surface forms plus the trim/index trio (leading/trailing ASCII
    /// space stripping, grapheme-indexed first occurrence). `split` produces a real `Array<String>`, matching
    /// the interpreter; `slice` / `get` fall through to the tolerant-read channels.
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

    private static func lowerMemberCall(
        object: Expression,
        memberName: String,
        arguments: [CallArgument],
        expected: IRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        /// 跨模块限定调用 `别名.符号(…)`：receiver 是 import 别名、**不是变量**，
        /// 故必须在 lower receiver 之前拦截（否则会按变量解析并报「未声明变量」）。
        if case .identifier(let aliasName, _) = object,
            let signature = context.moduleSignatures["\(aliasName).\(memberName)"]
        {
            return try lowerModuleQualifiedCall(
                functionName: memberName, signature: signature,
                arguments: arguments, at: location, into: &context
            )
        }

        // Qualified case constructor `Enum.Case(args)` (G4, P5-5): the
        // receiver is a user TYPE name, not a variable.
        if case .identifier(let typeName, _) = object, let enumDecl = context.enums[typeName],
            let enumCase = enumDecl.cases.first(where: { $0.name == memberName })
        {
            return try lowerEnumCaseConstructor(
                enumDecl: enumDecl, enumCase: enumCase, arguments: arguments,
                at: location, into: &context
            )
        }

        // Member calls on the Optional type name (G7): `Optional.some(v)` is
        // the direct some construction; `Optional.none` (no call) is handled
        // in the .member case above.
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

        let loweredObject = try lowerExpr(object, expected: nil, into: &context)
        let objectType = loweredObject.type

        // 三级派发的第一级：内建类型（`String` / `Array`）的用户扩展方法排在语言内标准库（下面按名硬编码的
        // 分支）与宿主原生之前。缺这一支时，新增方法会落到尾部兜底报「later grids」，覆盖同名成员则直接读到
        // 内建结果 —— 用户实现被静默压过。
        if let receiverName = builtinReceiverName(of: objectType),
            let ext = context.builtinExtensionMethods[receiverName]?[memberName]
        {
            let loweredArgs = try arguments.map {
                try lowerExpr($0.expression, expected: nil, into: &context)
            }
            return LoweredExpr(
                node: .call(
                    function: ext.irName,
                    arguments: [loweredObject.node] + loweredArgs.map(\.node),
                    returnType: ext.returnType
                ),
                type: ext.returnType
            )
        }

        // String member methods: upper/lower/contains/substring/split, plus the trim/index trio (leading/trailing
        // ASCII space stripping, grapheme-indexed first occurrence). `slice` / `get` fall through to the
        // tolerant-read channels.
        if case .string = objectType,
            ["upper", "lower", "contains", "substring", "split",
             "trimLeft", "trimRight", "indexOf"].contains(memberName)
        {
            return try lowerStringMethod(
                receiver: loweredObject, memberName: memberName, arguments: arguments,
                at: location, into: &context
            )
        }
        // Array member method `join`: the node stringifies each element and interposes the separator, which is
        // what the interpreter's `join` arm does to whatever the array holds — so the element type need not be a
        // string.
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

        // LazyRef `.value` in call form (G13 batch 1): `r.value()` — same
        // node as the field form; the zero-arg call is the only accepted
        // arity (parity with the interpreter's property-style read).
        if case .lazyRef(let element) = objectType, memberName == "value" {
            guard arguments.isEmpty else {
                throw unsupported("LazyRef .value takes no arguments", at: location)
            }
            return LoweredExpr(
                node: .lazyRefValue(handle: loweredObject.node, type: element),
                type: element
            )
        }

        // Nominal method dispatch: the receiver is the implicit first argument and the callee is the mangled IR
        // name `方法__类型`. When the nominal has no own or extension method of that name, fall back to an
        // implemented trait's default body, specialized to the receiver type.
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
                // The call site uses the method's effective return type: a void-declared method whose body returns a value
                // upgrades to that type, as on the definition side. The fallback goes through the wide `resolveReturnType`
                // — the narrow `IRType(from:)` rejects user-declared types — so multi-slot returns collapse to the tuple.
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
                return LoweredExpr(
                    node: .call(function: irName, arguments: arguments_ir, returnType: returnType),
                    type: returnType ?? .i32
                )
            }
            // Trait-default fallback: after an own/extension method misses, walk the receiver type's trait list for a
            // default body of this name. The body is re-lowered with the receiver's nominal as self, so it sees the
            // receiver's fields — own methods first, then trait defaults, matching the interpreter.
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
            // A dictionary's `.get` keys off any value the dictionary
            // accepts, so the index expectation follows the key type and the
            // I32 requirement is the Array/String arm's alone.
            let wrapped: IRType
            let indexExpectation: IRType?
            var requireI32Index = false
            switch objectType {
            case .array(let element): wrapped = element; indexExpectation = .i32; requireI32Index = true
            // G67（P0d）：`String` 的 `.get(i)` 取的是**元素**，与 `s[i]` 同物
            // ⇒ 元素类型同为 `Char`。留成 `.string` 会让这个通道的**声明类型**
            // 与它实际取到的**值**不符（读策略返回 `.char`）。
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

        // The rest of the Array member face: `append` / `pop` and `last`, lowered to a named `call` the executor
        // answers rather than to new nodes, so the node set stays frozen. The types are the runtime's: append
        // yields a new array, last the element or null, pop the pair (arrayWithoutLast, lastOrNull).
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
                let found = IRType.optional(wrapped: element)
                return LoweredExpr(
                    node: .call(
                        function: callName, arguments: [loweredObject.node],
                        returnType: found),
                    type: found
                )
            default:
                guard arguments.isEmpty else {
                    throw unsupported("pop takes no arguments", at: location)
                }
                let pair = IRType.tuple(
                    labels: [nil, nil],
                    fieldTypes: [
                        .array(element: element),
                        .optional(wrapped: element),
                    ])
                return LoweredExpr(
                    node: .call(
                        function: callName, arguments: [loweredObject.node],
                        returnType: pair),
                    type: pair
                )
            }
        }

        // `t.cancel()`: the one Future member the corpus reaches. The receiver rides as the first argument, as on
        // the array member face, and the result is discarded (the interpreter's cancel returns null).
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

    /// `match scrutinee: case name(binding): body ...` — the general case skeleton. The scrutinee's type picks
    /// the arm family: Optional (some/none, with `none` as the language-level nil), enum, Result, or the bare
    /// value path. Every family emits the same `matchStmt` node, differing only in scrutinee and case types.
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
            // Result scrutinee: without this arm the case falls to `default` below, whose binding adopts the scrutinee
            // type — so `case ok(v)` would bind `v` as a Result and every use of it (print, arithmetic, typed copy)
            // would be rejected against a type the source never names.
            let irCases = try lowerResultCases(cases, okType: okType, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: irCases, scrutineeType: loweredValue.type)
        default:
            // Bare scrutinee — neither Optional nor enum (a direct subscript read yields a plain value). Enum-case arms
            // (`some` / `none`) never match a bare value, so they fall through silently; literal arms (`case 1:`) do
            // compare by value and dispatch, with the operand riding along as `IRMatchLiteral` instead of pattern text.
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

    /// Literal-pattern operand handed to the emitter; nil for enum-case and
    /// wildcard patterns, whose dispatch is not value-based.
    private static func literalOperand(of pattern: MatchPattern) -> IRMatchLiteral? {
        switch pattern {
        case .intLiteral(let n): return .int(n)
        case .floatLiteral(let f): return .float(f)
        case .stringLiteral(let s): return .string(s)
        case .boolLiteral(let b): return .boolean(b)
        case .enumCase, .wildcard: return nil
        }
    }

    /// One arm body of a match whose scrutinee is neither Optional nor enum (see `lowerMatch`). The body lowers
    /// so its bindings scope-resolve; whether the arm dispatches at emission follows from its pattern — literal
    /// arms do, enum-case arms cannot. Each binding adopts the scrutinee type, wildcard/none arms bind nothing.
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

    /// Optional scrutinee arms: some/none (nil alias), single positional
    /// binding typed by the wrapped payload.
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

    /// Result scrutinee arms: ok/err, single positional binding. The asymmetry is the point: the ok binding
    /// takes the payload type (that narrowing is what makes a print, arithmetic operand or typed copy legal),
    /// while the err binding is the erased machine word try-else already uses, readable only via `pini.err.message`.
    private static func lowerResultCases(
        _ cases: [MatchCase],
        okType: IRType,
        into context: inout FunctionContext
    ) throws -> [IRMatchCase] {
        var irCases: [IRMatchCase] = []
        for matchCase in cases {
            switch matchCase.pattern {
            case .enumCase(let rawCaseName):
                // A qualified spelling (`Result.ok`) names the same leaf.
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
                    // Only undo an insertion of ours — an outer error binding
                    // of the same name must survive the arm.
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

    /// Enum scrutinee arms (G4): tag dispatch through the general skeleton;
    /// bindings are positional per the case's payload list, `_` placeholders
    /// skip, named labels (`text: s`) resolve through the declared names.
    private static func lowerEnumCases(
        _ cases: [MatchCase],
        enumDecl: IREnumDecl,
        into context: inout FunctionContext
    ) throws -> [IRMatchCase] {
        var irCases: [IRMatchCase] = []
        for (caseOrder, matchCase) in cases.enumerated() {
            // Wildcard `case _:` matches everything — last arm only.
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

    // MARK: - Prefix increment / decrement (G-2c)

    /// Lower prefix `++`/`--` to a read-modify-write: read, add or subtract one, write back, yield the written
    /// value — I32 only, over variable, field and subscript targets, as `evaluateIncDec` defines it. One helper
    /// serves both statement position and `var m = ++n`, and the returned value is the node the write stores.
    private static func lowerIncDec(
        op: UnaryOperator,
        target: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> (statement: IRStmt, value: IRExpr, type: IRType) {
        // The direction lives in the operator, not in the constant: `--` is
        // `subtract` by one, not `add` by minus one.
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
            // The read-back is the value the write just left. The interpreter returns the value it computed; for the
            // I32 targets accepted here the two are equal, and reading back keeps `var m = ++n` from running the
            // arithmetic twice.
            let readBack = IRExpr.load(name: name, type: varType)
            return (
                .storeVar(
                    name: name, type: varType, value: value,
                    adopt: varType.adoption(of: value), releaseOld: context.isHeld(name)
                ),
                readBack, varType
            )

        case .member(let base, let fieldName, _):
            let loweredBase = try lowerExpr(base, expected: nil, into: &context)
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
            let value = IRExpr.binary(
                op: baseOp,
                lhs: .fieldGet(base: loweredBase.node, field: fieldName, type: fieldType),
                rhs: one, type: fieldType
            )
            return (
                .fieldStore(
                    base: loweredBase.node, field: fieldName,
                    value: value, fieldType: fieldType,
                    adopt: fieldType.adoption(of: value), releaseOld: fieldType.holdsAShare
                ),
                .fieldGet(base: loweredBase.node, field: fieldName, type: fieldType),
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

    // MARK: - Array stores & compound assignment (G2 batch 2)

    /// Lower `container[index] = value` for array containers. The read path
    /// gates the container type; the value adopts the element type.
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

    /// Lower `target op= value` in statement position: read-modify-write. Subscript targets reuse the read's
    /// container and index nodes, so the container is emitted exactly twice (read + write).
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

    // MARK: - Array literals (G2)

    /// Lower an array literal. The checker does not infer collection literal types, so the element type comes
    /// from the lowered elements, which must be homogeneous. An expected `.array(element:)` context (annotation
    /// or enclosing literal) drives empty-literal and integer-literal adoption.
    private static func lowerArrayLiteral(
        _ elements: [Expression],
        expected: IRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        let elementExpected = expected?.arrayElementType
        // An empty literal with no expected element type adopts I32. Runtime construction is element-type free —
        // `[]` lowers to an empty handle — so the choice only fixes the static element type for later reads and
        // writes; I32 is the language's default numeric type.
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

    // MARK: - G12 trait default dispatch

    /// Lower a member call through an implemented trait's default body: the body is specialized to the receiver
    /// type as a method `方法__类型` (self = receiver), queued in `pendingTraitDefaults` for module emission,
    /// and the call site invokes it with the receiver as the implicit first argument.
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
        // Specialize the default body for this receiver type (same shape as
        // lowerMethod: self = receiver nominal + declared params). Dedup by
        // IR name so repeated call sites share one function.
        let irName = "\(IRName.mangle(defaultMethod.name))__\(IRName.mangle(typeName))"
        context.traitDefaultsCollector.add(
            try lowerMethod(
                defaultMethod, typeName: typeName, selfType: receiverType,
                typeInference: context.typeInference, moduleSignatures: context.moduleSignatures,
                nominalTypes: context.nominalTypes, userTypes: context.userTypes,
                enums: context.enums, genericFuncTemplates: context.genericFuncTemplates,
                closureIds: context.closureIds
            ))
        return LoweredExpr(
            node: .call(
                function: irName,
                arguments: [receiver] + loweredArgs.map { $0.node },
                returnType: returnType
            ),
            type: returnType ?? .i32
        )
    }

    // MARK: - Type conformance

    /// The IR type of a nominal field, resolved through the registry (G3).
    private static func nominalFieldType(of type: IRType, field: String, in context: FunctionContext) -> IRType? {
        guard case .nominal(let name, _) = type,
            let info = context.nominalTypes[name],
            let fieldDecl = info.fields.first(where: { $0.name == field })
        else {
            return nil
        }
        return resolveAnnotationType(fieldDecl.typeAnnotation, userTypes: context.userTypes)
    }

    /// Slice set: exact match only, plus one exception — `Char` widens into `String`, a declared rule the checker
    /// admits and both share an ABI for (`i8*`), so no coercion is emitted; narrowing is not admitted here.
    /// Tuples ignore component names: LLVM's spelling has none, and the executor stamps the declared labels on.
    private static func requireAssignable(_ from: IRType, to: IRType, at location: SourceLocation) throws {
        guard labelInsensitiveEqual(from, to) || (from == .char && to == .string) else {
            throw unsupported("type mismatch: \(from) is not \(to)", at: location)
        }
    }

    /// `==` everywhere except inside a tuple, where the label dimension is
    /// dropped and the element types still have to match one by one (nesting
    /// included).
    private static func labelInsensitiveEqual(_ from: IRType, _ to: IRType) -> Bool {
        if case .tuple(_, let fromFields) = from, case .tuple(_, let toFields) = to {
            guard fromFields.count == toFields.count else { return false }
            for (a, b) in zip(fromFields, toFields) where !labelInsensitiveEqual(a, b) {
                return false
            }
            return true
        }
        return from == to
    }

    /// The top-level name a declaration binds, for the import merge's
    /// duplicate check. Cases that bind nothing (imports, exports) return nil;
    /// extensions attach to a type that is named elsewhere.
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

    /// Stable funcLiteral identity: file + line + column. The `行:列` pair alone would let a merged multi-file
    /// package collide two files' literals, so the file component is explicit.
    private static func closureIdKey(_ location: SourceLocation) -> String {
        "\(location.fileName):\(location.line):\(location.column)"
    }

    // MARK: - Effective return type (G13 batch 2, package-demo parity)

    /// Scan a body for `return <expr>` and return the type of the first returned value, resolved without a
    /// full lowering pass. The interpreter flows a void-declared method's value out at run time, while the LLVM
    /// ABI needs one concrete return type at definition — so the effective type upgrades the declared signature.
    private static func effectiveReturnType(
        decl: FuncDecl,
        userTypes: [String: IRType],
        nominals: [String: NominalInfo],
        selfTypeName: String? = nil
    ) throws -> IRType? {
        // Declared non-void: nothing to upgrade.
        if decl.returnTypes.first != nil { return nil }
        for statement in decl.body?.statements ?? [] {
            guard case .returnStatement(let value, _) = statement, let value = value else {
                continue
            }
            // Error-binding returns were already dropped before this point
            // for void functions (returnStmt(value: nil)); a plain return
            // with a value upgrades the type.
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

    /// Type resolution for the effective-return pre-scan. Mirrors the
    /// annotation resolver plus the nominal field-read / zero-arg method
    /// call shapes the corpus uses; literals resolve directly.
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
            // Zero-arg method call: `self.方法()` — the method's declared
            // return annotation is the effective value type.
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

    // MARK: - Location helpers (best-effort source points for gate errors)

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
    /// Normalize a `TypeAnnotation` into the scalar slice set; nil for
    /// anything outside it (the caller turns nil into a gate error).
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
            default: return nil
            }
        case .generic(let name, let params, _):
            /// `^T` 源形态（Result 类型的糖）：钉住 ok 载荷；错误槽在 IR ABI 里类型擦除。
            if name == "Result", let first = params.first,
                let ok = IRType(from: first)
            {
                self = .result(ok: ok)
                return
            }
            // `Array<T>` (G2): nested generics recurse through the element.
            if name == "Array", params.count == 1, let element = IRType(from: params[0]) {
                self = .array(element: element)
                return
            }
            // `Optional<T>` (G7): covers the `?T` sugar too — the parser maps
            // `?T` to the same Optional generic annotation.
            if name == "Optional", params.count == 1, let wrapped = IRType(from: params[0]) {
                self = .optional(wrapped: wrapped)
                return
            }
            // `LazyRef<T>` (G13 batch 1): opaque once-evaluated handle;
            // element rides along for the boxing ABI / `.value` load.
            if name == "LazyRef", params.count == 1, let element = IRType(from: params[0]) {
                self = .lazyRef(element: element)
                return
            }
            return nil
        case .pointer(let element, _):
            // `*T` (G14, FFI 子系统): element recurses; the pointer itself
            // is an opaque `ptr` in the IR ABI.
            guard let elementType = IRType(from: element) else { return nil }
            self = .pointer(element: elementType)
        case .tuple(let labels, let elements, _):
            // `(a: I32, b: F64,)` (G8): fields recurse, labels carry over.
            var fieldTypes: [IRType] = []
            for element in elements {
                guard let fieldType = IRType(from: element) else { return nil }
                fieldTypes.append(fieldType)
            }
            // The annotation layer writes `labels: []` for element lists whose members are all positional (call-site
            // inference and the checker's payload shape). IR keeps labels index-aligned with field types, so the empty
            // list expands to all-nil; a genuinely partial list passes through as-is.
            let resolvedLabels =
                labels.isEmpty && !fieldTypes.isEmpty
                ? [String?](repeating: nil, count: fieldTypes.count)
                : labels
            self = .tuple(labels: resolvedLabels, fieldTypes: fieldTypes)
        case .function(let params, let returns, _, let usingIndices, _):
            // `(I32,) -> (I32,)` (G6): the fat-pointer ABI is uniform, the
            // shapes ride along for parity checks. A single return is the
            // slice surface; zero returns = void.
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
    /// Map a compound-assign AST operator onto its base IR operator; nil for
    /// operators outside the slice (bitwise/shift compounds are later grids).
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

    /// Map an AST binary operator onto the slice set; nil for operators it does not carry. Bitwise and shift
    /// are included, but single-pipe `|` bitwise-or has no parse path — it lexes as pipe, orAssign or logicalOr.
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
    /// Short node-kind name for gate-error messages.
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
    /// The statement's source position. Every `Statement` case carries a location and this switch has no
    /// `default:` on purpose — a new statement case fails to compile here, so no statement can reach lowering
    /// with no position to record.
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
        case .matchStatement(_, _, let l): return l
        case .detachStatement(_, let l): return l
        case .expressionStmt(_, let l): return l
        case .deferStatement(_, let l): return l
        case .passStatement(let l): return l
        case .captureStatement(_, let l): return l
        case .scopedBlock(_, _, let l): return l
        }
    }

    /// Short node-kind name for gate-error messages.
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

/// Module-level function signature captured by the pre-pass, so a body can
/// call functions declared later in the file.
struct IRLowererSignatureInfo {
    let paramTypes: [IRType]
    /// The type a caller of this function sees. For an async (`=>`) function that is `future(ok:)` — a handle
    /// to a running process — so the two differ exactly where a backend must treat the call differently;
    /// everywhere else the defaults make them equal.
    let returnType: IRType?
    /// The type carried on the emitted `.call` node: the value the callee's body actually produces, an
    /// `ok(v)` / `err(e)` Result even for an async function. Kept apart from `returnType` because a value's
    /// type is what a backend moves values by, while the call node's protocol is what the callee really returns.
    let bodyReturnType: IRType?
    /// Parameter positions declared without a type annotation. The checker leaves these inferred and skips them
    /// in the body check, so a call site must not reject them either — `greet(name,)` is legal and `name` may
    /// arrive as a string. The slot still gets the declaration's fallback type; only the comparison is skipped.
    let untypedParamIndices: Set<Int>
    /// `using` 形参的位置（0 基）。与检查器的 `FunctionSignature.usingParamIndices` 同一口径：调用点按「实参
    /// 个数 == 形参个数 − using 个数」认省略式调用，并把实参按非 using 形参逐位对上；空集即无 `using` 形参。
    let usingParamIndices: Set<Int>

    init(
        paramTypes: [IRType], returnType: IRType?, bodyReturnType: IRType? = nil,
        untypedParamIndices: Set<Int> = [], usingParamIndices: Set<Int> = []
    ) {
        self.paramTypes = paramTypes
        self.returnType = returnType
        // Defaulted rather than required: every call site that has nothing to
        // say about a handle keeps saying nothing, and the two types coincide
        // everywhere the call protocol is not an async dispatch.
        self.bodyReturnType = bodyReturnType ?? returnType
        self.untypedParamIndices = untypedParamIndices
        self.usingParamIndices = usingParamIndices
    }
}

/// The module's generic-enum templates plus the case → owner index. The qualified spelling
/// (`结果<I32, String>.ok(42)`) names the enum and needs only `templates`; the bare one (`ok<I32, String>(42)`)
/// names the case and resolves its parent through `caseOwners` — one owner settles it, more means ambiguous.
private struct IRGenericEnumIndex {
    let templates: [String: EnumDecl]
    let caseOwners: [String: [String]]

    static let empty = IRGenericEnumIndex(templates: [:], caseOwners: [:])

    /// The template a construction spelling belongs to. `qualifier` is the
    /// enum name in the qualified form and the case name in the bare one;
    /// `caseName` is the case in both.
    func parentTemplate(qualifier: String, caseName: String) -> EnumDecl? {
        if let template = templates[qualifier] { return template }
        guard let owners = caseOwners[caseName], owners.count == 1 else { return nil }
        return templates[owners[0]]
    }

    /// Two or more generic enums declare this case name, so the bare spelling
    /// cannot place it and 裸名 case 消歧（静态收敛版） tier 3 applies.
    func isAmbiguousCase(_ caseName: String) -> Bool {
        (caseOwners[caseName]?.count ?? 0) > 1
    }
}

/// One enclosing construct a `break` / `continue` may leave. Loops are `continue` targets as well; a
/// labeled `if` block is not, because only loop labels satisfy `continue` while `break` accepts any
/// labeled frame.
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
    let moduleSignatures: [String: IRLowererSignatureInfo]
    let nominalTypes: [String: IRLowerer.NominalInfo]
    let userTypes: [String: IRType]
    let enums: [String: IREnumDecl]
    /// 模块的泛型枚举模板 + case → 属主索引：给泛型枚举构造定形，
    /// 并找到前处理登记的专用体。
    let genericEnums: IRGenericEnumIndex
    /// Generic function templates by source name, for call-site
    /// dispatch of `身份<I32>(...)` (the specialization itself is
    /// pre-registered during the monomorphization pre-pass).
    let genericFuncTemplates: [String: FuncDecl]
    /// 闭包字面量 id，键为 `funcLiteral.location` 的 "行:列" —— AST 节点级稳定身份。
    /// 由模块级前处理统一分配，故发射顺序与源码顺序一致。
    let closureIds: [String: Int]
    /// trait 注册表：按名的 trait 体 + 每类型的 trait 列表。降载期只读，
    /// 供成员调用在无具体实现时回落到 trait 默认方法。
    let traitRegistry: IRLowerer.TraitRegistry
    /// Trait default bodies specialized at dispatch sites (IR name
    /// `方法__类型`), collected here for module emission. Reference type so
    /// appends from nested FunctionContexts propagate to `lower()`.
    let traitDefaultsCollector: IRLowerer.TraitDefaultCollector
    /// H-3 三级派发的第一级：内建类型（`String` / `Array`）的**用户扩展方法**。
    /// 接收者类型名 → 方法名 → （降载后的 IR 函数名, 返回类型）。由模块级预扫描填
    /// （见 `lower(module:)` 的扩展块分支）；空表即「本模块没有内建扩展」。
    var builtinExtensionMethods: [String: [String: (irName: String, returnType: IRType)]] = [:]
    /// Receiver field types for bare-name resolution inside method
    /// bodies (interpreter bindInstanceFields parity). Empty outside methods.
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

    /// Enclosing interruptible frames, innermost last (`nil` = unlabeled loop). Drives labeled break/continue
    /// depth resolution: a label matches the nearest enclosing frame carrying that label.
    var controlFrames: [ControlFrame] = []

    /// Counter for synthetic slot names (`$destructureN`), so several destructures in one function cannot share
    /// a slot. `$` is not a source-identifier character, so these never collide with user names, and unlike
    /// angle brackets it is legal in an unquoted LLVM local name.
    var tempCounter: Int = 0

    /// `await` / `wait` 的上下文判定：最近的体是否异步。「最近的体」而非整条链是刻意的 —— 同步闭包嵌在
    /// `=>` 体里时，闭包体自己没有可让出的任务，`await` 写在那里兑现不了（帧栈是一个任务一个，穿透闭包挂起
    /// 会打破这个前提）。故每个体各判各的，闭包体用自己的 `isAsync` 覆盖。
    var isAsync: Bool = false

    /// 本次语句降载里唯一被允许出现可让出 `await` 的位置（`nil` = 这条语句不允许）。用位置而非布尔标志：
    /// 标志要么在表达式入口一次性消费（`try` 包装位会被误伤），要么得改遍每个表达式分支才能正确传播（漏
    /// 一个就静默放行）。位置比较不必碰任何分支 —— 子表达式里的 `await` 位置天然不同。
    var allowedAwaitAt: SourceLocation?

    /// 体嵌套深度：函数 / 闭包体的那一层是 1，每进一层控制流的体加一。它只用于与 `allowedAwaitLocation` 的
    /// 句法判定合取，把可让出位置收到体那一层。与发射层的同名计数同一含义但不是同一个变量：两者是独立实现，
    /// 必须对同一条规则给出同一个答案，答案一旦分叉就会出现「降载层放行、发射层拒绝」。
    var bodyDepth: Int = 0

    /// G13 batch 2: alias for the effective-return pre-scan (same dictionary,
    /// shorter name at call sites).
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
        typeInference?.infer(expression: expression)
    }
}
