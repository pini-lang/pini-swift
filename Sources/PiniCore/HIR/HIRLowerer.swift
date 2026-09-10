import Foundation

/// Lowers a type-checked `Module` (AST) plus the checker's `TypeInference`
/// into a typed `HIRModule`. This is the single point where all type
/// decisions are made for the LLVM backend, and the single place allowed to
/// say "unsupported": every capability gap surfaces as one
/// `HIRLoweringError.unsupported` thrown from this file. The old IRGenerator
/// scattered ~108 such decisions across emitters; they consolidate here.
public enum HIRLowerer {

    /// The single capability-gate error for the new pipeline.
    public struct HIRLoweringError: Error, CustomStringConvertible {
        public let message: String
        public let location: SourceLocation

        public var description: String {
            "HIR lowering error at \(location.line):\(location.column): \(message)"
        }
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
        var funcSpecializations: [String: FuncDecl] = [:]
        /// Specialized-name -> substitution used for that struct instance
        /// (generic param name -> concrete annotation).
        var structSubstitutions: [String: [String: TypeAnnotation]] = [:]
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
            default: return []
            }
        }

        var methods: [FuncDecl] {
            switch decl {
            case .structDecl(let sd): return sd.methods + extensionMethods
            case .objectDecl(let od): return od.methods + extensionMethods
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
                copy.decl = .structDecl(StructDecl(
                    name: sd.name, genericParams: sd.genericParams,
                    fields: fields, methods: [],
                    composedType: sd.composedType, traits: sd.traits, location: sd.location
                ))
            case .objectDecl(let od):
                copy.decl = .objectDecl(ObjectDecl(
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
                  let parent = nominals[parentName] else {
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
    public static func lower(package: Package, typeInference: TypeInference?) throws -> HIRModule {
        guard package.fileUnits.count > 1 else {
            let module = package.fileUnits.first?.module
                ?? Module(declarations: [], imports: [], exports: [],
                          location: SourceLocation(line: 0, column: 0, fileName: package.name))
            return try lower(module: module, typeInference: typeInference)
        }
        let merged = Module(
            declarations: package.fileUnits.flatMap { $0.module.declarations },
            imports: package.fileUnits.flatMap { $0.module.imports },
            exports: package.fileUnits.flatMap { $0.module.exports },
            location: package.location
        )
        return try lower(module: merged, typeInference: typeInference)
    }

    /// Lower a checked module. `typeInference` is the TypeChecker's inference
    /// output; callers must run the checker first (same contract as the old
    /// `typeCheckThenGenerate` pipeline).
    public static func lower(module: Module, typeInference: TypeInference?) throws -> HIRModule {
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
        for decl in module.declarations {
            switch decl {
            case .structDecl(let sd):
                if sd.genericParams.isEmpty {
                    nominals[sd.name] = NominalInfo(name: sd.name, isObject: false, decl: decl)
                } else {
                    genericStructTemplates[sd.name] = sd
                }
            case .objectDecl(let od): nominals[od.name] = NominalInfo(name: od.name, isObject: true, decl: decl)
            case .funcDecl(let fd) where !fd.genericParams.isEmpty:
                genericFuncTemplates[fd.name] = fd
            default: break
            }
        }
        for decl in module.declarations {
            if case .extensionDecl(let ext) = decl, ext.kind == .structExt || ext.kind == .objectExt,
               nominals[ext.targetType] != nil {
                nominals[ext.targetType]!.extensionMethods.append(contentsOf: ext.methods)
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
        for decl in module.declarations {
            precollectGenericUses(in: decl,
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
                   specializedName == ext.targetType || specializedName.hasPrefix("\(ext.targetType)_") {
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
        var enums: [String: HIREnumDecl] = [:]
        var userTypes: [String: HIRType] = [:]
        for decl in module.declarations {
            switch decl {
            case .enumDecl(let ed):
                enums[ed.name] = HIREnumDecl(
                    name: ed.name,
                    cases: ed.cases.enumerated().map { index, ec in
                        HIREnumCase(name: ec.name, tag: index,
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
        for decl in module.declarations {
            if case .enumDecl(let ed) = decl {
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
                    resolvedCases.append(HIREnumCase(
                        name: ec.name, tag: index,
                        paramNames: ec.associatedParams.map { $0.name },
                        payloadTypes: payloadTypes
                    ))
                }
                enums[ed.name] = HIREnumDecl(name: ed.name, cases: resolvedCases)
            }
        }

        // Signature pre-pass (after type registries so enum/struct/object
        // parameter annotations resolve): captures every declared function's
        // signature so bodies can call functions declared later in the file.
        var signatures: [String: HIRLowererSignatureInfo] = [:]

        /// G12: signature info for a trait default implementation. The
        /// leading `self` parameter (annotation nil — trait bodies do not
        /// annotate it) is stripped; remaining parameters resolve normally.
        func traitSignatureInfo(_ sig: FuncDecl, userTypes: [String: HIRType]) throws -> HIRLowererSignatureInfo {
            let bodyParams = sig.params.first?.name == "self" ? Array(sig.params.dropFirst()) : sig.params
            let paramTypes = try bodyParams.map { parameter -> HIRType in
                guard let annotation = parameter.typeAnnotation,
                      let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                    throw unsupported(
                        "parameter '\(parameter.name)' of trait default '\(sig.name)' lacks a resolvable scalar type",
                        at: sig.location
                    )
                }
                return type
            }
            let returnType: HIRType? = try sig.returnTypes.first.map { annotation in
                guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                    throw unsupported(
                        "return type '\(annotation.simpleName ?? "(non-scalar)")' of trait default '\(sig.name)'",
                        at: sig.location
                    )
                }
                return type
            }
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
                let paramTypes = try funcDecl.params.map { parameter -> HIRType in
                    guard let annotation = parameter.typeAnnotation,
                          let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                        throw unsupported(
                            "parameter '\(parameter.name)' of '\(funcDecl.name)' lacks a resolvable scalar type",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                let returnType: HIRType? = try funcDecl.returnTypes.first.map { annotation in
                    guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                        throw unsupported(
                            "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(funcDecl.name)'",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                // G13 batch 2: effective return for void-declared top-level
                // functions that return a value (interpreter-faithful; the
                // signature table drives call sites, so it must agree with
                // the definition side's upgrade).
                let effectiveReturn = try effectiveReturnType(
                    decl: funcDecl, userTypes: userTypes, nominals: nominals
                ) ?? returnType
                signatures[funcDecl.name] = HIRLowererSignatureInfo(
                    paramTypes: paramTypes, returnType: effectiveReturn
                )
            default: break
            }
        }
        // G10: specialized generic functions join the signature table (their
        // bodies reference only concrete types now).
        for (_, specialized) in specializationState.funcSpecializations {
            let paramTypes = try specialized.params.map { parameter -> HIRType in
                guard let annotation = parameter.typeAnnotation,
                      let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                    throw unsupported(
                        "parameter '\(parameter.name)' of '\(specialized.name)' lacks a resolvable type",
                        at: specialized.location
                    )
                }
                return type
            }
            let returnType: HIRType? = try specialized.returnTypes.first.map { annotation in
                guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                    throw unsupported(
                        "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(specialized.name)'",
                        at: specialized.location
                    )
                }
                return type
            }
            signatures[specialized.name] = HIRLowererSignatureInfo(
                paramTypes: paramTypes, returnType: returnType
            )
        }

        var functions: [HIRFunction] = []
        for decl in module.declarations {
            switch decl {
            case .funcDecl(let funcDecl):
                // Generic templates are not emitted — only their
                // specializations are (G10 monomorphization).
                guard funcDecl.genericParams.isEmpty else { continue }
                functions.append(
                    try lowerFunction(funcDecl, typeInference: typeInference, moduleSignatures: signatures,
                                      nominalTypes: nominals, userTypes: userTypes, enums: enums,
                                      genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                                          traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector)
                )
            case .traitDecl, .structDecl, .objectDecl, .extensionDecl, .enumDecl:
                // Handled by the nominal-type / enum passes below; trait
                // default bodies specialize at their dispatch sites (G12).
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
                try lowerFunction(specialized, typeInference: typeInference, moduleSignatures: signatures,
                                  nominalTypes: nominals, userTypes: userTypes, enums: enums,
                                  genericFuncTemplates: genericFuncTemplates, closureIds: closureIds,
                                          traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector)
            )
        }
        guard functions.contains(where: { $0.name == "main" }) else {
            throw unsupported("no 'main' function found", at: module.location)
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
                typeDecls.append(try lowerNominal(
                    name: sd.name, isObject: false, fields: info.fields,
                    methods: info.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                    userTypes: userTypes, enums: enums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds,
                    traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector
                ))
            case .objectDecl(let od):
                let info = nominals[od.name]!
                typeDecls.append(try lowerNominal(
                    name: od.name, isObject: true, fields: info.fields,
                    methods: info.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                    userTypes: userTypes, enums: enums, genericFuncTemplates: genericFuncTemplates,
                    closureIds: closureIds,
                    traitRegistry: traitRegistry, traitDefaultsCollector: traitDefaultsCollector
                ))
            default:
                break
            }
        }

        // G10: emit typeDecls for specialized struct instances (fields +
        // re-specialized extension methods, both registered in `nominals`).
        for specializedName in specializationState.structSpecializations.keys {
            let info = nominals[specializedName]!
            guard case .structDecl(let sd) = info.decl else { continue }
            typeDecls.append(try lowerNominal(
                name: specializedName, isObject: false, fields: sd.fields,
                methods: info.methods,
                typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals,
                userTypes: userTypes, enums: enums, genericFuncTemplates: genericFuncTemplates,
                closureIds: closureIds
            ))
        }
        // G12: trait default bodies specialized at dispatch sites join the
        // function list (dedup by IR name already applied at the dispatch).
        functions.append(contentsOf: traitDefaultsCollector.functions)
        return HIRModule(functions: functions, types: typeDecls, enums: Array(enums.values))
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
            precollectGenericUses(in: fd.body?.statements ?? [],
                                  genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates,
                                  state: &state)
        case .structDecl(let sd):
            for m in sd.methods {
                precollectGenericUses(in: m.body?.statements ?? [],
                                      genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates,
                                      state: &state)
            }
        case .objectDecl(let od):
            for m in od.methods {
                precollectGenericUses(in: m.body?.statements ?? [],
                                      genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates,
                                      state: &state)
            }
        case .enumDecl(let ed):
            for m in ed.methods {
                precollectGenericUses(in: m.body?.statements ?? [],
                                      genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates,
                                      state: &state)
            }
        case .extensionDecl(let ext):
            for m in ext.methods {
                precollectGenericUses(in: m.body?.statements ?? [],
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
            precollectGenericUses(in: statement,
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
                precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .assign(let target, let value, _):
            if case .member(let base, _) = target {
                precollectGenericUses(in: base, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
            precollectGenericUses(in: value, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .expressionStmt(let e, _):
            precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .returnStatement(let e, _):
            if let e = e {
                precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
            precollectGenericUses(in: condition, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(in: thenBlock.statements, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            for branch in elifs {
                precollectGenericUses(in: branch.condition, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
                precollectGenericUses(in: branch.block.statements, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
            if let elseBlock = elseBlock {
                precollectGenericUses(in: elseBlock.statements, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .whileStatement(let condition, let body, _, _, _):
            precollectGenericUses(in: condition, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(in: body.statements, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .matchStatement(let value, let cases, _):
            precollectGenericUses(in: value, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            for matchCase in cases {
                precollectGenericUses(in: matchCase.block.statements, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .deferStatement(let wrapped, _):
            precollectGenericUses(in: wrapped, genericStructTemplates: genericStructTemplates,
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
        case .call(let callee, let arguments, _):
            precollectGenericUses(in: callee, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            // `身份<I32>(...)` arrives as a genericConstruct callee inside a
            // call — the callee scan above already registers it.
            for argument in arguments {
                precollectGenericUses(in: argument.expression, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .binary(let lhs, _, let rhs, _):
            precollectGenericUses(in: lhs, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(in: rhs, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .unary(_, let operand, _):
            precollectGenericUses(in: operand, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .member(let base, _, _):
            precollectGenericUses(in: base, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .subscript(let container, let index, _):
            precollectGenericUses(in: container, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
            precollectGenericUses(in: index, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tupleIndex(let base, _, _):
            precollectGenericUses(in: base, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tryExpression(let operand, _, _, _):
            precollectGenericUses(in: operand, genericStructTemplates: genericStructTemplates,
                                  genericFuncTemplates: genericFuncTemplates, state: &state)
        case .tuple(_, let elements, _):
            for e in elements {
                precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .arrayLiteral(let elements, _):
            for e in elements {
                precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
                                      genericFuncTemplates: genericFuncTemplates, state: &state)
            }
        case .stringInterpolation(let segments, _):
            for segment in segments {
                if case .expression(let e) = segment {
                    precollectGenericUses(in: e, genericStructTemplates: genericStructTemplates,
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
        for (index, argument) in loweredArgs.enumerated() {
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

    private static func lowerFunction(
        _ decl: FuncDecl,
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo],
        userTypes: [String: HIRType],
        enums: [String: HIREnumDecl],
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> HIRFunction {
        guard decl.body != nil else {
            throw unsupported("function '\(decl.name)' has no body", at: decl.location)
        }
        guard decl.genericParams.isEmpty else {
            throw unsupported("generic function '\(decl.name)'", at: decl.location)
        }
        guard decl.returnTypes.count <= 1 else {
            throw unsupported(
                "function '\(decl.name)' returns \(decl.returnTypes.count) values (tuple returns are a later grid)",
                at: decl.location
            )
        }
        let returnType: HIRType? = try decl.returnTypes.first.map { annotation in
            guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(decl.name)'",
                    at: decl.location
                )
            }
            return type
        }
        // G13 batch 2: effective return for void-declared functions that
        // return a value (must match the signature-table upgrade so call
        // sites and the definition agree).
        let effectiveReturn = try effectiveReturnType(
            decl: decl, userTypes: userTypes, nominals: nominalTypes
        ) ?? returnType

        var params: [HIRFunction.HIRParam] = []
        for param in decl.params {
            guard let annotation = param.typeAnnotation,
                  let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "parameter '\(param.name)' of '\(decl.name)' lacks a resolvable scalar type",
                    at: decl.location
                )
            }
            params.append(HIRFunction.HIRParam(name: param.name, type: type))
        }

        var context = FunctionContext(
            functionName: decl.name,
            returnType: effectiveReturn,
            paramTypes: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.type) }),
            typeInference: typeInference,
            moduleSignatures: moduleSignatures,
            nominalTypes: nominalTypes,
            userTypes: userTypes,
            enums: enums,
            genericFuncTemplates: genericFuncTemplates,
            closureIds: closureIds,
            traitRegistry: traitRegistry,
            traitDefaultsCollector: traitDefaultsCollector
        )
        let body = try lowerBlock(decl.body!, into: &context)
        return HIRFunction(name: decl.name, params: params, returnType: effectiveReturn, body: body)
    }

    // MARK: - Annotation resolution (G3/G4 user types)

    /// Resolve a type annotation: the built-in slice set first, then the
    /// module's user types (structs / objects / enums) by simple name.
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
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: TraitRegistry = TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: TraitDefaultCollector = TraitDefaultCollector()
    ) throws -> HIRTypeDecl {
        let selfType = HIRType.nominal(name: name, isObject: isObject)
        var scratch = FunctionContext(
            functionName: "<field-default:\(name)>", returnType: nil, paramTypes: [:],
            typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes,
            userTypes: userTypes, enums: enums, closureIds: closureIds
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
            loweredMethods.append(try lowerMethod(
                method, typeName: name, selfType: selfType,
                typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes,
                userTypes: userTypes, enums: enums, genericFuncTemplates: genericFuncTemplates,
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
        guard decl.returnTypes.count <= 1 else {
            throw unsupported(
                "method '\(decl.name)' returns \(decl.returnTypes.count) values (tuple returns are a later grid)",
                at: decl.location
            )
        }
        let returnType: HIRType? = try decl.returnTypes.first.map { annotation in
            guard let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(decl.name)'",
                    at: decl.location
                )
            }
            return type
        }
        // G13 batch 2: a void-declared method whose body returns a value
        // (package-demo corpus documents the interpreter flows it out)
        // upgrades to the effective return type — body returns and call
        // sites both use it.
        let effectiveReturn = try effectiveReturnType(
            decl: decl, userTypes: userTypes, nominals: nominalTypes,
            selfTypeName: typeName
        ) ?? returnType
        var params = [HIRFunction.HIRParam(name: "self", type: selfType)]
        for param in decl.params {
            guard let annotation = param.typeAnnotation,
                  let type = resolveAnnotationType(annotation, userTypes: userTypes) else {
                throw unsupported(
                    "parameter '\(param.name)' of method '\(decl.name)' lacks a resolvable type",
                    at: decl.location
                )
            }
            params.append(HIRFunction.HIRParam(name: param.name, type: type))
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
           let info = nominalTypes[selfTypeName] {
            var fieldTypes: [String: HIRType] = [:]
            for field in info.fields {
                if let fieldType = HIRType(from: field.typeAnnotation) {
                    fieldTypes[field.name] = fieldType
                }
            }
            context.selfFieldTypes = fieldTypes
            context.selfTypeNameLowered = selfTypeName
            context.selfIsObjectLowered = selfIsObject
        }
        let body = try lowerBlock(decl.body!, into: &context)
        return HIRFunction(name: irName, params: params, returnType: effectiveReturn, body: body)
    }

    private static func lowerBlock(
        _ block: Block,
        into context: inout FunctionContext
    ) throws -> [HIRStmt] {
        var statements: [HIRStmt] = []
        for statement in block.statements {
            statements.append(contentsOf: try lowerStatement(statement, into: &context))
        }
        return statements
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

        case .assign(let target, let value, let location):
            // Subscript stores are the G2 write path (array family); member
            // stores are the G3 write path (nominal field store).
            if case .subscript(let container, let index) = target {
                return [try lowerSubscriptStore(
                    container: container, index: index, value: value, at: location, into: &context
                )]
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
                return [.fieldStore(
                    base: loweredBase.node, field: fieldName,
                    value: loweredValue.node, fieldType: fieldType
                )]
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

        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
            let cond = try lowerExpr(condition, expected: .boolean, into: &context)
            guard cond.type == .boolean else {
                throw unsupported("if condition is not Bool", at: conditionLocation(condition))
            }
            let thenBody = try lowerBlock(thenBlock, into: &context)
            // Elif chains lower to nested ifs (tree shape keeps them structural).
            var chain: [HIRStmt]? = nil
            if let elseBlock = elseBlock {
                chain = try lowerBlock(elseBlock, into: &context)
            }
            for branch in elifs.reversed() {
                let branchCond = try lowerExpr(branch.condition, expected: .boolean, into: &context)
                guard branchCond.type == .boolean else {
                    throw unsupported("elif condition is not Bool", at: conditionLocation(branch.condition))
                }
                let branchBody = try lowerBlock(branch.block, into: &context)
                chain = [.ifStmt(condition: branchCond.node, thenBody: branchBody, elseBody: chain)]
            }
            return [.ifStmt(condition: cond.node, thenBody: thenBody, elseBody: chain)]

        case .whileStatement(let condition, let body, _, _, _):
            let cond = try lowerExpr(condition, expected: .boolean, into: &context)
            guard cond.type == .boolean else {
                throw unsupported("while condition is not Bool", at: conditionLocation(condition))
            }
            let bodyStmts = try lowerBlock(body, into: &context)
            return [.whileStmt(condition: cond.node, body: bodyStmts)]

        case .breakStatement(let label, let location):
            guard label == nil else {
                throw unsupported("labeled break is a later grid", at: location)
            }
            return [.breakStmt]

        case .matchStatement(let value, let cases, let location):
            return [try lowerMatch(value: value, cases: cases, at: location, into: &context)]

        case .deferStatement(let wrapped, _):
            // G9: defer runs at the enclosing block scope's normal end,
            // LIFO across the defers of that scope (emitter block protocol).
            return [.deferStmt(body: try lowerStatement(wrapped, into: &context))]

        case .expressionStmt(let expr, let location):
            // Statement-position try-else: ok value discarded (ADR-032).
            if case .tryExpression(let operand, let errorVar, let handler, _) = expr {
                return [try lowerTry(
                    operand: operand, errorVar: errorVar, handler: handler,
                    okTarget: nil, at: location, into: &context
                )]
            }
            // Compound assignment (`a[i] += k` / `x += 1`) parses as a binary
            // expression; statement position lowers it to a store (G2).
            if case .binary(let left, let op, let right, let binaryLocation) = expr,
               let baseOp = HIRBinaryOp(compound: op) {
                return [try lowerCompoundAssign(
                    left: left, baseOp: baseOp, right: right,
                    at: binaryLocation, into: &context
                )]
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

        default:
            throw unsupported(
                "statement '\(statement.kindName)' outside the M4 slice",
                at: statementLocation(statement)
            )
        }
    }

    private static func lowerVarDecl(
        name: String,
        annotation: TypeAnnotation?,
        initializer: Expression?,
        isMutable: Bool,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> [HIRStmt] {
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
               let type = HIRType(from: inferred) {
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
        if let initializer = initializer {
            let lowered = try lowerExpr(initializer, expected: varType, into: &context)
            try requireAssignable(lowered.type, to: varType, at: location)
            loweredInit = lowered.node
        } else {
            loweredInit = nil
        }
        context.variableTypes[name] = varType
        return [.allocVar(name: name, type: varType, mutable: isMutable, initializer: loweredInit)]
    }

    // MARK: - Try-else (ADR-032, G1)

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
        let loweredOperand = try lowerExpr(operand, expected: nil, into: &context)
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
            handler: handlerStmts, okTarget: okTarget, type: .result(ok: okType)
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
            case .string: elementType = .string
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
                let type = HIRType.function(params: signature.paramTypes, returnType: signature.returnType)
                return LoweredExpr(node: .functionValue(functionName: name, type: type), type: type)
            }
            throw unsupported("reference to undeclared variable '\(name)'", at: location)

        case .binary(let left, let op, let right, let location):
            guard let hirOp = HIRBinaryOp(from: op) else {
                throw unsupported(
                    "binary operator '\(op)' outside the M4 slice",
                    at: location
                )
            }
            // Comparison operands are lowered without scalar expectation;
            // arithmetic operands adopt the expected numeric type.
            let operandExpectation: HIRType? = hirOp.isComparison ? nil : expected
            let lhs = try lowerExpr(left, expected: operandExpectation, into: &context)
            let rhs = try lowerExpr(right, expected: lhs.type, into: &context)
            if hirOp.isComparison {
                guard lhs.type == rhs.type else {
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
            if hirOp == .add, lhs.type == .string, rhs.type == .string {
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
            let hirOp: HIRUnaryOp
            switch op {
            case .minus: hirOp = .negate
            case .logicalNot, .not: hirOp = .logicalNot
            default:
                throw unsupported("unary operator '\(op)' outside the M4 slice", at: location)
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
            // name or the checker's expected-type registry (E-131).
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
            // Intrinsic print: exactly one argument.
            if functionName == "print" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("print expects exactly one argument", at: location)
                }
                if case .load(let name, _) = loweredArgs[0].node, context.errorBindings.contains(name) {
                    throw unsupported(
                        "printing an error binding is not supported by the LLVM Result ABI this grid (the err slot is type-erased)",
                        at: location
                    )
                }
                if case .result = loweredArgs[0].type {
                    throw unsupported("printing a Result value is outside the slice", at: location)                }
                if case .nominal = loweredArgs[0].type {
                    throw unsupported(
                        "printing a struct/object value is a later grid (value formatting)",
                        at: location
                    )
                }
                return LoweredExpr(node: .printCall(argument: loweredArgs[0].node), type: .i32)
            }
            // Intrinsic sqrt (G3): libc math, F64 only — the struct.pini
            // corpus dependency. Other math intrinsics join their own grid.
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
                    node: .binary(op: .divide,
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
                    node: .binary(op: functionName == "min" ? .minOf : .maxOf,
                        lhs: loweredArgs[0].node, rhs: loweredArgs[1].node, type: .i32),
                    type: .i32
                )
            }
            // Intrinsic len: arrays/dicts/sets through the runtime handles,
            // strings via the inline strlen scan.
            if functionName == "len" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("len expects exactly one argument", at: location)
                }
                switch loweredArgs[0].type {
                case .array, .dict, .set, .string:
                    return LoweredExpr(node: .lenCall(argument: loweredArgs[0].node), type: .i32)
                default:
                    throw unsupported(
                        "len on '\(loweredArgs[0].type)' is outside this grid",
                        at: location
                    )
                }
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
            if let signature = context.variableTypes[functionName],
               case .function(let paramTypes, let functionReturn) = signature {
                guard loweredArgs.count == paramTypes.count else {
                    throw unsupported(
                        "indirect call through '\(functionName)' expects \(paramTypes.count) arguments, got \(loweredArgs.count)",
                        at: location
                    )
                }
                for (index, argument) in loweredArgs.enumerated() {
                    try requireAssignable(argument.type, to: paramTypes[index], at: location)
                }
                return LoweredExpr(
                    node: .indirectCall(
                        callee: .load(name: functionName, type: signature),
                        arguments: loweredArgs.map { $0.node },
                        returnType: functionReturn
                    ),
                    type: functionReturn ?? .i32
                )
            }
            // Direct call on an immediate closure literal `sq(6)` where sq
            // was just created inline — `f(...)` with a funcLiteral callee.
            if case .funcLiteral(let literalDecl, let literalLocation) = callee {
                let loweredCallee = try lowerFuncLiteral(
                    decl: literalDecl, expected: nil, at: literalLocation, into: &context
                )
                guard case .function(let literalParams, let literalReturn) = loweredCallee.type else {
                    throw unsupported("inline anonymous function resolved to a non-function type", at: location)
                }
                guard loweredArgs.count == literalParams.count else {
                    throw unsupported(
                        "anonymous function call expects \(literalParams.count) arguments, got \(loweredArgs.count)",
                        at: location
                    )
                }
                for (index, argument) in loweredArgs.enumerated() {
                    try requireAssignable(argument.type, to: literalParams[index], at: location)
                }
                return LoweredExpr(
                    node: .indirectCall(
                        callee: loweredCallee.node,
                        arguments: loweredArgs.map { $0.node },
                        returnType: literalReturn
                    ),
                    type: literalReturn ?? .i32
                )
            }
            // Enum case construction `圆(2.0)` / `identifier(text= "x")` (G4):
            // resolved before the function-signature table — case names share
            // the identifier namespace with functions.
            if case .identifier(let caseName, _) = callee,
               let (enumDecl, enumCase) = try resolveEnumCase(caseName, at: location, in: context) {
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
            guard loweredArgs.count == signature.paramTypes.count else {
                throw unsupported(
                    "call to '\(functionName)' expects \(signature.paramTypes.count) arguments, got \(loweredArgs.count)",
                    at: location
                )
            }
            for (index, argument) in loweredArgs.enumerated() {
                try requireAssignable(argument.type, to: signature.paramTypes[index], at: location)
            }
            return LoweredExpr(
                node: .call(
                    function: functionName,
                    arguments: loweredArgs.map { $0.node },
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

        default:
            throw unsupported(
                "expression '\(expression.kindName)' outside the M4 slice",
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
            if case .identifier = target {} // identifier targets carry no literals
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
        if let annotation = inferredAnnotation, let mapped = HIRType(from: annotation),
           case .function = mapped {
            functionType = mapped
        } else if case .function(let expectedParams, let expectedReturn) = expected {
            functionType = .function(params: expectedParams, returnType: expectedReturn)
        } else {
            throw unsupported(
                "anonymous function type could not be resolved (annotate the parameter or the variable)",
                at: location
            )
        }
        guard case .function(let paramTypes, let returnType) = functionType else {
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
    /// (ADR-026 D1: call-site location → parent enum, E-131) and are gated
    /// when unresolved.
    private static func resolveEnumCase(
        _ caseName: String,
        at location: SourceLocation?,
        in context: FunctionContext
    ) throws -> (HIREnumDecl, HIREnumCase)? {
        if let dotIndex = caseName.firstIndex(of: ".") {
            let enumName = String(caseName[..<dotIndex])
            let caseLeaf = String(caseName[caseName.index(after: dotIndex)...])
            guard let enumDecl = context.enums[enumName],
                  let enumCase = enumDecl.cases.first(where: { $0.name == caseLeaf }) else {
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
           let hit = matches.first(where: { $0.0.name == parent }) {
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
              enumCase.payloadTypes.isEmpty else {
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

    private static func lowerMemberCall(
        object: Expression,
        memberName: String,
        arguments: [CallArgument],
        expected: HIRType?,
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        // Qualified case constructor `Enum.Case(args)` (G4, P5-5): the
        // receiver is a user TYPE name, not a variable.
        if case .identifier(let typeName, _) = object, let enumDecl = context.enums[typeName],
           let enumCase = enumDecl.cases.first(where: { $0.name == memberName }) {
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

        // String member methods (G9): upper/lower/contains/substring/split.
        // `slice`/`get` fall through to the G2/G2b tolerant-read channels.
        if case .string = objectType,
           ["upper", "lower", "contains", "substring", "split"].contains(memberName) {
            return try lowerStringMethod(
                receiver: loweredObject, memberName: memberName, arguments: arguments,
                at: location, into: &context
            )
        }
        // Array member methods (G9): join on Array<String>.
        if case .array(let joinElem) = objectType, joinElem == .string, memberName == "join" {
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
                guard arguments.count == method.params.count else {
                    throw unsupported(
                        "method '\(memberName)' expects \(method.params.count) arguments, got \(arguments.count)",
                        at: location
                    )
                }
                // G13 batch 2: the call site uses the method's EFFECTIVE
                // return type (void-declared value-returning methods upgrade
                // to the body's returned type — same computation as the
                // definition side, so body and calls agree).
                let returnType = try effectiveReturnType(
                    decl: method, userTypes: context.userTypes,
                    nominals: context.nominalTypesMap, selfTypeName: typeName
                ) ?? method.returnTypes.first.map { annotation -> HIRType in
                    guard let type = HIRType(from: annotation) else {
                        throw unsupported(
                            "return type of '\(memberName)' is not resolvable",
                            at: location
                        )
                    }
                    return type
                }
                var arguments_ir = [loweredObject.node]
                for (index, argument) in arguments.enumerated() {
                    guard let annotation = method.params[index].typeAnnotation,
                          let paramType = HIRType(from: annotation) else {
                        throw unsupported(
                            "parameter '\(method.params[index].name)' of '\(memberName)' lacks a resolvable type",
                            at: location
                        )
                    }
                    let loweredArg = try lowerExpr(argument.expression, expected: paramType, into: &context)
                    try requireAssignable(loweredArg.type, to: paramType, at: location)
                    arguments_ir.append(loweredArg.node)
                }
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
                          }) else { continue }
                    let loweredCall = try lowerTraitDefaultCall(
                        defaultMethod, receiver: loweredObject.node, receiverType: objectType,
                        arguments: arguments, at: location, into: &context
                    )
                    return loweredCall                }
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
            let wrapped: HIRType
            switch objectType {
            case .array(let element): wrapped = element
            case .string: wrapped = .string
            default:
                throw unsupported(".get on type '\(objectType)' outside this grid (Array/String)", at: location)
            }
            let loweredIndex = try lowerExpr(arguments[0].expression, expected: .i32, into: &context)
            guard loweredIndex.type == .i32 else {
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
        default:
            // G11 multidim corpus: the interpreter's direct subscript read
            // yields a bare value (the Optional-returning read channel is a
            // separate, not-yet-landed semantic), so some/none arms never
            // fire and the match falls through silently (probe-verified —
            // applies at any scrutinee depth: outer `match m[1]` on
            // array(I32), inner `match row[2]` on I32). Parity: lower every
            // arm body with its binding typed by the scrutinee itself (the
            // value a live some-arm would bind), but drop the dispatch.
            var hirCases: [HIRMatchCase] = []
            for matchCase in cases {
                let body = try lowerDeadArmBody(matchCase, bindingType: loweredValue.type, into: &context)
                hirCases.append(HIRMatchCase(caseName: matchCase.pattern.description, bindings: matchCase.bindings.map { $0.varName }, body: body))
            }
            return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
        }
    }

    /// G11: one dead-arm body of a match whose scrutinee is neither Optional
    /// nor enum — the arm is never dispatched at emission (probe-verified
    /// silent fall-through in the interpreter); the body still lowers so its
    /// bindings scope-resolve. Each binding adopts the scrutinee type (the
    /// value a live some-arm would bind), wildcard/none arms bind nothing.
    private static func lowerDeadArmBody(
        _ matchCase: MatchCase,
        bindingType: HIRType,
        into context: inout FunctionContext
    ) throws -> [HIRStmt] {
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
                          matchCase.bindings[0].varName != "_" else {
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
            let leafName = rawCaseName.contains(".")
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
        if case .subscript(let container, let index, _) = left {
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
        guard !elements.isEmpty || elementExpected != nil else {
            throw unsupported(
                "empty array literal needs an element type (annotate the variable)",
                at: location
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
        let bodyParams = defaultMethod.params.first?.name == "self"
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
                  let paramType = resolveAnnotationType(annotation, userTypes: context.userTypes) else {
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
        context.traitDefaultsCollector.add(try lowerMethod(
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
              let fieldDecl = info.fields.first(where: { $0.name == field }) else {
            return nil
        }
        return HIRType(from: fieldDecl.typeAnnotation)
    }

    /// Slice set: exact match only. Widening (I32 literal into I64 slot) is
    /// already handled at the literal level via `expected`; non-matching
    /// composite/implicit coercions are later grids.
    private static func requireAssignable(_ from: HIRType, to: HIRType, at location: SourceLocation) throws {
        guard from == to else {
            throw unsupported("type mismatch: \(from) is not \(to)", at: location)
        }
    }

    private static func unsupported(_ message: String, at location: SourceLocation) -> HIRLoweringError {
        HIRLoweringError(message: message, location: location)
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
            switch inferHIRType(of: value, userTypes: userTypes, nominals: nominals,
                                selfTypeName: selfTypeName) {
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
                  let field = info.fields.first(where: { $0.name == fieldName }) else {
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
                  let method = info.methods.first(where: { $0.name == methodName }) else {
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
            default: return nil
            }
        case .generic(let name, let params, _):
            // `^T` surface form (Result type sugar, ADR-032): pins the ok
            // payload; the error slot is type-erased in the IR ABI (LR-12).
            if name == "Result", let first = params.first,
               let ok = HIRType(from: first) {
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
            // `*T` (G14, ADR-015 FFI): element recurses; the pointer itself
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
            self = .tuple(labels: labels, fieldTypes: fieldTypes)
        case .function(let params, let returns, _, _):
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
            self = .function(params: paramTypes, returnType: returnType)
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
        default: return nil
        }
    }

    /// Map an AST binary operator onto the slice set; nil for operators the
    /// slice does not carry (bitwise/shift/compound-assign are later grids).
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
}

/// Per-function lowering context: variable slot types, the enclosing
/// function's return type, the module-wide signatures from the pre-pass,
/// the nominal type registry (G3), the user-type name table and enum
/// registry (G4).
/// `errorBindings` tracks names currently bound to a try-else error word so
/// `return err` can re-box and print can gate on the type-erased ABI.
private struct FunctionContext {
    let functionName: String
    let returnType: HIRType?
    let typeInference: TypeInference?
    var variableTypes: [String: HIRType]
    let moduleSignatures: [String: HIRLowererSignatureInfo]
    let nominalTypes: [String: HIRLowerer.NominalInfo]
    let userTypes: [String: HIRType]
    let enums: [String: HIREnumDecl]
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
    /// G12: receiver field types for bare-name resolution inside method
    /// bodies (interpreter bindInstanceFields parity). Empty outside methods.
    var selfFieldTypes: [String: HIRType] = [:]
    var selfTypeNameLowered: String?
    var selfIsObjectLowered: Bool = false
    var errorBindings: Set<String> = []

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
        genericFuncTemplates: [String: FuncDecl] = [:],
        closureIds: [String: Int] = [:],
        traitRegistry: HIRLowerer.TraitRegistry = HIRLowerer.TraitRegistry(traits: [:], typeTraits: [:]),
        traitDefaultsCollector: HIRLowerer.TraitDefaultCollector = HIRLowerer.TraitDefaultCollector()
    ) {
        self.functionName = functionName
        self.returnType = returnType
        self.variableTypes = paramTypes
        self.typeInference = typeInference
        self.moduleSignatures = moduleSignatures
        self.nominalTypes = nominalTypes
        self.userTypes = userTypes
        self.enums = enums
        self.genericFuncTemplates = genericFuncTemplates
        self.closureIds = closureIds
        self.traitRegistry = traitRegistry
        self.traitDefaultsCollector = traitDefaultsCollector
    }

    func inferType(of expression: Expression) -> TypeAnnotation? {
        typeInference?.infer(expression: expression)
    }
}
