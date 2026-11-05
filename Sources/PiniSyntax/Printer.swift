import Foundation

/// 源码打印器：AST → 源码。`fmt` 与展开出口共用这一条映射，故它只能从 AST 重建，
/// 不读原文本、不做空白重排。
/// 版面只做三件事：缩进、空行、行内空白归一；不看列宽、不折行、不做列对齐。
public enum Printer {

    /// 打印整模块。结论以「重新解析得到同一棵树」验收，不以观感验收。
    public static func print(module: Module) -> String {
        print(module: module, comments: [])
    }

    /// 带注释表打印。`comments` 为空即无源文本模式（`pini expand` 走这条）。
    public static func print(module: Module, comments: CommentTable) -> String {
        print(module: module, comments: comments, hints: .empty)
    }

    /// 带位置旁路打印：字面量原文与行前导空格从 `hints` 取。空表等同于无源模式。
    public static func print(module: Module, comments: CommentTable, hints: PrintHints) -> String {
        var writer = SourceWriter(fileName: module.location.fileName, hints: hints)
        writer.write(module: module)
        return writer.finish(comments: comments)
    }

    /// 中缀运算符的写出形态。与解析共用一张表，避免只在一侧认得的记号。
    static func spelling(_ op: BinaryOperator) -> String {
        switch op {
        case .plus: return "+"
        case .minus: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .modulo: return "%"
        case .equal: return "=="
        case .notEqual: return "!="
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .lessThanOrEqual: return "<="
        case .greaterThanOrEqual: return ">="
        case .bitwiseAnd: return "&"
        case .bitwiseOr: return "|"
        case .bitwiseXor: return "^"
        case .leftShift: return "<<"
        case .rightShift: return ">>"
        case .assign: return "="
        case .plusAssign: return "+="
        case .minusAssign: return "-="
        case .multiplyAssign: return "*="
        case .divideAssign: return "/="
        case .moduloAssign: return "%="
        case .andAssign: return "&="
        case .orAssign: return "|="
        case .xorAssign: return "^="
        case .leftShiftAssign: return "<<="
        case .rightShiftAssign: return ">>="
        case .and: return "&&"
        case .or: return "||"
        }
    }

    /// 一元运算符：`postfix` 为真时写在操作数右侧。
    static func spelling(_ op: UnaryOperator) -> (text: String, postfix: Bool) {
        switch op {
        case .minus: return ("-", false)
        case .plus: return ("+", false)
        case .logicalNot, .not: return ("!", false)
        case .bitwiseNot: return ("~", false)
        case .increment: return ("++", false)
        case .decrement: return ("--", false)
        case .forceUnwrap: return ("!", true)
        }
    }

    /// 二元优先级：数字越大结合越紧。同层右操作数须加括号，左操作数不必（左结合）。
    static func precedence(_ op: BinaryOperator) -> Int {
        switch op {
        case .or: return 1
        case .and: return 2
        case .equal, .notEqual: return 3
        case .lessThan, .greaterThan, .lessThanOrEqual, .greaterThanOrEqual: return 4
        case .bitwiseAnd, .bitwiseOr, .bitwiseXor, .leftShift, .rightShift: return 5
        case .plus, .minus: return 6
        case .multiply, .divide, .modulo: return 7
        default: return 0
        }
    }

    /// 求值上下文里不能再接后缀 / 会被更大范围吃掉的节点：作成员、调用、下标基座时加括号。
    static func isAtomic(_ expr: Expression) -> Bool {
        switch expr {
        case .binary, .unary, .join, .tryExpression, .unsafe, .addressOf:
            return false
        default:
            return true
        }
    }
}

// MARK: - 写入器

extension Printer {

    /// 缩进的两套坐标：`column` 是输出列，`source` 是父块首行的源宽度。
    /// `step` 是本块进入时的增量，无源行的子块沿用它——二格文件里合成的体才不会跳回四格。
    struct Indent: Equatable {
        var column: Int
        var source: Int
        var step: Int = 4
        static let zero = Indent(column: 0, source: 0)
    }

    /// 行缓冲 + 缩进坐标。所有输出都经 `line` 一处落行，缩进才不会分叉。
    /// 每行登记生成它的节点位置：注释锚回靠这份对照，不靠重新解析原文本。
    struct SourceWriter {
        /// 一条物理输出行。`anchor` 是写出该行的节点位置；续行与合成行（空行、`pass`、收尾括号）为 nil。
        struct Line: Equatable {
            var text: String
            var column: Int
            var anchor: SourceLocation?
        }

