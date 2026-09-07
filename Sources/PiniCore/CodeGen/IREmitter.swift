import Foundation

/// HIR -> LLVM IR text emitter for the M4 vertical slice (LR-2/LR-3).
///
/// The emitter is a mechanical translation: every type decision was already
/// made by `HIRLowerer` (the single capability gate), so this file contains no
/// type inference, no shadow type tables, and no unsupported paths — the
/// slice node set is emitted in full. State is per-emission: create one fresh
/// emitter per module; nothing is shared with the legacy `IRGenerator`.
///
/// Output contract: LLVM IR text that `lli`/`clang` execute with stdout
/// semantics matching the interpreter (print = value + newline; bool as
/// true/false; double via %f — see the print-format parity note in
/// issue-llvm-rewrite-plan-2026-09-07 for the known F64 divergence).
public final class IREmitter {

    // MARK: - Per-function state

    /// Block-nested variable slots: scopes.last is the innermost block.
    /// Mirrors the HIR tree nesting so shadowing declarations resolve
    /// innermost-first at emit time.
    private var scopes: [[String: String]] = []

    /// Per-function slot-name counters so shadowing declarations get fresh
    /// allocas instead of colliding with the outer slot.
    private var slotCounters: [String: Int] = [:]

    /// Current block terminated by `ret`; later statements in the block are
    /// unreachable and must not be emitted (instructions after a terminator
    /// are invalid IR).
    private var terminated = false

    private var currentIsMain = false
    private var currentReturnType: HIRType? = nil

    private var builder = IRBuilder()
    private var bodyIR = ""

    // MARK: - Module-level collected pieces

    private var stringConstantDefs: [String] = []
    private var stringConstants: [String: (name: String, length: Int)] = [:]
    private var usesStrCmp = false

    public init() {}

    // MARK: - Module

    public func emit(module: HIRModule) -> String {
        var header = "; Pini LLVM IR (HIR pipeline, M4 slice)\n"
        header += "declare i32 @printf(ptr, ...)\n"
        header += "declare ptr @bk_double_to_string(double)\n"
        header += "declare ptr @free(ptr)\n"
        header += "@fmt_int = private constant [3 x i8] c\"%d\\00\"\n"
        header += "@fmt_bool_true = private constant [6 x i8] c\"true\\00\\00\"\n"
        header += "@fmt_bool_false = private constant [7 x i8] c\"false\\00\\00\"\n"
        header += "@fmt_string = private constant [3 x i8] c\"%s\\00\"\n"
        header += "@fmt_newline = private constant [2 x i8] c\"\\0A\\00\"\n"
        // Array family (G2): opaque handle type + runtime C ABI declares.
        // Forward references are legal in LLVM IR modules (same contract as
        // the legacy IRGenerator header), so declares are unconditional.
        header += "%bk_array = type { ptr }\n"
        header += "declare ptr @bk_array_create(i32)\n"
        header += "declare i32 @bk_array_len(ptr)\n"
        header += "declare ptr @bk_array_get(ptr, i32)\n"
        header += "declare ptr @bk_array_set(ptr, i32, ptr, i32, i32)\n"
        header += "declare void @bk_handle_retain(ptr)\n"
        header += "declare ptr @bk_handle_ensure_unique(ptr)\n"
        header += "declare ptr @bk_array_ensure_unique_at(ptr, i32)\n"
        header += "\n"

        bodyIR = ""
        stringConstantDefs = []
        stringConstants = [:]
        usesStrCmp = false
        for function in module.functions {
            emitFunction(function)
        }

        var tail = ""
        for def in stringConstantDefs {
            tail += def + "\n"
        }
        if usesStrCmp {
            tail += "declare i32 @strcmp(ptr, ptr)\n"
        }
        return header + tail + "\n" + bodyIR
    }

    // MARK: - Functions

