import Foundation
import PiniCore

/// P7-1 REPL：增量解析 + 声明累积 + 表达式求值 + 续行检测。
///
/// 核心设计（对标 GHCi / evcxr 的模式）：
/// 1. **声明累积**——func/struct/object/enum/trait/import 声明追加到 `accumulatedDeclarations`
/// 2. **表达式求值**——非声明输入包装为 `_repl_main() { print(<expr>) }` 临时函数
/// 3. **续行检测**——检测未闭合的括号、INDENT 续行（`:` 结尾）、反斜杠续行
/// 4. **错误恢复**——解析/类型/运行时错误打印并回 loop，不退出
/// 5. **特殊命令**——`:quit` / `:help` / `:clear`
///
/// 每次求值时创建 fresh Interpreter 并 `registerDecls` 所有累积声明 +
/// 合成 main 函数——虽然每次都重新注册，但对 REPL 规模的声明（< 100 条）瞬时完成。
final class ReplSession {
 private var accumulatedDeclarations: [TopLevelDecl] = []

 /// 续行提示符。
 private static let promptMain = ">> "
 private static let promptCont = "... "

 // MARK: - 入口

 func run() {
 print("Pini REPL (P7-1). 输入表达式或声明；:help 查看帮助，:quit 退出。")
 var linesBuffer: [String] = []

 while true {
 let prompt = linesBuffer.isEmpty ? Self.promptMain : Self.promptCont
 print(prompt, terminator: "")
 fflush(stdout)

 guard let line = readLine() else { print(); break } // ctrl+d → exit

 // 空行：若已有累积缓冲 → 提交；否则忽略
 let trimmed = line.trimmingCharacters(in: .whitespaces)
 if trimmed.isEmpty {
 if linesBuffer.isEmpty { continue }
 // 空行结束多行输入
 try? evaluate(linesBuffer)
 linesBuffer.removeAll()
 continue
 }

 // 特殊命令（仅在缓冲为空时生效）
 if linesBuffer.isEmpty {
 if trimmed.hasPrefix(":") {
 if handleSpecialCommand(trimmed) { return } // :quit
 continue
 }
 // 整行注释忽略
 if trimmed.hasPrefix(";") { continue }
 }

 linesBuffer.append(line)

 // 续行检测
 if needsContinuation(accumulated: linesBuffer) { continue }

 // 提交
 do {
 try evaluate(linesBuffer)
 } catch {
 print("错误: \(error.localizedDescription)")
 }
 linesBuffer.removeAll()
 }
 }

 // MARK: - 求值

 private func evaluate(_ lines: [String]) throws {
 let source = lines.joined(separator: "\n")
 let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

 // 检测表达式模式：不以声明关键字开头 → wrap 为 main + print
 if isExpressionInput(trimmed) {
 let body: String
 if trimmed.hasPrefix("print(") || trimmed.hasPrefix("print ") {
 // 已经是 print 调用 → 直接放入（避免 print(print(...)) 的双层 null）
 body = trimmed
 } else {
 body = "print(\(trimmed))"
 }
 let wrapped = "main|func() -> ()\n \(body)\n return\n"
 let exprModule = try parseReplSource(wrapped)
 let runModule = Module(
 declarations: accumulatedDeclarations + exprModule.declarations,
 imports: [], exports: [],
 location: SourceLocation(line: 0, column: 0, fileName: "<repl>")
 )
 let interpreter = Interpreter()
 try interpreter.run(module: runModule)
 return
 }

 // 声明模式：追加到累积列表，只注册声明不执行 main
 let module = try parseReplSource(source)
 for decl in module.declarations {
 accumulatedDeclarations.append(decl)
 }
 let interpreter = Interpreter()
 let runModule = Module(
 declarations: accumulatedDeclarations,
 imports: [], exports: [],
 location: SourceLocation(line: 0, column: 0, fileName: "<repl>")
 )
 // 声明路径可能没有 main 函数 — 吞掉 mainNotFound（正常），其他错误上报
 do {
 try interpreter.run(module: runModule)
 } catch let error as RuntimeError {
 // mainNotFound 在声明模式正常，其他错误仍上报
 if case .mainNotFound = error { /* ok */ }
 else { throw error }
 }
 }

 /// 判断输入是否为表达式（非声明）。
 /// 以声明关键字/符号开头 → 否；否则 → 是。
 private let declarationStarters: Set<String> = [
 "{", "object", "enum", "trait", "func",
 "let", "var", "import", "export",
 ]