        private(set) var lines: [Line] = []
        var indent: Indent = .zero
        private var savedIndents: [Indent] = []
        let fileName: String
        /// 位置旁路：字面量原文与行前导空格，供写出分支按锚点取用。
        let hints: PrintHints
        /// 当前锚点。写语句 / 声明 / 块头之前设置，`line` 据此登记；续行不继承。
        var anchor: SourceLocation?

        init(fileName: String, hints: PrintHints = .empty) {
            self.fileName = fileName
            self.hints = hints
        }

        /// 全部行按换行拼接。内联函数字面量与 try 处理器要把自己的行塞回调用方的字符串。
        var text: String { lines.map(\.text).joined(separator: "\n") }

        /// `text` 内的换行就地拆成多行：首行带锚点，续行只保留已含缩进的原文。
        mutating func line(_ text: String) {
            let head = String(repeating: " ", count: indent.column) + text
            var isFirst = true
            for physical in head.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(Line(text: String(physical), column: indent.column, anchor: isFirst ? anchor : nil))
                isFirst = false
            }
        }

        mutating func blank() {
            if lines.last?.text != "" { lines.append(Line(text: "", column: 0, anchor: nil)) }
        }

        /// 进入缩进块：增量取「本块首行源宽度 − 父块首行源宽度」，无源行或差值为零时跟随父块步长。
        /// 差值为零会把体印成与块头同列，解析器读不回块，故不能按零走。
        mutating func enterBlock(sourceLine: Int?) {
            savedIndents.append(indent)
            let childSource = sourceLine.flatMap { hints.indents[$0] }
            let delta: Int
            if let childSource, childSource > indent.source {
                delta = childSource - indent.source
            } else {
                delta = indent.step
            }
            indent = Indent(
                column: indent.column + delta, source: childSource ?? indent.source, step: delta)
        }

        mutating func exitBlock() {
            indent = savedIndents.removeLast()
        }

        /// 块头名：文件名去目录、去 `.pini`。import / export 块头由它派生。
        var baseName: String {
            let name = (fileName as NSString).lastPathComponent
            return name.hasSuffix(".pini") ? String(name.dropLast(5)) : name
        }

        /// 收尾：先按锚点插回注释，再去掉尾部空行。
        mutating func finish(comments: CommentTable) -> String {
            let out = CommentAnchoring.apply(lines: lines, comments: comments)
            var trimmed = out
            while trimmed.last?.text == "" { trimmed.removeLast() }
            guard !trimmed.isEmpty else { return "" }
            return trimmed.map(\.text).joined(separator: "\n") + "\n"
        }
    }
}

// MARK: - 模块与声明

extension Printer.SourceWriter {

    mutating func write(module: Module) {
        if !module.imports.isEmpty {
            write(imports: module.imports)
            blank()
        }
        if !module.exports.isEmpty {
            for export in module.exports {
                write(export: export)
                blank()
            }
        }
        for (index, decl) in module.declarations.enumerated() {
            if index > 0 { blank() }
            write(decl: decl)
        }
    }

    mutating func write(imports: [ImportDecl]) {
        anchor = imports.first?.location
        line("[\(baseName)|import]")
        for item in imports {
            anchor = item.location
            line("\(item.alias) = \(Printer.quote(item.packagePath))")
        }
    }

    mutating func write(export: ExportDecl) {
        anchor = export.location
        line("[\(export.name)|export]")
        for entry in export.entries {
            anchor = entry.location
            switch entry.target {
            case .pini: line("\(entry.name) = \(entry.symbol)")
            case .c: line("\(entry.name)|c = \(entry.symbol)")
            }
        }
    }

    mutating func write(decl: TopLevelDecl) {
        anchor = decl.location
        switch decl {
        case .structDecl(let node):
            line("(\(node.name)\(Printer.genericParams(node.genericParams)))")
            write(structBody: node)
        case .objectDecl(let node):
            line("{\(node.name)\(Printer.genericParams(node.genericParams))}")
            write(fields: node.fields)
            write(traits: node.traits)
            for method in node.methods { write(funcDecl: method) }
        case .givenDecl(let node):
            line("[\(node.name)\(Printer.genericParams(node.genericParams))|given]")
            write(fields: node.fields)
            write(traits: node.traits)
            for method in node.methods { write(funcDecl: method) }
        case .enumDecl(let node):
            line("[\(node.name)\(Printer.genericParams(node.genericParams))]")
            for item in node.cases {
                anchor = item.location
                line(Printer.enumCase(item))
            }
            write(traits: node.traits)
            for method in node.methods { write(funcDecl: method) }
        case .traitDecl(let node):
            line("<\(node.name)>")
            for signature in node.signatures { write(funcDecl: signature) }
        case .extensionDecl(let node):
            line(Printer.extensionHeader(node))
            for method in node.methods { write(funcDecl: method) }
        case .foreignDecl(let node):
            line("[\(node.name)|foreign]")
            for symbol in node.symbols {
                anchor = symbol.location
                line(Printer.foreignSymbol(symbol))
            }
        case .funcDecl(let node):
            write(funcDecl: node)
        case .varDecl(let statement), .statement(let statement):
            write(statement: statement)
        case .importDecl(let item):
            write(imports: [item])
        case .exportDecl(let node):
            write(export: node)
        }
    }

