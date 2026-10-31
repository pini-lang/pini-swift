import Foundation

/// 结构串（SIG）序列化器：把模块 AST 机械派生成结构串行。
/// 语义权威在语言规范的结构串派生视图条款；本件只实现机械发射，⛔ 不做任何文本再解析。
public enum SignatureSerializer {

    /// 对模块内 main 函数的每个顶层语句产出一行 `SIG|<序号>|<结构串>`。
    /// 模块无 main 函数 ⇒ 零行（⛔ 不产占位行）。
    public static func signatureLines(module: Module) -> [String] {
        guard let main = module.declarations.compactMap({ decl -> FuncDecl? in
            if case .funcDecl(let f) = decl { return f }
            return nil
        }).first(where: { $0.name == "main" }) else {
            return []
        }
        guard let body = main.body else { return [] }
        var lines: [String] = []
        for (index, stmt) in body.statements.enumerated() {
            var rendered: [CanonicalLine] = []
            renderStatement(stmt, depth: 0, into: &rendered)
            lines.append("SIG|\(index + 1)|\(extractSignature(from: rendered))")
        }
        return lines
    }

    // MARK: - 规范树一行（缩进以空格计，逐层 +1）

    private struct CanonicalLine {
        let depth: Int
        let text: String
    }

    private static func emit(_ text: String, depth: Int, into: inout [CanonicalLine]) {
        into.append(CanonicalLine(depth: depth, text: text))
    }

    // MARK: - 词表（条款钉死的两个集合）

    private static let nodeNames: Set<String> = [
        "binary", "unary", "call", "member", "subscript", "join", "tupleIndex", "tuple",
        "arrayLiteral", "dictionaryLiteral", "setLiteral", "genericConstruct", "try",
        "unsafe", "addressOf", "funcLiteral", "stringInterpolation", "exprStmt", "assign",
    ]

    private static let fieldNames: Set<String> = [
        "left", "right", "operand", "callee", "arg", "arguments", "entry", "target", "value",
        "then", "else", "elif", "step", "case", "pattern", "bindings", "initializer",
        "receiver", "index",
    ]

    // MARK: - 抽取（条款的元素规则；语句行只在其行名属节点名集合时产 @0 元素）

    private static func extractSignature(from lines: [CanonicalLine]) -> String {
        guard let first = lines.first else { return "" }
        var parts: [String] = []
        let headName = lineName(first.text)
        if nodeNames.contains(headName) {
            parts.append(headName + "@0")
        }
        for line in lines.dropFirst() {
            if line.text.isEmpty { continue }
            let name = lineName(line.text)
            let segment: String
            if name == "op" {
                segment = valueAfterOp(line.text)
            } else if nodeNames.contains(name) || fieldNames.contains(name) {
                segment = name
            } else if let value = valueAfterColonSpace(line.text) {
                segment = value
            } else {
                segment = line.text
            }
            parts.append(segment + "@\(line.depth)")
        }
        return parts.joined(separator: "|")
    }

    private static func lineName(_ text: String) -> String {
        if let idx = text.firstIndex(of: ":") {
            return String(text[text.startIndex..<idx])
        }
        return text
    }

    private static func valueAfterOp(_ text: String) -> String {
        guard text.hasPrefix("op:") else { return text }
        return String(text.dropFirst(3).drop { $0 == " " })
    }

    private static func valueAfterColonSpace(_ text: String) -> String? {
        guard text.contains(": ") else { return nil }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        return String(text[text.index(after: colon)...].drop { $0 == " " })
    }

    // MARK: - 规范树渲染：语句

    private static func renderStatements(_ list: [Statement], depth: Int, into: inout [CanonicalLine]) {
        for s in list {
            renderStatement(s, depth: depth, into: &into)
        }
    }