    private func emitFunction(_ function: HIRFunction) {
        builder.reset()
        scopes = [[:]]
        slotCounters = [:]
        terminated = false
        currentIsMain = function.name == "main"
        currentReturnType = function.returnType

        // main is the process entry: emitted with i32 return regardless of
        // the Pini-level void signature (bare returns become `ret i32 0`).
        let returnSpelling = currentIsMain
            ? "i32"
            : (function.returnType?.llvmSpelling ?? "void")
        let params = function.params.map { "\($0.type.llvmSpelling) %\(Self.mangle($0.name))" }
        bodyIR += "define \(returnSpelling) @\(Self.mangle(function.name))(\(params.joined(separator: ", "))) {\n"

        for param in function.params {
            let spelling = param.type.llvmSpelling
            let slot = "%\(Self.mangle(param.name))_slot"
            bodyIR += builder.fmtAlloca(name: slot, type: spelling) + "\n"
            bodyIR += builder.fmtStore(value: "%\(Self.mangle(param.name))", type: spelling, ptr: slot) + "\n"
            scopes[scopes.count - 1][param.name] = slot
        }

        emitBlock(function.body)

        if !terminated {
            bodyIR += builder.fmtBr(labelName: "exit_block") + "\n"
            bodyIR += "exit_block:\n"
            if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else if let returnType = function.returnType {
                bodyIR += " ret \(returnType.llvmSpelling) undef\n"
            } else {
                bodyIR += " ret void\n"
            }
        }
        bodyIR += "}\n\n"
    }

    // MARK: - Statements

    private func emitBlock(_ statements: [HIRStmt]) {
        for statement in statements {
            if terminated { break }
            emitStatement(statement)
        }
    }