    /// 结构体体：内嵌父类型先出，随后字段与 `实现:`。父类型同时占一条字段，故跳过那一条。
    mutating func write(structBody node: StructDecl) {
        if let composed = node.composedType { line(composed) }
        var fields = node.fields
        if let composed = node.composedType, let first = fields.first,
            first.name == composed, first.initializer == nil
        {
            fields.removeFirst()
        }
        write(fields: fields)
        write(traits: node.traits)
        for method in node.methods { write(funcDecl: method) }
    }

    mutating func write(fields: [FieldDecl]) {
        for field in fields {
            anchor = field.location
            var text = "\(field.name): \(Printer.type(field.typeAnnotation))"
            if let initializer = field.initializer {
                text += " = \(Printer.expr(initializer, indent: indent, fileName: fileName, hints: hints))"
            }
            line(text)
        }
    }

    mutating func write(traits: [String]) {
        for trait in traits { line("实现: \(trait)") }
    }

    mutating func write(funcDecl node: FuncDecl) {
        anchor = node.location
        let signature = Printer.funcSignature(node)
        guard let body = node.body else {
            line(signature)
            return
        }
        line(signature + ":")
        write(nested: body)
    }

    mutating func write(statements list: [Statement]) {
        for statement in list { write(statement: statement) }
    }
}

// MARK: - 语句

extension Printer.SourceWriter {

