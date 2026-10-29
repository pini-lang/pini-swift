import Foundation

/// 一个 C 产物文件。名字由发射器按程序名决定，目录由调用方决定 —— 发射器不认识路径。
public struct CFile: Equatable {
    public let name: String
    public let contents: String

    public init(name: String, contents: String) {
        self.name = name
        self.contents = contents
    }
}

/// C 后端的失败信号。骨架期遇到未支持的节点一律抛它，⛔ 不静默降级：
/// 降级产出的 C 能编译、能运行，只是算错，那是比编译失败昂贵得多的失败模式。
public struct CBackendError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// IRModule → C99 风格的 C 源文件。控件流走 C 的结构化语句（IR 本身是语句树），
/// 只有带标签的跳出落到 `goto`；类型、打印与所有权规则逐条镜像 LLVM 发射器，
/// 两边的差异只能靠逐字节对比发现，故不在此处「顺手改进」。
public final class CEmitter {

    /// 程序基准，口径同 LLVM 侧：nil ⇒ 不注入 `bk_set_program_base`，产物不含该常量。
    public var programBase: String?

    public init() {}

    public func emit(module: IRModule, programName: String) throws -> [CFile] {
        let functions = module.functions.filter { $0.sourceFile != PredefinedDecls.sourceName }
        guard functions.contains(where: { $0.name == "main" }) else {
            throw CBackendError(message: "C 后端：模块里没有 main，无法产出可执行程序")
        }
        let state = CEmitState(defined: Set(functions.map(\.name)))
        var bodies: [String] = []
        for function in functions {
            let emitter = CFunctionEmitter(
                function: function, state: state, programBase: programBase)
            bodies.append(try emitter.emit())
        }
        let unresolved = state.calledNames.subtracting(state.defined)
        guard unresolved.isEmpty else {
            let names = unresolved.sorted().joined(separator: "、")
            throw CBackendError(
                message: "C 后端尚未支持：这些被调函数不在本模块内 —— \(names)")
        }

        var out = "// 由 Pini 编译器生成，勿手改。\n"
        out += "#include \"\(PiniRTHeader.fileName)\"\n\n"
        for constant in state.constantOrder {
            out += "static const char \(constant.name)[] = \(Self.cLiteral(constant.value));\n"
        }
        out += "\n"
        for function in functions where function.name != "main" {
            out += try CFunctionEmitter.prototype(of: function) + ";\n"
        }
        out += "\n"
        out += bodies.joined(separator: "\n")
        return [CFile(name: "\(programName).c", contents: out)]
    }

    /// C 字符串字面量。非 ASCII 原样输出（C23 源文件是 UTF-8），控制字符走三位八进制 ——
    /// 十六进制转义会吃掉紧随其后的十六进制数字，八进制定长不吃。
    static func cLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// 跨函数共享的模块级状态：常量池与被调名账本。
/// 常量按需登记 —— 预扫全模块会把只在被剪掉的函数里出现的字符串也写进产物。
private final class CEmitState {
    let defined: Set<String>
    private var byValue: [String: String] = [:]
    private(set) var constantOrder: [(name: String, value: String)] = []
    var calledNames: Set<String> = []

    init(defined: Set<String>) {
        self.defined = defined
    }

    func registerString(_ value: String) -> String {
        if let hit = byValue[value] { return hit }
        let name = "k_str\(constantOrder.count)"
        byValue[value] = name
        constantOrder.append((name: name, value: value))
        return name
    }
}

/// 单个函数的发射器。帧栈记的是「谁可以被 break / continue 指向」——
/// 带标签的 `if` 也是帧（`break 标签` 能跳出它），故不能只压循环。
private final class CFunctionEmitter {
    private let function: IRFunction
    private let state: CEmitState
    private let programBase: String?
    private let writer = CWriter()
    private var frames: [Frame] = []
    private var labelSeq = 0
    private var tempSeq = 0
    private var terminated = false

    private struct Frame {
        let exit: String
        let header: String
        let isLoop: Bool
        let needsExit: Bool
        let needsHeader: Bool
    }

    init(function: IRFunction, state: CEmitState, programBase: String?) {
        self.function = function
        self.state = state
        self.programBase = programBase
    }

    private var isMain: Bool { function.name == "main" }

    func emit() throws -> String {
        writer.open(try signature())
        if isMain, let base = programBase {
            let constant = state.registerString(base)
            writer.line("bk_set_program_base((void *)\(constant));")
        }
        try emitBlock(function.body)
        if isMain, !terminated { writer.line("return 0;") }
        writer.close()
        return writer.output
    }

