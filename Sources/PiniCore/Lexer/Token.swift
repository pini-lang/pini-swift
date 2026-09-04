public enum StringSegment: Equatable {
 case literal(String)
 case expression(String)
}

public enum Token: Equatable {
 case keyword(Keyword, SourceLocation)
 case identifier(String, SourceLocation)
 case integerLiteral(Int, SourceLocation)
 case floatLiteral(Double, SourceLocation)
 case stringLiteral(String, SourceLocation)
 case interpolatedString(segments: [StringSegment], SourceLocation)
 case boolLiteral(Bool, SourceLocation)

 case plus(SourceLocation)
 case minus(SourceLocation)
 case star(SourceLocation)
 case slash(SourceLocation)
 case percent(SourceLocation)
 case increment(SourceLocation)
 case decrement(SourceLocation)
 case logicalAnd(SourceLocation)
 case logicalOr(SourceLocation)
 case logicalNot(SourceLocation)
 case equal(SourceLocation)
 case notEqual(SourceLocation)
 case lessThanOrEqual(SourceLocation)
 case greaterThanOrEqual(SourceLocation)
 case lessThan(SourceLocation)
 case greaterThan(SourceLocation)
 case bitwiseAnd(SourceLocation)
 case bitwiseXor(SourceLocation)
 case bitwiseNot(SourceLocation)
 case leftShift(SourceLocation)
 case rightShift(SourceLocation)
 case assign(SourceLocation)
 case plusAssign(SourceLocation)
 case minusAssign(SourceLocation)
 case multiplyAssign(SourceLocation)
 case divideAssign(SourceLocation)
 case moduloAssign(SourceLocation)
 case andAssign(SourceLocation)
 case orAssign(SourceLocation)
 case xorAssign(SourceLocation)
 case leftShiftAssign(SourceLocation)
 case rightShiftAssign(SourceLocation)

 case leftParen(SourceLocation)
 case rightParen(SourceLocation)
 case leftBracket(SourceLocation)
 case rightBracket(SourceLocation)
 case leftBrace(SourceLocation)
 case rightBrace(SourceLocation)
 case colon(SourceLocation)
 case comma(SourceLocation)
 case arrow(SourceLocation)
 case doubleArrow(SourceLocation)
 case pipe(SourceLocation)
 case dot(SourceLocation)
 case at(SourceLocation)
 case hash(SourceLocation)
 case questionMark(SourceLocation)

 case indent(SourceLocation)
 case dedent(SourceLocation)
 case newline(SourceLocation)
 case eof(SourceLocation)
}

extension Token {
 public var location: SourceLocation {
 switch self {
 case .keyword(_, let loc): return loc
 case .identifier(_, let loc): return loc
 case .integerLiteral(_, let loc): return loc
 case .floatLiteral(_, let loc): return loc
 case .stringLiteral(_, let loc): return loc
 case .interpolatedString(_, let loc): return loc
 case .boolLiteral(_, let loc): return loc
 case .plus(let loc): return loc
 case .minus(let loc): return loc
 case .star(let loc): return loc
 case .slash(let loc): return loc
 case .percent(let loc): return loc
 case .increment(let loc): return loc
 case .decrement(let loc): return loc
 case .logicalAnd(let loc): return loc
 case .logicalOr(let loc): return loc
 case .logicalNot(let loc): return loc
 case .equal(let loc): return loc
 case .notEqual(let loc): return loc
 case .lessThanOrEqual(let loc): return loc
 case .greaterThanOrEqual(let loc): return loc
 case .lessThan(let loc): return loc
 case .greaterThan(let loc): return loc
 case .bitwiseAnd(let loc): return loc
 case .bitwiseXor(let loc): return loc
 case .bitwiseNot(let loc): return loc
 case .leftShift(let loc): return loc
 case .rightShift(let loc): return loc
 case .assign(let loc): return loc
 case .plusAssign(let loc): return loc
 case .minusAssign(let loc): return loc
 case .multiplyAssign(let loc): return loc
 case .divideAssign(let loc): return loc
 case .moduloAssign(let loc): return loc
 case .andAssign(let loc): return loc
 case .orAssign(let loc): return loc
 case .xorAssign(let loc): return loc
 case .leftShiftAssign(let loc): return loc
 case .rightShiftAssign(let loc): return loc
 case .leftParen(let loc): return loc
 case .rightParen(let loc): return loc
 case .leftBracket(let loc): return loc
 case .rightBracket(let loc): return loc
 case .leftBrace(let loc): return loc
 case .rightBrace(let loc): return loc
 case .colon(let loc): return loc
 case .comma(let loc): return loc
 case .arrow(let loc): return loc
 case .doubleArrow(let loc): return loc
 case .pipe(let loc): return loc
 case .dot(let loc): return loc
 case .at(let loc): return loc
 case .hash(let loc): return loc
 case .questionMark(let loc): return loc
 case .indent(let loc): return loc
 case .dedent(let loc): return loc
 case .newline(let loc): return loc
 case .eof(let loc): return loc
 }
 }