 private func isExpressionInput(_ trimmed: String) -> Bool {
 for starter in declarationStarters {
 if trimmed.hasPrefix(starter) { return false }
 }
 return !trimmed.isEmpty
 }

 // MARK: - 解析

 private func parseReplSource(_ source: String) throws -> Module {
 let lexer = Lexer(source: source, fileName: "<repl>")
 let tokens = try lexer.tokenize()
 let parser = Parser(tokens: tokens, fileName: "<repl>")
 let result = parser.parseModuleCollectingErrors()
 if !result.errors.isEmpty {
 throw ReplError.parseError(
 result.errors.map { ErrorFormatter.formatParserError($0, source: source) }.joined(separator: "\n")
 )
 }
 return result.module
 }

 // MARK: - 续行检测

 /// 判断当前累积行是否需要继续读取。
 ///
 /// 规则：
 /// 1. 括号未闭合 `() [] {} <>`
 /// 2. INDENT 块：累积行中存在 `:` 结尾的非注释行，且最后一行有缩进（或空行）
 /// 3. 反斜杠续行
 ///
 /// INDENT 规则的对标：Python REPL 的 `>>>` → `...` 切换基于 `compile(..., 'single')`。
 /// Pini 没有 compile('single') 模式，故用缩进检测近似——`:` 语句后只要下一行有缩进
 /// 就继续累积，直到遇到无缩进的非空行。
 private func needsContinuation(accumulated lines: [String]) -> Bool {
 guard let last = lines.last else { return false }
 let trimmed = last.trimmingCharacters(in: .whitespaces)
 if trimmed.isEmpty {
 // 空行：如果已有 INDENT 块且 next would be more → could go either way
 // 保守策略：空行不改变续行状态，回退到 INDENT 块检测
 }

 // 反斜杠续行
 if trimmed.hasSuffix("\\") { return true }

 // 括号平衡检测
 var parens = 0
 for line in lines {
 for ch in line {
 switch ch {
 case "(", "[", "{", "<": parens += 1
 case ")", "]", "}", ">": parens -= 1
 default: break
 }
 }
 }
 if parens != 0 { return true }

 // INDENT 块检测：找到最后一个 `:` 结尾的非注释行
 var colonLineIdx: Int? = nil
 for (i, line) in lines.enumerated().reversed() {
 let code = stripComment(line.trimmingCharacters(in: .whitespaces))
 if code.hasSuffix(":") && !code.isEmpty {
 colonLineIdx = i
 break
 }
 }

 guard let colonIdx = colonLineIdx else { return false }

 // `:` 之后的行必须缩进才算续行
 // DEBUG
 var allIndented = true
 for i in (colonIdx + 1) ..< lines.count {
 let line = lines[i]
 if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
 if line.first?.isWhitespace == true { continue }
 allIndented = false
 break
 }
 if !allIndented { return false }
 // DEBUG
 return true
 }

 /// 剥离行尾 `;` 注释。
 private func stripComment(_ line: String) -> String {
 // 简单规则：找第一个不在字符串内的 `;`
 var inString = false
 var stringChar: Character? = nil
 for (i, ch) in line.enumerated() {
 if inString {
 if ch == stringChar { inString = false; stringChar = nil }
 } else if ch == "\"" || ch == "'" {
 inString = true; stringChar = ch
 } else if ch == ";" {
 return String(line.prefix(i))
 }
 }
 return line
 }

 // MARK: - 特殊命令

 /// 返回 true 表示退出 REPL。
 private func handleSpecialCommand(_ input: String) -> Bool {
 let cmd = input.dropFirst().lowercased() // 去掉 `:`
 switch cmd {
 case "q", "quit", "exit":
 print("Goodbye.")
 return true
 case "h", "help":
 print("""
 Pini REPL 特殊命令：
 :quit, :q 退出 REPL
 :help, :h 打印此帮助
 :clear 清除累积的声明（重置会话）

 支持多行输入——括号未闭合或 `:` 结尾时自动续行。
 空行（或 ctrl+d）结束多行输入并提交。

 声明类型（func/struct/object/enum/trait）会累积到会话中。
 """)
 case "clear":
 accumulatedDeclarations.removeAll()
 print("会话已重置：累积的声明已清除。")
 default:
 print("未知命令：\(input)。输入 :help 查看帮助。")
 }
 return false
 }
}

// MARK: - 错误类型

enum ReplError: LocalizedError {
 case parseError(String)
 var errorDescription: String? {
 switch self {
 case .parseError(let msg): return "解析错误:\n\(msg)"
 }
 }
}