    static func prototype(of function: IRFunction) throws -> String {
        let name = "pini_\(IRName.mangle(function.name))"
        let ret = try function.returnType.map { try CTypeMap.spelling(of: $0) } ?? "void"
        let params = try function.params.map {
            "\(try CTypeMap.spelling(of: $0.type)) v_\(IRName.mangle($0.name))"
        }.joined(separator: ", ")
        return "static \(ret) \(name)(\(params.isEmpty ? "void" : params))"
    }

    private func signature() throws -> String {
        if isMain { return "int main(void)" }
        return try Self.prototype(of: function)
    }

    // MARK: - 语句

    private func emitBlock(_ block: IRBlock) throws {
        for statement in block.statements {
            try emitStmt(statement)
        }
    }

    private func emitStmt(_ statement: IRStmt) throws {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            let spelling = try CTypeMap.spelling(of: type)
            let local = "v_\(IRName.mangle(name))"
            if let initializer {
                let value = try emitExpr(initializer)
                writer.line("\(spelling) \(local) = \(value);")
            } else {
                writer.line("\(spelling) \(local);")
            }
            terminated = false

        case .storeVar(let name, _, let value):
            let lowered = try emitExpr(value)
            writer.line("v_\(IRName.mangle(name)) = \(lowered);")
            terminated = false

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            try emitIf(label: label, condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let body, let step):
            guard step == nil else {
                throw CBackendError(message: "C 后端尚未支持：带 step 块的 while")
            }
            try emitWhile(condition: condition, body: body)

        case .forInStmt:
            throw CBackendError(message: "C 后端尚未支持：for-in（需要容器运行时段）")

        case .returnStmt(let value):
            if let value {
                let lowered = try emitExpr(value)
                writer.line("return \(lowered);")
            } else if isMain {
                writer.line("return 0;")
            } else {
                writer.line("return;")
            }
            terminated = true

        case .exprStmt(let expr):
            let text = try emitExpr(expr)
            if !text.isEmpty { writer.line("\(text);") }
            terminated = false

        case .panicStmt(let message):
            let constant = state.registerString(message)
            writer.line("bk_panic(\(constant));")
            terminated = true

        case .breakStmt(let depth):
            let frame = try frame(at: depth)
            if frame.isLoop && depth == 1 {
                writer.line("break;")
            } else if frame.needsExit {
                writer.line("goto \(frame.exit);")
            } else {
                throw CBackendError(message: "C 后端：break 的目标帧未落标号，扫描与发射不一致")
            }
            terminated = true

        case .continueStmt(let depth):
            let frame = try frame(at: depth)
            if frame.isLoop && depth == 1 {
                writer.line("continue;")
            } else if frame.isLoop && frame.needsHeader {
                writer.line("goto \(frame.header);")
            } else if !frame.isLoop && frame.needsExit {
                writer.line("goto \(frame.exit);")
            } else {
                throw CBackendError(message: "C 后端：continue 的目标帧未落标号，扫描与发射不一致")
            }
            terminated = true

        default:
            throw CBackendError(message: "C 后端尚未支持的语句：\(Self.nodeName(statement))")
        }
    }

    private func emitIf(
        label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?
    ) throws {
        let cond = bareCondition(try emitExpr(condition))
        var frame: Frame?
        if label != nil {
            let exit = "end_if_\(nextLabelSeq())"
            let needsExit =
                scan(thenBody, nesting: 0, direct: true).brk
                || scan(elseBody, nesting: 0, direct: true).brk
            let pushed = Frame(
                exit: exit, header: exit, isLoop: false, needsExit: needsExit, needsHeader: false)
            frames.append(pushed)
            frame = pushed
        }
        writer.open("if (\(cond))")
        try emitBlock(thenBody)
        if let elseBody {
            writer.elseOpen()
            try emitBlock(elseBody)
            writer.close()
        } else {
            writer.close()
        }
        if let frame {
            frames.removeLast()
            if frame.needsExit { writer.line("\(frame.exit): ;") }
        }
        terminated = false
    }

    /// `while cond: body`。无标号需求时原样落 `while`，产物最好读；
    /// 一旦有内层 `break`/`continue` 指向它，就换成 `for (;;)`,以便开出显式标号 ——
    /// C 没有给条件挂标号的语法，`continue 标签` 要靠 `goto` 回到循环头。
    private func emitWhile(condition: IRExpr, body: IRBlock) throws {
        let info = scan(body, nesting: 0, direct: false)
        let id = nextLabelSeq()
        let exit = "end_\(id)"
        let header = "cont_\(id)"
        frames.append(
            Frame(
                exit: exit, header: header, isLoop: true,
                needsExit: info.brk, needsHeader: info.cont))
        let cond = bareCondition(try emitExpr(condition))
        if info.cont {
            writer.open("for (;;)")
            writer.line("\(header): ;")
            writer.line("if (!(\(cond))) break;")
        } else if info.brk {
            writer.open("for (;;)")
            writer.line("if (!(\(cond))) break;")
        } else {
            writer.open("while (\(cond))")
        }
        try emitBlock(body)
        writer.close()
        frames.removeLast()
        if info.brk { writer.line("\(exit): ;") }
        terminated = false
    }

