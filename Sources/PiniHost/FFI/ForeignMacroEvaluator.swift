import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax

/// 宏常量求值的失败面。每一条都带原文或位置：静默跳过正是 Swift 那条路失败的方式，这里不重复。
public enum ForeignMacroError: Error, CustomStringConvertible, LocalizedError {
    case noHeaders(symbol: String)
    case compilerFailed(command: String, output: String)
    case unparsable(symbol: String, text: String, reason: String)
    case outOfRange(symbol: String, type: String, value: String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .noHeaders(let symbol):
            return "宏常量 `\(symbol)` 需要在 `pini.toml` 的 `[ffi].headers` 里声明来源头文件"
        case .compilerFailed(let command, let output):
            return "C 预处理器执行失败：`\(command)`\n\(output)"
        case .unparsable(let symbol, let text, let reason):
            return "宏常量 `\(symbol)` 展开后是 `\(text)`，不是常量表达式：\(reason)"
        case .outOfRange(let symbol, let type, let value):
            return "宏常量 `\(symbol)` 的值 \(value) 超出声明类型 \(type) 的范围"
        }
    }
}

/// 宏常量的构建期求值：每个 `|macro` 条目一行探针，一次 `cc -E` 展开，按标记行读回再解析。
/// 值只能来自 C 的头文件体系——块内写值是另一回事，那会把「来自外部」这条链路切断。
public enum ForeignMacroEvaluator {
    /// 求值全部 `|macro` 条目。没有宏条目时不碰工具链，模块保持零依赖。
    public static func evaluate(
        symbols: [ForeignSymbol], config: FFIConfig
    ) throws -> [IRForeignConstant] {
        let macros = symbols.filter { $0.flags.contains("macro") }
        guard !macros.isEmpty else { return [] }
        guard !config.headers.isEmpty else {
            throw ForeignMacroError.noHeaders(symbol: macros[0].name)
        }

        let source = probeSource(headers: config.headers, names: macros.map(\.name))
        let expanded = try runPreprocessor(source: source, config: config)
        let bodies = extract(expanded, count: macros.count)

        return try zip(macros, bodies).map { symbol, body in
            let type = try irType(of: symbol)
            let value = try MacroExpressionParser.evaluate(body, symbol: symbol.name)
            return IRForeignConstant(
                name: symbol.name, type: type,
                value: try coerced(
                    value, to: type, symbol: symbol.name,
                    typeName: symbol.annotation.describe()))
        }
    }

