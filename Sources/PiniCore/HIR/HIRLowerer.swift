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

    /// G3 nominal registry entry: the AST declaration of a struct/object
    /// plus methods merged in from `((T))`/`{{T}}` extension blocks
    /// (data/logic separation — the parser puts methods in extensions).
    fileprivate struct NominalInfo {
        let name: String
        let isObject: Bool
        let decl: TopLevelDecl
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
    }

    /// Lower a checked module. `typeInference` is the TypeChecker's inference
    /// output; callers must run the checker first (same contract as the old
    /// `typeCheckThenGenerate` pipeline).
    public static func lower(module: Module, typeInference: TypeInference?) throws -> HIRModule {
        // Pre-pass: capture every declared function's signature so bodies can
        // call functions declared later in the file.
        var signatures: [String: HIRLowererSignatureInfo] = [:]
        for decl in module.declarations {
            if case .funcDecl(let funcDecl) = decl {
                let paramTypes = try funcDecl.params.map { parameter -> HIRType in
                    guard let annotation = parameter.typeAnnotation,
                          let type = HIRType(from: annotation) else {
                        throw unsupported(
                            "parameter '\(parameter.name)' of '\(funcDecl.name)' lacks a resolvable scalar type",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                let returnType: HIRType? = try funcDecl.returnTypes.first.map { annotation in
                    guard let type = HIRType(from: annotation) else {
                        throw unsupported(
                            "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(funcDecl.name)'",
                            at: funcDecl.location
                        )
                    }
                    return type
                }
                signatures[funcDecl.name] = HIRLowererSignatureInfo(
                    paramTypes: paramTypes, returnType: returnType
                )
            }
        }

        // G3 pre-pass: nominal type registry (structs/objects), with methods
        // merged in from extension blocks ((T)) / {{T}}.
        var nominals: [String: NominalInfo] = [:]
        for decl in module.declarations {
            switch decl {
            case .structDecl(let sd): nominals[sd.name] = NominalInfo(name: sd.name, isObject: false, decl: decl)
            case .objectDecl(let od): nominals[od.name] = NominalInfo(name: od.name, isObject: true, decl: decl)
            default: break
            }
        }
        for decl in module.declarations {
            if case .extensionDecl(let ext) = decl, ext.kind == .structExt || ext.kind == .objectExt,
               nominals[ext.targetType] != nil {
                nominals[ext.targetType]!.extensionMethods.append(contentsOf: ext.methods)
            }
        }

        var functions: [HIRFunction] = []
        for decl in module.declarations {
            switch decl {
            case .funcDecl(let funcDecl):
                functions.append(
                    try lowerFunction(funcDecl, typeInference: typeInference, moduleSignatures: signatures,
                                      nominalTypes: nominals)
                )
            case .structDecl, .objectDecl, .extensionDecl:
                // Handled by the nominal-type pass below.
                continue
            default:
                throw unsupported(
                    "top-level construct outside the slice (named functions + struct/object types)",
                    at: module.location
                )
            }
        }
        guard functions.contains(where: { $0.name == "main" }) else {
            throw unsupported("no 'main' function found", at: module.location)
        }

        // G3: lower nominal type declarations (field defaults via a scratch
        // context; methods as self-parameterized functions with mangled IR
        // names `方法__类型` so they cannot collide with top-level functions).
        var typeDecls: [HIRTypeDecl] = []
        for decl in module.declarations {
            switch decl {
            case .structDecl(let sd):
                typeDecls.append(try lowerNominal(
                    name: sd.name, isObject: false, fields: sd.fields,
                    methods: nominals[sd.name]!.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals
                ))
            case .objectDecl(let od):
                typeDecls.append(try lowerNominal(
                    name: od.name, isObject: true, fields: od.fields,
                    methods: nominals[od.name]!.methods,
                    typeInference: typeInference, moduleSignatures: signatures, nominalTypes: nominals
                ))
            default:
                break
            }
        }
        return HIRModule(functions: functions, types: typeDecls)
    }

    // MARK: - Functions

    private static func lowerFunction(
        _ decl: FuncDecl,
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: NominalInfo]
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
            guard let type = HIRType(from: annotation) else {
                throw unsupported(
                    "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(decl.name)'",
                    at: decl.location
                )
            }
            return type
        }

        var params: [HIRFunction.HIRParam] = []
        for param in decl.params {
            guard let annotation = param.typeAnnotation,
                  let type = HIRType(from: annotation) else {
                throw unsupported(
                    "parameter '\(param.name)' of '\(decl.name)' lacks a resolvable scalar type",
                    at: decl.location
                )
            }
            params.append(HIRFunction.HIRParam(name: param.name, type: type))
        }

        var context = FunctionContext(
            functionName: decl.name,
            returnType: returnType,
            paramTypes: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.type) }),
            typeInference: typeInference,
            moduleSignatures: moduleSignatures,
            nominalTypes: nominalTypes
        )
        let body = try lowerBlock(decl.body!, into: &context)
        return HIRFunction(name: decl.name, params: params, returnType: returnType, body: body)
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
        nominalTypes: [String: NominalInfo]
    ) throws -> HIRTypeDecl {
        let selfType = HIRType.nominal(name: name, isObject: isObject)
        var scratch = FunctionContext(
            functionName: "<field-default:\(name)>", returnType: nil, paramTypes: [:],
            typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes
        )
        var loweredFields: [HIRTypeDecl.Field] = []
        for field in fields {
            guard let fieldType = HIRType(from: field.typeAnnotation) else {
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
                typeInference: typeInference, moduleSignatures: moduleSignatures, nominalTypes: nominalTypes
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
        nominalTypes: [String: NominalInfo]
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
            guard let type = HIRType(from: annotation) else {
                throw unsupported(
                    "return type '\(annotation.simpleName ?? "(non-scalar)")' of '\(decl.name)'",
                    at: decl.location
                )
            }
            return type
        }
        var params = [HIRFunction.HIRParam(name: "self", type: selfType)]
        for param in decl.params {
            guard let annotation = param.typeAnnotation,
                  let type = HIRType(from: annotation) else {
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
            returnType: returnType,
            paramTypes: Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.type) }),
            typeInference: typeInference,
            moduleSignatures: moduleSignatures,
            nominalTypes: nominalTypes
        )
        let body = try lowerBlock(decl.body!, into: &context)
        return HIRFunction(name: irName, params: params, returnType: returnType, body: body)
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
            guard let type = HIRType(from: annotation) else {
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
            case .string: elementType = .string
            default:
                throw unsupported(
                    "subscript on non-array type '\(loweredContainer.type)'",
                    at: location
                )
            }
            let loweredIndex = try lowerExpr(index, expected: .i32, into: &context)
            guard loweredIndex.type == .i32 else {
                throw unsupported("array subscript needs an I32 index", at: location)
            }
            return LoweredExpr(
                node: .subscriptGet(container: loweredContainer.node, index: loweredIndex.node, type: elementType),
                type: elementType
            )

        case .identifier(let name, let location):
            guard let type = context.variableTypes[name] else {
                throw unsupported("reference to undeclared variable '\(name)'", at: location)
            }
            return LoweredExpr(node: .load(name: name, type: type), type: type)

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
            let loweredBase = try lowerExpr(object, expected: nil, into: &context)
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

        case .call(let callee, let arguments, let location):
            // Member calls: the tolerant read channel `arr.get(i)` (G2) and
            // the slice channel `base.slice(start, end)` (G2b, the slice-
            // sugar desugaring). All other method calls stay gated.
            if case .member(let object, let memberName, _) = callee {
                return try lowerMemberCall(
                    object: object, memberName: memberName, arguments: arguments,
                    at: location, into: &context
                )
            }
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
                    throw unsupported("printing a Result value is outside the slice", at: location)
                }
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
            // Intrinsic len: arrays go through the runtime handle (bk_array_len);
            // other operand kinds are later grids.
            if functionName == "len" {
                guard loweredArgs.count == 1 else {
                    throw unsupported("len expects exactly one argument", at: location)
                }
                guard case .array = loweredArgs[0].type else {
                    throw unsupported(
                        "len on '\(loweredArgs[0].type)' is outside this grid (arrays only)",
                        at: location
                    )
                }
                return LoweredExpr(node: .lenCall(argument: loweredArgs[0].node), type: .i32)
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

        default:
            throw unsupported(
                "expression '\(expression.kindName)' outside the M4 slice",
                at: expressionLocation(expression)
            )
        }
    }

    // MARK: - Member .get & match (G2 batch 3)

    /// Member calls on built-in receivers. `.get(i)`: the tolerant read
    /// channel — out of bounds yields none (the language-level nil), in
    /// bounds some(value); negative indices tail-count (G2b fix: batch 3
    /// missed the tail count). `.slice(s, e)`: the slice-sugar desugaring;
    /// bounds are ints or the none literal. Only Array/String receivers are
    /// wired; Dictionary and other methods join their own grids.
    private static func lowerMemberCall(
        object: Expression,
        memberName: String,
        arguments: [CallArgument],
        at location: SourceLocation,
        into context: inout FunctionContext
    ) throws -> LoweredExpr {
        let loweredObject = try lowerExpr(object, expected: nil, into: &context)
        let objectType = loweredObject.type

        // Nominal method dispatch (G3): the receiver is the implicit first
        // argument; the callee is the mangled IR name `方法__类型`.
        if case .nominal(let typeName, _) = objectType {
            guard let info = context.nominalTypes[typeName],
                  let method = info.methods.first(where: { $0.name == memberName }) else {
                throw unsupported(
                    "undefined method '\(memberName)' on '\(objectType)'",
                    at: location
                )
            }
            guard arguments.count == method.params.count else {
                throw unsupported(
                    "method '\(memberName)' expects \(method.params.count) arguments, got \(arguments.count)",
                    at: location
                )
            }
            let returnType = try method.returnTypes.first.map { annotation -> HIRType in
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
        guard case .optional(let wrapped) = loweredValue.type else {
            throw unsupported(
                "match scrutinee type '\(loweredValue.type)' outside this grid (Optional only; enum match is a later grid)",
                at: location
            )
        }
        var hirCases: [HIRMatchCase] = []
        for matchCase in cases {
            switch matchCase.pattern {
            case .enumCase(let caseName):
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
                hirCases.append(HIRMatchCase(caseName: caseName, binding: bindingName, body: body))
            default:
                throw unsupported(
                    "match pattern '\(matchCase.pattern)' outside this grid (enum-case patterns only)",
                    at: matchCase.location
                )
            }
        }
        return .matchStmt(scrutinee: loweredValue.node, cases: hirCases, scrutineeType: loweredValue.type)
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
        guard let elementType = loweredContainer.type.arrayElementType else {
            throw unsupported(
                "subscript store on non-array type '\(loweredContainer.type)'",
                at: location
            )
        }
        let loweredIndex = try lowerExpr(index, expected: .i32, into: &context)
        guard loweredIndex.type == .i32 else {
            throw unsupported("array subscript needs an I32 index", at: location)
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
            case "I32": self = .i32
            case "I64": self = .i64
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
            return nil
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
/// and the nominal type registry (G3).
/// `errorBindings` tracks names currently bound to a try-else error word so
/// `return err` can re-box and print can gate on the type-erased ABI.
private struct FunctionContext {
    let functionName: String
    let returnType: HIRType?
    let typeInference: TypeInference?
    var variableTypes: [String: HIRType]
    let moduleSignatures: [String: HIRLowererSignatureInfo]
    let nominalTypes: [String: HIRLowerer.NominalInfo]
    var errorBindings: Set<String> = []

    init(
        functionName: String,
        returnType: HIRType?,
        paramTypes: [String: HIRType],
        typeInference: TypeInference?,
        moduleSignatures: [String: HIRLowererSignatureInfo],
        nominalTypes: [String: HIRLowerer.NominalInfo] = [:]
    ) {
        self.functionName = functionName
        self.returnType = returnType
        self.variableTypes = paramTypes
        self.typeInference = typeInference
        self.moduleSignatures = moduleSignatures
        self.nominalTypes = nominalTypes
    }

    func inferType(of expression: Expression) -> TypeAnnotation? {
        typeInference?.infer(expression: expression)
    }
}
