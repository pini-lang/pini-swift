import PiniBackendKit
import PiniIR

/// 试点通道：把 `IRModule` 翻成 embedded_min 字节码汇编。26 条指令、寄存器式、操作数内联。
/// 它的价值不在覆盖率，在**边际成本**：本文件只读 IR 与布局，不推导类型、不决定归还责任。
/// 加一条新通道若必须回到布局或归还责任那两行去改，说明那两行没归位干净。

///  注意  能力表按族表态，族内个别节点仍可拒绝：拒绝一律抛 `BackendError` 并写明节点与族。
/// 静默跳过会产出能读却错的码。
public struct EmbeddedMinBackend: PiniBackend {

    public static var identifier: String { "embedded_min" }

    public static var capabilities: BackendCapabilities { .embeddedMin }

    public init() {}

    public func emit(module: IRModule) throws -> String {
        var builder = Builder(functions: Set(module.functions.map(\.name)))
        return try builder.emit(module)
    }
}

extension BackendCapabilities {
    /// 只认值语义的一角：标量 · 变量与运算 · 控制流 · 直接调用 · 字符串。
    /// 其余九族显式拒绝，拒绝由 `EmbeddedMinBackend` 逐节点抛出。
    public static let embeddedMin = BackendCapabilities(
        output: .bytecode,
        supported: [.scalars, .variablesAndOperators, .controlFlow, .calls, .strings])
}

// MARK: - 发射器

private struct Builder {

    /// 常量池的一项。相同值与种类只占一个槽，故产物不随出现次数膨胀。
    private enum Constant: Hashable {
        case integer(Int)
        case float(Double)
        case boolean(Bool)
        case string(String)

        var listing: String {
            switch self {
            case .integer(let v): return "int \(v)"
            case .float(let v): return "f64 \(v)"
            case .boolean(let v): return "bool \(v)"
            case .string(let v): return "str \"\(Builder.escape(v))\""
            }
        }
    }

    /// 一层可中断目标：循环给 `continueLabel`，带标签的 `if` 只给 `breakLabel`。
    private struct Frame {
        let breakLabel: String
        let continueLabel: String?
        /// 该帧所属的作用域深度：`break` 要把这层之上的 `defer` 全部跑完。
        let scopeDepth: Int
    }

    private let functions: Set<String>

    private var constants: [Constant] = []
    private var constantSlots: [Constant: Int] = [:]

    private var body: [String] = []
    private var registers = 0
    private var labelCount = 0
    private var scopes: [[String: String]] = []
    private var defers: [[IRBlock]] = []
    private var frames: [Frame] = []
    private var terminated = false
    private var isEntry = false

    init(functions: Set<String>) {
        self.functions = functions
    }

    // MARK: 模块

    mutating func emit(_ module: IRModule) throws -> String {
        funcLines = []
        for function in module.functions {
            try emitFunction(function)
        }
        var out = ["; pini embedded_min bytecode"]
        out.append("; profile embedded_min · \(EmbeddedMinOpcode.count) opcodes")
        if !constants.isEmpty {
            out.append(".consts")
            for (index, constant) in constants.enumerated() {
                out.append("  k\(index) \(constant.listing)")
            }
        }
        out.append(contentsOf: funcLines)
        return out.joined(separator: "\n") + "\n"
    }

    private var funcLines: [String] = []

    private mutating func emitFunction(_ function: IRFunction) throws {
        body = []
        registers = function.params.count
        labelCount = 0
        scopes = [[:]]
        deferStackReset()
        frames = []
        terminated = false
        isEntry = function.name == "main"
        for (index, param) in function.params.enumerated() {
            scopes[0][param.name] = "r\(index)"
        }
        for statement in function.body.statements {
            if terminated { break }
            try emit(statement)
        }
        if !terminated {
            try runDefers(from: 0)
            emitLine("  \(isEntry ? "HALT" : "RET")")
        }
        funcLines.append(".func \(function.name) argc=\(function.params.count) regs=\(registers)")
        funcLines.append(contentsOf: body)
    }

    // MARK: 作用域与清理

    private mutating func deferStackReset() {
        defers = [[]]
    }

    private mutating func pushScope() {
        scopes.append([:])
        defers.append([])
    }

    private mutating func popScope() {
        scopes.removeLast()
        defers.removeLast()
    }

    /// 从最内层起到 `index`（含）逐层跑 `defer` 体：退出路径与正常结束共用这一条次序。
    private mutating func runDefers(from index: Int) throws {
        var depth = defers.count - 1
        while depth >= index {
            let pending = defers[depth].reversed()
            for block in pending {
                try emitBlock(block)
            }
            depth -= 1
        }
    }