    /// 探针源码：头文件在前，随后每条一行标记加符号名。
    /// 标记是未定义标识符，预处理器原样保留，于是「标记 + 展开结果」构成可定位的一行。
    private static func probeSource(headers: [String], names: [String]) -> String {
        var lines: [String] = headers.map { "#include \($0)" }
        for (index, name) in names.enumerated() {
            lines.append("PINI_MACRO_PROBE_\(index)__ \(name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func runPreprocessor(source: String, config: FFIConfig) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-macro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.c")
        try source.write(to: file, atomically: true, encoding: .utf8)

        /// `Process` 只认可执行文件的绝对路径，不查 PATH，故这里自己按 PATH 找。
        let compiler = preprocessorPath()
        let arguments = ["-E", "-P"] + config.includePaths.map { "-I\($0)" } + [file.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ForeignMacroError.compilerFailed(
                command: ([compiler] + arguments).joined(separator: " "), output: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ForeignMacroError.compilerFailed(
                command: ([compiler] + arguments).joined(separator: " "),
                output: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// 预处理器：`PINI_CC` 优先，其次 PATH 里的 `cc`、`clang`，末位落回 `/usr/bin/cc`。
    /// 只有 `cc` 一处兜底会把只装了 clang 的镜像挡在门外，而 clang 本身就是 C 预处理器。
    private static func preprocessorPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PINI_CC"], !override.isEmpty,
            FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for tool in ["cc", "clang"] {
            for directory in directories {
                let candidate = (directory as NSString).appendingPathComponent(tool)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return "/usr/bin/cc"
    }

    /// 按标记切段：每段从标记之后到下一个标记之前，跨行展开一并收进来。
    private static func extract(_ output: String, count: Int) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var bodies = Array(repeating: "", count: count)
        var current: Int?
        for line in lines {
            if let index = markerIndex(line), index < count {
                current = index
                bodies[index] += line.replacingOccurrences(of: "PINI_MACRO_PROBE_\(index)__", with: "")
                continue
            }
            if let index = current {
                bodies[index] += " " + line
            }
        }
        return bodies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func markerIndex(_ line: String) -> Int? {
        guard let range = line.range(of: "PINI_MACRO_PROBE_") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "_") else { return nil }
        return Int(rest[..<end])
    }

    private static func irType(of symbol: ForeignSymbol) throws -> IRType {
        guard case .simple(let name, _) = symbol.annotation else {
            throw unsupportedMacroType(symbol)
        }
        switch name {
        case "I8": return .i8
        case "U8": return .u8
        case "I32": return .i32
        case "I64": return .i64
        case "U64": return .u64
        case "F64": return .f64
        case "Bool": return .boolean
        default: throw unsupportedMacroType(symbol)
        }
    }

    private static func unsupportedMacroType(_ symbol: ForeignSymbol) -> ForeignMacroError {
        ForeignMacroError.unparsable(
            symbol: symbol.name, text: symbol.annotation.describe(),
            reason: "宏常量的类型须为标量（I8 / U8 / I32 / I64 / U64 / F64 / Bool）")
    }

    /// 按声明类型收敛并查范围。整数溢出即拒：C 侧的值放不进 Pini 声明的宽度，是声明写错了。
    /// `typeName` 取声明处的写法，不用 `IRType` 的 LLVM 拼写——`U8` 的 LLVM 名是 `i8`，报错时会误导。
    private static func coerced(
        _ value: IRForeignConstantValue, to type: IRType, symbol: String, typeName: String
    ) throws -> IRForeignConstantValue {
        switch (type, value) {
        case (.f64, .float):
            return value
        case (.f64, .integer(let v)):
            return .float(Double(v))
        case (.boolean, .integer(let v)) where v == 0 || v == 1:
            return value
        case (.i8, .integer(let v)) where Int8(exactly: v) != nil:
            return value
        case (.u8, .integer(let v)) where UInt8(exactly: v) != nil:
            return value
        case (.i32, .integer(let v)) where Int32(exactly: v) != nil:
            return value
        case (.i64, .integer):
            return value
        case (.u64, .integer(let v)) where v >= 0:
            return value
        default:
            let rendered: String
            switch value {
            case .integer(let v): rendered = String(v)
            case .float(let v): rendered = String(v)
            }
            throw ForeignMacroError.outOfRange(symbol: symbol, type: typeName, value: rendered)
        }
    }
}

/// 常量表达式求值：整数四则与位运算按 Int64 精确算；浮点只认字面量。
/// 自己算而不是交给 C，是因为「报错时能给出展开原文」需要知道表达式长什么样。
private struct MacroExpressionParser {
    private enum Token: Equatable {
        case integer(String)
        case floating(String)
        case op(String)
        case leftParen
        case rightParen
        case other(String)
    }

    private enum Number {
        case int(Int64)
        case double(Double)
    }

    private let text: String
    private let symbol: String
    private let tokens: [Token]
    private var index = 0

    static func evaluate(_ text: String, symbol: String) throws -> IRForeignConstantValue {
        guard !text.isEmpty else {
            throw ForeignMacroError.unparsable(
                symbol: symbol, text: text, reason: "展开结果为空")
        }
        var parser = MacroExpressionParser(text: text, symbol: symbol, tokens: lex(text))
        let value = try parser.parseOr()
        guard parser.index == parser.tokens.count else {
            let rest = parser.tokens[parser.index...].map(describe).joined(separator: " ")
            throw parser.failure("多余内容 `\(rest)`")
        }
        switch value {
        case .int(let v): return .integer(Int(v))
        case .double(let v): return .float(v)
        }
    }

    private func failure(_ reason: String) -> ForeignMacroError {
        ForeignMacroError.unparsable(symbol: symbol, text: text, reason: reason)
    }

    private static func describe(_ token: Token) -> String {
        switch token {
        case .integer(let s), .floating(let s), .op(let s), .other(let s): return s
        case .leftParen: return "("
        case .rightParen: return ")"
        }
    }

    private static func lex(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
                continue
            }
            if ch == "(" {
                tokens.append(.leftParen)
                i += 1
                continue
            }
            if ch == ")" {
                tokens.append(.rightParen)
                i += 1
                continue
            }
            if ch.isNumber || ch == "." {
                let start = i
                var seenDot = false
                var seenExponent = false
                /// 十六进制的 `e` 是数字位，指数只在十进制里出现。
                let isHex = start + 1 < chars.count && chars[start] == "0"
                    && (chars[start + 1] == "x" || chars[start + 1] == "X")
                while i < chars.count {
                    let c = chars[i]
                    if c.isNumber || c.isHexDigit || c == "x" || c == "X" {
                        i += 1
                    } else if c == "." {
                        seenDot = true
                        i += 1
                    } else if c == "e" || c == "E" {
                        if isHex {
                            i += 1
                            continue
                        }
                        seenExponent = true
                        i += 1
                        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
                    } else {
                        break
                    }
                }
                var literal = String(chars[start..<i])
                /// 整数后缀 `u` / `U` / `l` / `L` 全部剥掉：宽度由声明类型决定，不由此处。
                while let last = literal.last, "uUlL".contains(last) {
                    literal.removeLast()
                }
                tokens.append(seenDot || seenExponent ? .floating(literal) : .integer(literal))
                continue
            }
            if let pair = twoCharOperator(chars, at: i) {
                tokens.append(.op(pair))
                i += 2
                continue
            }
            if "+-*/%&|^~".contains(ch) {
                tokens.append(.op(String(ch)))
                i += 1
                continue
            }
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                i += 1
            }
            if start == i { i += 1 }
            tokens.append(.other(String(chars[start..<i])))
        }
        return tokens
    }

    private static func twoCharOperator(_ chars: [Character], at index: Int) -> String? {
        guard index + 1 < chars.count else { return nil }
        let pair = String(chars[index...index + 1])
        return pair == "<<" || pair == ">>" ? pair : nil
    }

    /// 当前运算符文本；非运算符或到头时为 nil。
    private func peekOp() -> String? {
        guard index < tokens.count, case .op(let op) = tokens[index] else { return nil }
        return op
    }

    private mutating func parseOr() throws -> Number {
        var value = try parseXor()
        while peekOp() == "|" {
            index += 1
            value = try combine(value, try parseXor(), "|")
        }
        return value
    }

    private mutating func parseXor() throws -> Number {
        var value = try parseAnd()
        while peekOp() == "^" {
            index += 1
            value = try combine(value, try parseAnd(), "^")
        }
        return value
    }

    private mutating func parseAnd() throws -> Number {
        var value = try parseShift()
        while peekOp() == "&" {
            index += 1
            value = try combine(value, try parseShift(), "&")
        }
        return value
    }

    private mutating func parseShift() throws -> Number {
        var value = try parseAdditive()
        while let op = peekOp(), op == "<<" || op == ">>" {
            index += 1
            value = try combine(value, try parseAdditive(), op)
        }
        return value
    }

    private mutating func parseAdditive() throws -> Number {
        var value = try parseMultiplicative()
        while let op = peekOp(), op == "+" || op == "-" {
            index += 1
            value = try combine(value, try parseMultiplicative(), op)
        }
        return value
    }

    private mutating func parseMultiplicative() throws -> Number {
        var value = try parseUnary()
        while let op = peekOp(), op == "*" || op == "/" || op == "%" {
            index += 1
            value = try combine(value, try parseUnary(), op)
        }
        return value
    }

    private mutating func parseUnary() throws -> Number {
        guard let op = peekOp(), op == "-" || op == "+" || op == "~" else {
            return try parsePrimary()
        }
        index += 1
        let operand = try parseUnary()
        switch (op, operand) {
        case ("-", .int(let v)): return .int(-v)
        case ("+", .int): return operand
        case ("~", .int(let v)): return .int(~v)
        case ("-", .double(let v)): return .double(-v)
        case ("+", .double): return operand
        default:
            throw failure("`~` 只支持整数")
        }
    }

    private mutating func parsePrimary() throws -> Number {
        guard index < tokens.count else {
            throw failure("表达式不完整")
        }
        let token = tokens[index]
        index += 1
        switch token {
        case .integer(let literal):
            guard let v = parseIntLiteral(literal) else {
                throw failure("无法解析整数 `\(literal)`")
            }
            return .int(v)
        case .floating(let literal):
            guard let v = Double(literal) else {
                throw failure("无法解析浮点数 `\(literal)`")
            }
            return .double(v)
        case .leftParen:
            let value = try parseOr()
            guard index < tokens.count, case .rightParen = tokens[index] else {
                throw failure("括号未闭合")
            }
            index += 1
            return value
        case .other(let word):
            throw failure("`\(word)` 不是常量——函数式宏或未展开的标识符不能烘成常量")
        case .op(let op):
            throw failure("运算符 `\(op)` 出现在不该出现的位置")
        case .rightParen:
            throw failure("多余的 `)`")
        }
    }

    private func parseIntLiteral(_ literal: String) -> Int64? {
        let lower = literal.lowercased()
        if lower.hasPrefix("0x") {
            return Int64(lower.dropFirst(2), radix: 16)
        }
        if lower.count > 1, lower.hasPrefix("0") {
            return Int64(lower.dropFirst(), radix: 8)
        }
        return Int64(lower)
    }

    private mutating func combine(_ lhs: Number, _ rhs: Number, _ op: String) throws -> Number {
        guard case .int(let a) = lhs, case .int(let b) = rhs else {
            throw failure("浮点只接受字面量，不参与运算")
        }
        switch op {
        case "+": return .int(a &+ b)
        case "-": return .int(a &- b)
        case "*": return .int(a &* b)
        case "/":
            guard b != 0 else { throw failure("除以零") }
            return .int(a / b)
        case "%":
            guard b != 0 else { throw failure("对零取模") }
            return .int(a % b)
        case "&": return .int(a & b)
        case "|": return .int(a | b)
        case "^": return .int(a ^ b)
        case "<<":
            guard b >= 0, b < 64 else { throw failure("移位越界") }
            return .int(a << b)
        case ">>":
            guard b >= 0, b < 64 else { throw failure("移位越界") }
            return .int(a >> b)
        default:
            throw failure("不支持的运算符 `\(op)`")
        }
    }
}