    mutating func write(statement: Statement) {
        anchor = statement.location
        switch statement {
        case .varDecl(let name, let type, let initializer, let isMutable, _):
            var text = "\(isMutable ? "var" : "let") \(name)"
            if let type { text += ": \(Printer.type(type))" }
            if let initializer { text += " = \(Printer.expr(initializer, indent: indent, fileName: fileName, hints: hints))" }
            line(text)

        case .varDestructure(let names, let type, let initializer, let isMutable, _):
            var text = "\(isMutable ? "var" : "let") (\(names.joined(separator: ", ")),)"
            if let type { text += ": \(Printer.type(type))" }
            if let initializer { text += " = \(Printer.expr(initializer, indent: indent, fileName: fileName, hints: hints))" }
            line(text)

        case .assign(let target, let value, _):
            let right = Printer.expr(value, indent: indent, fileName: fileName, hints: hints)
            line("\(Printer.assignTarget(target, indent: indent, fileName: fileName, hints: hints)) = \(right)")

        case .returnStatement(let value, _):
            if let value {
                line("return \(Printer.expr(value, indent: indent, fileName: fileName, hints: hints))")
            } else {
                line("return")
            }

        case .breakStatement(let label, _):
            line(label.map { "break \($0)" } ?? "break")

        case .continueStatement(let label, _):
            line(label.map { "continue \($0)" } ?? "continue")

        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, _):
            let head = Printer.labelPrefix(label) + "if " + Printer.expr(condition, indent: indent, fileName: fileName, hints: hints)
            write(branchHead: head, body: thenBlock)
            for branch in elifs {
                anchor = branch.block.location
                let elifHead = "elif " + Printer.expr(branch.condition, indent: indent, fileName: fileName, hints: hints)
                write(branchHead: elifHead, body: branch.block)
            }
            if let elseBlock {
                anchor = elseBlock.location
                line("else:")
                write(nested: elseBlock)
            }

        case .whileStatement(let condition, let body, let step, let label, _):
            let head = Printer.labelPrefix(label) + "while " + Printer.expr(condition, indent: indent, fileName: fileName, hints: hints)
            line(head + ":")
            write(nested: body)
            write(step: step)

        case .forStatement(let pattern, let iterable, let body, let step, let label, _):
            let head = Printer.labelPrefix(label) + "for (" + pattern.joined(separator: ", ") + ",) in "
                + Printer.expr(iterable, indent: indent, fileName: fileName, hints: hints)
            line(head + ":")
            write(nested: body)
            write(step: step)

        case .unrollStatement(let pattern, let table, let body, _):
            line(
                "unroll (" + pattern.joined(separator: ", ") + ",) in "
                    + Printer.expr(table, indent: indent, fileName: fileName, hints: hints) + ":")
            write(nested: body)

        case .matchStatement(let value, let cases, _):
            line("match \(Printer.expr(value, indent: indent, fileName: fileName, hints: hints)):")
            enterBlock(sourceLine: cases.first?.location.line)
            for matchCase in cases {
                anchor = matchCase.location
                line(Printer.matchCaseHead(matchCase, hints: hints))
                enterBlock(sourceLine: matchCase.block.statements.first?.location.line)
                write(statements: matchCase.block.statements)
                exitBlock()
            }
            exitBlock()

        case .scopedBlock(_, let body, _):
            // 唯一来源是 `defer:` 的块形体，由 defer 分支拦下；走到这里只可能是手上构的树。
            write(statements: body.statements)

        case .detachStatement(let expression, _):
            line("detach \(Printer.expr(expression, indent: indent, fileName: fileName, hints: hints))")

        case .expressionStmt(let expression, _):
            line(Printer.expr(expression, indent: indent, fileName: fileName, hints: hints))

        case .deferStatement(let inner, _):
            if case .scopedBlock(_, let body, _) = inner {
                line("defer:")
                write(nested: body)
            } else {
                line("defer " + (Printer.inlineStatement(inner, indent: indent, fileName: fileName, hints: hints) ?? ""))
            }

        case .passStatement:
            line("pass")

        case .captureStatement(let name, _):
            line("capture \(name)")
        }
    }

    /// 分支体：能写成一行就与块头同行，否则换行下潜。判据只在 `inlineBranch` 一处。
    mutating func write(branchHead head: String, body: Block) {
        if let inline = inlineBranch(body) {
            line(head + ": " + inline)
        } else {
            line(head + ":")
            write(nested: body)
        }
    }

    /// 单行体判据：恰一条表达式语句，且与块头同源行。块的 `location` 就是块头冒号的位置，
    /// 故两种写法都拿它当基准。解析器的单行分支只调 `parseExpression`，声明与 `return`
    /// 写在同一行读不回来，所以只认表达式语句。
    private func inlineBranch(_ block: Block) -> String? {
        guard block.statements.count == 1,
            case .expressionStmt(let expression, let location) = block.statements[0],
            location.line == block.location.line
        else { return nil }
        return Printer.expr(expression, indent: indent, fileName: fileName, hints: hints)
    }

    /// 缩进块：按本块首行宽度下潜，再逐句写。空块写 `pass`，否则重新解析时该块无体可依。
    /// 合成 `pass` 没有源位置，锚点置空：它不该被当成注释的落点。
    mutating func write(nested block: Block) {
        enterBlock(sourceLine: block.statements.first?.location.line)
        if block.statements.isEmpty {
            anchor = nil
            line("pass")
        } else {
            write(statements: block.statements)
        }
        exitBlock()
    }

    mutating func write(step block: Block?) {
        guard let block else { return }
        anchor = block.location
        line("step:")
        write(nested: block)
    }
}

// MARK: - 表达式

extension Printer {