 public var lexeme: String {
 switch self {
 case .keyword(let k, _): return k.rawValue
 case .identifier(let s, _): return s
 case .integerLiteral(let v, _): return String(v)
 case .floatLiteral(let v, _): return String(v)
 case .stringLiteral(let v, _): return "\"\(v)\""
 case .interpolatedString(let segs, _):
 let inner = segs.map { seg in
 switch seg {
 case .literal(let s): return s
 case .expression(let e): return "\\(\(e))"
 }
 }.joined()
 return "\"\(inner)\""
 case .boolLiteral(let v, _): return String(v)
 case .plus: return "+"
 case .minus: return "-"
 case .star: return "*"
 case .slash: return "/"
 case .percent: return "%"
 case .increment: return "++"
 case .decrement: return "--"
 case .logicalAnd: return "&&"
 case .logicalOr: return "||"
 case .logicalNot: return "!"
 case .equal: return "=="
 case .notEqual: return "!="
 case .lessThanOrEqual: return "<="
 case .greaterThanOrEqual: return ">="
 case .lessThan: return "<"
 case .greaterThan: return ">"
 case .bitwiseAnd: return "&"
 case .bitwiseXor: return "^"
 case .bitwiseNot: return "~"
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
 case .leftParen: return "("
 case .rightParen: return ")"
 case .leftBracket: return "["
 case .rightBracket: return "]"
 case .leftBrace: return "{"
 case .rightBrace: return "}"
 case .colon: return ":"
 case .comma: return ","
 case .arrow: return "->"
 case .doubleArrow: return "=>"
 case .pipe: return "|"
 case .dot: return "."
 case .at: return "@"
 case .hash: return "#"
 case .questionMark: return "?"
 case .indent: return "→"
 case .dedent: return "←"
 case .newline: return "\\n"
 case .eof: return ""
 }
 }

