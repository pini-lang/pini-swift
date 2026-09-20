import Foundation

/// Lowers a type-checked `Module` (AST) plus the checker's `TypeInference`
/// into a typed `HIRModule`. This is the single point where all type
/// decisions are made for every backend, and the single place allowed to
/// say "unsupported": every capability gap surfaces as one
/// `HIRLoweringError.unsupported` thrown from this file. The old IRGenerator
/// scattered ~108 such decisions across emitters; they consolidate here.
public enum HIRLowerer {

    /// The single capability-gate error for the new pipeline: free-form
    /// English detail plus the source position of the construct that gate
    /// rejected. The CLI renders it through the diagnostic resource layer,
    /// which dispatches on a code and a position rather than on the message
    /// text, so the type carries both (see the `DiagnosticProviding`
    /// conformance in the common diagnostic layer).
    ///
    /// Every gate reports the same thing — "this construct is not lowered
    /// yet" — so they share one code from the legacy E6 surface rather than
    /// being classified one by one. `LocalizedError` is kept because the
    /// description is the only text a caller without the resource layer gets.
    public struct HIRLoweringError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public let location: SourceLocation
        /// Diagnostic code, defaulted to the E6 unsupported-feature bucket.
        /// The domain enum is the same source the legacy generator's codes
        /// come from, so switching pipelines does not change the code domain.
        public var code: String = "\(DiagnosticDomain.irgen.rawValue)-004"

        public var description: String {
            "HIR lowering error at \(location.line):\(location.column): \(message)"
        }