    /// 行内表达式文本。函数字面量的多语句体自带换行与缩进，故这里要带 `depth`。
    static func expr(_ node: Expression, indent: Indent, fileName: String, hints: PrintHints) -> String {
        switch node {
        case .identifier(let name, _):
            return name
        case .integerLiteral(let value, let location):
            return hints.spelling(at: location) ?? "\(value)"
        case .floatLiteral(let value, let location):
            return hints.spelling(at: location) ?? float(value)
        case .stringLiteral(let value, _):
            return quote(value)
        case .stringInterpolation(let segments, _):
            return interpolated(segments, indent: indent, fileName: fileName, hints: hints)
        case .boolLiteral(let value, _):
            return value ? "true" : "false"
        case .selfKeyword:
            return "self"
        case .selfTypeKeyword:
            return "own"
        case .dotCaseRef(let name, _):
            return ".\(name)"
        case .binary(let left, let op, let right, _):
            return binaryText(left: left, op: op, right: right, indent: indent, fileName: fileName, hints: hints)
        case .unary(let op, let operand, _):
            return unaryText(op: op, operand: operand, indent: indent, fileName: fileName, hints: hints)
        case .call(let callee, let arguments, _):
            return wrapper(
                atom(callee, indent: indent, fileName: fileName, hints: hints) + "(",
                callArguments(arguments, indent: indent, fileName: fileName, hints: hints), ")", column: indent.column)
        case .member(let object, let name, _):
            return atom(object, indent: indent, fileName: fileName, hints: hints) + "." + name
        case .tupleIndex(let object, let index, _):
            return atom(object, indent: indent, fileName: fileName, hints: hints) + ".\(index)"
        case .subscript(let target, let index, _):
            return wrapper(
                atom(target, indent: indent, fileName: fileName, hints: hints) + "[",
                expr(index, indent: indent, fileName: fileName, hints: hints), "]", column: indent.column)
        case .tuple(let labels, let elements, let location):
            return tupleText(
                labels: labels, elements: elements, literal: location,
                indent: indent, fileName: fileName, hints: hints)
        case .arrayLiteral(let elements, let location):
            let inner = lineBreakIndent(
                elements.map(\.location), literal: location, indent: indent, hints: hints)
            return collectionLiteral(
                head: "[", tail: "]",
                texts: elements.map { expr($0, indent: inner ?? indent, fileName: fileName, hints: hints) },
                inner: inner, column: indent.column, trailing: false)
        case .dictionaryLiteral(let entries, let location):
            let inner = lineBreakIndent(
                entries.map(\.key.location), literal: location, indent: indent, hints: hints)
            return collectionLiteral(
                head: "{", tail: "}",
                texts: entries.map {
                    dictionaryEntry($0, indent: inner ?? indent, fileName: fileName, hints: hints)
                },
                inner: inner, column: indent.column, trailing: false)
        case .setLiteral(let elements, let location):
            let inner = lineBreakIndent(
                elements.map(\.location), literal: location, indent: indent, hints: hints)
            return collectionLiteral(
                head: "{", tail: "}",
                texts: elements.map { expr($0, indent: inner ?? indent, fileName: fileName, hints: hints) },
                inner: inner, column: indent.column, trailing: false)
        case .funcLiteral(let decl, _):
            return funcLiteral(decl, indent: indent, fileName: fileName, hints: hints)
        case .genericConstruct(let typeName, let typeArgs, let arguments, _):
            let types = typeArgs.map { type($0) }.joined(separator: ", ")
            let tail = types.hasSuffix(">") ? " >" : ">"
            return wrapper(
                "\(typeName)<\(types)\(tail)(",
                callArguments(arguments, indent: indent, fileName: fileName, hints: hints), ")", column: indent.column)
        case .join(let operand, _, let form):
            return "\(form.keyword) " + atom(operand, indent: indent, fileName: fileName, hints: hints)
        case .tryExpression(let operand, let errorVar, let handler, _):
            return tryText(operand: operand, errorVar: errorVar, handler: handler, indent: indent, fileName: fileName, hints: hints)
        case .unsafe(let operand, _):
            return "unsafe " + atom(operand, indent: indent, fileName: fileName, hints: hints)
        case .addressOf(let operand, _):
            return "&" + atom(operand, indent: indent, fileName: fileName, hints: hints)
        }
    }

    /// 基座位：不是原子节点就套括号，避免后缀落到子树里层去。
    static func atom(_ node: Expression, indent: Indent, fileName: String, hints: PrintHints) -> String {
        isAtomic(node) ? expr(node, indent: indent, fileName: fileName, hints: hints) : "(" + expr(node, indent: indent, fileName: fileName, hints: hints) + ")"
    }

    /// 拼包围结构：体内出现换行时，收尾符号另起一行并回到语句缩进。
    /// 不然多语句函数字面量作实参时，`)` 会黏在最后一条语句尾巴上。
    static func wrapper(_ head: String, _ body: String, _ tail: String, column: Int) -> String {
        guard body.contains("\n") else { return head + body + tail }
        return head + body + "\n" + String(repeating: " ", count: column) + tail
    }

    static func binaryText(left: Expression, op: BinaryOperator, right: Expression, indent: Indent, fileName: String, hints: PrintHints) -> String {
        let level = precedence(op)
        var leftText = expr(left, indent: indent, fileName: fileName, hints: hints)
        var rightText = expr(right, indent: indent, fileName: fileName, hints: hints)
        if case .binary(_, let childOp, _, _) = left, precedence(childOp) < level {
            leftText = "(" + leftText + ")"
        }
        if case .binary(_, let childOp, _, _) = right, precedence(childOp) <= level {
            rightText = "(" + rightText + ")"
        }
        return leftText + " " + spelling(op) + " " + rightText
    }

    static func unaryText(op: UnaryOperator, operand: Expression, indent: Indent, fileName: String, hints: PrintHints) -> String {
        let form = spelling(op)
        let text = atom(operand, indent: indent, fileName: fileName, hints: hints)
        return form.postfix ? text + form.text : form.text + text
    }