    // MARK: - 表达式

    /// 返回 C 表达式文本。打印一类会写多条语句的节点返回空串，调用方据此判断是否加 `;`。
    private func emitExpr(_ expr: IRExpr) throws -> String {
        switch expr {
        case .intConst(let value, let type):
            return try CTypeMap.integerLiteral(value, type: type)

        case .floatConst(let value):
            return try CTypeMap.floatLiteral(value)

        case .boolConst(let value):
            return value ? "true" : "false"

        case .stringConst(let value):
            return state.registerString(value)

        case .load(let name, _):
            return "v_\(IRName.mangle(name))"

        case .binary(let op, let lhs, let rhs, _):
            let left = try emitExpr(lhs)
            let right = try emitExpr(rhs)
            guard let spelling = Self.binarySpelling(op) else {
                throw CBackendError(message: "C 后端尚未支持的二元运算：\(op)")
            }
            return "((\(left)) \(spelling) (\(right)))"

        case .unary(let op, let operand, _):
            let value = try emitExpr(operand)
            switch op {
            case .negate: return "(-(\(value)))"
            case .logicalNot: return "(!(\(value)))"
            case .bitwiseNot: return "(~(\(value)))"
            case .abs:
                throw CBackendError(message: "C 后端尚未支持的一元运算：abs")
            }

        case .call(let name, let arguments, _):
            let args = try arguments.map { try emitExpr($0) }
            if name == "F64", args.count == 1 {
                return "((double)(\(args[0])))"
            }
            let callee =
                state.defined.contains(name) || !name.hasPrefix("bk_")
                ? "pini_\(IRName.mangle(name))" : name
            if !state.defined.contains(name) && !name.hasPrefix("bk_") {
                state.calledNames.insert(name)
            }
            return "\(callee)(\(args.joined(separator: ", ")))"

        case .printCall(let argument):
            try emitPrint(argument, newline: true)
            return ""

        case .printMulti(let arguments):
            try emitPrintMulti(arguments)
            return ""

        default:
            throw CBackendError(message: "C 后端尚未支持的表达式：\(Self.nodeName(expr))")
        }
    }

    /// 逐类型镜像 `IREmitter.emitScalarPrint`。两处必须逐字一致，包括那两处看起来像缺陷的地方：
    /// `I64` 打印按 `%d` 收窄到 i32，`F64` 走运行时的十进制渲染再 `printf("%s")`。
    private func emitPrint(_ argument: IRExpr, newline: Bool) throws {
        let value = try emitExpr(argument)
        guard let type = Self.type(of: argument) else {
            throw CBackendError(message: "C 后端：打印的实参没有携带类型，无法选定格式")
        }
        switch type {
        case .boolean:
            writer.line("printf(\"%s\", \(value) ? \"true\" : \"false\");")
        case .string, .char:
            writer.line("printf(\"%s\", \(value));")
        case .i32:
            writer.line("printf(\"%d\", \(value));")
        case .i64, .u64:
            writer.line("printf(\"%d\", (int32_t)(\(value)));")
        case .f64:
            let temp = "t_text\(nextTempSeq())"
            writer.line("char *\(temp) = bk_double_to_string(\(value));")
            writer.line("printf(\"%s\", \(temp));")
            writer.line("bk_str_release(\(temp));")
        default:
            throw CBackendError(
                message: "C 后端尚未支持的打印类型：\(CTypeMap.label(of: type))")
        }
        if newline { writer.line("printf(\"\\n\");") }
    }

    /// `print(a, b, c)`：实参之间一个空格，行尾一个换行。与 LLVM 侧同序。
    private func emitPrintMulti(_ arguments: [IRExpr]) throws {
        for (index, argument) in arguments.enumerated() {
            if index > 0 { writer.line("printf(\" \");") }
            try emitPrint(argument, newline: false)
        }
        writer.line("printf(\"\\n\");")
    }

    // MARK: - 辅助

    private func frame(at depth: Int) throws -> Frame {
        guard depth >= 1, depth <= frames.count else {
            throw CBackendError(message: "C 后端：break/continue 的层数 \(depth) 超出帧栈")
        }
        return frames[frames.count - depth]
    }

