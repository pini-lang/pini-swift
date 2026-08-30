public class Lexer {
 private let source: String
 private let chars: [Character]
 private let fileName: String
 private var position: Int
 private var line: Int
 private var column: Int
 private var indentTracker: IndentTracker
 /// 草稿 A2（批次 1）：上一个已产出 token 是否为 `.`（dot）。
 /// 用于元组位置访问 `.index` 的词法消歧：`.` 后随数字时只读整数、不进浮点，
 /// 避免 `t.0.1` 中 `0.1` 被读成浮点字面量（`0.1` 本应拆为 `.0` `.1`）。
 private var prevTokenIsDot = false

 public init(source: String, fileName: String) {
 self.source = source
 self.chars = Array(source)
 self.fileName = fileName
 self.position = 0
 self.line = 1
 self.column = 1
 self.indentTracker = IndentTracker()
 }

 public func tokenize() throws -> [Token] {
 var tokens: [Token] = []

 while !isAtEnd {
 if skipBlankOrCommentLine() {
 continue
 }

 if isAtEnd {
 break
 }

 let loc = currentLocation
 let indentCount = countLeadingWhitespace()
 let indentTokens = try indentTracker.processLineStart(whitespaceCount: indentCount, location: loc)
 tokens.append(contentsOf: indentTokens)

 while !isAtEnd && currentChar != "\n" {
 guard let char = currentChar else { break }

 if char == " " || char == "\t" {
 _ = advance()
 continue
 }

 if char == ";" || char == "#" {
 // `;` 行注释 / `#` 文档注释（行首=文档注释，行中=退化行注释）；均持续到行尾（G35）
 skipToEndOfLine()
 break
 }

 let token = try nextToken()
 prevTokenIsDot = isDotToken(token)
 tokens.append(token)
 }

 if !isAtEnd && currentChar == "\n" {
 let nlLoc = currentLocation
 _ = advance()
 tokens.append(.newline(nlLoc))
 }
 }

 let loc = currentLocation
 tokens.append(contentsOf: indentTracker.finalize(location: loc))
 tokens.append(.eof(loc))
 return tokens
 }

 private var isAtEnd: Bool {
 return position >= chars.count
 }

 private func isDotToken(_ token: Token) -> Bool {
 if case .dot = token { return true }
 return false
 }

 private var currentChar: Character? {
 guard position < chars.count else { return nil }
 return chars[position]
 }

 private var currentLocation: SourceLocation {
 return SourceLocation(line: line, column: column, fileName: fileName)
 }

 @discardableResult
 private func advance() -> Character? {
 guard position < chars.count else { return nil }
 let char = chars[position]
 position += 1
 if char == "\n" {
 line += 1
 column = 1
 } else {
 column += 1
 }
 return char
 }

 private func match(_ expected: Character) -> Bool {
 guard let char = currentChar, char == expected else { return false }
 _ = advance()
 return true
 }

 private func peek(offset: Int = 0) -> Character? {
 let idx = position + offset
 guard idx < chars.count else { return nil }
 return chars[idx]
 }

 private func countLeadingWhitespace() -> Int {
 var count = 0
 while let char = currentChar, char == " " || char == "\t" {
 count += 1
 _ = advance()
 }
 return count
 }

 private func skipToEndOfLine() {
 while let char = currentChar, char != "\n" {
 _ = advance()
 }
 }

 private func skipBlankOrCommentLine() -> Bool {
 let savedPos = position
 let savedLine = line
 let savedCol = column

 while let char = currentChar, char == " " || char == "\t" {
 _ = advance()
 }

 if isAtEnd || currentChar == "\n" || currentChar == ";" || currentChar == "#" {
 skipToEndOfLine()
 if !isAtEnd && currentChar == "\n" {
 _ = advance()
 }
 return true
 }

 position = savedPos
 line = savedLine
 column = savedCol
 return false
 }

 private func nextToken() throws -> Token {
 guard let char = currentChar else {
 return .eof(currentLocation)
 }

 let loc = currentLocation

 switch char {
 case "\"":
 return try stringLiteral()
 case "0"..."9":
 return try numberLiteral()
 case "(":
 _ = advance()
 return .leftParen(loc)
 case ")":
 _ = advance()
 return .rightParen(loc)
 case "[":
 _ = advance()
 return .leftBracket(loc)
 case "]":
 _ = advance()
 return .rightBracket(loc)
 case "{":
 _ = advance()
 return .leftBrace(loc)
 case "}":
 _ = advance()
 return .rightBrace(loc)
 case ":":
 _ = advance()
 return .colon(loc)
 case ",":
 _ = advance()
 return .comma(loc)
 case "|":
 _ = advance()
 if match("|") { return .logicalOr(loc) }
 if match("=") { return .orAssign(loc) }
 return .pipe(loc)
 case ".":
 _ = advance()
 return .dot(loc)
 case "@":
 _ = advance()
 return .at(loc)
 case "`":
 // ADR-027 D1：反引号转义——`名称` 整体产出 IDENT token（跳过关键字
 // 分类），允许关键字作标识符/构造标签（自举探针 G-P5，用户提案）。
 // D2：未闭合（行尾/EOF）或空内容回退 ADR-021 兜底（单字符 IDENT），
 // 保持「词法器零错误」契约；L0 语料第 95 行的裸反引号即此兜底。
 _ = advance()
 var escaped = ""
 var closed = false
 while let c = currentChar {
 if c == "`" {
 _ = advance()
 closed = true
 break
 }
 if c == "\n" { break }
 escaped.append(c)
 _ = advance()
 }
 if closed && !escaped.isEmpty {
 return .identifier(escaped, loc)
 }
 return .identifier("`", loc)
 // `#` 已由行级注释拦截（G35：文档注释/退化行注释），不再产出 token；
 // 若意外到达此处则落入 default → invalidCharacter（历史 `.hash` token 保留于 Token.swift 供兼容）。
 case "?":
 _ = advance()
 return .questionMark(loc)
 case "+", "-", "*", "/", "%", "!", "~", "&", "^", "<", ">", "=":
 return try operatorToken(char)
 case "_":
 return try underscoreToken()
 default:
 if char.isLetter {
 return try identifierOrKeyword()
 }
 // ADR-021：宽松词法——未匹配任何词法类的字符产出单字符标识符，
 // 错误报告后移到解析/语义阶段（标识符落在不合适的位置被拒）。
 _ = advance()
 return .identifier(String(char), loc)
 }
 }

 private func operatorToken(_ head: Character) throws -> Token {
 let loc = currentLocation

 switch currentChar {
 case "+":
 _ = advance()
 if match("=") { return .plusAssign(loc) }
 if match("+") { return .increment(loc) }
 return .plus(loc)
 case "-":
 _ = advance()
 if match("=") { return .minusAssign(loc) }
 if match(">") { return .arrow(loc) }
 if match("-") { return .decrement(loc) }
 return .minus(loc)
 case "*":
 _ = advance()
 if match("=") { return .multiplyAssign(loc) }
 return .star(loc)
 case "/":
 _ = advance()
 if match("=") { return .divideAssign(loc) }
 return .slash(loc)
 case "%":
 _ = advance()
 if match("=") { return .moduloAssign(loc) }
 return .percent(loc)
 case "!":
 _ = advance()
 if match("=") { return .notEqual(loc) }
 return .logicalNot(loc)
 case "~":
 _ = advance()
 return .bitwiseNot(loc)
 case "&":
 _ = advance()
 if match("&") { return .logicalAnd(loc) }
 if match("=") { return .andAssign(loc) }
 return .bitwiseAnd(loc)
 case "^":
 _ = advance()
 if match("=") { return .xorAssign(loc) }
 return .bitwiseXor(loc)
 case "<":
 _ = advance()
 if match("<") {
 if match("=") { return .leftShiftAssign(loc) }
 return .leftShift(loc)
 }
 if match("=") { return .lessThanOrEqual(loc) }
 return .lessThan(loc)
 case ">":
 _ = advance()
 if match(">") {
 if match("=") { return .rightShiftAssign(loc) }
 return .rightShift(loc)
 }
 if match("=") { return .greaterThanOrEqual(loc) }
 return .greaterThan(loc)
 case "=":
 _ = advance()
 if match("=") { return .equal(loc) }
 if match(">") { return .doubleArrow(loc) }
 return .assign(loc)
 default:
 // ADR-021：宽松词法兜底（防御分支，现有 12 字符均有 case）
 return .identifier(String(head), loc)
 }
 }

 private func underscoreToken() throws -> Token {
 let loc = currentLocation
 // 先消费开头的 `_`，再以其为前缀续读，避免把 `_密钥` 误读成 `__密钥`
 // （readIdentifier 的循环会把起始字符再扫一遍，导致前导下划线被重复）。
 _ = advance()
 let name = readIdentifier(startingWith: "_")
 return makeIdentifierOrKeyword(name, loc)
 }

 private func identifierOrKeyword() throws -> Token {
 let loc = currentLocation
 let name = readIdentifier(startingWith: "")
 return makeIdentifierOrKeyword(name, loc)
 }

 private func readIdentifier(startingWith prefix: String) -> String {
 // ADR-019 D3：IDENT 续字符 = \p{L} ∪ numeric property ∪ `_`——spec 已按
 // numeric property（isNumber 语义，严格超集 \p{N}）放宽对齐本实现（见 spec「词法类」主题）；INT 字面量仍限 [0-9]。
 var name = prefix
 while let char = currentChar, char.isLetter || char.isNumber || char == "_" {
 name.append(char)
 _ = advance()
 }
 return name
 }

 private func makeIdentifierOrKeyword(_ name: String, _ loc: SourceLocation) -> Token {
 if let keyword = Keyword(rawValue: name) {
 return .keyword(keyword, loc)
 }
 if name == "true" {
 return .boolLiteral(true, loc)
 }
 if name == "false" {
 return .boolLiteral(false, loc)
 }
 return .identifier(name, loc)
 }

 private func numberLiteral() throws -> Token {
 let loc = currentLocation

 // 进制前缀：0x / 0b / 0o
 if let first = currentChar, first == "0", let second = peek(offset: 1) {
 switch second {
 case "x", "X":
 // ADR-021：前缀后无有效数字 → 只消费 '0' 产出 int 0，余下按标识符走
 // （注意检查的是「前缀字母 + 后随数字」，x 本身不是 hex 字符）
 _ = advance()
 if let d3 = currentChar, d3 == "x" || d3 == "X",
 let d4 = peek(offset: 1), "0123456789abcdefABCDEF".contains(d4) {
 _ = advance()
 let rest = readRadixDigits("0123456789abcdefABCDEF")
 if let value = Int(rest, radix: 16) {
 return .integerLiteral(value, loc)
 }
 }
 return .integerLiteral(0, loc)
 case "b":
 _ = advance()
 if let d3 = currentChar, d3 == "b", let d4 = peek(offset: 1), "01".contains(d4) {
 _ = advance()
 let rest = readRadixDigits("01")
 if let value = Int(rest, radix: 2) {
 return .integerLiteral(value, loc)
 }
 }
 return .integerLiteral(0, loc)
 case "o":
 _ = advance()
 if let d3 = currentChar, d3 == "o", let d4 = peek(offset: 1), "01234567".contains(d4) {
 _ = advance()
 let rest = readRadixDigits("01234567")
 if let value = Int(rest, radix: 8) {
 return .integerLiteral(value, loc)
 }
 }
 return .integerLiteral(0, loc)
 default:
 break
 }
 }

 var digits = ""
 while let char = currentChar, char.isNumber {
 digits.append(char)
 _ = advance()
 }

 var isFloat = false
 // 草稿 A2（批次 1）：`.` 后随数字 = 元组位置访问 `.index`（如 `t.0.1` 拆为 `.0` `.1`），
 // 数字只读整数部分、不进入浮点；其余位置（前 token 非 `.`）照常支持 `3.14` 浮点。
 if !prevTokenIsDot, let char = currentChar, char == ".", let next = peek(offset: 1), next.isNumber {
 isFloat = true
 digits.append(char)
 _ = advance()
 while let c = currentChar, c.isNumber {
 digits.append(c)
 _ = advance()
 }
 }

 // 科学计数法：e/E[+-]?digits——ADR-021：仅当指数位确有数字才消费，
 // 否则 e 留给标识符通道（如 `1e` → int 1 + identifier e）
 if let char = currentChar, char == "e" || char == "E" {
 var offset = 1
 var hasExpDigit = false
 if let sign = peek(offset: offset), sign == "+" || sign == "-" {
 offset += 1
 }
 if let d = peek(offset: offset), d.isNumber {
 hasExpDigit = true
 }
 if hasExpDigit {
 isFloat = true
 digits.append(char)
 _ = advance()
 if let sign = currentChar, sign == "+" || sign == "-" {
 digits.append(sign)
 _ = advance()
 }
 while let c = currentChar, c.isNumber {
 digits.append(c)
 _ = advance()
 }
 }
 }

 if isFloat {
 if let value = Double(digits) {
 return .floatLiteral(value, loc)
 }
 throw LexerError.invalidCharacter("Invalid float literal: \(digits)", loc)
 }

 if let value = Int(digits) {
 return .integerLiteral(value, loc)
 }
 throw LexerError.invalidCharacter("Invalid integer literal: \(digits)", loc)
 }

 private func readRadixDigits(_ allowed: String) -> String {
 var s = ""
 while let char = currentChar, allowed.contains(String(char)) {
 s.append(char)
 _ = advance()
 }
 return s
 }

 private func stringLiteral() throws -> Token {
 let loc = currentLocation
 _ = advance()

 var segments: [StringSegment] = []
 var literal = ""

 func flushLiteral() {
 if !literal.isEmpty {
 segments.append(.literal(literal))
 literal = ""
 }
 }

 while let char = currentChar, char != "\"" {
 if char == "\n" {
 // ADR-021：宽松词法——字符串在行尾隐式终止（换行不消费，
 // 版面处理照常），不再抛 unterminatedString
 break
 }
 if char == "\\" {
 _ = advance()
 guard let esc = currentChar else {
 throw LexerError.unterminatedString(loc)
 }
 if esc == "(" {
 flushLiteral()
 let exprSource = try scanInterpolationExpression()
 segments.append(.expression(exprSource))
 } else {
 switch esc {
 case "n": literal.append("\n")
 case "t": literal.append("\t")
 case "r": literal.append("\r")
 case "0": literal.append("\0")
 case "\\": literal.append("\\")
 case "\"": literal.append("\"")
 default:
 // ADR-021：非法转义原样保留（反斜杠 + 字符），不报错
 literal.append("\\")
 literal.append(esc)
 }
 _ = advance()
 }
 } else {
 literal.append(char)
 _ = advance()
 }
 }

 if currentChar == "\"" {
 _ = advance()
 }

 flushLiteral()

 // 无插值段时仍发 .stringLiteral，保持向后兼容（不破坏现有测试）
 if segments.count == 1, case .literal(let s) = segments[0] {
 return .stringLiteral(s, loc)
 }
 return .interpolatedString(segments: segments, loc)
 }

 /// 扫描 `\(` 之后的插值表达式源码，直到匹配的 `)` 结束。
 /// 表达式内可含嵌套 `()[]{}` 与字符串字面量；MVP 不支持插值内再嵌套 `\(`。
 private func scanInterpolationExpression() throws -> String {
 // 进入时 currentChar 为 '('（即 '\' 之后的 '('）
 _ = advance()
 var depth = 1
 var text = ""
 while let char = currentChar {
 if char == "\"" {
 text.append(char)
 _ = advance()
 while let c = currentChar, c != "\"" {
 if c == "\\" {
 text.append(c)
 _ = advance()
 if let n = currentChar {
 text.append(n)
 _ = advance()
 } else {
 throw LexerError.unterminatedString(currentLocation)
 }
 } else {
 text.append(c)
 _ = advance()
 }
 }
 if currentChar == "\"" {
 text.append("\"")
 _ = advance()
 }
 continue
 }
 if char == "(" {
 depth += 1
 text.append(char)
 _ = advance()
 continue
 }
 if char == ")" {
 depth -= 1
 if depth == 0 {
 _ = advance()
 return text
 }
 text.append(char)
 _ = advance()
 continue
 }
 if char == "[" || char == "{" || char == "]" || char == "}" {
 text.append(char)
 _ = advance()
 continue
 }
 if char == "\n" {
 throw LexerError.unterminatedString(currentLocation)
 }
 text.append(char)
 _ = advance()
 }
 throw LexerError.unterminatedString(currentLocation)
 }
}