    private static func renderStatement(_ stmt: Statement, depth: Int, into: inout [CanonicalLine]) {
        switch stmt {
        case .varDecl(let name, let ann, let initializer, let isMutable, _):
            var head = isMutable ? "varDecl(mut): \(name)" : "varDecl: \(name)"
            if let t = ann {
                head += ": \(typeText(t))"
            }
            emit(head, depth: depth, into: &into)
            renderOptionalExpression(initializer, depth: depth + 1, into: &into)
        case .varDestructure(let names, let ann, let initializer, _, _):
            emit("varDestructure \(names.joined(separator: " ")): \(ann.map(typeText) ?? "")",
                 depth: depth, into: &into)
            renderOptionalExpression(initializer, depth: depth + 1, into: &into)
        case .assign(let target, let value, _):
            emit("assign:", depth: depth, into: &into)
            renderAssignTarget(target, depth: depth + 1, into: &into)
            emit("value:", depth: depth + 1, into: &into)
            renderExpression(value, depth: depth + 2, into: &into)
        case .returnStatement(let value, _):
            emit("return:", depth: depth, into: &into)
            renderOptionalExpression(value, depth: depth + 1, into: &into)
        case .breakStatement(let label, _):
            emit("break \(label ?? "")", depth: depth, into: &into)
        case .continueStatement(let label, _):
            emit("continue \(label ?? "")", depth: depth, into: &into)
        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, _):
            emit("if [\(label ?? "")]:", depth: depth, into: &into)
            renderExpression(condition, depth: depth + 1, into: &into)
            emit("then:", depth: depth + 1, into: &into)
            renderStatements(thenBlock.statements, depth: depth + 2, into: &into)
            for elif in elifs {
                emit("elif:", depth: depth + 1, into: &into)
                renderExpression(elif.condition, depth: depth + 2, into: &into)
                emit("then:", depth: depth + 2, into: &into)
                renderStatements(elif.block.statements, depth: depth + 3, into: &into)
            }
            if let els = elseBlock {
                emit("else:", depth: depth + 1, into: &into)
                renderStatements(els.statements, depth: depth + 2, into: &into)
            }
        case .whileStatement(let condition, let body, let step, let label, _):
            emit("while [\(label ?? "")]:", depth: depth, into: &into)
            renderExpression(condition, depth: depth + 1, into: &into)
            renderStatements(body.statements, depth: depth + 1, into: &into)
            renderStepBlock(step, depth: depth + 1, into: &into)
        case .forStatement(let pattern, let iterable, let body, let step, let label, _):
            emit("for \(pattern.joined(separator: " ")) in [\(label ?? "")]:",
                 depth: depth, into: &into)
            renderExpression(iterable, depth: depth + 1, into: &into)
            renderStatements(body.statements, depth: depth + 1, into: &into)
            renderStepBlock(step, depth: depth + 1, into: &into)
        case .matchStatement(let value, let cases, _):
            emit("match:", depth: depth, into: &into)
            renderExpression(value, depth: depth + 1, into: &into)
            for c in cases {
                emit("case:", depth: depth + 1, into: &into)
                renderMatchPattern(c.pattern, depth: depth + 2, into: &into)
                for b in c.bindings {
                    emit("bind: \(b.paramName ?? "") -> \(b.varName)", depth: depth + 2, into: &into)
                }
                renderStatements(c.block.statements, depth: depth + 2, into: &into)
            }
        case .scopedBlock(let label, let body, _):
            emit("scopedBlock [\(label ?? "")]:", depth: depth, into: &into)
            renderStatements(body.statements, depth: depth + 1, into: &into)
        case .detachStatement(let expr, _):
            emit("detach:", depth: depth, into: &into)
            renderExpression(expr, depth: depth + 1, into: &into)
        case .expressionStmt(let expr, _):
            emit("exprStmt:", depth: depth, into: &into)
            renderExpression(expr, depth: depth + 1, into: &into)
        case .deferStatement(let inner, _):
            emit("defer:", depth: depth, into: &into)
            renderStatement(inner, depth: depth + 1, into: &into)
        case .passStatement:
            emit("pass", depth: depth, into: &into)
        case .captureStatement(let name, _):
            emit("capture \(name)", depth: depth, into: &into)
        }
    }

    private static func renderOptionalExpression(_ expr: Expression?, depth: Int, into: inout [CanonicalLine]) {
        if let e = expr {
            emit("initializer:", depth: depth, into: &into)
            renderExpression(e, depth: depth + 1, into: &into)
        } else {
            emit("(none)", depth: depth, into: &into)
        }
    }

    private static func renderStepBlock(_ block: Block?, depth: Int, into: inout [CanonicalLine]) {
        guard let b = block else { return }
        emit("step:", depth: depth, into: &into)
        renderStatements(b.statements, depth: depth + 1, into: &into)
    }

    private static func renderAssignTarget(_ target: AssignTarget, depth: Int, into: inout [CanonicalLine]) {
        switch target {
        case .identifier(let name):
            emit("target:", depth: depth, into: &into)
            emit("identifier: \(name)", depth: depth + 1, into: &into)
        case .member(let object, let name):
            emit("target:", depth: depth, into: &into)
            emit("member: \(name)", depth: depth + 1, into: &into)
            emit("receiver:", depth: depth + 1, into: &into)
            renderExpression(object, depth: depth + 2, into: &into)
        case .subscript(let expr, let index):
            emit("target:", depth: depth, into: &into)
            emit("subscript:", depth: depth + 1, into: &into)
            emit("receiver:", depth: depth + 2, into: &into)
            renderExpression(expr, depth: depth + 3, into: &into)
            emit("index:", depth: depth + 2, into: &into)
            renderExpression(index, depth: depth + 3, into: &into)
        }
    }

    private static func renderMatchPattern(_ pattern: MatchPattern, depth: Int, into: inout [CanonicalLine]) {
        switch pattern {
        case .wildcard:
            emit("_", depth: depth, into: &into)
        case .enumCase(let name):
            emit("caseName: \(name)", depth: depth, into: &into)
        case .intLiteral(let n):
            emit("intPattern: \(n)", depth: depth, into: &into)
        case .floatLiteral(let f):
            emit("floatPattern: \(f)", depth: depth, into: &into)
        case .stringLiteral(let s):
            emit("stringPattern: \"\(s)\"", depth: depth, into: &into)
        case .boolLiteral(let b):
            emit("boolPattern: \(b)", depth: depth, into: &into)
        }
    }

    // MARK: - 规范树渲染：表达式

    private static func renderExpression(_ expr: Expression, depth: Int, into: inout [CanonicalLine]) {
        switch expr {
        case .identifier(let name, _):
            emit("identifier: \(name)", depth: depth, into: &into)
        case .integerLiteral(let value, _):
            emit("int: \(value)", depth: depth, into: &into)
        case .floatLiteral(let value, _):
            emit("float: \(value)", depth: depth, into: &into)
        case .stringLiteral(let value, _):
            emit("string: \"\(value)\"", depth: depth, into: &into)
        case .boolLiteral(let value, _):
            emit("bool: \(value)", depth: depth, into: &into)
        case .stringInterpolation(let segments, _):
            emit("stringInterpolation:", depth: depth, into: &into)
            for seg in segments {
                switch seg {
                case .literal(let s):
                    emit("literal: \"\(s)\"", depth: depth + 1, into: &into)
                case .expression(let e):
                    emit("expr:", depth: depth + 1, into: &into)
                    renderExpression(e, depth: depth + 2, into: &into)
                }
            }
        case .binary(let left, let op, let right, _):
            emit("binary:", depth: depth, into: &into)
            emit("op: \(op)", depth: depth + 1, into: &into)
            emit("left:", depth: depth + 1, into: &into)
            renderExpression(left, depth: depth + 2, into: &into)
            emit("right:", depth: depth + 1, into: &into)
            renderExpression(right, depth: depth + 2, into: &into)
        case .unary(let op, let operand, _):
            emit("unary:", depth: depth, into: &into)
            emit("op: \(op)", depth: depth + 1, into: &into)
            emit("operand:", depth: depth + 1, into: &into)
            renderExpression(operand, depth: depth + 2, into: &into)
        case .call(let callee, let arguments, _):
            emit("call:", depth: depth, into: &into)
            emit("callee:", depth: depth + 1, into: &into)
            renderExpression(callee, depth: depth + 2, into: &into)
            renderArguments(arguments, depth: depth + 1, into: &into)
        case .member(let object, let name, _):
            emit("member: \(name)", depth: depth, into: &into)
            renderExpression(object, depth: depth + 1, into: &into)
        case .tupleIndex(let object, let index, _):
            emit("tupleIndex: \(index)", depth: depth, into: &into)
            renderExpression(object, depth: depth + 1, into: &into)
        case .tuple(let labels, let elements, _):
            emit("tuple: [\(labels.map { $0 ?? "" }.joined(separator: " "))]",
                 depth: depth, into: &into)
            for elem in elements {
                renderExpression(elem, depth: depth + 1, into: &into)
            }
        case .arrayLiteral(let elements, _):
            emit("arrayLiteral:", depth: depth, into: &into)
            for elem in elements {
                renderExpression(elem, depth: depth + 1, into: &into)
            }
        case .dictionaryLiteral(let entries, _):
            emit("dictionaryLiteral:", depth: depth, into: &into)
            for entry in entries {
                emit("entry:", depth: depth + 1, into: &into)
                renderExpression(entry.key, depth: depth + 2, into: &into)
                renderExpression(entry.value, depth: depth + 2, into: &into)
            }
        case .setLiteral(let elements, _):
            emit("setLiteral:", depth: depth, into: &into)
            for elem in elements {
                renderExpression(elem, depth: depth + 1, into: &into)
            }
        case .subscript(let expr, let index, _):
            emit("subscript:", depth: depth, into: &into)
            emit("receiver:", depth: depth + 1, into: &into)
            renderExpression(expr, depth: depth + 2, into: &into)
            emit("index:", depth: depth + 1, into: &into)
            renderExpression(index, depth: depth + 2, into: &into)
        case .funcLiteral(let decl, _):
            emit("funcLiteral:", depth: depth, into: &into)
            renderAnonymousFuncDecl(decl, depth: depth + 1, into: &into)
        case .selfKeyword:
            emit("self", depth: depth, into: &into)
        case .selfTypeKeyword:
            emit("own", depth: depth, into: &into)
        case .genericConstruct(let typeName, let typeArgs, let arguments, _):
            emit("genericConstruct: \(typeName)<\(typeArgs.map(typeText).joined(separator: " "))>",
                 depth: depth, into: &into)
            renderArguments(arguments, depth: depth + 1, into: &into)
        case .join(let inner, _, let form):
            emit("join: \(form.keyword)", depth: depth, into: &into)
            renderExpression(inner, depth: depth + 1, into: &into)
        case .tryExpression(let operand, let errorVar, let handler, _):
            emit("try: errorVar \(errorVar)", depth: depth, into: &into)
            renderExpression(operand, depth: depth + 1, into: &into)
            renderStatements(handler.statements, depth: depth + 1, into: &into)
        case .unsafe(let operand, _):
            emit("unsafe:", depth: depth, into: &into)
            renderExpression(operand, depth: depth + 1, into: &into)
        case .addressOf(let operand, _):
            emit("addressOf:", depth: depth, into: &into)
            renderExpression(operand, depth: depth + 1, into: &into)
        case .dotCaseRef(let name, _):
            emit("dotCaseRef: \(name)", depth: depth, into: &into)
        }
    }

    private static func renderArguments(_ args: [CallArgument], depth: Int, into: inout [CanonicalLine]) {
        for arg in args {
            emit("arg [\(arg.label ?? "")]:", depth: depth, into: &into)
            renderExpression(arg.expression, depth: depth + 1, into: &into)
        }
    }

    // MARK: - 规范树渲染：函数声明头（仅函数字面量到达；头名为空）

    private static func renderAnonymousFuncDecl(_ decl: FuncDecl, depth: Int, into: inout [CanonicalLine]) {
        var head = "func (\(paramsText(decl.params)))"
        if !decl.returnTypes.isEmpty {
            head += " -> (\(annotationsText(decl.returnTypes)))"
        }
        if decl.isAsync {
            head += " [async]"
        }
        head += " [func]:"
        emit(head, depth: depth, into: &into)
        if let body = decl.body {
            renderStatements(body.statements, depth: depth + 1, into: &into)
        } else {
            emit("(no body)", depth: depth + 1, into: &into)
        }
    }

    private static func paramsText(_ params: [Parameter]) -> String {
        var s = ""
        for p in params {
            s += "\(p.name):\(p.typeAnnotation.map(typeText) ?? "") "
        }
        return s
    }

    private static func annotationsText(_ list: [TypeAnnotation]) -> String {
        var s = ""
        for t in list {
            s += "\(typeText(t)) "
        }
        return s
    }

    private static func typeText(_ t: TypeAnnotation) -> String {
        switch t {
        case .simple(let name, _):
            return name
        case .generic(let name, let params, _):
            return "\(name)<\(annotationsText(params))>"
        case .pointer(let element, _):
            return "*\(typeText(element))"
        case .tuple(_, let elements, _):
            return "(\(annotationsText(elements)))"
        case .function(let params, let returns, _, _, _):
            return "(\(annotationsText(params)) -> (\(annotationsText(returns)))"
        }
    }
}