    static func tupleText(
        labels: [String?], elements: [Expression], literal: SourceLocation,
        indent: Indent, fileName: String, hints: PrintHints
    ) -> String {
        if elements.isEmpty { return "()" }
        let parts = elements.enumerated().map { index, element -> String in
            let text = expr(element, indent: indent, fileName: fileName, hints: hints)
            if labels.indices.contains(index), let label = labels[index] {
                return "\(label) = \(text)"
            }
            return text
        }
        return collectionLiteral(
            head: "(", tail: ")",
            texts: parts,
            inner: lineBreakIndent(
                elements.map(\.location), literal: literal, indent: indent, hints: hints),
            column: indent.column, trailing: true)
    }

    /// 跨行字面量里元素的落位：首个不在字面量首行的元素定步长，取其源缩进减父块源缩进。
    /// 差值非正或源缩进未知时跟随父块步长；内层字面量按这个落位再算，收尾括号才不会退回语句列。
    static func lineBreakIndent(
        _ starts: [SourceLocation], literal: SourceLocation, indent: Indent, hints: PrintHints
    ) -> Indent? {
        guard let first = starts.first(where: { $0.line != literal.line }) else { return nil }
        let delta = (hints.indents[first.line] ?? (indent.source + indent.step)) - indent.source
        let step = delta > 0 ? delta : indent.step
        return Indent(column: indent.column + step, source: indent.source + step, step: step)
    }

    /// 拼集合字面量。单行沿用原拼接；作者断过行则一行一元素、末元素带逗号，收尾回父列。
    /// 多行是规范形，只保留「断不断」，不还原元素原本挤在第几行。
    static func collectionLiteral(
        head: String, tail: String, texts: [String], inner: Indent?, column: Int, trailing: Bool
    ) -> String {
        let singleLine = texts.joined(separator: ", ") + (trailing ? "," : "")
        guard let inner, !texts.isEmpty else {
            return wrapper(head, singleLine, tail, column: column)
        }
        let pad = String(repeating: " ", count: inner.column)
        let body = texts.map { pad + $0 + "," }.joined(separator: "\n")
        return head + "\n" + body + "\n" + String(repeating: " ", count: column) + tail
    }

    static func dictionaryEntry(_ entry: DictEntry, indent: Indent, fileName: String, hints: PrintHints) -> String {
        let key = expr(entry.key, indent: indent, fileName: fileName, hints: hints)
        let value = expr(entry.value, indent: indent, fileName: fileName, hints: hints)
        if let valueType = entry.valueType {
            return "\(key): \(type(valueType)) = \(value)"
        }
        return "\(key) = \(value)"
    }

    static func callArguments(_ arguments: [CallArgument], indent: Indent, fileName: String, hints: PrintHints) -> String {
        arguments.map { argument -> String in
            let text = expr(argument.expression, indent: indent, fileName: fileName, hints: hints)
            guard let label = argument.label else { return text }
            return "\(label) = \(text)"
        }.joined(separator: ", ")
    }

    /// 函数字面量：单语句体写成同一行，多语句体另起缩进块。
    static func funcLiteral(_ decl: FuncDecl, indent: Indent, fileName: String, hints: PrintHints) -> String {
        var head = "func (" + parameters(decl.params) + ")"
        head += (decl.isAsync ? " => " : " -> ") + "(" + returnTypes(decl.returnTypes, labels: decl.returnLabels) + ")"
        guard let body = decl.body else { return head }
        if body.statements.count == 1,
            let inline = inlineStatement(
                body.statements[0], indent: indent, fileName: fileName, hints: hints)
        {
            return head + ": " + inline
        }
        var writer = SourceWriter(fileName: fileName, hints: hints)
        writer.indent = indent
        writer.enterBlock(sourceLine: body.statements.first?.location.line)
        writer.write(statements: body.statements)
        return head + ":\n" + writer.text
    }

    static func tryText(operand: Expression, errorVar: String, handler: Block, indent: Indent, fileName: String, hints: PrintHints) -> String {
        let head = "try " + expr(operand, indent: indent, fileName: fileName, hints: hints) + " else " + errorVar + ":"
        var writer = SourceWriter(fileName: fileName, hints: hints)
        writer.indent = indent
        writer.enterBlock(sourceLine: handler.statements.first?.location.line)
        if handler.statements.isEmpty {
            writer.line("pass")
        } else {
            writer.write(statements: handler.statements)
        }
        return head + "\n" + writer.text
    }

