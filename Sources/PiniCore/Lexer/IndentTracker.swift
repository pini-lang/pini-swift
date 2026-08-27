public struct IndentTracker {
 private var stack: [Int] = [0]

 public init() {}

 public mutating func processLineStart(whitespaceCount: Int, location: SourceLocation) throws -> [Token] {
 let current = currentIndent()

 if whitespaceCount > current {
 stack.append(whitespaceCount)
 return [.indent(location)]
 } else if whitespaceCount < current {
 var tokens: [Token] = []
 while currentIndent() > whitespaceCount {
 stack.removeLast()
 tokens.append(.dedent(location))
 }
 if currentIndent() != whitespaceCount {
 throw LexerError.indentationError(location)
 }
 return tokens
 } else {
 return []
 }
 }

 public mutating func finalize(location: SourceLocation) -> [Token] {
 var tokens: [Token] = []
 while stack.count > 1 {
 stack.removeLast()
 tokens.append(.dedent(location))
 }
 return tokens
 }

 public func currentIndent() -> Int {
 return stack.last ?? 0
 }
}