    private func nextLabelSeq() -> Int {
        labelSeq += 1
        return labelSeq
    }

    private func nextTempSeq() -> Int {
        tempSeq += 1
        return tempSeq
    }

    /// 求「本帧是否被更内层的 break / continue 指名」：`depth == nesting + 1` 即指向本帧，
    /// 未加标签的 `if` 不压帧、故不改 `nesting`。`direct` 决定 nesting 为 0 的命中算不算数 ——
    /// 循环在那一层用 C 的 `break` / `continue`，不需要标号；`if` 帧只能走 `goto`。
    private func scan(_ block: IRBlock?, nesting: Int, direct: Bool) -> (brk: Bool, cont: Bool) {
        guard let block else { return (false, false) }
        func hits(_ depth: Int) -> Bool {
            depth == nesting + 1 && (nesting > 0 || direct)
        }
        var brk = false
        var cont = false
        for statement in block.statements {
            switch statement {
            case .breakStmt(let depth):
                if hits(depth) { brk = true }
            case .continueStmt(let depth):
                if hits(depth) { cont = true }
            case .whileStmt(_, let body, let step):
                let inner = scan(body, nesting: nesting + 1, direct: direct)
                brk = brk || inner.brk
                cont = cont || inner.cont
                let stepped = scan(step, nesting: nesting + 1, direct: direct)
                brk = brk || stepped.brk
                cont = cont || stepped.cont
            case .forInStmt(_, _, _, _, let body, let step):
                let inner = scan(body, nesting: nesting + 1, direct: direct)
                brk = brk || inner.brk
                cont = cont || inner.cont
                let stepped = scan(step, nesting: nesting + 1, direct: direct)
                brk = brk || stepped.brk
                cont = cont || stepped.cont
            case .ifStmt(let label, _, let thenBody, let elseBody):
                let inner = nesting + (label == nil ? 0 : 1)
                let a = scan(thenBody, nesting: inner, direct: direct)
                let b = scan(elseBody, nesting: inner, direct: direct)
                brk = brk || a.brk || b.brk
                cont = cont || a.cont || b.cont
            default:
                break
            }
        }
        return (brk, cont)
    }

    /// 条件已整体加过括号时去掉一层，避免 `while (((a) < (b)))` 这种三重括号。
    /// 本发射器产出的复合表达式一律整包，故「首尾都是括号」即表示整包，不会误伤 `f(x)`。
    private func bareCondition(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func binarySpelling(_ op: IRBinaryOp) -> String? {
        switch op {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .modulo: return "%"
        case .equal: return "=="
        case .notEqual: return "!="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .bitwiseAnd: return "&"
        case .bitwiseOr: return "|"
        case .bitwiseXor: return "^"
        case .leftShift: return "<<"
        case .rightShift: return ">>"
        case .minOf, .maxOf: return nil
        }
    }

    /// 表达式自带的类型。返回 nil 表示该节点不在骨架期的表达式面内 ——
    /// ⛔ 不退化成 `I32`：那会让一个聚合值按整数打出来，编得过、跑得通、结果是错的。
    static func type(of expr: IRExpr) -> IRType? {
        switch expr {
        case .intConst(_, let type): return type
        case .floatConst: return .f64
        case .boolConst: return .boolean
        case .stringConst: return .string
        case .load(_, let type): return type
        case .binary(_, _, _, let type): return type
        case .unary(_, _, let type): return type
        case .call(_, _, let returnType): return returnType ?? .i32
        case .printCall, .printMulti: return .i32
        default: return nil
        }
    }

    private static func nodeName(_ statement: IRStmt) -> String {
        let text = String(describing: statement)
        if let cut = text.firstIndex(where: { $0 == "(" }) { return String(text[..<cut]) }
        return text
    }

    private static func nodeName(_ expr: IRExpr) -> String {
        let text = String(describing: expr)
        if let cut = text.firstIndex(where: { $0 == "(" }) { return String(text[..<cut]) }
        return text
    }
}

/// 缩进与行管理。`open` / `close` 成对出现，`elseOpen` 承担 `} else {` 这一种夹缝形态。
private final class CWriter {
    private var lines: [String] = []
    private var depth = 0

    func open(_ text: String) {
        line(text + " {")
        depth += 1
    }

    func elseOpen() {
        depth -= 1
        line("} else {")
        depth += 1
    }

    func close() {
        depth -= 1
        line("}")
    }

    func line(_ text: String) {
        lines.append(String(repeating: "    ", count: depth) + text)
    }

    var output: String { lines.joined(separator: "\n") + "\n" }
}