    private mutating func emitBlock(_ block: IRBlock) throws {
        pushScope()
        let outerTerminated = terminated
        terminated = false
        for statement in block.statements {
            if terminated { break }
            try emit(statement)
        }
        if !terminated {
            try runDefers(from: defers.count - 1)
        }
        popScope()
        terminated = outerTerminated
    }

    // MARK: 语句

    private mutating func emit(_ statement: IRStmt) throws {
        switch statement {
        case .allocVar(let name, _, _, let initializer, _):
            let slot = freshRegister()
            if let initializer {
                let value = try emit(initializer)
                emitLine("  \(EmbeddedMinOpcode.storeVar.rawValue) \(slot), \(value)")
            }
            scopes[scopes.count - 1][name] = slot

        case .storeVar(let name, _, let value, _, _):
            let slot = try slot(for: name)
            let source = try emit(value)
            emitLine("  \(EmbeddedMinOpcode.storeVar.rawValue) \(slot), \(source)")

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            try emitIf(label: label, condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let body, let step):
            try emitWhile(condition: condition, body: body, step: step)

        case .returnStmt(let value, _):
            let result = try value.map { try emit($0) }
            try runDefers(from: 0)
            if let result {
                emitLine("  \(EmbeddedMinOpcode.ret.rawValue) \(result)")
            } else {
                emitLine("  \(EmbeddedMinOpcode.ret.rawValue)")
            }
            terminated = true

        case .exprStmt(let expression):
            _ = try emit(expression)

        case .deferStmt(let block):
            defers[defers.count - 1].append(block)

        case .breakStmt(let depth):
            let frame = try frameAt(depth)
            try runDefers(from: frame.scopeDepth)
            emitLine("  \(EmbeddedMinOpcode.jump.rawValue) \(frame.breakLabel)")
            terminated = true

        case .continueStmt(let depth):
            let frame = try frameAt(depth)
            guard let target = frame.continueLabel else {
                throw BackendError(
                    node: "continueStmt", family: .controlFlow,
                    reason: "目标帧是带标签的 if，不是循环")
            }
            try runDefers(from: frame.scopeDepth)
            emitLine("  \(EmbeddedMinOpcode.jump.rawValue) \(target)")
            terminated = true

        case .panicStmt(let message):
            let text = loadConstant(.string(message), into: freshRegister())
            emitLine("  \(EmbeddedMinOpcode.panic.rawValue) \(text)")
            terminated = true

        case .forInStmt:
            throw BackendError(
                node: "forInStmt", family: .controlFlow,
                reason: "迭代按容器访问器族降级，本 profile 不含容器")

        case .tryStmt:
            throw BackendError(
                node: "tryStmt", family: .controlFlow,
                reason: "错误路径要靠 Result 三槽布局，本 profile 不含聚合")

        case .subscriptStore:
            throw BackendError(
                node: "subscriptStore", family: .controlFlow,
                reason: "元素写入要 COW 唯一化，本 profile 不含容器")

        case .matchStmt:
            throw BackendError(
                node: "matchStmt", family: .controlFlow,
                reason: "标签位与载荷槽属枚举布局，本 profile 不含具名类型")

        case .fieldStore:
            throw BackendError(
                node: "fieldStore", family: .controlFlow,
                reason: "字段偏移属名义类型布局，本 profile 不含具名类型")

        case .captureMarker(let name):
            throw BackendError(
                node: "captureMarker(\(name))", family: .controlFlow,
                reason: "捕获槽要独立环境对象，本 profile 不含闭包")

        case .detachStmt:
            throw BackendError(
                node: "detachStmt", family: .controlFlow,
                reason: "任务边界属于并发 profile")
        }
    }

    private mutating func emitIf(
        label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?
    ) throws {
        let thenLabel = freshLabel()
        let endLabel = freshLabel()
        if label != nil {
            frames.append(Frame(
                breakLabel: endLabel, continueLabel: nil, scopeDepth: scopes.count))
        }
        let cond = try emit(condition)
        if let elseBody {
            emitLine("  \(EmbeddedMinOpcode.jumpIf.rawValue) \(cond), \(thenLabel)")
            try emitBlock(elseBody)
            emitLine("  \(EmbeddedMinOpcode.jump.rawValue) \(endLabel)")
            emitLine("\(thenLabel):")
            try emitBlock(thenBody)
        } else {
            emitLine("  \(EmbeddedMinOpcode.jumpIfNot.rawValue) \(cond), \(endLabel)")
            try emitBlock(thenBody)
        }
        emitLine("\(endLabel):")
        if label != nil {
            frames.removeLast()
        }
    }