        public var errorDescription: String? { description }
    }

    /// A lowered expression plus its resolved type. The HIR nodes already
    /// carry their own types where the emitter needs them; this wrapper keeps
    /// the lowering-time type decisions explicit and uniform.
    private struct LoweredExpr {
        let node: HIRExpr
        let type: HIRType
    }

    /// G10 monomorphization scratch: one specialization per concrete
    /// type-argument combination, keyed by the specialized source name
    /// (`盒_I32`, `身份_I32`). Struct specializations carry the substitution
    /// map so extension methods can be re-specialized per instance.
    fileprivate struct G10SpecializationState {
        var structSpecializations: [String: StructDecl] = [:]
        /// ADR-001 `P2b`：泛型**给定块**的特化体（按特化名键，形如 `匣_I32`）。
        /// 与结构体那一格分开：给定块不是 `StructDecl`，且它还要驱动默认实例的取用。
        var givenSpecializations: [String: GivenDecl] = [:]
        var funcSpecializations: [String: FuncDecl] = [:]
        /// Specialized-name -> substitution used for that struct instance
        /// (generic param name -> concrete annotation).
        var structSubstitutions: [String: [String: TypeAnnotation]] = [:]
        /// G-2d: specialized generic-enum bodies, keyed the same way
        /// (`结果_I32_String`).
        var enumSpecializations: [String: EnumDecl] = [:]
        /// G-2d: what the pre-pass resolves enum construction sites against.
        /// Carried here rather than threaded through every recursive call of
        /// `precollectGenericUses` -- the scan already passes this state
        /// everywhere, and a fourth by-value table would have to be added to
        /// each of its ~40 call sites for no gain.
        var genericEnums: HIRGenericEnumIndex = .empty
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
            // ADR-001 `P1b`：给定块与对象同规 —— 块内字段即其字段表（`[[T]]` 追加的
            // 只有方法，从不追加字段，故这里不含 `extensionMethods` 对应物）。
            case .givenDecl(let gd): return gd.fields
            default: return []
            }
        }

        var methods: [FuncDecl] {
            switch decl {
            case .structDecl(let sd): return sd.methods + extensionMethods
            case .objectDecl(let od): return od.methods + extensionMethods
            // ADR-001 `P1b`：给定块**自带的方法**与 `[[给定块名]]` 归并进来的方法合成
            // 一张表 —— 须显式列出，`default:` 分支只给 `extensionMethods`，会丢块内方法。
            case .givenDecl(let gd): return gd.methods + extensionMethods
            default: return extensionMethods
            }
        }

        var composedParent: String? {
            switch decl {
            case .structDecl(let sd): return sd.composedType
            default: return nil
            }
        }

        /// Rebuild this entry with merged fields/methods (composition
        /// flattening result). The full merged method list (own + extension
        /// + inherited) is stored back as extension methods so `methods`
        /// keeps its "own + extension" shape and mangling stays child-side.
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

    /// G11: resolve struct composition by merging the composed parent's
    /// fields/methods into the child nominal — child members first, then the
    /// parent's non-overridden ones (interpreter mergeComposedType parity).
    /// Nested composition recurses; `visited` breaks cycles. Object parents
    /// are rejected (interpreter checkComposedTypeAllowed parity).
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

    /// G12: module-level trait registry. Trait default bodies lower once
    /// per implementing type at the dispatch site; abstract signatures are
    /// skipped (conformance is the checker's contract).
    struct TraitRegistry {
        let traits: [String: TraitDecl]
        let typeTraits: [String: [String]]
    }

    /// G12: collector for trait default bodies specialized at dispatch
    /// sites. Reference type — appends from nested contexts (function bodies
    /// inside main) reach the module assembly in `lower()`.
    final class TraitDefaultCollector {
        private(set) var functions: [HIRFunction] = []
        private var seen: Set<String> = []

        func add(_ function: HIRFunction) {
            guard seen.insert(function.name).inserted else { return }
            functions.append(function)
        }
    }

    /// G13 batch 2: lower a checked multi-file package. Callers must run the
    /// package-level semantic + type-check passes first (same contract as
    /// `check(package:)`). The checker's package context has already enforced
    /// cross-file visibility (D4: the HIR channel re-enforces nothing).
    ///
    /// D1 implementation: merge every file's declarations into one virtual
    /// module and run the existing single-module pre-pass chain on the
    /// union. All pre-passes (trait/nominal/enum registries, signature
    /// table, closure pre-collection, monomorphization) become global
    /// pre-scans for free — cross-file references resolve exactly like
    /// same-file forward references. No redeclaration risk: the semantic
    /// layer's `PackageSymbolIndex.build` already rejects cross-file
    /// duplicate top-level names.
    ///
    /// File ordering follows `FileLoader.loadDirectory`'s deterministic sort
    /// (fileName ascending), so pre-pass registration order is stable.
    public static func lower(
        package: Package, typeInference: TypeInference?,
        requiresMain: Bool = true
    ) throws -> HIRModule {
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

    /// P4-1c: 把 `import` 目标的声明并入虚拟模块，并返回「别名 → 可引入符号名」表。
    ///
    /// 为什么需要它：整包降载合并的是**本包**各文件的声明，而 `import` 目标的声明在
    /// **另一份清单**之下 —— 目录加载器按「嵌套模块」规则把自带清单的子目录剔出本包，
    /// 于是依赖符号根本不在 `Package.fileUnits` 里。解释器侧无此问题，它给每个别名建一个
    /// 子解释器（运行时机制）；本侧是静态降载，故改为**把依赖声明并入同一个虚拟模块**：
    /// 裸调用从此按前向引用解析，限定调用按 `别名.符号` 键解析。
    ///
    /// 传递性：依赖自身的 `import` 一并递归（`pending` 队列），环由加载器的 R2 检测兜住。
    /// 只并入 **public** 符号的声明（跨模块可引入门槛与解释器一致）。
    /// Public because the single-module run path needs it too: a lone file may
    /// carry `[main|import] helper = "../helper"` and then call
    /// `helper.加法(1, 2)`. The package path merged imports for it; the module
    /// path did not, so the alias had nothing to key off and was read as a
    /// variable. One merge, both paths.
    public static func mergedWithImports(_ module: Module) throws -> (Module, [String: Set<String>]) {
        guard !module.imports.isEmpty else { return (module, [:]) }
        let loader = ModuleDependencyLoader.shared
        var aliasMap: [String: Set<String>] = [:]
        var extraDecls: [TopLevelDecl] = []
        var seenRoots = Set<String>()
        // Which module supplied each merged top-level name.
        //
        // Flat merging gives every imported module one shared namespace, so two
        // modules exporting the same public name would collapse into whichever
        // arrived last -- a *wrong value* rather than a missing one, which is
        // the worse failure of the two. The three-level fixture exists to pin
        // exactly this (frontend and syntax both export 取值, 100 and 10): with
        // the collapse the program prints 20 instead of 110. Tracking the
        // supplier lets the merge refuse instead.
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
                    throw HIRLoweringError(
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

    /// Lower a checked module. `typeInference` is the TypeChecker's inference
    /// output; callers must run the checker first (same contract as the old
    /// `typeCheckThenGenerate` pipeline).
    /// - Parameter requiresMain: whether the lowered module must carry `main`.
    ///   The default is the executable-program contract, so every existing
    ///   caller keeps it. `pini test` passes `false`: a test-only file is a
    ///   legitimate module with no `main` at all (two of the `|test` fixtures
    ///   are exactly that), and refusing one would delete a working program
    ///   shape rather than migrate it. The requirement is the *runner's*, not
    ///   the IR's — which is why it is a parameter here and not a property of
    ///   every lowered module.
    public static func lower(
        module: Module, typeInference: TypeInference?,
        moduleAliases: [String: Set<String>] = [:],
        requiresMain: Bool = true
    ) throws -> HIRModule {
        // G12 pre-pass: trait registry. Trait default-implementation bodies
        // (signatures with a body) join the signature table like any named
        // function; abstract signatures (body == nil) are skipped — the type
        // checker already verified conformance (verifyTraitConformance).
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
        // G-2d: generic enum templates, plus the case -> owner index that the
        // bare construction spelling resolves through (泛型枚举构造形态). The qualified
        // spelling names the enum itself, so it needs no index.
        var genericEnumTemplates: [String: EnumDecl] = [:]
        var genericEnumCaseOwners: [String: [String]] = [:]
        for decl in module.declarations {
            switch decl {
            case .structDecl(let sd):
                if sd.genericParams.isEmpty {
                    nominals[sd.name] = NominalInfo(name: sd.name, isObject: false, decl: decl)
                } else {
                    genericStructTemplates[sd.name] = sd
                }
            case .objectDecl(let od): nominals[od.name] = NominalInfo(name: od.name, isObject: true, decl: decl)
            // ADR-001 `P1b`：给定块与结构 / 对象**同规进入归并表** ⇒ `[[给定块名]]`
            // 的方法能归并进来。`[[X]]` 的覆盖范围由这张表决定，与括号形无关。
            // ⚠️ `isObject: false` **不是**新语义承诺，而是与类型层现状对齐：`TypeChecker`
            // 显式不把给定块登记进 `referenceTypeNames`（值 / 引用语义属 `P2` 未裁项），
            // 故此处取「非引用」= 忠实反映现状，而非替 `P2` 预裁。后批若裁定给定块为
            // 引用类型，改这一处即可（`userTypes` 与 self 类型随之）。
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
        let genericEnums = HIRGenericEnumIndex(
            templates: genericEnumTemplates, caseOwners: genericEnumCaseOwners
        )
        // ADR-001 `P1b`：三形扩展的目标按**实际注册类别**分三类处置。
        // 「放过但今日也不归并」的名单 = 已声明、却不在 `nominals` 里的类型名：枚举
        // （含泛型枚举）与泛型结构模板 —— 前者今日即无归并路径（`P1a` 登记的不覆盖面，
        // 逐字维持），后者在 `G10` 特化段落按 `盒_<实参>` 另行归并。两者都**不是**本批要动的面。
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
            // ADR-001：`.bracketExt`（方括号 = 通用扩展形）与 `((` / `{{` 两形**同权**。
            // 归并条件从来只看「目标是否注册为名义类型」，不看 kind 本身 —— 实测（2026-09-19）
            // `((` 与 `{{` 对结构 / 对象目标**互通**，即是一例。
            //
            // ⚠️ **订正**（`P1b`，2026-09-19）：`P1a` 此处曾写「故 `[[X]]` 对结构 / 对象 /
            // **给定块**生效」—— 当时**失实**：给定块根本没进 `nominals`（落 `default: break`），
            // 其方法在归并处被**静默丢弃**。`P1b` 把给定块收编进表后，那句话才成立。
            //
            // 三类处置：① 在 `nominals` 里（结构 / 对象 / 给定块）⇒ 归并；
            // ② 在 `toleratedExtensionTargets` 里（枚举 / 泛型模板）⇒ 放过，维持今日行为；
            // ③ 其余 —— 名字谁都不是，或指向**特征**（特征名不在这两份名单里）⇒ **响亮拒绝**
            //    （新码 `E6-006`）。今日为静默丢弃；`P1b` 按用户裁定改为出声 ——
            //    静默会让「写对了却没效果」无从定位。
            if case .extensionDecl(let ext) = decl,
                ext.kind == .structExt || ext.kind == .objectExt || ext.kind == .bracketExt
            {
                if nominals[ext.targetType] != nil {
                    nominals[ext.targetType]!.extensionMethods.append(contentsOf: ext.methods)
                } else if !toleratedExtensionTargets.contains(ext.targetType) {
                    let spelling =
                        ext.kind == .structExt ? "((\(ext.targetType)))"
                        : ext.kind == .objectExt ? "{{\(ext.targetType)}}" : "[[\(ext.targetType)]]"
                    throw HIRLoweringError(
                        message: "extension block `\(spelling)`：目标 `\(ext.targetType)` 未声明为"
                            + "可归并的类型（结构 / 对象 / 给定块），或指向特征 —— 方法无处可归",
                        location: ext.location,
                        code: "\(DiagnosticDomain.irgen.rawValue)-006"
                    )
                }
            }
        }

        // G11: struct composition flattening (mirror of the interpreter's
        // mergeComposedType / legacy mergeComposedStructTypes). A struct body
        // whose first line is a bare parent type name (`计数器`) embeds that
        // parent: the child keeps its own fields/methods first, then the
        // parent's non-overridden ones are appended (child overrides same-name
        // parent members). Nested composition recurses with cycle guard.
        // Parent methods are re-lowered with the child's self type (the
        // interpreter shares the receiver environment; the flattened method
        // mangles to `方法__子类型` and dispatches through the child nominal).
        flattenComposedNominals(&nominals)

        // G6 pre-pass: assign every funcLiteral a stable closure id (source
        // order, keyed by "行:列" — legacy ClosureEmitter registry contract).
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

        // G10 pre-pass: monomorphization. Scan the whole module for generic
        // construction / call sites (`盒<I32>()`, `身份<I32>(...)`), register
        // a specialized nominal (fields substituted) or function decl per
        // type-argument combination, and merge the specializations into the
        // registries so the rest of lowering sees only concrete types.
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
            // `((盒<T>))` parses with targetType `盒` (type params stripped);
            // the specialized instance is `盒_I32`, so match the template by
            // prefix `盒_` / exact name `盒` (non-generic extensions on a
            // concrete struct of the same name cannot exist alongside it).
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

        // G4 pre-pass: enum registry + the user-type name table (structs,
        // objects, enums) used for annotation resolution. Names collect
        // first; payload annotations resolve second (they may reference
        // other user types).
        //
        // G-2d: a generic enum is a template, not a type -- its payload types
        // name the type parameters, so they only resolve per specialization.
        // Registering the template here is what failed on the first `T`, and it
        // failed at the declaration, for every module that merely declared a
        // generic enum. The specializations the G10 pre-pass registered take
        // its place (added below, before any lookup can see them).
        var enums: [String: HIREnumDecl] = [:]
        var userTypes: [String: HIRType] = [:]
        for decl in module.declarations {
            switch decl {
            case .enumDecl(let ed):
                guard ed.genericParams.isEmpty else { break }
                enums[ed.name] = HIREnumDecl(
                    name: ed.name,
                    cases: ed.cases.enumerated().map { index, ec in
                        HIREnumCase(
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
        // G-2d: the specialized bodies are ordinary enums by now (no type
        // parameters left), so they resolve through the same call.
        for (specializedName, specialized) in specializationState.enumSpecializations {
            enums[specializedName] = try resolveEnumPayloads(specialized, userTypes: userTypes)
        }

        // Signature pre-pass (after type registries so enum/struct/object
        // parameter annotations resolve): captures every declared function's
        // signature so bodies can call functions declared later in the file.
        // ADR-001 `P2b`：泛型给定块的**模板**与被用到的**特化**。
        //
        // ⚠️ **位置是承重的**：必须排在**签名表构造之前**。签名表要解析每个形参的类型标注，
        // 而 `using 箱: 匣<I32>` 的标注是泛型形 ⇒ 特化得先登记进 `userTypes`，否则
        // 「parameter lacks a resolvable scalar type」当场就报（实测踩过一次）。
        // 这里也正好是「类型表已就绪、签名还没建」的那一档。
        // ADR-001 `P2b`：泛型给定块的**模板**与被用到的**特化**。
        //
        // 为什么在这里扫而不是进 `precollectGenericUses` 的递归：泛型给定块只有**一个**
        // 可达入口 —— `using` 形参的类型标注（它没有构造点、没有调用点，故语句级预扫看不见它）。
        // 一个入口就一段扫描，硬塞进预扫要给它的递归加一层参数；参数一多，那条链上每处都要跟。
        // ⚠️ 本扫描只登记「被 `using` 用到的」特化（= 可达集合），不做全量枚举。
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

        var signatures: [String: HIRLowererSignatureInfo] = [:]

        /// G12: signature info for a trait default implementation. The
        /// leading `self` parameter (annotation nil — trait bodies do not
        /// annotate it) is stripped; remaining parameters resolve normally.
        func traitSignatureInfo(_ sig: FuncDecl, userTypes: [String: HIRType]) throws -> HIRLowererSignatureInfo {
            let bodyParams = sig.params.first?.name == "self" ? Array(sig.params.dropFirst()) : sig.params
            let paramTypes = try bodyParams.map { parameter -> HIRType in
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
            return HIRLowererSignatureInfo(paramTypes: paramTypes, returnType: returnType)
        }

        for decl in module.declarations {
            switch decl {
            case .traitDecl(let td):
                // G12: default-implementation bodies enter the signature
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
                // G13 batch 2: effective return for void-declared top-level
                // functions that return a value (interpreter-faithful; the
                // signature table drives call sites, so it must agree with
                // the definition side's upgrade).
                let effectiveReturn =
                    try effectiveReturnType(
                        decl: funcDecl, userTypes: userTypes, nominals: nominals
                    ) ?? returnType
                signatures[funcDecl.name] = HIRLowererSignatureInfo(
                    paramTypes: paramTypes,
                    returnType: asyncBodyReturnType(declared: effectiveReturn, isAsync: funcDecl.isAsync),
                    untypedParamIndices: untypedParamIndices(funcDecl),
                    usingParamIndices: usingParamIndices(funcDecl)
                )
            case .foreignDecl(let foreignDecl):
                // G14: foreign block signatures join the shared table so
                // call sites resolve them like any top-level function.
                for funcDecl in foreignDecl.funcs {
                    let paramTypes = try funcDecl.params.map { parameter -> HIRType in
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
                    signatures[funcDecl.name] = HIRLowererSignatureInfo(
                        paramTypes: paramTypes, returnType: returnType
                    )
                }
            default: break
            }
        }
        // G10: specialized generic functions join the signature table (their
        // bodies reference only concrete types now).
        for (_, specialized) in specializationState.funcSpecializations {
            let paramTypes = try resolveParamTypes(specialized, userTypes: userTypes)
            let returnType = try resolveReturnType(
                specialized, userTypes: userTypes, subject: "'\(specialized.name)'"
            )
            signatures[specialized.name] = HIRLowererSignatureInfo(
                paramTypes: paramTypes, returnType: returnType, untypedParamIndices: untypedParamIndices(specialized),
                usingParamIndices: usingParamIndices(specialized)
            )
        }

        // P4-1c: 跨模块限定名键。`别名.符号` 与裸名**共用同一份签名**，只在键上带别名前缀 ——
        // 于是限定调用不必另开一条解析路径，也不会与变量的成员访问混淆
        // （变量 `a.b(...)` 的键永远不会出现在签名表里）。
        for (alias, symbols) in moduleAliases {
            for symbol in symbols {
                if let info = signatures[symbol] { signatures["\(alias).\(symbol)"] = info }
            }
        }

        var functions: [HIRFunction] = []

        // H-3 三级派发（用户扩展 > 语言内标准库 > 宿主原生）的第一级。
        //
        // 内建类型（`String` / `Array`）不是名义声明 ⇒ 上面那轮扩展注册收不到它们，
        // 方法体从未被降载：新增方法在 `lowerMemberCall` 落到「later grids」兜底，
        // 覆盖同名成员则读不到用户实现（派发直接走内建表）。
        //
        // 这里把方法体降载成普通 `HIRFunction`（IR 名 `方法__类型`，与名义类型同一
        // mangle 规则），调用点按名分派 ⇒ 执行期不需要第二份实现。
        //
        // ⚠️ **必须先于**函数降载跑：函数降载要把这张表带进 `FunctionContext`，
        // 同序遍历会让先降载的函数拿到空表。
        // ⚠️ `Array` 在扩展块里不署名元素类型，self 取 i32 占位。本批的对象不使用
        // self 的元素，故占位不参与语义；元素敏感的扩展方法需要调用点特化。
        var builtinExtensionMethods: [String: [String: (irName: String, returnType: HIRType)]] = [:]
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
                // G14: declare-only surface — lowered into `foreigns` below,
                // no function body to emit.
                continue
            case .givenDecl(let givenDecl):
                // ADR-001 `P2b`：中间态结束 —— 给定块不再是「能解析、不能跑」。它现在与
                // 结构 / 对象同规进入类型面（下面的类型装配），默认实例由 `using` 取用点物化。
                //
                // ⚠️ **字段初值必须齐全**：默认实例的定义就是「各字段初值合起来」（ADR §2.2）
                // ⇒ 缺一个就没有完整默认值。用户 2026-09-19 裁定：**降载期对每个给定块报**，
                // 不做「用到了才报」—— 于是未被任何 `using` 使用的给定块**也**会因此报错。
                // 这是**行为收紧**，已在那条裁定里登记；代价是「字段留空、以后显式构造」这种
                // 写法不再合法（要它就写显式初值）。
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
        // G10: emit the specialized generic function bodies.
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

        // G3: lower nominal type declarations (field defaults via a scratch
        // context; methods as self-parameterized functions with mangled IR
        // names `方法__类型` so they cannot collide with top-level functions).
        // Fields come from the registry, not the raw declaration: G11
        // composition flattening has already merged inherited members there.
        var typeDecls: [HIRTypeDecl] = []
        for decl in module.declarations {
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
                // ADR-001 `P2b`：给定块**进类型面**。此前它只进 `nominals`（`P1b`）而进不了
                // `types` ⇒ 既没有聚合体、也不可构造（`配置()` 曾直接报错），默认实例更无从
                // 物化。`isObject: false` 与 `P1b` 的登记一致：值 / 引用语义仍不预裁。
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

        // ADR-001 `P2b`：泛型给定块的**特化**进同一张类型表。只到降载面（用户 2026-09-19
        // 裁定「含泛型但只到降载」）—— 发射与引擎沿用非泛型路径，故这里只保证「类型存在且
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

        // G10: emit typeDecls for specialized struct instances (fields +
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
        // G12: trait default bodies specialized at dispatch sites join the
        // function list (dedup by IR name already applied at the dispatch).
        functions.append(contentsOf: traitDefaultsCollector.functions)

        // G14: lower foreign blocks into the declare-only surface.
        var foreigns: [HIRForeignBlock] = []
        for decl in module.declarations {
            guard case .foreignDecl(let foreignDecl) = decl else { continue }
            var foreignFuncs: [HIRForeignFunction] = []
            for funcDecl in foreignDecl.funcs {
                let paramTypes = try funcDecl.params.map { parameter -> HIRType in
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
                let returnType: HIRType? = try funcDecl.returnTypes.first.map { annotation in
                    guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                        throw unsupported(
                            "return type '\(annotation.simpleName ?? "(non-scalar)")' of foreign '\(funcDecl.name)'",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                foreignFuncs.append(
                    HIRForeignFunction(
                        name: funcDecl.name, paramTypes: paramTypes, returnType: returnType
                    ))
            }
            foreigns.append(HIRForeignBlock(name: foreignDecl.name, funcs: foreignFuncs))
        }

        return HIRModule(
            functions: functions, types: typeDecls, enums: Array(enums.values),
            foreigns: foreigns,
            // ADR-001（用户第 5 条裁定的余量）：物化依赖留痕。当期**不产诊断** ——
            // 环检测本体是后置的，这里只保证「后置的检测是加一条遍历，而不是重扫降载结果」。
            givenReferences: Self.givenReferences(of: functions))
    }

    // MARK: - G10 monomorphization

    /// Whole-module scan for generic construction / call sites, registering
    /// specializations (legacy precollectGenericStructUses mirror, extended
    /// to generic functions). Idempotent: the state deduplicates by the
    /// specialized source name.
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
            // G-2d: a generic enum's case carries the type arguments in the
            // bare spelling (`ok<I32, String>(42)`), so this is where it lands
            // — neither branch above matches a case name. The qualified
            // spelling (`结果<I32, String>.ok(42)`) reaches this same case
            // through the member's receiver, so both spellings register here.
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

    /// ADR-001 `P2b`：登记一份**给定块**特化（字段经同一套替换）。
    ///
    /// 与结构体那条的差别只有两点：类型参数换成 `GivenDecl`；**方法一并带上**
    /// （给定块的方法表要参与默认实例的成员访问，丢掉就不是同一个类型了）。
    /// 字段初值原样保留 —— 替换只动类型标注，不动初值表达式。
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

    /// G-2d: one specialized enum body per concrete type-argument combination
    /// (`结果` + [I32, String] -> `结果_I32_String`), with every case payload
    /// replaced through the same substitution the struct path uses. Case order
    /// and therefore every tag is inherited unchanged from the template, which
    /// is what lets the value-based `match` keep working without knowing about
    /// specialization at all.
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
                returnType: signature.returnType
            ),
            type: signature.returnType ?? .i32
        )
    }

    // MARK: - Functions

    /// The type of the value an async (`=>`) body hands to its caller's join.
    ///
    /// The checker already pins this from the front end: `bodyReturns` requires
    /// `Result<T, Error>` at a `=>` body's return position, which is why the
    /// written forms there are `return ok(v)` / `return err(e)`, and why a bare
    /// `=> ()` process keeps the void path. The interpreter states the same rule
    /// from the other side -- its join passes a Result through untouched and
    /// boxes anything else into `ok(v)` -- so narrowing this position to Result
    /// is that rule written statically, not a second rule.
    private static func asyncBodyReturnType(
        declared: HIRType?, isAsync: Bool
    ) -> HIRType? {
        guard isAsync, let ok = declared else { return declared }
        return .result(ok: ok)
    }

    private static func lowerFunction(
        _ decl: FuncDecl,
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: HIRType],
        enums: [String: HIREnumDecl],
        genericEnums: HIRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector(),
        builtinExtensionMethods: [String: [String: (irName: String, returnType: HIRType)]] = [:]
    ) throws -> HIRFunction {
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
        let params: [HIRFunction.HIRParam] = zip(decl.params, paramTypes).map { param, type in
            HIRFunction.HIRParam(name: param.name, type: type, isUsing: param.isUsing)
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
        let body = try lowerBlock(decl.body!, into: &context)
        return HIRFunction(
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

    /// Resolve a type annotation: the built-in slice set first, then the
    /// module's user types (structs / objects / enums) by simple name.
    /// G-2d: build the HIR enum registry entry for one enum declaration whose
    /// payload annotations are expected to resolve. Shared by the module's own
    /// (non-generic) enums and by the specialized generic bodies, which are
    /// indistinguishable from the former by the time they reach here.
    private static func resolveEnumPayloads(
        _ ed: EnumDecl,
        userTypes: [String: HIRType]
    ) throws -> HIREnumDecl {
        var resolvedCases: [HIREnumCase] = []
        for (index, ec) in ed.cases.enumerated() {
            var payloadTypes: [HIRType] = []
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
                HIREnumCase(
                    name: ec.name, tag: index,
                    paramNames: ec.associatedParams.map { $0.name },
                    payloadTypes: payloadTypes
                ))
        }
        return HIREnumDecl(name: ed.name, cases: resolvedCases)
    }

    private static func resolveAnnotationType(
        _ annotation: TypeAnnotation,
        userTypes: [String: HIRType]
    ) -> HIRType? {
        if let builtin = HIRType(from: annotation) { return builtin }
        if case .simple(let name, _) = annotation {
            return userTypes[name]
        }
        return nil
    }

    /// Resolve a function definition's parameter types, applying the
    /// unannotated-parameter fallback the legacy emitter established (P6-4a):
    /// a parameter that carries no annotation adopts the function's single
    /// declared return type when there is exactly one, and I32 otherwise (the
    /// interpreter's default numeric type). Both corpus shapes are covered by
    /// the two branches — `f(x, y) -> ()` and `f(x, y) -> (I32,)` both land on
    /// I32. Annotated parameters resolve as before, and an annotation that
    /// does not resolve stays a gate error.
    ///
    /// Used by both ends of a definition: the signature pre-pass (so call
    /// sites see the fallback) and the body lowering (so the definition
    /// agrees). `foreign` and trait-default declarations keep their own
    /// resolution — neither surface allows an unannotated parameter.
    /// Positions of parameters declared without a type annotation.
    ///
    /// One source for the call-site rule: the signature builders record these,
    /// and the call-site comparison skips exactly these positions.
    private static func untypedParamIndices(_ decl: FuncDecl) -> Set<Int> {
        Set(
            decl.params.enumerated().compactMap { index, parameter in
                parameter.typeAnnotation == nil ? index : nil
            })
    }

    /// ADR-001 `P2b`：一个顶层声明里**全部参数表**（自由函数 / 方法 / 特征默认体 / 扩展方法）。
    ///
    /// 泛型给定块的特化只在 `using` 形参的类型标注上出现，故扫描面就是参数表本身；
    /// 语句级预扫看不见类型标注，两者是**互补**的，不是重复。
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

    /// ADR-001：`using` 形参的位置（0 基）。
    ///
    /// 与 `untypedParamIndices` 并列，理由相同：这个量在**声明侧**成立（AST 上记着），
    /// 调用侧只是照它判合法性并补实参 —— 两处必须来自同一个函数，否则会漂。
    private static func usingParamIndices(_ decl: FuncDecl) -> Set<Int> {
        Set(
            decl.params.enumerated().compactMap { index, parameter in
                parameter.isUsing ? index : nil
            })
    }

    /// ADR-001 `P2b`：依赖留痕的聚合 —— 函数名 → 它取用过的给定块类型（升序）。
    private static func givenReferences(of functions: [HIRFunction]) -> [String: [String]] {
        var edges: [String: [String]] = [:]
        for function in functions where !function.givenReferenceNames.isEmpty {
            edges[function.name] = function.givenReferenceNames.sorted()
        }
        return edges
    }

    /// ADR-001 `P2b`：把一次调用的实参映射到**形参位**。
    ///
    /// 与检查器 `FunctionSignature.argumentToParamIndices` 同口径（那份判合法性，这份真插入）：
    /// 全显式 ⇒ 恒等；省略式（个数 = 形参个数 − using 个数）⇒ 实参只落非 using 位。
    /// 两者都不成立 ⇒ arity 错，**文案与改动前逐字相同**（`using` 为空时两式合一）。
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

    /// ADR-001 `P2b`：`using` 形参的类型 —— 通用路径之外多一条**泛型给定块特化**的路。
    ///
    /// `HIRType(from:)` / `resolveAnnotationType` 只吃简单名；泛型给定块在标注位写的是
    /// `匣<I32>`，故先按特化名查一次（特化由预扫描登记进 `userTypes`）。
    private static func resolveUsingParamType(
        _ annotation: TypeAnnotation,
        userTypes: [String: HIRType]
    ) -> HIRType? {
        if case .generic(let name, let typeArgs, _) = annotation,
            let specialized = userTypes[specializedSourceName(name, typeArgs: typeArgs)]
        {
            return specialized
        }
        return HIRType(from: annotation) ?? resolveAnnotationType(annotation, userTypes: userTypes)
    }

    /// ADR-001 §2.6：把**推断出的函数类型标注**逐位解析成 HIR 函数类型。
    ///
    /// ⚠️ 不能直接用 `HIRType(from:)` —— 它只吃**内建简单名**，而匿名函数的参数类型
    /// 可以是用户类型（给定块 `配置`、结构、对象…）。这与 `P2b` 在函数签名处遇到的是
    /// 同一个坑，故复用 `resolveUsingParamType` 逐位解析。
    /// 取用下标集合**原样透传** —— 它正是本批要让它活起来的那一位。
    private static func resolvedFunctionType(
        _ annotation: TypeAnnotation,
        userTypes: [String: HIRType]
    ) -> HIRType? {
        guard case .function(let aParams, let aReturns, _, let usingIndices, _) = annotation else {
            return HIRType(from: annotation)
        }
        let params = aParams.compactMap { resolveUsingParamType($0, userTypes: userTypes) }
        guard params.count == aParams.count else { return nil }
        let returns = aReturns.compactMap { resolveUsingParamType($0, userTypes: userTypes) }
        return .function(params: params, returnType: returns.first, usingIndices: usingIndices)
    }

    /// ADR-001 `P2b`：一个 `using` 形参的取用点。
    ///
    /// 只判一件事 —— **该类型有默认实例**，即它得是给定块（`[名|given]`）。
    /// ⚠️ 字段是否齐全**不在**这里判：那条判据在声明处按「降载期对每个给定块」执行
    /// （用户 2026-09-19 裁定），跑到调用点时声明早已过一遍 ⇒ 齐的。
    private static func givenInstanceNode(
        forParamType type: HIRType,
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

    /// ADR-001 `P2b`：把降载好的实参放回形参位，并在 `using` 位补取用点。
    private static func fillUsingArguments(
        retypedArgs: [LoweredExpr],
        paramIndices: [Int],
        paramTypes: [HIRType],
        usingParamIndices: Set<Int>,
        omittedForm: Bool,
        callee: String,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [HIRExpr] {
        // ⚠️ **全显式形态下一位都不注入**：那种形态里每个形参位都有调用点给的实参，
        // 在 `using` 位再插一个取用点会把它**顶掉**（`取(5, 6,)` 会变成「5 被忽略、
        // 甲 取默认实例」）。ADR 说显式提供合法 ⇒ 这条守卫就是那句「允许」的落地。
        // 本缺陷是被既有判据抓到的（`usingPrefixMarksOnlyItsOwnParameter`），不是想出来的。
        guard omittedForm else { return retypedArgs.map(\.node) }
        var nodes: [HIRExpr] = []
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
        userTypes: [String: HIRType]
    ) throws -> [HIRType] {
        let fallback: HIRType
        if decl.returnTypes.count == 1,
            let single = resolveAnnotationType(decl.returnTypes[0], userTypes: userTypes)
        {
            fallback = single
        } else {
            fallback = .i32
        }
        return try decl.params.map { parameter in
            guard let annotation = parameter.typeAnnotation else { return fallback }
            // ADR-001 `P2b`：走 `resolveUsingParamType` —— 它比 `resolveAnnotationType`
            // 多一条**泛型给定块特化**的路（`using 箱: 匣<I32>` 的类型标注是泛型形，
            // 通用解析只吃简单名）。非泛型标注两条路等价，故这是纯放宽。
            guard let type = resolveUsingParamType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "parameter '\(parameter.name)' of '\(decl.name)' lacks a resolvable scalar type",
                    at: decl.location
                )
            }
            return type
        }
    }

    /// Declared return type in HIR terms.
    ///
    /// Several return slots (`-> (I32, I32,)`) collapse into ONE tuple value —
    /// the representation the single-slot tuple form (`-> ((I32, I32,),)`)
    /// already uses. Call sites, the return statement and the IR ABI therefore
    /// need no second path: the call's value type is the tuple, exactly as if
    /// the declaration had written the tuple annotation directly. The elements
    /// are positional, so their labels are all nil — the same label shape the
    /// call-site inference produces for a multi-value call (HIRType's tuple
    /// branch normalises the annotation layer's empty label list to all-nil).
    ///
    /// `subject` names the declaration kind for diagnostics ("'f'", "foreign
    /// 'f'", "trait default 'f'", "method 'f'").
    private static func resolveReturnType(
        _ decl: FuncDecl,
        userTypes: [String: HIRType],
        subject: String
    ) throws -> HIRType? {
        func resolve(_ annotation: TypeAnnotation) throws -> HIRType {
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
            // G2: the declared component names ride along. `-> (商: I32, 余:
            // I32,)` is not decoration — the interpreter relabels the returned
            // value from `decl.returnLabels` at the function boundary, the
            // executor does the same off this type, and the emitter prints a
            // tuple's labels straight from the type it was handed. Dropping
            // them here un-names the value on *both* HIR arms while the AST
            // engine keeps the names: measured, `print(r)` gave `[3, 2]` on
            // both arms and `[商: 3, 余: 2]` on the reference.
            //
            // Only a genuinely named signature switches this on. A positional
            // multi-return keeps the all-nil list it had before, which matters
            // because `HIRType(from: annotation)` reads an *empty* label list
            // as "positional" and expands it to all-nil.
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

    /// Lower one struct/object declaration: field defaults via a scratch
    /// context, methods as self-parameterized HIRFunctions with IR names
    /// `方法__类型` (double-underscore separator cannot collide with
    /// mangle output, which never emits underscores for ASCII names).
    private static func lowerNominal(
        name: String,
        isObject: Bool,
        fields: [FieldDecl],
        methods: [FuncDecl],
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: HIRType],
        enums: [String: HIREnumDecl],
        genericEnums: HIRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> HIRTypeDecl {
        let selfType = HIRType.nominal(name: name, isObject: isObject)
        var scratch = FunctionContext(
            functionName: "<field-default:\(name)>", returnType: nil, paramTypes: [:],
            typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes,
            userTypes: userTypes, enums: enums, genericEnums: genericEnums, closureIds: closureIds
        )
        var loweredFields: [HIRTypeDecl.Field] = []
        for field in fields {
            guard let fieldType = resolveAnnotationType(field.typeAnnotation, userTypes: userTypes) else {
                throw unsupported(
                    "field '\(field.name)' of '\(name)' lacks a resolvable type",
                    at: field.location
                )
            }
            var defaultValue: HIRExpr? = nil
            if let initializer = field.initializer {
                let lowered = try lowerExpr(initializer, expected: fieldType, into: &scratch)
                try requireAssignable(lowered.type, to: fieldType, at: field.location)
                defaultValue = lowered.node
            }
            loweredFields.append(HIRTypeDecl.Field(name: field.name, type: fieldType, defaultValue: defaultValue))
        }
        var loweredMethods: [HIRFunction] = []
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
        return HIRTypeDecl(name: name, isObject: isObject, fields: loweredFields, methods: loweredMethods)
    }

    /// Lower one method: IR name `方法__类型`, params = [self] + declared.
    private static func lowerMethod(
        _ decl: FuncDecl,
        typeName: String,
        selfType: HIRType,
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: HIRType],
        enums: [String: HIREnumDecl],
        genericEnums: HIRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> HIRFunction {
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
        // G13 batch 2: a void-declared method whose body returns a value
        // (package-demo corpus documents the interpreter flows it out)
        // upgrades to the effective return type — body returns and call
        // sites both use it.
        let effectiveReturn =
            try effectiveReturnType(
                decl: decl, userTypes: userTypes, nominals: nominalTypes,
                selfTypeName: typeName
            ) ?? returnType
        var params = [HIRFunction.HIRParam(name: "self", type: selfType)]
        // The receiver may also be written as an explicit leading `self`
        // parameter (trait default bodies are written that way). It is the
        // receiver marker rather than a parameter: the interpreter, the type
        // checker and the trait signature pre-pass all drop it. Lowering it
        // as an ordinary parameter made it look like an unannotated one.
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
            params.append(HIRFunction.HIRParam(name: param.name, type: type, isUsing: param.isUsing))
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
        // G12: bare field names resolve against the receiver's fields inside
        // method bodies (interpreter bindInstanceFields parity — trait.pini's
        // default body reads `名字` without a `self.` prefix). Emission goes
        // through an explicit self load + fieldGet at the identifier site.
        if case .nominal(let selfTypeName, let selfIsObject) = selfType,
            let info = nominalTypes[selfTypeName]
        {
            var fieldTypes: [String: HIRType] = [:]
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
        return HIRFunction(
            name: irName, params: params, returnType: effectiveReturn, body: body,
            sourceFile: decl.location.fileName, givenReferenceNames: context.givenReferenceNames)
    }

    private static func lowerBlock(
        _ block: Block,
        into context: inout FunctionContext
    ) throws -> HIRBlock {
        var statements: [HIRStmt] = []
        var positions: [SourceLocation] = []
        for statement in block.statements {
            let lowered = try lowerStatement(statement, into: &context)
            statements.append(contentsOf: lowered)
            // P4-3: every statement this source statement lowered to carries
            // that statement's own position. One `Block` statement can expand
            // into several HIR statements (a try-else variable initializer
            // yields the allocation plus the try), and all of them are *this*
            // line — which is what the interpreter reports for the same code.
            let location = statement.location
            positions.append(contentsOf: Array(repeating: location, count: lowered.count))
        }
        return HIRBlock(statements, positions: positions)
    }

    // MARK: - Statements

    /// Returns the lowered statements for one source statement. Most cases
    /// produce exactly one; a try-else variable initializer produces the
    /// allocation plus the try statement.
    private static func lowerStatement(
        _ statement: Statement,
        into context: inout FunctionContext
    ) throws -> [HIRStmt] {
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
                        value: loweredValue.node, fieldType: fieldType
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
            return [.storeVar(name: name, type: varType, value: lowered.node)]

        case .returnStatement(let value, let location):
            if let value = value {
                // A bare error binding (`return err` in a handler, the `^e`
                // sugar shape): the interpreter flows the RAW error payload
                // out (a type hole — issue-try-else-raw-err-return-2026-09-08).
                // Void functions drop the value (interpreter-faithful: silent
                // return); non-void returns are gated — the type-erased err
                // word cannot flow out as a typed payload without guessing.
                if case .identifier(let name, _) = value, context.errorBindings.contains(name) {
                    if context.returnType == nil {
                        return [.returnStmt(value: nil)]
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
                return [.returnStmt(value: lowered.node)]
            }
            guard context.returnType == nil else {
                throw unsupported(
                    "bare return from non-void function '\(context.functionName)'",
                    at: location
                )
            }
            return [.returnStmt(value: nil)]

        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, _):
            let cond = try lowerExpr(condition, expected: .boolean, into: &context)
            guard cond.type == .boolean else {
                throw unsupported("if condition is not Bool", at: conditionLocation(condition))
            }
            // 标签 break 定向范围: a labeled `if` is an interruptible frame, so `break 标签`
            // may leave the block. It is not a `continue` target (`isLoop:
            // false`). The frame covers every branch — `then`, each `elif` and
            // `else` — because the AST channel's `executeIf` wraps the whole of
            // `executeIfBody` in its catch.
            if let label = label {
                context.controlFrames.append(ControlFrame(label: label, isLoop: false))
            }
            defer { if label != nil { context.controlFrames.removeLast() } }
            let thenBody = try lowerBlock(thenBlock, into: &context)
            // Elif chains lower to nested ifs (tree shape keeps them structural).
            // The chain is nested *inside* this frame and therefore carries no
            // label of its own: `break label` in an `elif` body leaves the whole
            // `if`, which is where `executeIf`'s catch sits.
            var chain: HIRBlock? = nil
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
            // Unresolvable target: fail-loud at run time, exactly like the
            // interpreter (the signal escapes past every frame and errors at
            // the top level). Lowering it hard here would reject programs the
            // interpreter accepts. "Unresolvable" means no enclosing
            // interruptible frame carries the label — a labeled `if` counts
            // (标签 break 定向范围), so this set is narrower than it was before that ADR.
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
            // G9: defer runs at the enclosing block scope's normal end,
            // LIFO across the defers of that scope (emitter block protocol).
            //
            // G-2f: `defer:` with an indented body parses as a *scoped block*,
            // not as a single statement, so lowering the wrapped statement
            // reached the catch-all and reported "statement 'scoped block'".
            // The body is what has to be deferred, and it is a real block --
            // it carries its own positions -- so it lowers through lowerBlock
            // rather than statement by statement.
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
                let baseOp = HIRBinaryOp(compound: op)
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
            // expression statement so HIRStmt stays total without a new case.
            return [.exprStmt(.intConst(value: 0, type: .i32))]

        case .captureStatement(let name, _):
            // G6: marker only — the capture set is resolved at the enclosing
            // closure literal's creation point (free-variable analysis); the
            // statement itself carries no runtime effect.
            return [.captureMarker(name: name)]

        case .detachStatement(let expr, _):
            // `detach <expr>` (G-3c-1): evaluate the operand and prune the task
            // it yields from its parent, so the parent's return no longer cancels
            // it — fire-and-forget's only sanctioned exit.
            //
            // A non-future operand is refused by the engine at run time, not
            // here: the interpreter reports the same condition from its own
            // detach arm, so a lowering-time refusal would be the earlier of
            // the two rather than the equal one.
            let inner = try lowerExpr(expr, expected: nil, into: &context)
            return [.detachStmt(inner: inner.node)]

        default:
            throw unsupported(
                "statement '\(statement.kindName)' is not yet lowered to HIR",
                at: statementLocation(statement)
            )
        }
    }

    /// G15: lower `for (pattern,) in iterable: body [step:]`. The iterable is
    /// lowered once; its HIR type decides the container kind and the
    /// per-field element types, which must line up with the pattern arity
    /// (`_` placeholders included — the interpreter requires an exact
    /// field-count match, decomposePatternRow).
    private static func lowerForIn(
        pattern: [String],
        iterable: Expression,
        body: Block,
        step: Block?,
        label: String?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> HIRStmt {
        let lowered = try lowerExpr(iterable, expected: nil, into: &context)
        let kind: HIRForIterableKind
        let elementTypes: [HIRType]
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
        for (position, name) in pattern.enumerated() where name != "_" {
            context.variableTypes[name] = elementTypes[position]
        }
        defer {
            for (index, name) in boundNames.enumerated() {
                context.variableTypes[name] = previousTypes[index]
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

    /// Resolve a break/continue to its unwind depth (标签语法反转 labeled control
    /// flow, widened by 标签 break 定向范围). Depth counts **frames unwound from the
    /// innermost one, target included**, so it doubles as the number of
    /// `depth - 1` decrements the signal makes on its way out.
    ///
    /// An unlabeled signal targets the innermost **loop**, not the innermost
    /// frame: a labeled `if` on the way out is stepped over, because on the
    /// AST channel the signal arrives there as `nil != label` and is rethrown
    /// unchanged. Unresolvable targets (no frame of the required kind, no
    /// matching label) return `nil` — the caller lowers those to a runtime
    /// panic, matching the interpreter's escape-to-top-level error.
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
    ) throws -> [HIRStmt] {
        // `var m = ++n`: the initializer writes back to n and yields the value
        // it wrote, so the statement expands to the write followed by the
        // allocation that consumes it (G-2c). The written value is I32, which
        // is the only target type `lowerIncDec` accepts.
        if case .unary(let op, let target, let unaryLocation)? = initializer,
            op == .increment || op == .decrement
        {
            if let annotation = annotation {
                guard HIRType(from: annotation) == .i32 else {
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
            return [
                lowered.statement,
                .allocVar(
                    name: name, type: lowered.type, mutable: isMutable,
                    initializer: lowered.value
                ),
            ]
        }
        // `let x = try f() else ...`: the try unwraps the ok payload into x,
        // so x's type is the Result's payload type, not a Result itself.
        if case .tryExpression(let operand, let errorVar, let handler, _) = initializer {
            if let annotation = annotation {
                guard let declared = HIRType(from: annotation), !isResultAnnotation(annotation) else {
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
            let alloc = HIRStmt.allocVar(name: name, type: okType, mutable: isMutable, initializer: nil)
            let tryStmt = try lowerTry(
                operand: operand, errorVar: errorVar, handler: handler,
                okTarget: name, at: location, into: &context
            )
            context.variableTypes[name] = okType
            return [alloc, tryStmt]
        }

        let declaredType: HIRType?
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
                let type = HIRType(from: inferred)
            {
                declaredType = type
            } else {
                // Checker inference miss (collection literals, checker-untracked
                // identifiers): derive the type by lowering the initializer
                // without an expectation — same fallback contract as the
                // legacy codegen (G2). The result is discarded; the real
                // lowering below re-lowers with the resolved expectation.
                declaredType = try lowerExpr(initializer, expected: nil, into: &context).type
            }
        } else {
            throw unsupported(
                "variable '\(name)' has neither annotation nor initializer",
                at: location
            )
        }
        let varType = declaredType!
        let loweredInit: HIRExpr?
        var initializerType: HIRType?
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
        return [
            .allocVar(
                name: name,
                type: slotType(declared: varType, initializer: initializerType),
                mutable: isMutable,
                initializer: loweredInit
            )
        ]
    }

    /// The type a binding's slot actually stores.
    ///
    /// The interpreter attaches tuple component names at exactly two points:
    /// an explicit `return` (the engine mirrors it at its own return site, fed
    /// from the declared return type), and an explicit tuple annotation on a
    /// binding (`applyTypeAnnotationLabels`). A declaration that names no more
    /// than the initializer's type already names is therefore the annotation
    /// case only when it names *something else* — a named declaration sitting
    /// over an initializer of the very same named type adds nothing, and the
    /// engine's binding-site relabel (which fires on a slot type that names a
    /// component) must not fire on it.
    ///
    /// "Do not relabel" is encoded as an all-`nil` label list rather than an
    /// empty one: the arity of the label list is load-bearing for the emitter's
    /// tuple rendering, so the field count is preserved and only the names go.
    ///
    /// The case that makes this observable: a function whose declared return
    /// type is a named tuple, entered through its implicit trailing
    /// expression. The interpreter's implicit path returns the last value
    /// untouched — it relabels on the `return` statement only — so an inferred
    /// binding over such a call holds an unlabelled value, even though the
    /// call's static type is labelled.
    ///
    /// A positional annotation over an initializer of the same arity but a
    /// named type (`let t: (I32, I32,) = namedCall()`) keeps the declared
    /// names, which is the one shape where this test and the interpreter's
    /// syntactic rule can disagree — registered as an open issue (tuple label
    /// binding rule, 2026-09-13) rather than papered over here.
    private static func slotType(declared: HIRType, initializer: HIRType?) -> HIRType {
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

    /// Lower `let (a, b) = tupleExpr` (M6a D7).
    ///
    /// Interpreter semantics: evaluate the initializer ONCE, require a tuple,
    /// require the name count to equal the arity, then bind each non-`_` name.
    /// Lowering mirrors that literally — the initializer goes into a synthetic
    /// slot (so a call with side effects still runs exactly once) and each name
    /// is bound to an extractvalue off that slot. `_` placeholders still occupy
    /// a position but bind nothing, matching the interpreter's
    /// `where name != "_"` filter. A destructure with no static tuple shape is
    /// not resolvable here (the interpreter's arity error is a run-time one).
    private static func lowerVarDestructure(
        names: [String],
        initializer: Expression?,
        isMutable: Bool,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [HIRStmt] {
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
        var statements: [HIRStmt] = [
            .allocVar(name: tempName, type: lowered.type, mutable: false, initializer: lowered.node)
        ]
        let base = HIRExpr.load(name: tempName, type: lowered.type)
        for (index, name) in names.enumerated() where name != "_" {
            context.variableTypes[name] = fieldTypes[index]
            let element = HIRExpr.tupleIndexGet(
                base: base, index: index, type: fieldTypes[index]
            )
            statements.append(
                .allocVar(name: name, type: fieldTypes[index], mutable: isMutable, initializer: element)
            )
        }
        return statements
    }

    // MARK: - Try-else (try-else 迁移, G1)

    /// The static Result type of a try operand: annotation-derived when
    /// resolvable, otherwise via the checker's inference (Result -> params[0]).
    private static func resultType(of operand: Expression, into context: FunctionContext) throws -> HIRType {
        if let inferred = context.inferType(of: operand), let type = HIRType(from: inferred) {
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

    /// Lower `try operand else errorVar: handler`.
    ///
    /// Error binding: the ABI type-erases the err slot to a machine word
    /// (LR-12 — Pini's `^T` surface leaves E unconstrained, so no static err
    /// type exists), so the bound name carries type i64. The binding scopes
    /// to the handler only; shadowing an existing variable is rejected this
    /// grid. Handler statements are restricted to return/pass (break/continue
    /// need the labeled-control-flow grid); expression position (okTarget)
    /// additionally requires the handler to end in return.
    private static func lowerTry(
        operand: Expression,
        errorVar: String,
        handler: Block,
        okTarget: String?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> HIRStmt {
        // A bare `ok(x)` / `err(x)` operand has no expected Result type to
        // adopt: Pini's `^T` surface constrains neither half, so the general
        // `ok`/`err` rule (which reads the expectation) has nothing to read.
        // The two halves are not equally knowable, though -- `ok`'s payload
        // fixes the ok half outright -- so the operand is built here with that
        // type rather than being sent through the expectation channel.
        //
        // For `err` no ok type exists at all. I32 stands in, which is the same
        // device `pass` uses to stay total without a node of its own: the ok
        // half of a literal `err(...)` operand is unreachable (the handler owns
        // control flow, and statement position is the only place this shape
        // reaches), so the stand-in never carries a value.
        let loweredOperand: LoweredExpr
        if case .call(let callee, let arguments, _) = operand,
            case .identifier(let calleeName, _) = callee,
            calleeName == "ok" || calleeName == "err",
            arguments.count == 1
        {
            let payload = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
            let resultType = HIRType.result(ok: calleeName == "ok" ? payload.type : .i32)
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

        var handlerStmts: [HIRStmt] = []
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
        expected: HIRType?,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        switch expression {
        case .integerLiteral(let value, _):
            // Int literals adopt the expected numeric type (I32 by default),
            // mirroring how the checker treats untyped integer literals.
            let type = (expected?.isNumeric == true) ? expected! : .i32
            return LoweredExpr(node: .intConst(value: value, type: type), type: type)

        case .floatLiteral(let value, _):
            // Declaration width alignment (the legacy emitter's convertNumeric
            // contract): a float literal sitting in an integer-typed slot
            // folds to the truncated integer constant — the constant form of
            // the legacy `fptosi`. Out-of-range or non-finite literals fall
            // through to the float path, where requireAssignable reports the
            // mismatch as an ordinary gate error instead of trapping here.
            // Non-literal float expressions in integer slots stay fail-loud.
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
            // G9: each expression part goes through the value display
            // pipeline at emission (stringify parity, interpreter channel).
            var parts: [HIRExpr] = []
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
            // Array subscript read (G2): safe-assert channel — out of bounds
            // panics at runtime, matching the interpreter. String subscript
            // read (G2b) yields the single character as a String, same
            // panic channel. Negative indices tail-count in both. The
            // tolerant `.get` channel (Optional) is the member-call path.
            let loweredContainer = try lowerExpr(container, expected: nil, into: &context)
            let elementType: HIRType
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
            let indexExpectation: HIRType?
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
            // G12: bare field name inside a method body (interpreter
            // bindInstanceFields parity) — lower as `self.<field>`.
            if let fieldType = context.selfFieldTypes[name] {
                let selfType = HIRType.nominal(
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
                let type = HIRType.function(params: signature.paramTypes, returnType: signature.returnType, usingIndices: signature.usingParamIndices)
                return LoweredExpr(node: .functionValue(functionName: name, type: type), type: type)
            }
            throw unsupported("reference to undeclared variable '\(name)'", at: location)

        case .binary(let left, let op, let right, let location):
            guard let hirOp = HIRBinaryOp(from: op) else {
                throw unsupported(
                    "binary operator '\(op)' is not yet lowered to HIR",
                    at: location
                )
            }
            // Comparison operands are lowered without scalar expectation;
            // arithmetic operands adopt the expected numeric type.
            let operandExpectation: HIRType? = hirOp.isComparison ? nil : expected
            let lhs = try lowerExpr(left, expected: operandExpectation, into: &context)
            let rhs = try lowerExpr(right, expected: lhs.type, into: &context)
            if hirOp.isComparison {
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
                    node: .binary(op: hirOp, lhs: lhs.node, rhs: rhs.node, type: .boolean),
                    type: .boolean
                )
            }
            // String concatenation `s1 + s2` (G9): defer semantics build
            // strings incrementally; concat joins the two C strings.
            // G68（P0d-D）：判据从「两侧都是 `.string`」放宽为「两侧都是**字符串面**」
            // —— `Char` 与 `String` 表示同构（都是 `i8*`），拼接语义完全相同，
            // 而结果类型取 `String`（`c + c` 是两个字节，不再是单个字素）。
            if hirOp == .add, lhs.type.isStringFaced, rhs.type.isStringFaced {
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
                node: .binary(op: hirOp, lhs: lhs.node, rhs: rhs.node, type: lhs.type),
                type: lhs.type
            )

        case .unary(let op, let operand, let location):
            // Prefix `++`/`--` are read-modify-write on an assignable target
            // and yield the value they wrote. A store cannot live inside an
            // expression node (the HIR declares none), so statement position
            // lowers them — see `lowerIncDec`. Reaching here means an
            // expression position the read-modify-write shape does not cover.
            if op == .increment || op == .decrement {
                throw unsupported(
                    "prefix '\(op)' outside statement or variable-initializer position",
                    at: location
                )
            }
            // `+v` is the numeric identity: the interpreter's single-source
            // `unaryValue` hands back the operand unchanged, so this lowers to
            // the operand itself rather than to a node of its own. The guard
            // keeps the rejection the interpreter raises for non-numbers.
            if op == .plus {
                let identity = try lowerExpr(operand, expected: nil, into: &context)
                guard identity.type.isNumeric else {
                    throw unsupported("unary plus on non-numeric operand", at: location)
                }
                return identity
            }
            let hirOp: HIRUnaryOp
            switch op {
            case .minus: hirOp = .negate
            case .logicalNot, .not: hirOp = .logicalNot
            case .bitwiseNot: hirOp = .bitwiseNot
            default:
                throw unsupported("unary operator '\(op)' is not yet lowered to HIR", at: location)
            }
            let lowered = try lowerExpr(operand, expected: nil, into: &context)
            switch hirOp {
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
                fatalError("HIRLowerer: .abs outside the abs intrinsic handler")
            }

        case .selfKeyword(let location):
            // Methods carry self as their first HIR param (G3).
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
            // Nominal field read (G3): `base.field` / `self.field`.
            // Tuple label read (G5 minimal slice): extractvalue by index.
            let loweredBase = try lowerExpr(object, expected: nil, into: &context)
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
            // `.0` positional read (M6a D7): the numeric counterpart of the
            // labelled member read above — same extractvalue node, index taken
            // from the syntax instead of a label lookup. The interpreter
            // resolves out-of-range indices by raising a runtime error; a
            // statically known index outside the arity is unresolvable at
            // lowering time, so it fails loud here.
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
            // G13 batch 1: `LazyRef<T>(closure)` — built-in lazy reference,
            // not a user generic template. Checked before the template
            // dispatch so a user `LazyRef` template cannot shadow it
            // (parity with the legacy emitter's builtin-first contract).
            if typeName == "LazyRef" {
                guard typeArgs.count == 1, let element = HIRType(from: typeArgs[0]) else {
                    throw unsupported("LazyRef requires 1 resolvable type arg", at: location)
                }
                guard arguments.count == 1 else {
                    throw unsupported("LazyRef requires 1 argument (initializer closure)", at: location)
                }
                let loweredClosure = try lowerExpr(arguments[0].expression, expected: nil, into: &context)
                guard case .function = loweredClosure.type else {
                    throw unsupported("LazyRef argument must be an initializer closure", at: location)
                }
                let type = HIRType.lazyRef(element: element)
                return LoweredExpr(
                    node: .lazyRefConstruct(closure: loweredClosure.node, type: type),
                    type: type
                )
            }
            // G10 monomorphization call site: `盒<I32>()` (struct template ->
            // nominal construction of the specialized instance) or
            // `身份<I32>(x = 100)` (function template -> call to the
            // pre-registered specialization). The pre-pass has already
            // registered both; here we only dispatch.
            if let template = context.genericFuncTemplates[typeName] {
                return try lowerGenericFuncCall(
                    template: template, typeArgs: typeArgs, arguments: arguments,
                    at: location, into: &context
                )
            }
            // G-2d: generic enum case construction — the bare spelling, where
            // the case name carries the type arguments (`ok<I32, String>(42)`,
            // 泛型枚举构造形态). Neither template table above holds a case name, which
            // is why this is where it lands.
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
                let type = HIRType.nominal(name: specializedName, isObject: info.isObject)
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
            // G5: dict literal — key/value types derived from the lowered
            // first entry (homogeneity required, checker does not infer).
            var loweredEntries: [HIRDictEntry] = []
            var keyType: HIRType? = nil
            var valueType: HIRType? = nil
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
                loweredEntries.append(HIRDictEntry(key: loweredKey.node, value: loweredValue.node))
            }
            guard let key = keyType, let value = valueType else {
                throw unsupported("empty dictionary literal needs an entry (annotate the variable)", at: location)
            }
            let dictType = HIRType.dict(key: key, value: value)
            return LoweredExpr(node: .dictLiteral(entries: loweredEntries, type: dictType), type: dictType)

        case .setLiteral(let elements, let location):
            var loweredElements: [HIRExpr] = []
            var elementType: HIRType? = nil
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
            let setType = HIRType.set(element: resolvedElement)
            return LoweredExpr(node: .setLiteral(elements: loweredElements, type: setType), type: setType)

        case .tuple(let labels, let elements, let location):
            var loweredElements: [HIRExpr] = []
            var fieldTypes: [HIRType] = []
            for element in elements {
                let lowered = try lowerExpr(element, expected: nil, into: &context)
                loweredElements.append(lowered.node)
                fieldTypes.append(lowered.type)
            }
            let tupleType = HIRType.tuple(labels: labels, fieldTypes: fieldTypes)
            return LoweredExpr(node: .tupleConstruct(labels: labels, elements: loweredElements, type: tupleType), type: tupleType)

        case .call(let callee, let arguments, let location):
            // Member calls: the tolerant read channel `arr.get(i)` (G2) and
            // the slice channel `base.slice(start, end)` (G2b, the slice-
            // sugar desugaring). All other method calls stay gated.
            // Dot-case construction `.Case(args)` (G4, proposal-dot-case-
            // construction): member-intent marker resolved by unique case
            // name or the checker's expected-type registry.
            // `.none` / `.some` resolve to the built-in Optional first.
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
                    let type = HIRType.optional(wrapped: loweredPayload.type)
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
            // G-2d: the qualified generic enum case construction
            // (`结果<I32, String>.ok(42)`, 泛型枚举构造形态) reaches here as a member
            // call whose receiver is the *no-argument* generic construct: the
            // qualifier names the enum, so both the parent and the type
            // arguments are written down rather than inferred. An empty
            // argument list is what separates it from a member access on a
            // generic value, which this slice does not lower anyway.
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
                // The value re-lowers against the pointer's element type so
                // untyped literals adopt it (store(p, 42) on *U8 → u8).
                // A declared-typed value keeps its own type — the encode
                // semantics are truncating (interpreter parity: store of an
                // I32 into *U8 writes the low byte).
                let value = try lowerExpr(arguments[1].expression, expected: element, into: &context)
                return LoweredExpr(
                    node: .pointerStore(pointer: loweredArgs[0].node, value: value.node, type: element),
                    type: .i32
                )
            }
            // Intrinsic assert (G41 surface, needed by |test blocks in the
            // FFI corpus): assert(cond) / assert(cond, message). The cond
            // must be boolean; false traps via the runtime's panic path —
            // a failing assert is outside the differential baseline anyway
            // (assert only fires in test blocks, which the harness never
            // runs, but the lowering must still exist).
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
            // Intrinsic print: single-argument form keeps the existing
            // gates; the multi-argument form (G14, D-A=A1) joins the
            // stringified arguments with spaces on one line — no Result /
            // nominal gates there yet (the FFI corpus only prints scalars,
            // strings, and pointers).
            if functionName == "print" {
                // The zero-argument form is a bare newline: the interpreter
                // joins an empty argument list and hands the empty string to
                // the sink, and `printMulti` with no arguments does the same.
                if loweredArgs.isEmpty {
                    return LoweredExpr(node: .printMulti(arguments: []), type: .i32)
                }
                if loweredArgs.count == 1 {
                    if case .load(let name, _) = loweredArgs[0].node, context.errorBindings.contains(name) {
                        throw unsupported(
                            "printing an error binding is not supported by the LLVM Result ABI this grid (the err slot is type-erased)",
                            at: location
                        )
                    }
                    if case .result = loweredArgs[0].type {
                        throw unsupported("printing a Result value is outside the slice", at: location)
                    }
                    return LoweredExpr(node: .printCall(argument: loweredArgs[0].node), type: .i32)
                }
                return LoweredExpr(node: .printMulti(arguments: loweredArgs.map { $0.node }), type: .i32)
            }
            // P4-1b: 宿主环境查询内建。二者零参、由**执行器**按名回答，故降成同形的 `call`
            //（与 `print` 一样不需要新节点）；解释器侧同名内建即镜像源
            //（`argv` → 参数字符串数组；`moduleRoot` → 程序基准的绝对路径）。
            // ⚠️ LLVM 侧尚未实现（须新增运行时段），发射器对它 fail-loud，见在册工单。
            if functionName == "argv" || functionName == "moduleRoot" {
                guard loweredArgs.isEmpty else {
                    throw unsupported("\(functionName) takes no arguments", at: location)
                }
                let queryType: HIRType =
                    functionName == "argv"
                    ? .array(element: .string)
                    : .string
                return LoweredExpr(
                    node: .call(function: functionName, arguments: [], returnType: queryType),
                    type: queryType
                )
            }
            // Intrinsic sqrt (G3): libc math, F64 only — the struct.pini
            // corpus dependency. Other math intrinsics join their own grid.
            // G-2a: the character builtins. Same shape as the other intrinsics --
            // lowered to a `call` the executor answers by name -- and the name
            // whitelist is the table itself, so a builtin cannot be lowered here
            // and then go unanswered there.
            if RuntimeOps.characterBuiltins[functionName] != nil {
                guard loweredArgs.count == 1 else {
                    throw unsupported("\(functionName) expects exactly one argument", at: location)
                }
                let resultType: HIRType
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

            // G-3a: the concurrency builtins a plain call can carry -- `sleep`
            // blocks, `Error` / `CancelError` build a value. Same shape as the
            // character builtins above, and the same rule that the whitelist is the
            // table: a name cannot be lowered on this side and go unanswered by the
            // executor.
            //
            // The names that traffic in `Future` values (`joinAll`, `joinWithin`,
            // `isCancel`) stay out. The HIR has no representation for a Future yet,
            // so lowering them would accept an argument the channel cannot produce.
            if RuntimeOps.concurrencyBuiltins[functionName] != nil {
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
                let errorType = HIRType.nominal(name: functionName, isObject: false)
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: errorType),
                    type: errorType
                )
            }
            // G-3c-1: the Future-valued concurrency builtins. They stay out of
            // the shared builtin table because answering them needs a scheduler
            // and a task context, which a stateless table cannot carry — the two
            // sides match the names side by side instead, and both read the same
            // rule.
            //
            // The HIR denotes a Future by the `Result<T>` an async call already
            // returns (G-3b): the value is a future at run time, the type on the
            // node is what its join will yield.
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
                let aggregated = HIRType.result(ok: .array(element: element))
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
                let bounded = loweredArgs[0].type
                return LoweredExpr(
                    node: .call(
                        function: functionName,
                        arguments: loweredArgs.map { $0.node },
                        returnType: bounded),
                    type: bounded
                )
            }
            // G-2R: `F64(x)` -- the numeric value constructor. The AST channel
            // has answered it since G-P1 and the lowering layer never did, so
            // `F64(3)` was "an unknown function". A float passes through, an
            // integer widens through one `call` the executor answers by name
            // (the same shape the character builtins use); anything else is
            // refused here, matching the runtime's own refusal.
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
            // G-2R: `LazyRef(closure)` -- the inferred spelling (the G40 D1
            // sugar), sibling of the `LazyRef<T>(closure)` form the
            // generic-construct arm already lowers. "Inferred" here means the
            // element type is read off the initialiser closure's own return
            // type; a closure whose return type cannot be read is refused
            // rather than guessed.
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
                let type = HIRType.lazyRef(element: element)
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
            // Math intrinsics (G9, stdlib.pini corpus): sin/cos via llvm
            // intrinsics, tan = sin/cos (legacy parity), abs/min/max on I32.
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
            // File IO intrinsics (G15): writeFile/readFile. Absolute and
            // relative literal paths both lower as-is — the legacy emitter's
            // programBase baking only matters when the harness changes CWD,
            // and the IO corpus uses absolute paths.
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
            if functionName == "readFile" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("readFile expects (path)", at: location)
                }
                guard loweredArgs[0].type == .string else {
                    throw unsupported("readFile expects a String path", at: location)
                }
                return LoweredExpr(node: .fileRead(path: loweredArgs[0].node), type: .string)
            }
            // G17: the two remaining corpus builtins below the intrinsic
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
            // Result case construction (ok/err): requires a Result-typed
            // context (return position, Result-typed assignment) so the
            // static Result type is known — Pini's `^T` surface leaves the
            // error type unconstrained, so `err(e)` adopts the context.
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
            // Indirect call through a function value (G6): the callee is a
            // variable holding a closure / named-function value (function-
            // typed parameter `f(x)` or closure variable `sq(6)`). Named
            // top-level functions resolve through the signature table below;
            // a bare `加倍(x)` call never reaches this branch.
            // ADR-001 §2.6：**经变量**调用拿得到取用位（它随函数类型走）⇒
            // 按两式判 arity，并在省略式下于取用位插入取用点。
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
            // Direct call on an immediate closure literal `sq(6)` where sq
            // was just created inline — `f(...)` with a funcLiteral callee.
            // ADR-001 §2.6：内联字面量的取用位**就在声明里**（比经变量更直接）。
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
                let type = HIRType.nominal(name: functionName, isObject: info.isObject)
                return LoweredExpr(node: .construct(type: type), type: type)
            }
            guard let signature = context.moduleSignatures[functionName] else {
                throw unsupported(
                    "call to unknown function '\(functionName)' (intrinsics beyond print are later grids)",
                    at: location
                )
            }
            // G14: lower arguments with each parameter type as the expected
            // context so untyped integer literals adopt non-I32 parameter
            // slots (U64 param → literal 64 is u64) — mirroring the checker's
            // ADR-001 `P2b`：`using` 形参的实参可由编译器插入 ⇒ 先问「实参对哪些形参位」，
            // 再逐位降载；`using` 位在填充阶段补取用点。
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

        case .tryExpression(_, _, _, let location):
            throw unsupported(
                "try-else is only supported as a statement or a variable initializer this grid",
                at: location
            )

        case .funcLiteral(let decl, let location):
            return try lowerFuncLiteral(decl: decl, expected: expected, at: location, into: &context)

        case .unsafe(let operand, _):
            // G11 multidim corpus: the zero-scatter `unsafe (...)` context
            // marker is a parse/check-level concept only — the wrapped
            // expression lowers identically (the safe-assert subscript
            // channel needs no unsafe distinction at emission).
            return try lowerExpr(operand, expected: expected, into: &context)

        case .addressOf(let operand, let location):
            // G14 (D-B adjudication: true pointer semantics): `&x` yields
            // the variable's storage address. Only the identifier form is
            // in the corpus slice — `&expr.value` and friends are later
            // grids. The pointer element type mirrors the variable's type
            // (the interpreter labels the snapshot with the value's type).
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

        case .join(let inner, _):
            // `await f` / `wait f` (G-3c-1). The operand evaluates to a Future and
            // the site yields the `Result<T>` its join deconstructs — the very
            // type G-3b already puts on an async call's return, so nothing here
            // has to denote a future and no HIR type case had to be added: the
            // shape rides on the call node and the join site carries it through.
            //
            // The operand is lowered with no expectation, not with a Result
            // expectation: an operand that is *not* a future is a run-time type
            // mismatch on the other engine too (its join arm guards the same
            // way), so refusing it here would move the error earlier than the
            // channel it is being kept equal to.
            let future = try lowerExpr(inner, expected: nil, into: &context)
            return LoweredExpr(
                node: .join(future: future.node, type: future.type),
                type: future.type
            )

        default:
            throw unsupported(
                "expression '\(expression.kindName)' is not yet lowered to HIR",
                at: expressionLocation(expression)
            )
        }
    }

    // MARK: - Closures / higher-order functions (G6)

    /// Collect funcLiteral ids in source order (module pre-pass). Mirrors the
    /// legacy registry: every literal gets a stable id keyed by "行:列", even
    /// nested ones — traversal must not descend into funcLiteral bodies for
    /// id assignment of the nested literal itself... it must: nested closure
    /// ids are assigned outer-first, inner-after (same contract as the legacy
    /// collector which visits the literal node then returns).
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

    /// Lower a `func` literal (G6): capture analysis at the creation point,
    /// body lowered with the closure's own scope (captures pre-seeded into
    /// variableTypes so free references resolve; `capture` marker statements
    /// inside the body drop out). The param types adopt the checker's G29
    /// fallback chain through the annotation mapping — an unannotated param
    /// falls back to the return annotation (single concrete return), then
    /// the expected function type, then I32 (matching the legacy emitter's
    /// final fallback).
    private static func lowerFuncLiteral(
        decl: FuncDecl,
        expected: HIRType?,
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

        // Resolve the literal's function type: the checker's inference
        // (G29 bidirectional: annotations > body inversion > expected >
        // return-annotation fallback > wildcard) mapped through the same
        // annotation conversion as declared signatures.
        let inferredAnnotation = context.inferType(of: .funcLiteral(decl: decl, location: location))
        let functionType: HIRType
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

        // Capture analysis (creation point): identifiers used in the body,
        // minus the literal's own params and block-declared vars, minus
        // function-typed references that are named top-level functions
        // (those become adapters at their use site, not captures). Captures
        // are reference-captured: the env field holds the variable's slot
        // pointer. Only variables visible in the creation-point scope are
        // captured (declared but out-of-scope names cannot occur through
        // the checker).
        let used = collectBodyIdentifiers(in: decl)
        let localBound = Set(decl.params.map { $0.name })
            .union(declaredLocalVars(in: decl.body?.statements ?? []))
        var captures: [HIRCapture] = []
        var captureIndex: [String: Int] = [:]
        for name in used.sorted() where !localBound.contains(name) {
            // Named top-level functions are function values, not captures
            // (their adapters are emitted at the use site).
            if context.moduleSignatures[name] != nil { continue }
            guard let type = context.variableTypes[name] else { continue }
            guard captureIndex[name] == nil else { continue }
            captureIndex[name] = captures.count
            captures.append(HIRCapture(name: name, type: type))
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

    /// Identifiers referenced by a closure body (including callee names);
    /// funcLiteral sub-expressions are opaque — their own captures are
    /// resolved at their own creation point (legacy collector contract).
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

    /// Resolve a case name to (enum decl, case) — exact qualified
    /// `Enum.case` first, then unique unqualified fallback; ambiguous
    /// unqualified names resolve through the checker's static registry
    /// (裸名 case 消歧（静态收敛版）: call-site location → parent enum) and are gated
    /// when unresolved.
    /// G-2d: a generic enum case construction in either spelling (泛型枚举构造形态).
    ///
    /// Returns nil when the spelling names no generic enum at all, so callers
    /// can fall through to their other paths. Once the spelling *is* a generic
    /// enum, a failure is an error rather than a fall-through: the pre-pass
    /// registers every use site it can see, so reaching here without a
    /// specialization means the site and the registration disagree.
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
            // The bare spelling resolves its parent by name alone (裸名 case 消歧（静态收敛版）'s
            // second tier), so two enums sharing a case name cannot be told
            // apart -- that is the tier-3 situation the qualified form exists
            // for, and the message has to say which spelling to write.
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
    ) throws -> (HIREnumDecl, HIREnumCase)? {
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
        let matches = context.enums.values.compactMap { enumDecl -> (HIREnumDecl, HIREnumCase)? in
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

    /// Enum case construction with associated values: positional or labeled
    /// (`text= "x"`) arguments, resolved against the case's parameter names.
    /// Missing arguments fall back to declared default expressions
    /// (legacy createInstance parity).
    private static func lowerEnumCaseConstructor(
        enumDecl: HIREnumDecl,
        enumCase: HIREnumCase,
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
        var payloads: [HIRExpr?] = Array(repeating: nil, count: enumCase.payloadTypes.count)
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
        var loweredPayloads: [HIRExpr] = []
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

    /// Member calls on built-in receivers. `.get(i)`: the tolerant read
    /// channel — out of bounds yields none (the language-level nil), in
    /// bounds some(value); negative indices tail-count (G2b fix: batch 3
    /// missed the tail count). `.slice(s, e)`: the slice-sugar desugaring;
    /// bounds are ints or the none literal. Only Array/String receivers are
    /// wired; Dictionary and other methods join their own grids.
    /// String member methods (G9): the five corpus surface forms. `split`
    /// produces a real `Array<String>` (interpreter parity — the legacy
    /// emitter renders a formatted string instead, a recorded divergence).
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
            let arrayType = HIRType.array(element: .string)
            return LoweredExpr(
                node: .stringSplit(receiver: receiver.node, delim: delim.node, type: arrayType),
                type: arrayType
            )
        default:
            throw unsupported("string method '\(memberName)' is outside this grid", at: location)
        }
    }

    /// P4-1c: 降低 `别名.符号(…)`。合并之后它本就是同一张表里的具名函数，
    /// 故形状与 `lowerCall` 的具名分支**逐字同构**（参数按签名逐个给期望类型）。
    private static func lowerModuleQualifiedCall(
        functionName: String,
        signature: HIRLowererSignatureInfo,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        // ADR-001 `P2b`：与具名分支同一份映射与填充助手（两条路径必须同口径，
        // 否则同一个函数经裸名与经别名调用会得到不同的实参个数）。
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

    /// H-3 三级派发的类型映射：内建接收者类型名 → `HIRType`。
    ///
    /// ⚠️ `Array` 在扩展块里不署名元素类型 ⇒ 取 i32 占位。这个值只用于**登记**
    /// 扩展方法（`lowerMethod` 需要一个 self 类型），调用点的接收者类型仍由实际
    /// 值决定 ⇒ 本批的对象不使用 self 的元素，占位不参与语义。
    private static func builtinReceiverType(named name: String) -> HIRType? {
        switch name {
        case "String": return .string
        case "Array": return .array(element: .i32)
        default: return nil
        }
    }

    /// 反向映射：接收者类型 → 内建类型名（查扩展方法表用）。
    private static func builtinReceiverName(of type: HIRType) -> String? {
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
        expected: HIRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        // P4-1c: 跨模块限定调用 `别名.符号(…)` —— receiver 是 import 别名、**不是变量**，
        // 故必须在 lower receiver 之前拦截（否则会按变量解析并报「未声明变量」）。
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
            let type = HIRType.optional(wrapped: loweredPayload.type)
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

        // H-3 三级派发的第一级：内建类型（`String` / `Array`）的**用户扩展方法**
        // 排在语言内标准库（下面那些按名硬编码的分支）与宿主原生之前。
        // 缺这一支时：新增方法会落到尾部兜底报「later grids」，覆盖同名成员则
        // 直接读到内建结果（用户实现被静默压过）。
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

        // String member methods (G9): upper/lower/contains/substring/split.
        // `slice`/`get` fall through to the G2/G2b tolerant-read channels.
        if case .string = objectType,
            ["upper", "lower", "contains", "substring", "split"].contains(memberName)
        {
            return try lowerStringMethod(
                receiver: loweredObject, memberName: memberName, arguments: arguments,
                at: location, into: &context
            )
        }
        // Array member methods (G9): join. G-2b lifted the `[String]`-only
        // restriction -- the node's own semantics are "stringify each element
        // and interpose the separator", which is what the interpreter's `join`
        // arm does to whatever the array holds, so the element type never had
        // to be a string.
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

        // Nominal method dispatch (G3): the receiver is the implicit first
        // argument; the callee is the mangled IR name `方法__类型`.
        // G12: when the nominal has no own/extension method of that name,
        // fall back to an implemented trait's default body, specialized to
        // the receiver type (legacy tryTraitMethodDispatch mirror).
        if case .nominal(let typeName, _) = objectType {
            let dispatchInfo = context.nominalTypes[typeName]
            if let method = dispatchInfo?.methods.first(where: { $0.name == memberName }) {
                // ADR-001 `P2b`：方法位与自由函数位同规 —— `using` 形参可省略，
                // 实参由编译器在该位插入默认实例取用。
                let methodParamTypes: [HIRType] = try method.params.map { parameter -> HIRType in
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
                // G13 batch 2: the call site uses the method's EFFECTIVE
                // return type (void-declared value-returning methods upgrade
                // to the body's returned type — same computation as the
                // definition side, so body and calls agree).
                let returnType =
                    try effectiveReturnType(
                        decl: method, userTypes: context.userTypes,
                        nominals: context.nominalTypesMap, selfTypeName: typeName
                    )
                    ?? method.returnTypes.first.map { annotation -> HIRType in
                        guard let type = HIRType(from: annotation) else {
                            throw unsupported(
                                "return type of '\(memberName)' is not resolvable",
                                at: location
                            )
                        }
                        return type
                    }
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
            // G12 trait-default fallback: own/extension method missed — walk
            // the receiver type's trait list for a default body of this name.
            // The default body is re-lowered with the receiver's nominal as
            // self (parity with the interpreter: own methods first, then
            // trait defaults; the body sees the receiver's fields).
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
            // G-2b: a dictionary's `.get` keys off any value the dictionary
            // accepts, so the index expectation follows the key type and the
            // I32 requirement is the Array/String arm's alone.
            let wrapped: HIRType
            let indexExpectation: HIRType?
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
            var loweredBounds: [HIRExpr] = []
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

        // G-2S: the rest of the Array member face the registry already lists
        // (`append` / `pop` in the collection trait, plus `last`). `get` and
        // `slice` above became dedicated nodes because they predate the frozen
        // contract; these three keep the node set at 60 by lowering to a named
        // call the executor answers -- the shape `argv` and the character
        // builtins already use. The types are the ones the runtime produces:
        // append yields a new array, last the element or null, pop the pair
        // (arrayWithoutLast, lastOrNull).
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
                let appended = HIRType.array(element: element)
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
                let found = HIRType.optional(wrapped: element)
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
                let pair = HIRType.tuple(
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

        // G-3c-1: `t.cancel()` — the one Future member the corpus reaches. The
        // receiver rides as the first argument, exactly as the array member face
        // above does, and the result is discarded (the interpreter's cancel
        // returns null).
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

    /// `match scrutinee: case name(binding): body ...` — the general case
    /// skeleton, with the Optional scrutinee wired this grid (some/none;
    /// `none` is the language-level nil, user adjudication D-G2-1). Literal
    /// / wildcard patterns and user enums join through the same node later.
    private static func lowerMatch(
        value: Expression,
        cases: [MatchCase],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> HIRStmt {
        let loweredValue = try lowerExpr(value, expected: nil, into: &context)
        switch loweredValue.type {
        case .optional(let wrapped):
            let hirCases = try lowerOptionalCases(cases, wrapped: wrapped, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
        case .enumeration(let enumName):
            guard let enumDecl = context.enums[enumName] else {
                throw unsupported("match scrutinee enum '\(enumName)' not registered", at: location)
            }
            let hirCases = try lowerEnumCases(cases, enumDecl: enumDecl, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
        case .result(let okType):
            // Result scrutinee (`G72`): without this arm the family fell to
            // `default` below, whose binding adopts the scrutinee type — so
            // `case ok(v)` bound `v` as a Result and every use of it (a
            // print, an arithmetic operand, a typed copy) was rejected against
            // a type the source never names.
            let hirCases = try lowerResultCases(cases, okType: okType, into: &context)
            return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
        default:
            // Bare scrutinee — neither Optional nor enum (a direct subscript
            // read: the interpreter yields a plain value there, verified).
            // Two arm families share this node:
            //   · enum-case arms (`some` / `none`) never match a bare value —
            //     the interpreter's matchCaseMatches compares an enum case
            //     only against an enum value — so those arms never fire and
            //     the match falls through silently (G11 multidim corpus,
            //     probe-verified at any scrutinee depth: outer `match m[1]`
            //     on array(I32), inner `match row[2]` on I32).
            //   · literal arms (`case 1:`) DO compare by value and must
            //     dispatch; the operand rides along as `HIRMatchLiteral` so
            //     the emitter never re-parses rendered pattern text.
            // Either way each body lowers with its binding typed by the
            // scrutinee itself (the value a live some-arm would bind).
            var hirCases: [HIRMatchCase] = []
            for matchCase in cases {
                let body = try lowerBareScrutineeArmBody(matchCase, bindingType: loweredValue.type, into: &context)
                hirCases.append(
                    HIRMatchCase(
                        caseName: matchCase.pattern.description,
                        literal: literalOperand(of: matchCase.pattern),
                        bindings: matchCase.bindings.map { $0.varName },
                        body: body
                    ))
            }
            return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
        }
    }

    /// Literal-pattern operand handed to the emitter; nil for enum-case and
    /// wildcard patterns, whose dispatch is not value-based.
    private static func literalOperand(of pattern: MatchPattern) -> HIRMatchLiteral? {
        switch pattern {
        case .intLiteral(let n): return .int(n)
        case .floatLiteral(let f): return .float(f)
        case .stringLiteral(let s): return .string(s)
        case .boolLiteral(let b): return .boolean(b)
        case .enumCase, .wildcard: return nil
        }
    }

    /// One arm body of a match whose scrutinee is neither Optional nor enum
    /// (the bare-value family, see `lowerMatch`). The body lowers so its
    /// bindings scope-resolve; whether the arm actually dispatches at emission
    /// follows from its pattern — literal arms do, enum-case arms cannot.
    /// Each binding adopts the scrutinee type (the value a live some-arm would
    /// bind), wildcard/none arms bind nothing.
    private static func lowerBareScrutineeArmBody(
        _ matchCase: MatchCase,
        bindingType: HIRType,
        into context: inout FunctionContext
    ) throws -> HIRBlock {
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
        wrapped: HIRType,
        into context: inout FunctionContext
    ) throws -> [HIRMatchCase] {
        var hirCases: [HIRMatchCase] = []
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
                hirCases.append(HIRMatchCase(caseName: caseName, bindings: bindingName.map { [$0] } ?? [], body: body))
            default:
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
        }
        return hirCases
    }

    /// Result scrutinee arms (`G72`): ok/err, single positional binding. The
    /// two sides are deliberately asymmetric, and the asymmetry is the whole
    /// point of the arm family:
    ///
    /// - the **ok** binding takes the payload type — that narrowing is what
    ///   this family exists for, and it is what makes a print / arithmetic
    ///   operand / typed copy of `v` legal;
    /// - the **err** binding takes the shape try-else already established for
    ///   an error word: one machine word, tracked in `errorBindings`. It is
    ///   not a new form. `result(ok:)` carries no error type to narrow to
    ///   (the HIR type has one field, the ok type), and the IR ABI erases that
    ///   slot (LR-12), so the only faithful spelling is the erased word. The
    ///   consequence is that printing an err binding stays gated — loudly, by
    ///   the existing error-binding gate, and now with a message that names
    ///   the real reason instead of blaming the binding's type.
    private static func lowerResultCases(
        _ cases: [MatchCase],
        okType: HIRType,
        into context: inout FunctionContext
    ) throws -> [HIRMatchCase] {
        var hirCases: [HIRMatchCase] = []
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
                hirCases.append(HIRMatchCase(caseName: caseName, bindings: bindingName.map { [$0] } ?? [], body: body))
            default:
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
        }
        return hirCases
    }

    /// Enum scrutinee arms (G4): tag dispatch through the general skeleton;
    /// bindings are positional per the case's payload list, `_` placeholders
    /// skip, named labels (`text: s`) resolve through the declared names.
    private static func lowerEnumCases(
        _ cases: [MatchCase],
        enumDecl: HIREnumDecl,
        into context: inout FunctionContext
    ) throws -> [HIRMatchCase] {
        var hirCases: [HIRMatchCase] = []
        for (caseOrder, matchCase) in cases.enumerated() {
            // Wildcard `case _:` matches everything — last arm only.
            if case .wildcard = matchCase.pattern {
                guard caseOrder == cases.count - 1 else {
                    throw unsupported(
                        "wildcard case must be the last case this grid",
                        at: matchCase.location
                    )
                }
                hirCases.append(HIRMatchCase(caseName: "_", bindings: [], body: try lowerBlock(matchCase.block, into: &context)))
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
            var scoped: [(String, HIRType, HIRType?)] = []
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
            hirCases.append(HIRMatchCase(caseName: enumCase.name, bindings: bindingNames, body: body))
        }
        return hirCases
    }

    // MARK: - Prefix increment / decrement (G-2c)

    /// Lower prefix `++`/`--` to a read-modify-write on its target.
    ///
    /// The interpreter defines these in `evaluateIncDec` as "read the target,
    /// add or subtract one, write it back, yield the written value" — I32
    /// only, three assignable target shapes (variable, field, subscript). The
    /// same three are lowered here, which is why one helper serves both
    /// statement position and a variable initializer (`var m = ++n`): the
    /// second form needs the written value as well as the write.
    ///
    /// The write lives in a statement because no HIR expression node carries a
    /// side effect, and the returned `newValue` is the very node the write
    /// stores rather than a re-read, so the two cannot drift apart.
    private static func lowerIncDec(
        op: UnaryOperator,
        target: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> (statement: HIRStmt, value: HIRExpr, type: HIRType) {
        // The direction lives in the operator, not in the constant: `--` is
        // `subtract` by one, not `add` by minus one.
        let baseOp: HIRBinaryOp = op == .increment ? .add : .subtract
        let one = HIRExpr.intConst(value: 1, type: .i32)
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
            let value = HIRExpr.binary(
                op: baseOp, lhs: .load(name: name, type: varType),
                rhs: one, type: varType
            )
            // The read-back is the value the write just left. The interpreter
            // returns the value it computed instead; for the I32 targets this
            // grid accepts the two are the same, and reading back is what
            // keeps `var m = ++n` from running the arithmetic a second time.
            let readBack = HIRExpr.load(name: name, type: varType)
            return (.storeVar(name: name, type: varType, value: value), readBack, varType)

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
            let value = HIRExpr.binary(
                op: baseOp,
                lhs: .fieldGet(base: loweredBase.node, field: fieldName, type: fieldType),
                rhs: one, type: fieldType
            )
            return (
                .fieldStore(
                    base: loweredBase.node, field: fieldName,
                    value: value, fieldType: fieldType
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
            let value = HIRExpr.binary(
                op: baseOp, lhs: read.node, rhs: one, type: .i32
            )
            return (
                .subscriptStore(
                    container: container, index: index, value: value, elementType: .i32
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
    ) throws -> HIRStmt {
        let loweredContainer = try lowerExpr(container, expected: nil, into: &context)
        let elementType: HIRType
        switch loweredContainer.type {
        case .array(let element): elementType = element
        case .dict(_, let value): elementType = value
        default:
            throw unsupported(
                "subscript store on non-container type '\(loweredContainer.type)'",
                at: location
            )
        }
        let indexExpectation: HIRType?
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
            value: loweredValue.node, elementType: elementType
        )
    }

    /// Lower `target op= value` in statement position: read-modify-write.
    /// Subscript targets reuse the read's container/index nodes so the
    /// container is emitted exactly twice (read + write), matching the
    /// legacy emitter's evaluation shape.
    private static func lowerCompoundAssign(
        left: Expression,
        baseOp: HIRBinaryOp,
        right: Expression,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> HIRStmt {
        if case .identifier(let name, _) = left {
            guard let varType = context.variableTypes[name] else {
                throw unsupported("assignment to undeclared variable '\(name)'", at: location)
            }
            guard varType.isNumeric else {
                throw unsupported("compound assignment on non-numeric variable '\(name)'", at: location)
            }
            let rhs = try lowerExpr(right, expected: varType, into: &context)
            let combined = HIRExpr.binary(
                op: baseOp, lhs: .load(name: name, type: varType), rhs: rhs.node, type: varType
            )
            return .storeVar(name: name, type: varType, value: combined)
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
            let combined = HIRExpr.binary(op: baseOp, lhs: read.node, rhs: rhs.node, type: read.type)
            guard case .subscriptGet(let containerNode, let indexNode, _) = read.node else {
                throw unsupported("subscript read did not produce a subscript node", at: location)
            }
            return .subscriptStore(
                container: containerNode, index: indexNode,
                value: combined, elementType: read.type
            )
        }
        throw unsupported(
            "compound assignment target outside this grid (identifier or array subscript)",
            at: location
        )
    }

    // MARK: - Array literals (G2)

    /// Lower an array literal. The checker does not infer collection literal
    /// types, so the element type is derived from the lowered elements
    /// (homogeneity required — same contract as the legacy codegen fallback).
    /// An expected `.array(element:)` context (annotation / nested literal)
    /// drives empty-literal and integer-literal adoption.
    private static func lowerArrayLiteral(
        _ elements: [Expression],
        expected: HIRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        let elementExpected = expected?.arrayElementType
        // An empty literal with no expected element type adopts I32. Runtime
        // construction is element-type free — `[]` lowers to an empty handle
        // (the legacy contract), so the choice only fixes the static element
        // type for later reads and writes. I32 is the language's default
        // numeric type, the same fallback an unannotated parameter uses.
        if elements.isEmpty {
            let element = elementExpected ?? .i32
            return LoweredExpr(
                node: .arrayLiteral(elements: [], type: .array(element: element)),
                type: .array(element: element)
            )
        }
        var loweredElements: [HIRExpr] = []
        var elementType: HIRType? = elementExpected
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

    /// Lower a member call through an implemented trait's default body
    /// (legacy tryTraitMethodDispatch mirror): the body is specialized to
    /// the receiver type as a method `方法__类型` (self = receiver), queued
    /// in `pendingTraitDefaults` for module emission, and the call site
    /// invokes it with the receiver as the implicit first argument.
    private static func lowerTraitDefaultCall(
        _ defaultMethod: FuncDecl,
        receiver: HIRExpr,
        receiverType: HIRType,
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
        let returnType = try defaultMethod.returnTypes.first.map { annotation -> HIRType in
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

    /// The HIR type of a nominal field, resolved through the registry (G3).
    private static func nominalFieldType(of type: HIRType, field: String, in context: FunctionContext) -> HIRType? {
        guard case .nominal(let name, _) = type,
            let info = context.nominalTypes[name],
            let fieldDecl = info.fields.first(where: { $0.name == field })
        else {
            return nil
        }
        return resolveAnnotationType(fieldDecl.typeAnnotation, userTypes: context.userTypes)
    }

    /// Slice set: exact match only, **plus one named exception**.
    ///
    /// The exception is `G68`'s implicit widening (`Char` into a `String` slot).
    /// It is admitted here rather than left to the literal level because it is a
    /// **declared rule about two types**, not a literal-coercion convenience, and
    /// the checker already admits it — a lowering gate that refused it would turn
    /// a legal program into a loud `E6-004`. No coercion is emitted: the two share
    /// an ABI (`i8*`), so this is the same value in the same slot. The reverse
    /// direction is *not* admitted, matching the checker: narrowing is what the
    /// three constructors are for.
    ///
    /// Widening at the literal level (I32 literal into I64 slot) is handled via
    /// `expected`; other non-matching composite coercions are later grids.
    ///
    /// G2 exception, tuples only: component *names* are not part of the shape.
    /// A positional literal `(3, 2)` satisfies `(商: I32, 余: I32,)`. The
    /// checker's own tuple assignability already reads labels that way, and a
    /// tuple's LLVM spelling is `{ i32, i32 }` with the names nowhere in it, so
    /// a label-only difference is not an ABI difference either. The names are
    /// reconciled where the language says they are: the executor stamps the
    /// declared labels onto the value, exactly as the interpreter does at the
    /// two same sites.
    private static func requireAssignable(_ from: HIRType, to: HIRType, at location: SourceLocation) throws {
        guard labelInsensitiveEqual(from, to) || (from == .char && to == .string) else {
            throw unsupported("type mismatch: \(from) is not \(to)", at: location)
        }
    }

    /// `==` everywhere except inside a tuple, where the label dimension is
    /// dropped and the element types still have to match one by one (nesting
    /// included).
    private static func labelInsensitiveEqual(_ from: HIRType, _ to: HIRType) -> Bool {
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

    private static func unsupported(_ message: String, at location: SourceLocation) -> HIRLoweringError {
        HIRLoweringError(message: message, location: location)
    }

    /// ADR-001 `P2b`：默认实例相关的**用户错误**（不是「还没做」）。
    ///
    /// 与 `E6-004`（「不支持的特性」）分开是刻意的 —— 那一条的意思是「语言有了、编译器还没做」，
    /// 而这两条说的是「程序写错了」。混在一个码里，CLI 上就分不开「我该改程序」与「等它做完」。
    private static let noDefaultInstanceCode = "\(DiagnosticDomain.irgen.rawValue)-007"

    private static func rejected(
        _ message: String, code: String, at location: SourceLocation
    ) -> HIRLoweringError {
        HIRLoweringError(message: message, location: location, code: code)
    }

    /// Stable funcLiteral identity: file + line + column. The legacy
    /// ClosureEmitter registry contract was "行:列"; the file component was
    /// implicit (single-file world). G13 batch 2 makes it explicit so a
    /// merged multi-file package cannot collide two files' literals.
    private static func closureIdKey(_ location: SourceLocation) -> String {
        "\(location.fileName):\(location.line):\(location.column)"
    }

    // MARK: - Effective return type (G13 batch 2, package-demo parity)

    /// Scans a body for `return <expr>` statements and returns the type of
    /// the first returned value expression, resolved without a full
    /// lowering pass. Only the narrow slice the corpus exercises (field
    /// reads / calls / literals through annotations) is supported; anything
    /// else fails the full lowering later with the ordinary gate error.
    ///
    /// Why this exists: the interpreter flows a void-declared method's
    /// returned value out at runtime (the package-demo corpus documents
    /// this as "void, 返回值运行时照常返回"), while the LLVM ABI needs one
    /// concrete return type at definition. The effective type upgrades the
    /// declared-void signature for both the body's return statements and
    /// the call sites — interpreter-faithful, statically decided.
    private static func effectiveReturnType(
        decl: FuncDecl,
        userTypes: [String: HIRType],
        nominals: [String: NominalInfo],
        selfTypeName: String? = nil
    ) throws -> HIRType? {
        // Declared non-void: nothing to upgrade.
        if decl.returnTypes.first != nil { return nil }
        for statement in decl.body?.statements ?? [] {
            guard case .returnStatement(let value, _) = statement, let value = value else {
                continue
            }
            // Error-binding returns were already dropped before this point
            // for void functions (returnStmt(value: nil)); a plain return
            // with a value upgrades the type.
            switch inferHIRType(
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
    private static func inferHIRType(
        of expression: Expression,
        userTypes: [String: HIRType],
        nominals: [String: NominalInfo],
        selfTypeName: String? = nil
    ) -> HIRType? {
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
            guard let baseType = inferHIRType(of: object, userTypes: userTypes, nominals: nominals, selfTypeName: selfTypeName),
                case .nominal(let typeName, _) = baseType,
                let info = nominals[typeName],
                let field = info.fields.first(where: { $0.name == fieldName })
            else {
                return nil
            }
            return HIRType(from: field.typeAnnotation)
        case .call(let callee, let arguments, _):
            // Zero-arg method call: `self.方法()` — the method's declared
            // return annotation is the effective value type.
            guard arguments.isEmpty,
                case .member(let object, let methodName, _) = callee,
                let baseType = inferHIRType(of: object, userTypes: userTypes, nominals: nominals, selfTypeName: selfTypeName),
                case .nominal(let typeName, _) = baseType,
                let info = nominals[typeName],
                let method = info.methods.first(where: { $0.name == methodName })
            else {
                return nil
            }
            return method.returnTypes.first.flatMap { HIRType(from: $0) }
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

extension HIRType {
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
            // `^T` surface form (Result type sugar, try-else 迁移): pins the ok
            // payload; the error slot is type-erased in the IR ABI (LR-12).
            if name == "Result", let first = params.first,
                let ok = HIRType(from: first)
            {
                self = .result(ok: ok)
                return
            }
            // `Array<T>` (G2): nested generics recurse through the element.
            if name == "Array", params.count == 1, let element = HIRType(from: params[0]) {
                self = .array(element: element)
                return
            }
            // `Optional<T>` (G7): covers the `?T` sugar too — the parser maps
            // `?T` to the same Optional generic annotation.
            if name == "Optional", params.count == 1, let wrapped = HIRType(from: params[0]) {
                self = .optional(wrapped: wrapped)
                return
            }
            // `LazyRef<T>` (G13 batch 1): opaque once-evaluated handle;
            // element rides along for the boxing ABI / `.value` load.
            if name == "LazyRef", params.count == 1, let element = HIRType(from: params[0]) {
                self = .lazyRef(element: element)
                return
            }
            return nil
        case .pointer(let element, _):
            // `*T` (G14, FFI 子系统): element recurses; the pointer itself
            // is an opaque `ptr` in the IR ABI.
            guard let elementType = HIRType(from: element) else { return nil }
            self = .pointer(element: elementType)
        case .tuple(let labels, let elements, _):
            // `(a: I32, b: F64,)` (G8): fields recurse, labels carry over.
            var fieldTypes: [HIRType] = []
            for element in elements {
                guard let fieldType = HIRType(from: element) else { return nil }
                fieldTypes.append(fieldType)
            }
            // The annotation layer writes `labels: []` for element lists whose
            // members are all positional (the multi-value producers: call-site
            // inference and the checker's payload shape). HIR keeps labels
            // index-aligned with fieldTypes, so expand the empty list to
            // all-nil; a genuinely partial label list is passed through as-is.
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
            var paramTypes: [HIRType] = []
            for param in params {
                guard let paramType = HIRType(from: param) else { return nil }
                paramTypes.append(paramType)
            }
            var returnType: HIRType?
            if let firstReturn = returns.first {
                guard let resolved = HIRType(from: firstReturn) else { return nil }
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

extension HIRBinaryOp {
    /// Map a compound-assign AST operator onto its base HIR operator; nil for
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

    /// Map an AST binary operator onto the slice set; nil for operators the
    /// slice does not carry. Bitwise/shift joined in G15 (the `&`, `^`, `<<`,
    /// `>>` spellings; single-pipe `|` bitwise-or has no parse path — host
    /// gap, `|` lexes as pipe/orAssign/logicalOr only).
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
    /// The statement's source position.
    ///
    /// Mirrors `Interpreter.statementLocation`: every `Statement` case carries
    /// a location, and this switch has no `default:` on purpose — a new
    /// statement case fails to compile here, so there is no path where a
    /// statement reaches lowering with no position to record (P4-3).
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
struct HIRLowererSignatureInfo {
    let paramTypes: [HIRType]
    let returnType: HIRType?
    /// Parameter positions declared without a type annotation.
    ///
    /// WHY (LR-4 G-2R): the checker does not constrain these positions -- its
    /// return-consistency note says unannotated parameters stay inferred and the
    /// body check skips them -- so a call site must not reject them either.
    /// `greet(name,)` is legal, and `name` may arrive as a string. The slot type
    /// still comes from the declaration's fallback, because the body's own
    /// lowering needs *a* type; only the call-site comparison is skipped.
    let untypedParamIndices: Set<Int>
    /// ADR-001：`using` 形参的位置（0 基）。
    ///
    /// 与检查器的 `FunctionSignature.usingParamIndices` 是**同一口径的两份**：调用点按
    /// 「实参个数 == 形参个数 − using 个数」认省略式调用，并把实参按非 using 形参逐位对上。
    /// 空集 ⇒ 与 ADR-001 之前逐字同形（既有构造点靠默认值零改动）。
    let usingParamIndices: Set<Int>

    init(
        paramTypes: [HIRType], returnType: HIRType?, untypedParamIndices: Set<Int> = [],
        usingParamIndices: Set<Int> = []
    ) {
        self.paramTypes = paramTypes
        self.returnType = returnType
        self.untypedParamIndices = untypedParamIndices
        self.usingParamIndices = usingParamIndices
    }
}

/// Per-function lowering context: variable slot types, the enclosing
/// function's return type, the module-wide signatures from the pre-pass,
/// the nominal type registry (G3), the user-type name table and enum
/// registry (G4).
/// `errorBindings` tracks names currently bound to a try-else error word so
/// `return err` can re-box and print can gate on the type-erased ABI.
/// G-2d: the module's generic-enum templates plus the case -> owner index.
/// 泛型枚举构造形态 gives two construction spellings: the qualified form names the enum
/// (`结果<I32, String>.ok(42)`) and needs only `templates`; the bare form names
/// the case (`ok<I32, String>(42)`) and resolves its parent through the
/// 裸名 case 消歧（静态收敛版） ladder, which is what `caseOwners` answers — exactly one owner
/// means no expected type is needed, more than one means the spelling is
/// ambiguous and the qualified form is required.
private struct HIRGenericEnumIndex {
    let templates: [String: EnumDecl]
    let caseOwners: [String: [String]]

    static let empty = HIRGenericEnumIndex(templates: [:], caseOwners: [:])

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

/// One enclosing construct a `break`/`continue` may leave. Loops are
/// `continue` targets as well; a labeled `if` block is not (标签 break 定向范围; the
/// `continue-stmt` production carries the note *仅循环标签有效* while
/// `break-stmt` carries no such restriction).
private struct ControlFrame {
    let label: String?
    let isLoop: Bool
}

private struct FunctionContext {
    let functionName: String
    let returnType: HIRType?
    let typeInference: TypeInference?
    var variableTypes: [String: HIRType]
    /// ADR-001 `P2b`：函数体里取用过的给定块类型（留痕，见 `HIRFunction.givenReferenceNames`）。
    /// 值字段即可 —— 调用点全都在**同一个**函数的 `context` 上写，不需要跨函数共享。
    var givenReferenceNames: Set<String> = []
    let moduleSignatures: [String: HIRLowererSignatureInfo]
    let nominalTypes: [String: HIRLowerer.NominalInfo]
    let userTypes: [String: HIRType]
    let enums: [String: HIREnumDecl]
    /// G-2d: the module's generic-enum templates plus the case -> owner index,
    /// used to place a generic enum case construction and to find the
    /// specialized body the pre-pass registered (泛型枚举构造形态).
    let genericEnums: HIRGenericEnumIndex
    /// G10: generic function templates by source name, for call-site
    /// dispatch of `身份<I32>(...)` (the specialization itself is
    /// pre-registered during the monomorphization pre-pass).
    let genericFuncTemplates: [String: FuncDecl]
    /// G6: closure literal ids keyed by `funcLiteral.location` "行:列"
    /// (stable AST-node identity, legacy ClosureEmitter contract). Assigned
    /// by a module-level pre-pass so emission order is source-order stable.
    let closureIds: [String: Int]
    /// G12: trait registry — trait bodies by name plus per-type trait lists.
    /// Read-only at lowering time; drives the member-call trait-default
    /// fallback (legacy tryTraitMethodDispatch mirror).
    let traitRegistry: HIRLowerer.TraitRegistry
    /// G12: trait default bodies specialized at dispatch sites (IR name
    /// `方法__类型`), collected here for module emission. Reference type so
    /// appends from nested FunctionContexts propagate to `lower()`.
    let traitDefaultsCollector: HIRLowerer.TraitDefaultCollector
    /// H-3 三级派发的第一级：内建类型（`String` / `Array`）的**用户扩展方法**。
    /// 接收者类型名 → 方法名 → （降载后的 IR 函数名, 返回类型）。由模块级预扫描填
    /// （见 `lower(module:)` 的扩展块分支）；空表即「本模块没有内建扩展」。
    var builtinExtensionMethods: [String: [String: (irName: String, returnType: HIRType)]] = [:]
    /// G12: receiver field types for bare-name resolution inside method
    /// bodies (interpreter bindInstanceFields parity). Empty outside methods.
    var selfFieldTypes: [String: HIRType] = [:]
    var selfTypeNameLowered: String?
    var selfIsObjectLowered: Bool = false
    var errorBindings: Set<String> = []

    /// Enclosing interruptible frames, innermost last (`nil` = unlabeled
    /// loop). Drives labeled break/continue depth resolution (标签语法反转 for the
    /// loops-only era, 标签 break 定向范围 once a labeled `if` became a frame too): a
    /// label matches the nearest enclosing frame carrying that label.
    var controlFrames: [ControlFrame] = []

    /// M6a D7: counter for synthetic slot names (`$destructureN`) so several
    /// destructures in one function cannot share a slot. `$` is not a
    /// source-identifier character (identifiers are letters/digits/`_`), so
    /// these never collide with user names — and unlike angle brackets it is
    /// legal in an unquoted LLVM local name, which mangling leaves untouched.
    var tempCounter: Int = 0

    /// G13 batch 2: alias for the effective-return pre-scan (same dictionary,
    /// shorter name at call sites).
    fileprivate var nominalTypesMap: [String: HIRLowerer.NominalInfo] { nominalTypes }

    init(
        functionName: String,
        returnType: HIRType?,
        paramTypes: [String: HIRType],
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: HIRLowerer.NominalInfo] = [:],
        userTypes: [String: HIRType] = [:],
        enums: [String: HIREnumDecl] = [:],
        genericEnums: HIRGenericEnumIndex = .empty,
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: HIRLowerer.TraitRegistry = HIRLowerer.TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: HIRLowerer.TraitDefaultCollector = HIRLowerer.TraitDefaultCollector(),
        builtinExtensionMethods: [String: [String: (irName: String, returnType: HIRType)]] = [:]
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
    }

    func inferType(of expression: Expression) -> TypeAnnotation? {
        typeInference?.infer(expression: expression)
    }
}