    private func emitStatement(_ statement: HIRStmt) {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            let slot = freshSlot(for: name)
            bodyIR += builder.fmtAlloca(name: slot, type: type.llvmSpelling) + "\n"
            scopes[scopes.count - 1][name] = slot
            if let initializer = initializer {
                let value = emitExpr(initializer)
                bodyIR += builder.fmtStore(value: value.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"
            }

        case .storeVar(let name, let type, let value):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: store to undeclared variable '\(name)' (HIRLowerer guarantees declarations)")
            }
            let lowered = emitExpr(value)
            bodyIR += builder.fmtStore(value: lowered.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"

        case .ifStmt(let condition, let thenBody, let elseBody):
            emitIf(condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let loopBody):
            emitWhile(condition: condition, loopBody: loopBody)

        case .returnStmt(let value):
            if let value = value {
                let lowered = emitExpr(value)
                bodyIR += " ret \(lowered.llvmType) \(lowered.ssaName)\n"
            } else if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else {
                bodyIR += " ret void\n"
            }
            terminated = true

        case .exprStmt(let expr):
            _ = emitExpr(expr)

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, let type):
            emitTry(operand: operand, errorVar: errorVar, handler: handler, okTarget: okTarget, type: type)
        }
    }

    /// `try operand else errorVar: handler` — the err slot of the Result
    /// aggregate is a type-erased machine word (LR-12); the ok slot carries
    /// the payload type exactly. The error binding's slot is allocated at the
    /// try site and the handler runs as its own block scope; when the handler
    /// does not terminate (statement position / pass), control falls into the
    /// ok label, which stores the payload when this is expression position.
    private func emitTry(operand: HIRExpr, errorVar: String, handler: [HIRStmt], okTarget: String?, type: HIRType) {
        let errSlot = freshSlot(for: errorVar)
        bodyIR += builder.fmtAlloca(name: errSlot, type: "i64") + "\n"
        scopes[scopes.count - 1][errorVar] = errSlot

        let resultValue = emitExpr(operand)
        let aggregate = resultValue.llvmType
        let tag = builder.freshTemp()
        bodyIR += " \(tag) = extractvalue \(aggregate) \(resultValue.ssaName), 0\n"
        let isOk = builder.freshTemp()
        bodyIR += " \(isOk) = icmp eq i64 \(tag), 0\n"
        let id = builder.freshLabel()
        let okLabel = "try.ok.\(id)"
        let errLabel = "try.err.\(id)"
        bodyIR += builder.fmtCondBr(cond: isOk, thenLabelName: okLabel, elseLabelName: errLabel) + "\n"

        bodyIR += "\(errLabel):\n"
        scopes.append([:])
        terminated = false
        let errWord = builder.freshTemp()
        bodyIR += " \(errWord) = extractvalue \(aggregate) \(resultValue.ssaName), 2\n"
        bodyIR += builder.fmtStore(value: errWord, type: "i64", ptr: errSlot) + "\n"
        emitBlock(handler)
        let handlerTerminated = terminated
        if !handlerTerminated {
            bodyIR += builder.fmtBr(labelName: okLabel) + "\n"
        }
        scopes.removeLast()

        bodyIR += "\(okLabel):\n"
        if let okTarget = okTarget {
            guard let okSlot = lookupSlot(okTarget) else {
                fatalError("IREmitter: try ok target '\(okTarget)' undeclared (HIRLowerer guarantees the allocation)")
            }
            guard case .result(let okType) = type else {
                fatalError("IREmitter: tryStmt type is not a Result (HIRLowerer guarantees)")
            }
            terminated = false
            let payload = builder.freshTemp()
            bodyIR += " \(payload) = extractvalue \(aggregate) \(resultValue.ssaName), 1\n"
            bodyIR += builder.fmtStore(value: payload, type: okType.llvmSpelling, ptr: okSlot) + "\n"
        } else {
            terminated = false
        }
    }

    private func emitIf(condition: HIRExpr, thenBody: [HIRStmt], elseBody: [HIRStmt]?) {
        let cond = emitExpr(condition)
        let id = builder.freshLabel()
        let thenLabel = "if.then.\(id)"
        let endLabel = "if.end.\(id)"
        let elseLabel = elseBody != nil ? "if.else.\(id)" : endLabel
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: thenLabel, elseLabelName: elseLabel) + "\n"

        bodyIR += "\(thenLabel):\n"
        scopes.append([:])
        terminated = false
        emitBlock(thenBody)
        let thenTerminated = terminated
        if !thenTerminated {
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        }
        scopes.removeLast()

        var elseTerminated = false
        if let elseBody = elseBody {
            bodyIR += "\(elseLabel):\n"
            scopes.append([:])
            terminated = false
            emitBlock(elseBody)
            elseTerminated = terminated
            if !elseTerminated {
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
            }
            scopes.removeLast()
        }

        // The merge block is skippable only when both branches are covered by
        // an else and both returned. Without an else, the condition's false
        // edge targets the merge label, so it must always be emitted.
        if elseBody != nil && thenTerminated && elseTerminated {
            terminated = true
        } else {
            bodyIR += "\(endLabel):\n"
            terminated = false
        }
    }

    private func emitWhile(condition: HIRExpr, loopBody: [HIRStmt]) {
        let id = builder.freshLabel()
        let condLabel = "while.cond.\(id)"
        let bodyLabel = "while.body.\(id)"
        let exitLabel = "while.end.\(id)"

        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        bodyIR += "\(condLabel):\n"
        let cond = emitExpr(condition)
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: bodyLabel, elseLabelName: exitLabel) + "\n"

        bodyIR += "\(bodyLabel):\n"
        scopes.append([:])
        terminated = false
        emitBlock(loopBody)
        if !terminated {
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        }
        scopes.removeLast()

        // A loop's exit is always reachable (zero iterations), so control
        // flow resumes there regardless of body termination.
        bodyIR += "\(exitLabel):\n"
        terminated = false
    }

    // MARK: - Expressions

    private func emitExpr(_ expr: HIRExpr) -> IRValue {
        switch expr {
        case .intConst(let value, let type):
            return IRValue(llvmType: type.llvmSpelling, ssaName: String(value))

        case .floatConst(let value):
            return IRValue(llvmType: "double", ssaName: doubleLiteral(value))

        case .boolConst(let value):
            return IRValue(llvmType: "i1", ssaName: value ? "true" : "false")

        case .stringConst(let value):
            return emitStringConstant(value)

        case .load(let name, let type):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: load of undeclared variable '\(name)' (HIRLowerer guarantees declarations)")
            }
            let temp = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: temp, type: type.llvmSpelling, ptr: slot) + "\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: temp)

        case .binary(let op, let lhs, let rhs, let type):
            return emitBinary(op: op, lhs: lhs, rhs: rhs, type: type)

        case .unary(let op, let operand, let type):
            let lowered = emitExpr(operand)
            let temp = builder.freshTemp()
            switch op {
            case .negate:
                if lowered.llvmType == "double" {
                    bodyIR += " \(temp) = fneg double \(lowered.ssaName)\n"
                } else {
                    bodyIR += " \(temp) = sub \(lowered.llvmType) 0, \(lowered.ssaName)\n"
                }
            case .logicalNot:
                bodyIR += " \(temp) = xor i1 \(lowered.ssaName), 1\n"
            }
            return IRValue(llvmType: type.llvmSpelling, ssaName: temp)

        case .call(let function, let arguments, let returnType):
            let args = arguments.map { emitExpr($0) }
            let argList = args.map { "\($0.llvmType) \($0.ssaName)" }.joined(separator: ", ")
            let callee = "@\(Self.mangle(function))"
            if let returnType = returnType {
                let temp = builder.freshTemp()
                bodyIR += " \(temp) = call \(returnType.llvmSpelling) \(callee)(\(argList))\n"
                return IRValue(llvmType: returnType.llvmSpelling, ssaName: temp)
            }
            bodyIR += " call void \(callee)(\(argList))\n"
            return IRValue(llvmType: "void", ssaName: "")

        case .printCall(let argument):
            return emitPrint(argument)

        case .resultConstruct(let isOk, let payload, let type):
            guard case .result = type else {
                fatalError("IREmitter: resultConstruct type is not a Result (HIRLowerer guarantees)")
            }
            let p = emitExpr(payload)
            let aggregate = type.llvmSpelling
            let withTag = builder.freshTemp()
            bodyIR += " \(withTag) = insertvalue \(aggregate) undef, i64 \(isOk ? 0 : 1), 0\n"
            let filled = builder.freshTemp()
            if isOk {
                bodyIR += " \(filled) = insertvalue \(aggregate) \(withTag), \(p.llvmType) \(p.ssaName), 1\n"
            } else {
                let word = widenToWord(p)
                bodyIR += " \(filled) = insertvalue \(aggregate) \(withTag), i64 \(word.ssaName), 2\n"
            }
            return IRValue(llvmType: aggregate, ssaName: filled)

        case .arrayLiteral(let elements, let type):
            return emitArrayLiteral(elements: elements, type: type)

        case .subscriptGet(let container, let index, let type):
            return emitSubscriptGet(container: container, index: index, type: type)

        case .lenCall(let argument):
            return emitLen(argument)
        }
    }

    // MARK: - Array family (G2)

    /// Element boxing ABI against the runtime `_BkTag` values: the tag lets
    /// the runtime distinguish raw scalars from nested container handles
    /// (release / COW semantics). Strings mirror the legacy emitter exactly:
    /// their `i8*` spelling carries the handle tag (the boxed slot owns a
    /// refcounted box, not the string bytes).
    private func arrayElementABI(_ type: HIRType) -> (spelling: String, width: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 4)
        case .array: return ("%bk_array*", 8, 4)
        default:
            fatalError("IREmitter: no array element ABI for '\(type)' (HIRLowerer gates element types)")
        }
    }

    /// Alias-point retain (ownership contract 3): a `.load` value node means
    /// the source variable still holds its share, so copying it into a new
    /// holder requires one extra share. Temporaries (literals, subscript
    /// reads, call results) transfer ownership and must NOT retain.
    private func emitRetainIfAliased(_ valueNode: HIRExpr) {
        guard case .load(_, let valueType) = valueNode, valueType.llvmSpelling == "%bk_array*" else {
            return
        }
        let slotValue = emitExpr(valueNode)
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(slotValue.ssaName) to ptr\n"
        bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
    }

    private func emitArrayLiteral(elements: [HIRExpr], type: HIRType) -> IRValue {
        guard case .array(let elementType) = type else {
            fatalError("IREmitter: arrayLiteral type is not an array (HIRLowerer guarantees)")
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        let createTemp = builder.freshTemp()
        bodyIR += " \(createTemp) = call ptr @bk_array_create(i32 \(elements.count))\n"
        // The construction handle is always unique (create starts at shares==1),
        // but the set calls are threaded anyway so construction and write-back
        // share one shape (legacy emitter contract).
        var curRaw = createTemp
        for (index, element) in elements.enumerated() {
            let value = emitExpr(element)
            let boxPtr = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
            bodyIR += builder.fmtStore(value: value.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
            emitRetainIfAliased(element)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_array_set(ptr \(curRaw), i32 \(index), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_array*\n"
        return IRValue(llvmType: "%bk_array*", ssaName: handle)
    }

    private func emitSubscriptGet(container: HIRExpr, index: HIRExpr, type: HIRType) -> IRValue {
        let containerValue = emitExpr(container)
        let indexValue = emitExpr(index)
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(containerValue.ssaName) to ptr\n"
        let boxPtr = builder.freshTemp()
        bodyIR += " \(boxPtr) = call ptr @bk_array_get(ptr \(raw), i32 \(indexValue.ssaName))\n"
        let value = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: value, type: type.llvmSpelling, ptr: boxPtr) + "\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: value)
    }

    private func emitLen(_ argument: HIRExpr) -> IRValue {
        let value = emitExpr(argument)
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(value.ssaName) to ptr\n"
        let count = builder.freshTemp()
        bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
        return IRValue(llvmType: "i32", ssaName: count)
    }

    /// Widen any scalar payload to the type-erased error word (i64): sign /
    /// zero extension, pointer-to-int, or bitcast for doubles.
    private func widenToWord(_ value: IRValue) -> IRValue {
        switch value.llvmType {
        case "i64":
            return value
        case "i32":
            let t = builder.freshTemp()
            bodyIR += " \(t) = sext i32 \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "i1":
            let t = builder.freshTemp()
            bodyIR += " \(t) = zext i1 \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "i8*":
            let t = builder.freshTemp()
            bodyIR += " \(t) = ptrtoint ptr \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "double":
            let t = builder.freshTemp()
            bodyIR += " \(t) = bitcast double \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        default:
            fatalError("IREmitter: no word widening for '\(value.llvmType)' (HIRLowerer gates non-scalar payloads)")
        }
    }

    private func emitBinary(op: HIRBinaryOp, lhs: HIRExpr, rhs: HIRExpr, type: HIRType) -> IRValue {
        let lhsValue = emitExpr(lhs)
        let rhsValue = emitExpr(rhs)
        let temp = builder.freshTemp()

        if op.isComparison {
            let predicate = comparePredicate(op: op, operandType: lhsValue.llvmType, temp: temp,
                                             lhs: lhsValue, rhs: rhsValue)
            bodyIR += " \(temp) = \(predicate)\n"
            return IRValue(llvmType: "i1", ssaName: temp)
        }

        let instruction: String
        if lhsValue.llvmType == "double" {
            switch op {
            case .add: instruction = "fadd"
            case .subtract: instruction = "fsub"
            case .multiply: instruction = "fmul"
            case .divide: instruction = "fdiv"
            case .modulo: instruction = "frem"
            default: instruction = "add"
            }
        } else {
            switch op {
            case .add: instruction = "add"
            case .subtract: instruction = "sub"
            case .multiply: instruction = "mul"
            case .divide: instruction = "sdiv"
            case .modulo: instruction = "srem"
            default: instruction = "add"
            }
        }
        bodyIR += " \(temp) = \(instruction) \(lhsValue.llvmType) \(lhsValue.ssaName), \(rhsValue.ssaName)\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: temp)
    }

    /// Comparison line body for the operand kind. Strings compare via strcmp
    /// against zero; floats use ordered fcmp; integers/bools use icmp.
    private func comparePredicate(op: HIRBinaryOp, operandType: String, temp: String,
                                  lhs: IRValue, rhs: IRValue) -> String {
        if operandType == "i8*" {
            usesStrCmp = true
            let cmpTemp = builder.freshTemp()
            bodyIR += " \(cmpTemp) = call i32 @strcmp(ptr \(lhs.ssaName), ptr \(rhs.ssaName))\n"
            let intPredicate: String
            switch op {
            case .equal: intPredicate = "eq"
            case .notEqual: intPredicate = "ne"
            case .lessThan: intPredicate = "slt"
            case .lessThanOrEqual: intPredicate = "sle"
            case .greaterThan: intPredicate = "sgt"
            case .greaterThanOrEqual: intPredicate = "sge"
            default: intPredicate = "eq"
            }
            return "icmp \(intPredicate) i32 \(cmpTemp), 0"
        }
        let predicate: String
        if operandType == "double" {
            switch op {
            case .equal: predicate = "oeq"
            case .notEqual: predicate = "one"
            case .lessThan: predicate = "olt"
            case .lessThanOrEqual: predicate = "ole"
            case .greaterThan: predicate = "ogt"
            case .greaterThanOrEqual: predicate = "oge"
            default: predicate = "oeq"
            }
            return "fcmp \(predicate) \(operandType) \(lhs.ssaName), \(rhs.ssaName)"
        }
        switch op {
        case .equal: predicate = "eq"
        case .notEqual: predicate = "ne"
        case .lessThan: predicate = "slt"
        case .lessThanOrEqual: predicate = "sle"
        case .greaterThan: predicate = "sgt"
        case .greaterThanOrEqual: predicate = "sge"
        default: predicate = "eq"
        }
        return "icmp \(predicate) \(operandType) \(lhs.ssaName), \(rhs.ssaName)"
    }

    /// Intrinsic print: printf by operand type, then a newline (interpreter
    /// print semantics). F64 goes through the runtime's bk_double_to_string
    /// (shortest round-trip, spec "value display semantics" note, LR-8) so
    /// both backends render identically; the malloc'd C string is freed
    /// right after printf consumes it.
    private func emitPrint(_ argument: HIRExpr) -> IRValue {
        let value = emitExpr(argument)
        switch value.llvmType {
        case "i1":
            let sel = builder.freshTemp()
            bodyIR += " \(sel) = select i1 \(value.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(sel))\n"
        case "i64":
            // Narrow to i32 for %d; `sext i64 -> i32` is an invalid cast (the
            // legacy emitter has this same bug — registered separately).
            let narrow = builder.freshTemp()
            bodyIR += " \(narrow) = trunc i64 \(value.ssaName) to i32\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, i32 \(narrow))\n"
        case "double":
            let rendered = builder.freshTemp()
            bodyIR += " \(rendered) = call ptr @bk_double_to_string(double \(value.ssaName))\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(rendered))\n"
            bodyIR += " call ptr @free(ptr \(rendered))\n"
        case "i8*":
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(value.ssaName))\n"
        default:
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, \(value.llvmType) \(value.ssaName))\n"
        }
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    private func emitStringConstant(_ value: String) -> IRValue {
        let entry: (name: String, length: Int)
        if let existing = stringConstants[value] {
            entry = existing
        } else {
            let id = stringConstantDefs.count
            let name = "@.str\(id)"
            let bytes = Array(value.utf8)
            let length = bytes.count + 1
            var hex = ""
            for byte in bytes {
                hex += String(format: "\\%02X", byte)
            }
            stringConstantDefs.append("\(name) = private constant [\(length) x i8] c\"\(hex)\\00\"")
            entry = (name, length)
            stringConstants[value] = entry
        }
        let temp = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: temp, aggregate: "[\(entry.length) x i8]", base: entry.name, indices: [0, 0]) + "\n"
        return IRValue(llvmType: "i8*", ssaName: temp)
    }

    // MARK: - Slots & literals

    private func freshSlot(for name: String) -> String {
        let base = Self.mangle(name) + "_slot"
        let count = slotCounters[base] ?? 0
        slotCounters[base] = count + 1
        return count == 0 ? "%\(base)" : "%\(base)_\(count)"
    }

    private func lookupSlot(_ name: String) -> String? {
        for scope in scopes.reversed() {
            if let slot = scope[name] { return slot }
        }
        return nil
    }

    /// LLVM double literal: decimal form when it round-trips unambiguously,
    /// hex bit-pattern form otherwise (exponent notation, inf/nan, -0.0).
    private func doubleLiteral(_ value: Double) -> String {
        if value.isNaN || value.isInfinite || value == 0 {
            return "0x" + String(format: "%016llX", value.bitPattern)
        }
        let text = String(value)
        if text.contains("e") || text.contains("E") {
            return "0x" + String(format: "%016llX", value.bitPattern)
        }
        return text.contains(".") ? text : text + ".0"
    }

    /// Hex-encode non-ASCII identifiers into LLVM-safe names (`点` -> `_u70B9`).
    /// Same scheme as the legacy IRGenerator mangle; duplicated here so the
    /// new pipeline shares zero mutable state with the old one.
    static func mangle(_ name: String) -> String {
        var needs = false
        for byte in name.utf8 where byte > 127 {
            needs = true
            break
        }
        if !needs { return name }
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.value < 128 {
                result.append(Character(scalar))
            } else {
                result += "_u" + String(format: "%04X", scalar.value)
            }
        }
        return result
    }
}