    /// 单行语句的文本；写不成一行的返回 nil，由调用方改走缩进块。
    static func inlineStatement(_ statement: Statement, indent: Indent, fileName: String, hints: PrintHints) -> String? {
        switch statement {
        case .expressionStmt(let expression, _):
            return expr(expression, indent: indent, fileName: fileName, hints: hints)
        case .returnStatement(let value, _):
            guard let value else { return "return" }
            return "return " + expr(value, indent: indent, fileName: fileName, hints: hints)
        case .assign(let target, let value, _):
            return assignTarget(target, indent: indent, fileName: fileName, hints: hints) + " = "
                + expr(value, indent: indent, fileName: fileName, hints: hints)
        case .passStatement:
            return "pass"
        case .breakStatement(let label, _):
            return label.map { "break \($0)" } ?? "break"
        case .continueStatement(let label, _):
            return label.map { "continue \($0)" } ?? "continue"
        case .captureStatement(let name, _):
            return "capture \(name)"
        case .detachStatement(let expression, _):
            return "detach " + expr(expression, indent: indent, fileName: fileName, hints: hints)
        case .varDecl(let name, let annotation, let initializer, let isMutable, _):
            var text = "\(isMutable ? "var" : "let") \(name)"
            if let annotation { text += ": \(type(annotation))" }
            if let initializer { text += " = \(expr(initializer, indent: indent, fileName: fileName, hints: hints))" }
            return text
        default:
            return nil
        }
    }

    static func assignTarget(_ target: AssignTarget, indent: Indent, fileName: String, hints: PrintHints) -> String {
        switch target {
        case .identifier(let name):
            return name
        case .member(let object, let name):
            return atom(object, indent: indent, fileName: fileName, hints: hints) + "." + name
        case .subscript(let target, let index):
            return atom(target, indent: indent, fileName: fileName, hints: hints) + "["
                + expr(index, indent: indent, fileName: fileName, hints: hints) + "]"
        }
    }
}

// MARK: - 声明头与类型

extension Printer {

    static func labelPrefix(_ label: String?) -> String {
        guard let label else { return "" }
        return "\(label)|"
    }

    static func genericParams(_ params: [GenericParam]) -> String {
        guard !params.isEmpty else { return "" }
        let parts = params.map { param -> String in
            guard let constraint = param.constraint else { return param.name }
            return "\(param.name)|\(type(constraint))"
        }
        return "<" + parts.joined(separator: ", ") + ">"
    }

    static func parameters(_ params: [Parameter]) -> String {
        guard !params.isEmpty else { return "" }
        let parts = params.map { parameter -> String in
            var text = parameter.isUsing ? "using \(parameter.name)" : parameter.name
            if let annotation = parameter.typeAnnotation { text += ": \(type(annotation))" }
            return text
        }
        return parts.joined(separator: ", ") + ","
    }

    static func returnTypes(_ types: [TypeAnnotation], labels: [String?]) -> String {
        guard !types.isEmpty else { return "" }
        let parts = types.enumerated().map { index, annotation -> String in
            if labels.indices.contains(index), let label = labels[index] {
                return "\(label): \(type(annotation))"
            }
            return type(annotation)
        }
        return parts.joined(separator: ", ") + ","
    }

    /// 函数签名（不含体与结尾冒号）。匿名函数也走这里，故名字为空时不写名字与修饰符。
    static func funcSignature(_ node: FuncDecl) -> String {
        var text = node.name
        for modifier in node.modifiers { text += "|\(modifier)" }
        text += genericParams(node.genericParams)
        text += "(" + parameters(node.params) + ")"
        text += (node.isAsync ? " => " : " -> ") + "(" + returnTypes(node.returnTypes, labels: node.returnLabels) + ")"
        return text
    }

    static func enumCase(_ node: EnumCase) -> String {
        guard !node.associatedParams.isEmpty else { return node.name }
        let parts = node.associatedParams.map { param -> String in
            let annotation = type(param.type)
            guard let name = param.name else { return annotation }
            return "\(name): \(annotation)"
        }
        return node.name + "(" + parts.joined(separator: ", ") + ",)"
    }

    static func foreignSymbol(_ node: ForeignSymbol) -> String {
        var text = node.name
        for flag in node.flags { text += "|\(flag)" }
        return text + ": " + type(node.annotation)
    }

    static func extensionHeader(_ node: ExtensionDecl) -> String {
        let delimiters: (String, String)
        switch node.kind {
        case .structExt: delimiters = ("((", "))")
        case .objectExt: delimiters = ("{{", "}}")
        case .bracketExt: delimiters = ("[[", "]]")
        case .traitExt: delimiters = ("<<", ">>")
        }
        var text = delimiters.0 + node.targetType + genericParams(node.genericParams)
        if let annotation = node.targetTypeAnnotation { text += ": " + type(annotation) }
        return text + delimiters.1
    }