    private mutating func emitWhile(condition: IRExpr, body: IRBlock, step: IRBlock?) throws {
        let headLabel = freshLabel()
        let stepLabel = freshLabel()
        let endLabel = freshLabel()
        emitLine("\(headLabel):")
        let cond = try emit(condition)
        emitLine("  \(EmbeddedMinOpcode.jumpIfNot.rawValue) \(cond), \(endLabel)")
        frames.append(Frame(
            breakLabel: endLabel, continueLabel: stepLabel, scopeDepth: scopes.count))
        try emitBlock(body)
        emitLine("\(stepLabel):")
        if let step {
            try emitBlock(step)
        }
        emitLine("  \(EmbeddedMinOpcode.jump.rawValue) \(headLabel)")
        emitLine("\(endLabel):")
        frames.removeLast()
    }

    private func frameAt(_ depth: Int) throws -> Frame {
        guard depth >= 1, depth <= frames.count else {
            throw BackendError(
                node: "breakStmt(depth: \(depth))", family: .controlFlow,
                reason: "中断目标越界：当前只有 \(frames.count) 层可中断帧")
        }
        return frames[frames.count - depth]
    }

    // MARK: 表达式

    private mutating func emit(_ expression: IRExpr) throws -> String {
        switch expression {
        case .intConst(let value, _):
            return loadConstant(.integer(value), into: freshRegister())
        case .floatConst(let value):
            return loadConstant(.float(value), into: freshRegister())
        case .boolConst(let value):
            return loadConstant(.boolean(value), into: freshRegister())
        case .stringConst(let value):
            return loadConstant(.string(value), into: freshRegister())

        case .load(let name, _):
            let slot = try slot(for: name)
            let target = freshRegister()
            emitLine("  \(EmbeddedMinOpcode.loadVar.rawValue) \(target), \(slot)")
            return target

        case .binary(let op, let lhs, let rhs, _):
            let left = try emit(lhs)
            let right = try emit(rhs)
            let target = freshRegister()
            emitLine("  \(try opcode(for: op).rawValue) \(target), \(left), \(right)")
            return target

        case .unary(let op, let operand, _):
            let source = try emit(operand)
            let target = freshRegister()
            emitLine("  \(try opcode(for: op).rawValue) \(target), \(source)")
            return target

        case .call(let function, let arguments, _):
            guard functions.contains(function) else {
                throw BackendError(
                    node: "call(\(function))", family: .calls,
                    reason: "内建调用要按名查运行时分发表，本 profile 只认模块内函数")
            }
            let args = try arguments.map { try emit($0) }
            let target = freshRegister()
            let operands = ([target, function] + args).joined(separator: ", ")
            emitLine("  \(EmbeddedMinOpcode.call.rawValue) \(operands)")
            return target

        case .printCall(let argument):
            let value = try emit(argument)
            let text = toString(value)
            emitLine("  \(EmbeddedMinOpcode.print.rawValue) \(text)")
            return loadConstant(.integer(0), into: freshRegister())

        case .printMulti(let arguments):
            var parts: [String] = []
            for argument in arguments {
                parts.append(toString(try emit(argument)))
            }
            let joined = concatenate(parts)
            emitLine("  \(EmbeddedMinOpcode.print.rawValue) \(joined)")
            return loadConstant(.integer(0), into: freshRegister())

        case .stringConcat(let lhs, let rhs):
            let left = try emit(lhs)
            let right = try emit(rhs)
            return concatenate([left, right])

        case .interpString(let parts):
            var values: [String] = []
            for part in parts {
                values.append(toString(try emit(part)))
            }
            return concatenate(values)

        case .assertCall(let condition, let message):
            let cond = try emit(condition)
            let passLabel = freshLabel()
            emitLine("  \(EmbeddedMinOpcode.jumpIf.rawValue) \(cond), \(passLabel)")
            let note = try message.map { try emit($0) }
                ?? loadConstant(.string("断言失败"), into: freshRegister())
            emitLine("  \(EmbeddedMinOpcode.panic.rawValue) \(note)")
            emitLine("\(passLabel):")
            return loadConstant(.integer(0), into: freshRegister())

        case .resultConstruct:
            throw unsupported("resultConstruct", .resultAndOptional, "Result 三槽布局不在本 profile")
        case .optionalGet, .optionalConstruct:
            throw unsupported("optionalGet/optionalConstruct", .resultAndOptional, "Optional 标签槽不在本 profile")
        case .arrayLiteral, .lenCall, .sliceCall, .subscriptGet, .dictLiteral, .setLiteral:
            throw unsupported("容器节点", .collections, "容器要有运行时句柄与 COW 规则")
        case .construct, .enumConstruct, .fieldGet:
            throw unsupported("具名类型节点", .nominals, "字段偏移与标签位属名义布局")
        case .tupleConstruct, .tupleIndexGet:
            throw unsupported("元组节点", .collections, "聚合布局不在本 profile")
        case .closureLiteral, .functionValue, .indirectCall:
            throw unsupported("函数值节点", .calls, "函数值要环境对象与间接调用协议")
        case .pointerLoad, .pointerStore, .addressOfVar:
            throw unsupported("指针节点", .pointers, "unsafe 指针不在本 profile")
        case .fileWrite, .fileAppend, .fileRead, .readLine:
            throw unsupported("文件 IO 节点", .fileIO, "宿主 IO 不在本 profile")
        case .fileTryWrite, .fileTryAppend, .fileTryRead:
            throw unsupported("可接住 IO 节点", .catchableIO, "错误通道不在本 profile")
        case .isAsciiDigit, .stringCase, .stringContains, .stringSubstring, .stringSplit,
            .stringTrimLeft, .stringTrimRight, .stringIndexOf, .arrayJoin:
            throw unsupported("字符串内建节点", .strings, "字素级内建由运行时分发表回答")
        case .lazyRefConstruct, .lazyRefValue:
            throw unsupported("LazyRef 节点", .lazyRef, "延迟求值句柄不在本 profile")
        case .join:
            throw unsupported("join", .concurrency, "Future 不在本 profile")
        case .givenInstance:
            throw unsupported("givenInstance", .givenInstances, "默认实例物化不在本 profile")
        }
    }