 public var typeName: String {
 switch self {
 case .keyword: return "keyword"
 case .identifier: return "identifier"
 case .integerLiteral: return "int"
 case .floatLiteral: return "float"
 case .stringLiteral: return "string"
 case .interpolatedString: return "interpolatedString"
 case .boolLiteral: return "bool"
 case .plus: return "plus"
 case .minus: return "minus"
 case .star: return "star"
 case .slash: return "slash"
 case .percent: return "percent"
 case .increment: return "increment"
 case .decrement: return "decrement"
 case .logicalAnd: return "logicalAnd"
 case .logicalOr: return "logicalOr"
 case .logicalNot: return "logicalNot"
 case .equal: return "equal"
 case .notEqual: return "notEqual"
 case .lessThanOrEqual: return "lessThanOrEqual"
 case .greaterThanOrEqual: return "greaterThanOrEqual"
 case .lessThan: return "lessThan"
 case .greaterThan: return "greaterThan"
 case .bitwiseAnd: return "bitwiseAnd"
 case .bitwiseXor: return "bitwiseXor"
 case .bitwiseNot: return "bitwiseNot"
 case .leftShift: return "leftShift"
 case .rightShift: return "rightShift"
 case .assign: return "assign"
 case .plusAssign: return "plusAssign"
 case .minusAssign: return "minusAssign"
 case .multiplyAssign: return "multiplyAssign"
 case .divideAssign: return "divideAssign"
 case .moduloAssign: return "moduloAssign"
 case .andAssign: return "andAssign"
 case .orAssign: return "orAssign"
 case .xorAssign: return "xorAssign"
 case .leftShiftAssign: return "leftShiftAssign"
 case .rightShiftAssign: return "rightShiftAssign"
 case .leftParen: return "leftParen"
 case .rightParen: return "rightParen"
 case .leftBracket: return "leftBracket"
 case .rightBracket: return "rightBracket"
 case .leftBrace: return "leftBrace"
 case .rightBrace: return "rightBrace"
 case .colon: return "colon"
 case .comma: return "comma"
 case .arrow: return "arrow"
 case .doubleArrow: return "doubleArrow"
 case .pipe: return "pipe"
 case .dot: return "dot"
 case .at: return "at"
 case .hash: return "hash"
 case .questionMark: return "questionMark"
 case .indent: return "indent"
 case .dedent: return "dedent"
 case .newline: return "newline"
 case .eof: return "eof"
 }
 }
}

public enum Keyword: String, CaseIterable {
 case `var` = "var"
 case `let` = "let"
 case `func` = "func"
 case `enum` = "enum"
 case `object` = "object"
 case `if` = "if"
 case `elif` = "elif"
 case `else` = "else"
 case `match` = "match"
 case `case` = "case"
 case `while` = "while"
 case `try` = "try"
 case `except` = "except"
 case `return` = "return"
 case `break` = "break"
 case `continue` = "continue"
 case `self` = "self"
 // G50：`Self` 更名 `own`——类型内自指 + 扩展块方法修饰符 `|own`（与 `|self` 配对）；
 // `Self` 降级为普通标识符，旧代码须迁移为 `own`。
 case `own` = "own"
 case `defer` = "defer"
// ADR-012：异步表层 `<=` 前缀 join（立场 B）逆转，由 `await`/`wait` 关键字承载。
// `await` 用于异步函数体（=>` 派发）内的挂起等待；`wait` 用于同步上下文的阻塞 join；
// 二者均映射到既有 `.join` AST 节点（运行时按 suspendMode 上下文敏感，脊柱 ADR-009 不变）。
// ADR-013：块标签模型由 `while@label`/`for@label` 逆转，新增 `scope` 关键字
// 开启带标签无条件子块（`scope 块标签:`），`break`/`continue` 按标签名定向。见 ADR-012 / ADR-013。
 case `import` = "import"
 case `export` = "export"
 case `pass` = "pass"
 case `step` = "step"
 case `for` = "for"
 case `in` = "in"
 case `nil` = "nil"
 case `capture` = "capture"
 case `await` = "await"
 case `wait` = "wait"
 case `scope` = "scope"
 // ADR-016/任务 #13：detach 语句形式 `detach <expr>`（ detach-expr-stmt），
 // 从内建函数升格为保留关键字——fire-and-forget 唯一合法出口。
 case `detach` = "detach"
 // Phase 2a（ADR-015 FFI）：`unsafe` 前缀表达式 / `|unsafe` 函数修饰符 + `foreign` 块声明。
 // 关键字集 31→33（ADR-015）；34（G51 补 `test`，对齐 spec 『共 34』）。
 case `unsafe` = "unsafe"
 case `foreign` = "foreign"
 // G51（spec KEYWORD 收口）：测试函数块修饰符关键字——宿主词法对齐自举
 //（自举 lexer 关键字表本就含 kw_test）；`名称|test` 修饰符位经 parseIdentifier
 // 白名单接出为修饰符串 "test"（Interpreter.runTests 收集路径不变）。
 case `test` = "test"
}