    static func matchCaseHead(_ node: MatchCase, hints: PrintHints) -> String {
        let pattern = matchPattern(node.pattern, hints: hints)
        guard !node.bindings.isEmpty else { return "case \(pattern):" }
        let parts = node.bindings.map { binding -> String in
            guard let param = binding.paramName else { return binding.varName }
            return "\(param): \(binding.varName)"
        }
        return "case \(pattern)(" + parts.joined(separator: ", ") + ",):"
    }

    static func matchPattern(_ pattern: MatchPattern, hints: PrintHints) -> String {
        switch pattern {
        case .wildcard: return "_"
        case .enumCase(let name): return name
        case .intLiteral(let value, let location):
            return hints.spelling(at: location) ?? "\(value)"
        case .floatLiteral(let value, let location):
            return hints.spelling(at: location) ?? float(value)
        case .stringLiteral(let value): return quote(value)
        case .boolLiteral(let value): return value ? "true" : "false"
        }
    }

    static func type(_ annotation: TypeAnnotation) -> String {
        switch annotation {
        case .simple(let name, _):
            return name
        case .pointer(let element, _):
            return "*" + type(element)
        case .generic(let name, let params, _):
            // 末位参数以 `>` 收尾时补一个空格：否则 `>>` 会被词法并成右移，泛型在这里断掉。
            let inner = params.map { type($0) }.joined(separator: ", ")
            return name + "<" + inner + (inner.hasSuffix(">") ? " >" : ">")
        case .function(let params, let returns, _, _, _):
            let parameters = params.isEmpty ? "" : params.map { type($0) }.joined(separator: ", ") + ","
            let results = returns.isEmpty ? "" : returns.map { type($0) }.joined(separator: ", ") + ","
            return "(" + parameters + ") -> (" + results + ")"
        case .tuple(let labels, let elements, _):
            if elements.isEmpty { return "()" }
            let parts = elements.enumerated().map { index, element -> String in
                if labels.indices.contains(index), let label = labels[index] {
                    return "\(label): \(type(element))"
                }
                return type(element)
            }
            return "(" + parts.joined(separator: ", ") + ",)"
        }
    }
}

// MARK: - 锚点位置

extension Statement {
    /// 语句起点的源位置。没有 `default:`：新增语句分支会在这里编译失败，不会静默取错锚点。
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
        case .scopedBlock(_, _, let l): return l
        case .detachStatement(_, let l): return l
        case .expressionStmt(_, let l): return l
        case .deferStatement(_, let l): return l
        case .passStatement(let l): return l
        case .captureStatement(_, let l): return l
        }
    }
}

extension TopLevelDecl {
    /// 声明起点的源位置，转发到各节点自带的 `location`。
    var location: SourceLocation {
        switch self {
        case .structDecl(let node): return node.location
        case .objectDecl(let node): return node.location
        case .givenDecl(let node): return node.location
        case .enumDecl(let node): return node.location
        case .funcDecl(let node): return node.location
        case .traitDecl(let node): return node.location
        case .extensionDecl(let node): return node.location
        case .foreignDecl(let node): return node.location
        case .varDecl(let statement), .statement(let statement): return statement.location
        case .importDecl(let node): return node.location
        case .exportDecl(let node): return node.location
        }
    }
}

// MARK: - 字面量转义

extension Printer {

    /// 字符串字面量：反斜杠先转义，否则后面的 `\(` 会被重新读成插值。
    static func quote(_ value: String) -> String {
        var text = "\""
        for character in value {
            switch character {
            case "\\": text += "\\\\"
            case "\"": text += "\\\""
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case "\r": text += "\\r"
            case "\0": text += "\\0"
            default: text.append(character)
            }
        }
        return text + "\""
    }

    static func interpolated(_ segments: [InterpolationSegment], indent: Indent, fileName: String, hints: PrintHints) -> String {
        var text = "\""
        for segment in segments {
            switch segment {
            case .literal(let value):
                text += String(quote(value).dropFirst().dropLast())
            case .expression(let expression):
                text += "\\(" + expr(expression, indent: indent, fileName: fileName, hints: hints) + ")"
            }
        }
        return text + "\""
    }

    /// 浮点：沿用最短往返表示；整数形态补 `.0`，否则重新解析会落成整数字面量。
    static func float(_ value: Double) -> String {
        if value.isNaN { return "0.0" }
        if value.isInfinite { return value < 0 ? "-1e308" : "1e308" }
        let text = String(value)
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            return text + ".0"
        }
        return text
    }
}