    private func unsupported(
        _ node: String, _ family: BackendCapabilities.Family, _ reason: String
    ) -> BackendError {
        BackendError(node: node, family: family, reason: reason)
    }

    private func opcode(for op: IRBinaryOp) throws -> EmbeddedMinOpcode {
        switch op {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .modulo: return .modulo
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .lessThan: return .lessThan
        case .lessThanOrEqual: return .lessThanOrEqual
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqual: return .greaterThanOrEqual
        case .bitwiseAnd, .bitwiseOr, .bitwiseXor, .leftShift, .rightShift, .minOf, .maxOf:
            throw unsupported("binary(\(op))", .variablesAndOperators, "位运算与 min/max 不在本 profile")
        }
    }

    private func opcode(for op: IRUnaryOp) throws -> EmbeddedMinOpcode {
        switch op {
        case .negate: return .negate
        case .logicalNot: return .logicalNot
        case .bitwiseNot, .abs:
            throw unsupported("unary(\(op))", .variablesAndOperators, "取反与绝对值不在本 profile")
        }
    }

    // MARK: 装配辅助

    private mutating func freshRegister() -> String {
        registers += 1
        return "r\(registers - 1)"
    }

    private mutating func freshLabel() -> String {
        labelCount += 1
        return "L\(labelCount)"
    }

    private mutating func emitLine(_ line: String) {
        body.append(line)
    }

    private mutating func constant(_ value: Constant) -> String {
        if let index = constantSlots[value] {
            return "k\(index)"
        }
        let index = constants.count
        constants.append(value)
        constantSlots[value] = index
        return "k\(index)"
    }

    private mutating func loadConstant(_ value: Constant, into target: String) -> String {
        let slot = constant(value)
        emitLine("  \(EmbeddedMinOpcode.loadK.rawValue) \(target), \(slot)")
        return target
    }

    /// 值转展示串。字符串本身也走一次，使调用点不必先问类型 —— `TOSTR` 按定义幂等。
    private mutating func toString(_ register: String) -> String {
        let target = freshRegister()
        emitLine("  \(EmbeddedMinOpcode.toStr.rawValue) \(target), \(register)")
        return target
    }

    /// 用 `CONCAT` 拼成一串；空列表给空串常量，使调用点不必分支。
    private mutating func concatenate(_ parts: [String]) -> String {
        guard var result = parts.first else {
            return loadConstant(.string(""), into: freshRegister())
        }
        for part in parts.dropFirst() {
            let target = freshRegister()
            emitLine("  \(EmbeddedMinOpcode.concat.rawValue) \(target), \(result), \(part)")
            result = target
        }
        return result
    }

    private func slot(for name: String) throws -> String {
        for scope in scopes.reversed() {
            if let slot = scope[name] { return slot }
        }
        throw unsupported("load(\(name))", .variablesAndOperators, "变量不在任何作用域里")
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out
    }
}
