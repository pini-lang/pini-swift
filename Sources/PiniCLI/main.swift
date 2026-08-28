import Foundation
import PiniCore

// MARK: - Token Description

func describeToken(_ token: Token) -> String {
 let loc = token.location
 return "\(loc.line):\(loc.column) \(token.typeName) \(token.lexeme)"
}

// MARK: - AST Description

func describeTypeAnnotation(_ type: TypeAnnotation, indent: String = "") -> String {
 switch type {
 case .simple(let name, _):
 return name
 case .tuple(let labels, let elements, _):
 let elementStrs = elements.enumerated().map { i, t in
 if labels.indices.contains(i), let l = labels[i] {
 return "\(l): " + describeTypeAnnotation(t, indent: indent)
 }
 return describeTypeAnnotation(t, indent: indent)
 }
 return "(" + elementStrs.joined(separator: ", ") + ")"
 case .generic(let name, let params, _):
 let paramStrs = params.map { describeTypeAnnotation($0, indent: indent) }
 return "\(name)<" + paramStrs.joined(separator: ", ") + ">"
 case .function(let params, let returns, _, _):
 let paramStrs = params.map { describeTypeAnnotation($0, indent: indent) }
 let returnStrs = returns.map { describeTypeAnnotation($0, indent: indent) }
 let returnStr = returnStrs.count == 1 ? returnStrs[0] : "(" + returnStrs.joined(separator: ", ") + ")"
 return "(" + paramStrs.joined(separator: ", ") + ") -> " + returnStr
 case .pointer(let element, _):
 return "*" + describeTypeAnnotation(element, indent: indent)
 }
}

func describeExpression(_ expr: PiniCore.Expression, indent: String = "") -> String {
 switch expr {
 case .identifier(let name, _):
 return "\(indent)identifier: \(name)"
 case .integerLiteral(let value, _):
 return "\(indent)int: \(value)"
 case .floatLiteral(let value, _):
 return "\(indent)float: \(value)"
 case .stringLiteral(let value, _):
 return "\(indent)string: \"\(value)\""
 case .stringInterpolation(let segments, _):
 var result = "\(indent)stringInterpolation:\n"
 for (i, seg) in segments.enumerated() {
 switch seg {
 case .literal(let s):
 result += "\(indent) [\(i)] literal: \"\(s)\"\n"
 case .expression(let e):
 result += describeExpression(e, indent: indent + " [\(i)] ")
 }
 }
 return result
 case .boolLiteral(let value, _):
 return "\(indent)bool: \(value)"
 case .binary(let left, let op, let right, _):
 var result = "\(indent)binary:\n"
 result += "\(indent) op: \(op)\n"
 result += "\(indent) left:\n"
 result += describeExpression(left, indent: indent + " ") + "\n"
 result += "\(indent) right:\n"
 result += describeExpression(right, indent: indent + " ")
 return result
 case .unary(let op, let operand, _):
 var result = "\(indent)unary:\n"
 result += "\(indent) op: \(op)\n"
 result += "\(indent) operand:\n"
 result += describeExpression(operand, indent: indent + " ")
 return result
 case .call(let callee, let arguments, _):
 var result = "\(indent)call:\n"
 result += "\(indent) callee:\n"
 result += describeExpression(callee, indent: indent + " ") + "\n"
 result += "\(indent) args:"
 if arguments.isEmpty {
 result += " (none)"
 } else {
 result += "\n"
 for arg in arguments {
 if let label = arg.label {
 result += "\(indent) \(label):\n"
 result += describeExpression(arg.expression, indent: indent + " ") + "\n"
 } else {
 result += describeExpression(arg.expression, indent: indent + " ") + "\n"
 }
 }
 result = String(result.dropLast())
 }
 return result
 case .member(let object, let name, _):
 var result = "\(indent)member:\n"
 result += "\(indent) object:\n"
 result += describeExpression(object, indent: indent + " ") + "\n"
 result += "\(indent) name: \(name)"
 return result
 case .tupleIndex(let object, let index, _):
 var result = "\(indent)tupleIndex:\n"
 result += "\(indent) object:\n"
 result += describeExpression(object, indent: indent + " ") + "\n"
 result += "\(indent) index: \(index)"
 return result
 case .tuple(_, let elements, _):
 var result = "\(indent)tuple:"
 if elements.isEmpty {
 result += " (empty)"
 } else {
 result += "\n"
 for elem in elements {
 result += describeExpression(elem, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 }
 return result
 case .funcLiteral(let decl, _):
 var result = "\(indent)funcLiteral:\n"
 result += "\(indent) params: \(decl.params.map { $0.name })\n"
 if !decl.returnTypes.isEmpty {
 result += "\(indent) returnTypes: \(decl.returnTypes.map { String(describing: $0) })\n"
 }
 if let body = decl.body {
 result += "\(indent) body:\n"
 for stmt in body.statements {
 result += describeStatement(stmt, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 }
 return result
 case .join(let inner, _):
 return "\(indent)join(await/wait):\n" + describeExpression(inner, indent: indent + " ")
 case .resultUnwrap(let operand, _):
 // 草稿 A2（批次 1.4，D2）：`^` 右值糖描述。
 return "\(indent)resultUnwrap(^):\n" + describeExpression(operand, indent: indent + " ")
 case .selfKeyword:
 return "\(indent)self"
 case .selfTypeKeyword:
 return "\(indent)Self"
 case .arrayLiteral(let elements, _):
 var result = "\(indent)array:"
 if elements.isEmpty {
 result += " (empty)"
 } else {
 result += "\n"
 for elem in elements {
 result += describeExpression(elem, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 }
 return result
 case .dictionaryLiteral(let entries, _):
 var result = "\(indent)dictionary:"
 if entries.isEmpty {
 result += " (empty)"
 } else {
 result += "\n"
 for entry in entries {
 result += "\(indent) key:\n" + describeExpression(entry.key, indent: indent + " ") + "\n"
 result += "\(indent) value:\n" + describeExpression(entry.value, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 }
 return result
 case .setLiteral(let elements, _):
 var result = "\(indent)set:"
 if elements.isEmpty {
 result += " (empty)"
 } else {
 result += "\n"
 for elem in elements {
 result += describeExpression(elem, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 }
 return result
 case .subscript(let container, let index, _):
 var result = "\(indent)subscript:\n"
 result += "\(indent) container:\n" + describeExpression(container, indent: indent + " ") + "\n"
 result += "\(indent) index:\n" + describeExpression(index, indent: indent + " ")
 return result
 case .genericConstruct(let typeName, let typeArgs, let arguments, _):
 var result = "\(indent)genericConstruct:\n"
 result += "\(indent) type: \(typeName)"
 if !typeArgs.isEmpty {
 result += "<"
 let parts = typeArgs.map { describeTypeAnnotation($0) }
 result += parts.joined(separator: ", ")
 result += ">"
 }
 result += "\n\(indent) args:"
 if arguments.isEmpty {
 result += " (none)"
 } else {
 result += "\n"
 for arg in arguments {
 if let label = arg.label {
 result += "\(indent) \(label):\n"
 result += describeExpression(arg.expression, indent: indent + " ") + "\n"
 } else {
 result += describeExpression(arg.expression, indent: indent + " ") + "\n"
 }
 }
 result = String(result.dropLast())
 }
 return result
 case .unsafe(let operand, _):
 return "\(indent)unsafe:\n" + describeExpression(operand, indent: indent + " ")
 case .addressOf(let operand, _):
 return "\(indent)addressOf(&):\n" + describeExpression(operand, indent: indent + " ")
 }
}

func describeStatement(_ stmt: Statement, indent: String = "") -> String {
 switch stmt {
 case .varDecl(let name, let typeAnnotation, let initializer, let isMutable, _):
 var result = "\(indent)varDecl:\n"
 result += "\(indent) name: \(name)\n"
 result += "\(indent) mutable: \(isMutable)"
 if let type = typeAnnotation {
 result += "\n\(indent) type: \(describeTypeAnnotation(type))"
 }
 if let initExpr = initializer {
 result += "\n\(indent) initializer:\n"
 result += describeExpression(initExpr, indent: indent + " ")
 }
 return result
 case .varDestructure(let names, let typeAnnotation, let initializer, let isMutable, _):
 // 草稿 A1（批次 1）：解构声明描述。
 var result = "\(indent)varDestructure:\n"
 result += "\(indent) names: \(names.joined(separator: ", "))\n"
 result += "\(indent) mutable: \(isMutable)"
 if let type = typeAnnotation {
 result += "\n\(indent) type: \(describeTypeAnnotation(type))"
 }
 if let initExpr = initializer {
 result += "\n\(indent) initializer:\n"
 result += describeExpression(initExpr, indent: indent + " ")
 }
 return result
 case .assign(let target, let value, _):
 var result = "\(indent)assign:\n"
 result += "\(indent) target: "
 switch target {
 case .identifier(let name):
 result += "\(name)\n"
 case .member(let obj, let name):
 result += "member\n"
 result += describeExpression(obj, indent: indent + " ") + "\n"
 result += "\(indent) member: \(name)\n"
 case .subscript(let containerExpr, let indexExpr):
 result += "subscript\n"
 result += describeExpression(containerExpr, indent: indent + " ") + "\n"
 result += "\(indent) index:\n"
 result += describeExpression(indexExpr, indent: indent + " ")
 }
 result += "\(indent) value:\n"
 result += describeExpression(value, indent: indent + " ")
 return result
 case .returnStatement(let value, _):
 var result = "\(indent)return"
 if let val = value {
 result += ":\n"
 result += describeExpression(val, indent: indent + " ")
 }
 return result
 case .breakStatement(let label, _):
 if let l = label {
 return "\(indent)break: \(l)"
 }
 return "\(indent)break"
 case .continueStatement(let label, _):
 if let l = label {
 return "\(indent)continue: \(l)"
 }
 return "\(indent)continue"
 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
 var result = "\(indent)if:\n"
 result += "\(indent) condition:\n"
 result += describeExpression(condition, indent: indent + " ") + "\n"
 result += "\(indent) then:\n"
 for s in thenBlock.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 for elif in elifs {
 result += "\(indent) elif:\n"
 result += "\(indent) condition:\n"
 result += describeExpression(elif.condition, indent: indent + " ") + "\n"
 result += "\(indent) then:\n"
 for s in elif.block.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 }
 if let els = elseBlock {
 result += "\(indent) else:\n"
 for s in els.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 }
 return String(result.dropLast())
 case .whileStatement(let condition, let body, _, let label, _):
 var result = "\(indent)while"
 if let l = label {
 result += " (\(l))"
 }
 result += ":\n"
 result += "\(indent) condition:\n"
 result += describeExpression(condition, indent: indent + " ") + "\n"
 result += "\(indent) body:\n"
 for s in body.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 return String(result.dropLast())
 case .forStatement(let pattern, let iterable, let body, let step, let label, _):
 var result = "\(indent)for (\(pattern.joined(separator: ", ")))"
 if let l = label {
 result += " (@\(l))"
 }
 result += ":\n"
 result += "\(indent) iterable:\n"
 result += describeExpression(iterable, indent: indent + " ") + "\n"
 result += "\(indent) body:\n"
 for s in body.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 if let step = step {
 result += "\(indent) step:\n"
 for s in step.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 }
 return String(result.dropLast())
 case .matchStatement(let value, let cases, _):
 var result = "\(indent)match:\n"
 result += "\(indent) value:\n"
 result += describeExpression(value, indent: indent + " ") + "\n"
 for c in cases {
 result += "\(indent) case \(c.pattern)"
 if !c.bindings.isEmpty {
 let bindingStrs = c.bindings.map { b in
 if let paramName = b.paramName {
 return "\(paramName): \(b.varName)"
 } else {
 return b.varName
 }
 }
 result += "(\(bindingStrs.joined(separator: ", ")))"
 }
 result += ":\n"
 for s in c.block.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 }
 // D3①：`case _:` 通配已作为 case 进入 cases（case 列表覆盖），无独立 default/wildcard 块。
 return String(result.dropLast())
 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 var result = "\(indent)try:\n"
 result += "\(indent) expr:\n"
 result += describeExpression(expression, indent: indent + " ") + "\n"
 result += "\(indent) tryBlock:\n"
 for s in tryBlock.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 for exc in exceptClauses {
 result += "\(indent) except \(exc.errorVar):\n"
 for s in exc.body.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 }
 return String(result.dropLast())
 case .expressionStmt(let expr, _):
 return "\(indent)exprStmt:\n" + describeExpression(expr, indent: indent + " ")
 case .detachStatement(let expr, _):
 return "\(indent)detach:\n" + describeExpression(expr, indent: indent + " ")
 case .deferStatement(let statement, _):
 var result = "\(indent)defer:\n"
 result += describeStatement(statement, indent: indent + " ")
 return result
 case .scopedBlock(let label, let body, _):
 var result = "\(indent)scopedBlock"
 if let l = label {
 result += " (\(l))"
 }
 result += ":\n"
 result += "\(indent) body:\n"
 for s in body.statements {
 result += describeStatement(s, indent: indent + " ") + "\n"
 }
 return String(result.dropLast())
 case .passStatement(_):
 return "\(indent)pass"
 }
}

func describeFuncDecl(_ funcDecl: FuncDecl, indent: String = "") -> String {
 var result = "\(indent)func \(funcDecl.name)"
 
 if !funcDecl.genericParams.isEmpty {
 result += "<" + funcDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
 }
 
 result += "("
 result += funcDecl.params.map { p in
 if let type = p.typeAnnotation {
 return "\(p.name): \(describeTypeAnnotation(type))"
 }
 return p.name
 }.joined(separator: ", ")
 result += ")"
 
 if !funcDecl.returnTypes.isEmpty {
 let returns = funcDecl.returnTypes.map { describeTypeAnnotation($0) }
 result += " -> " + (returns.count == 1 ? returns[0] : "(" + returns.joined(separator: ", ") + ")")
 }
 
 if !funcDecl.modifiers.isEmpty {
 result += " [\(funcDecl.modifiers.joined(separator: ", "))]"
 }
 
 if let body = funcDecl.body {
 result += ":\n"
 for stmt in body.statements {
 result += describeStatement(stmt, indent: indent + " ") + "\n"
 }
 result = String(result.dropLast())
 } else {
 result += " (no body)"
 }
 
 return result
}

func describeFieldDecl(_ field: FieldDecl, indent: String = "") -> String {
 return "\(indent)field \(field.name): \(describeTypeAnnotation(field.typeAnnotation))"
}

func describeStructDecl(_ structDecl: StructDecl, indent: String = "") -> String {
 var result = "\(indent)struct \(structDecl.name)"

 if let composed = structDecl.composedType {
 result += " embeds \(composed)"
 }

 if !structDecl.genericParams.isEmpty {
 result += "<" + structDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
 }

 result += ":\n"
 
 for field in structDecl.fields {
 result += describeFieldDecl(field, indent: indent + " ") + "\n"
 }
 
 for method in structDecl.methods {
 result += describeFuncDecl(method, indent: indent + " ") + "\n"
 }
 
 return String(result.dropLast())
}

func describeObjectDecl(_ objectDecl: ObjectDecl, indent: String = "") -> String {
 var result = "\(indent)object \(objectDecl.name)"
 
 if !objectDecl.genericParams.isEmpty {
 result += "<" + objectDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
 }
 
 result += ":\n"
 
 for field in objectDecl.fields {
 result += describeFieldDecl(field, indent: indent + " ") + "\n"
 }
 
 for method in objectDecl.methods {
 result += describeFuncDecl(method, indent: indent + " ") + "\n"
 }
 
 return String(result.dropLast())
}

func describeEnumDecl(_ enumDecl: EnumDecl, indent: String = "") -> String {
 var result = "\(indent)enum \(enumDecl.name)"
 
 if !enumDecl.genericParams.isEmpty {
 result += "<" + enumDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
 }
 
 result += ":\n"
 
 for c in enumDecl.cases {
 result += "\(indent) case \(c.name)"
 if !c.associatedParams.isEmpty {
 let paramStrs = c.associatedParams.map { ap in
 if let name = ap.name {
 return "\(name): \(describeTypeAnnotation(ap.type))"
 } else {
 return describeTypeAnnotation(ap.type)
 }
 }
 result += "(" + paramStrs.joined(separator: ", ") + ")"
 }
 result += "\n"
 }
 
 for method in enumDecl.methods {
 result += describeFuncDecl(method, indent: indent + " ") + "\n"
 }
 
 return String(result.dropLast())
}

func describeTraitDecl(_ traitDecl: TraitDecl, indent: String = "") -> String {
 var result = "\(indent)trait \(traitDecl.name)"
 
 if !traitDecl.genericParams.isEmpty {
 result += "<" + traitDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
 }
 
 result += ":\n"
 
 for sig in traitDecl.signatures {
 result += describeFuncDecl(sig, indent: indent + " ") + "\n"
 }
 
 return String(result.dropLast())
}

func describeTopLevelDecl(_ decl: TopLevelDecl, indent: String = "") -> String {
 switch decl {
 case .structDecl(let structDecl):
 return describeStructDecl(structDecl, indent: indent)
 case .objectDecl(let objectDecl):
 return describeObjectDecl(objectDecl, indent: indent)
 case .enumDecl(let enumDecl):
 return describeEnumDecl(enumDecl, indent: indent)
 case .funcDecl(let funcDecl):
 return describeFuncDecl(funcDecl, indent: indent)
 case .traitDecl(let traitDecl):
 return describeTraitDecl(traitDecl, indent: indent)
 case .varDecl(let stmt):
 return describeStatement(stmt, indent: indent)
 case .statement(let stmt):
 return describeStatement(stmt, indent: indent)
 case .importDecl(let importDecl):
 return "\(indent)import \(importDecl.moduleName)"
 case .exportDecl(let exportDecl):
 return "\(indent)export \(exportDecl.symbolName)"
 case .extensionDecl(let ext):
 var result = "\(indent)extension \(ext.targetType):\n"
 for m in ext.methods {
 result += describeFuncDecl(m, indent: indent + " ") + "\n"
 }
 return String(result.dropLast())
 case .foreignDecl(let fd):
 var result = "\(indent)foreign \(fd.name):\n"
 for f in fd.funcs {
 result += describeFuncDecl(f, indent: indent + " ") + "\n"
 }
 return String(result.dropLast())
 }
}

func describeAST(_ module: Module) -> String {
 var result = "Module:\n"
 for decl in module.declarations {
 result += describeTopLevelDecl(decl, indent: " ") + "\n"
 }
 return String(result.dropLast())
}

// MARK: - CLI Commands

func printHelp() {
 print("Pini - A programming language")
 print("")
 print("Usage: pini <command> [arguments]")
 print("")
 print("Commands:")
 print(" run <path> Run a Pini program (single .pini file or a directory/module)")
 print(" check <path> Type check a Pini program (file or directory/module)")
 print(" build <path> Type check (alias of check) a file or directory/module")
 print(" test [path] Collect and run |test blocks; no path = whole module, file/dir narrows scope (G41/G49; assert-based)")
 print(" parse <file.pini> Parse and print the AST")
 print(" tokens <file.pini> Print tokens from lexical analysis")
 print(" emit <file.pini> Emit LLVM IR (.ll) to stdout or -o file")
 print(" compile <file.pini> Compile via clang and run (needs LLVM; set PINI_LLVM_BIN if not on PATH)")
 print(" run-llvm <file.pini> Run via LLVM JIT (lli) (needs LLVM; set PINI_LLVM_BIN if not on PATH)")
 print(" (LLVM backend requires clang/lli on PATH or PINI_LLVM_BIN. For interpreter-only execution, use 'run'.)")
 print(" lsp Start LSP server (Language Server Protocol)")
 print(" debug <path> Source-level debugger (single .pini file or a directory/module)")
 print(" dap <path> DAP debug adapter for VS Code (single .pini file or a directory/module)")
 print(" repl Start interactive REPL session")
 print(" help Print this help message")
 print(" version Print version information")
 print("")
 print("Directory / module mode:")
 print(" A directory containing pini.toml is treated as one multi-file module.")
 print(" A directory without pini.toml is checked file-by-file as independent programs.")
}

func printVersion() {
 // CLI 版本号对齐 spec 版本语义（历史曾滞后于 spec minor）。
 print("Pini 0.48.4")
}

func readFile(_ path: String) throws -> String {
 let url = URL(fileURLWithPath: path)
 return try String(contentsOf: url, encoding: .utf8)
}

/// P2-4.3：以收集模式解析；若有解析错误，格式化全部诊断并退出（不再『遇错即抛』只报第一个）。
/// 仅在无任何解析错误时返回成功解析的 module。词法错误仍按原有方式渲染并退出。
func parseOrReport(source: String, fileName: String) -> Module {
 let lexer = Lexer(source: source, fileName: fileName)
 let tokens: [Token]
 do {
 tokens = try lexer.tokenize()
 } catch {
 printError(formatCLIError(error: error, source: source))
 exit(1)
 }
 let parser = Parser(tokens: tokens, fileName: fileName)
 let result = parser.parseModuleCollectingErrors()
 if !result.errors.isEmpty {
 for error in result.errors {
 FileHandle.standardError.write(Data((ErrorFormatter.formatParserError(error, source: source) + "\n").utf8))
 }
 exit(1)
 }
 return ConstantFolder.foldConstants(in: result.module)
}

func runTokensCommand(source: String, fileName: String) throws {
 let lexer = Lexer(source: source, fileName: fileName)
 let tokens = try lexer.tokenize()
 
 for token in tokens {
 print(describeToken(token))
 }
}

func runParseCommand(source: String, fileName: String) throws {
 let module = parseOrReport(source: source, fileName: fileName)
 print(describeAST(module))
}

/// P4 Phase 5：run 接收文件或目录。
/// - 文件 → 单文件运行（零回归）。
/// - 目录含 `pini.toml` → 多文件模块运行（跨文件运行时链接，Phase 4）。
/// - 目录无 `pini.toml` → 无法定位单一入口，报错（运行一组独立程序无意义）。
func runRunPath(_ path: String) {
 var isDir: ObjCBool = false
 guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
 printError("Error: 路径不存在：\(path)"); exit(1)
 }

 if !isDir.boolValue {
 let source: String
 do { source = try readFile(path) } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 let module = parseOrReport(source: source, fileName: path)
 let interpreter = Interpreter()
 do { try interpreter.run(module: module) }
 catch { printError(formatCLIError(error: error, source: source)); exit(1) }
 return
 }

 // 目录
 let manifest: ModuleManifest?
 do { manifest = try FileLoader.loadManifest(directory: path) } catch {
 printError(formatCLIError(error: error, source: nil)); exit(1)
 }
 guard let manifest = manifest else {
 printError("Error: 目录 '\(path)' 不含 pini.toml，无法作为多文件模块运行。请运行单个 .pini 文件，或在该目录添加 pini.toml。")
 exit(1)
 }
 let pkg: Package
 do { pkg = try FileLoader.loadDirectory(path: path, manifest: manifest) } catch {
 printError(formatCLIError(error: error, source: nil)); exit(1)
 }
 // 与 runCheckPath 模块分支对齐：run 前先执行语义 + 类型层可见性 enforce，
 // 避免 `pini run` 绕过 4 级访问控制（P4 复审 HIGH：模块 run 路径此前不 enforce）。
 do {
 let analyzer = SemanticAnalyzer()
 try analyzer.analyze(package: pkg)
 let checker = TypeChecker()
 try checker.check(package: pkg)
 } catch {
 printError(formatCLIError(error: error, source: nil)); exit(1)
 }
 let interpreter = Interpreter(ffiConfig: manifest.ffi ?? .default)
 do { try interpreter.run(package: pkg) }
 catch { printError(formatCLIError(error: error, source: nil)); exit(1) }
}

// MARK: - 调试器（P7-4）

/// 从 stdin 读取命令的调试驱动。
struct CLIDebugDriver: DebugDriver {
 func nextCommand(_ event: StopEvent) -> DebugCommand {
 while true {
 print("debug> ", terminator: "")
 guard let line = readLine() else {
 return .quit // EOF：结束调试会话
 }
 let trimmed = line.trimmingCharacters(in: .whitespaces)
 if trimmed.isEmpty { continue }
 let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
 let cmd = parts[0].lowercased()
 let arg = parts.count > 1 ? parts[1] : ""
 switch cmd {
 case "c", "continue": return .continue
 case "n", "next": return .stepOver
 case "s", "step": return .stepIn
 case "q", "quit": return .quit
 case "l", "list": return .listBreakpoints
 case "bt", "backtrace": return .backtrace
 case "b", "break":
 if let (file, line) = parseBreakpoint(arg, defaultFile: event.location.fileName) {
 return .addBreakpoint(fileName: file, line: line)
 }
 print(" usage: b <line> | b <file>:<line>")
 continue
 case "p", "print":
 guard !arg.isEmpty else { print(" usage: p <var>"); continue }
 return .printVariable(arg)
 default:
 print(" unknown command: \(cmd) (c/n/s/q/b/l/p/bt)")
 continue
 }
 }
 }

 private func parseBreakpoint(_ arg: String, defaultFile: String) -> (String, Int)? {
 let comps = arg.split(separator: ":").map(String.init)
 if comps.count == 2, let line = Int(comps[1]) {
 return (comps[0], line)
 }
 if comps.count == 1, let line = Int(comps[0]) {
 return (defaultFile, line)
 }
 return nil
 }
}

/// 源码级调试入口（P7-4）：单 `.pini` 文件或含 `pini.toml` 的目录/模块均可。
func runDebugPath(_ path: String) {
 var isDir: ObjCBool = false
 guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
 printError("Error: 路径不存在：\(path)"); exit(1)
 }
 if isDir.boolValue {
 runDebugDirectory(path)
 } else {
 runDebugFile(path)
 }
}

/// 单文件调试：直接解析并用 SourceMap(sources:) 承载该文件源码。
private func runDebugFile(_ path: String) {
 let source: String
 do { source = try readFile(path) } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 let module = parseOrReport(source: source, fileName: path)
 let sources = [path: source]
 startDebugger(module: module, sources: sources, primaryName: path)
}

/// 目录/模块调试（P7-4 P3）：用 FileLoader 载入包，按 `unit.fileName` 收集各文件源码，
/// 供 SourceMap 跨文件展示断点上下文；运行时 `SourceLocation.fileName` 为全路径，
/// 与 CLI 用户输入的基名通过 `Debugger.breakpointMatches` 容差匹配。
private func runDebugDirectory(_ path: String) {
 let pkg: Package
 do { pkg = try FileLoader.loadDirectory(path: path) } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 var sources: [String: String] = [:]
 for unit in pkg.fileUnits {
 if let src = try? readFile(unit.fileName) {
 sources[unit.fileName] = src
 }
 }
 startDebugger(package: pkg, sources: sources)
}

private func startDebugger(module: Module, sources: [String: String], primaryName: String) {
 let debugger = Debugger(driver: CLIDebugDriver())
 debugger.stopAtEntry = true
 debugger.sourceMap = SourceMap(sources: sources)
 let interpreter = Interpreter()
 interpreter.debugHook = { ctx in
 try debugger.consult(ctx)
 }
 do {
 try interpreter.run(module: module)
 } catch is DebuggerError {
 print("调试会话已结束。")
 } catch {
 printError(formatCLIError(error: error, source: sources[primaryName])); exit(1)
 }
}

private func startDebugger(package: Package, sources: [String: String]) {
 let debugger = Debugger(driver: CLIDebugDriver())
 debugger.stopAtEntry = true
 debugger.sourceMap = SourceMap(sources: sources)
 let interpreter = Interpreter()
 interpreter.debugHook = { ctx in
 try debugger.consult(ctx)
 }
 do {
 try interpreter.run(package: package)
 } catch is DebuggerError {
 print("调试会话已结束。")
 } catch {
 printError(formatCLIError(error: error, source: sources.first?.value)); exit(1)
 }
}

/// 单文件收集式 check：返回诊断数组（空=通过），**不在此处退出**——
/// 供目录逐文件聚合场景复用（见 `runCheckPath`）。
func checkSingleFileDiagnostics(source: String, fileName: String) -> [String] {
 let module = parseOrReport(source: source, fileName: fileName)

 let analyzer = SemanticAnalyzer()
 let semanticErrors = analyzer.analyzeCollecting(module: module)
 var diagnostics: [String] = semanticErrors.map {
 ErrorFormatter.formatSemanticError($0, source: source)
 }

 // 类型检查阶段（P2-4 收尾）：收集模式一次性同报多错；
 // 仅在无语义错误时进入（语义层已能多错同报，类型层不重复污染）。
 if semanticErrors.isEmpty {
 let checker = TypeChecker()
 let typeErrors = checker.checkCollecting(module: module)
 diagnostics += typeErrors.map {
 ErrorFormatter.formatTypeError($0, source: source)
 }
 }
 return diagnostics
}

func runCheckCommand(source: String, fileName: String) throws {
 let diagnostics = checkSingleFileDiagnostics(source: source, fileName: fileName)
 if !diagnostics.isEmpty {
 for d in diagnostics {
 FileHandle.standardError.write(Data((d + "\n").utf8))
 }
 exit(1)
 }
 print("检查通过：\(fileName)")
}

/// #46-E G41（R1）：`pini test [path]` —— 收集顶级 `|test` 函数块逐一执行并汇总报告。
///
/// G49（issue-tdd-module-blockers-2026-08-28）：收集单位 = 模块（回归 G41「收集所有 |test」原意）。
/// - 无 `path`：收集当前目录所属模块根（向上定位清单），模块全量收集；
/// - `path` 为目录：定位所属模块后，收集范围限定该目录；
/// - `path` 为文件：定位所属模块后，收集范围限定该文件；
/// - 显式 `path` 可加回 `[build] exclude` 排除目录（测试目标可检视排除区）；
/// - 模块外单文件：保持单文件行为（向后兼容）。
/// 语义/类型门禁：模块模式整包 analyze/check（与 check 目录模式一致）；失败退出码 1。
/// 退出码：全部通过 0；存在失败测试 1；文件/解析/框架错误 2。
func runTestPath(_ path: String?) {
 do {
 // 无参：收集当前目录所属模块根
 guard let path = path else {
 let cwd = FileManager.default.currentDirectoryPath
 guard let root = try FileLoader.locateModuleRoot(for: cwd) else {
 printError("Error: \(cwd) 不属于任何模块（向上未找到清单）；请在模块内运行 `pini test`，或显式指定路径")
 exit(1)
 }
 try runModuleTests(moduleRoot: root, scopePath: nil)
 return
 }

 let abs = URL(fileURLWithPath: path).standardized.path
 var isDir: ObjCBool = false
 guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) else {
 printError("Error: 路径不存在：\(path)")
 exit(1)
 }

 // 模块内（文件或目录）：模块模式
 if let root = try FileLoader.locateModuleRoot(for: abs) {
 try runModuleTests(moduleRoot: root, scopePath: abs)
 return
 }

 if isDir.boolValue {
 // 模块外目录：聚合为包后全量收集（隐式根模块兜底）
 let pkg = try FileLoader.loadDirectory(path: abs)
 try gateAndRunTests(pkg: pkg, scope: nil, scopeLabel: nil, ffiConfig: .default)
 return
 }

 // 模块外单文件：单文件行为（G41 原语义，向后兼容）
 try runSingleFileTests(path: abs)
 } catch let err as SemanticError {
 handleSemanticError(err); exit(1)
 } catch let err as TypeError {
 handleTypeError(err); exit(1)
 } catch {
 printError(formatCLIError(error: error, source: nil))
 exit(2)
 }
}

/// G49：模块模式测试——整包加载（`[build] exclude` 生效）+ 显式路径加回 + 收集范围限定。
private func runModuleTests(moduleRoot: String, scopePath: String?) throws {
 let manifest = try FileLoader.loadManifest(directory: moduleRoot)
 var pkg = try FileLoader.loadDirectory(path: moduleRoot, manifest: manifest)

 var scope: ((String) -> Bool)? = nil
 var scopeLabel: String? = nil
 if let sp = scopePath {
 // 收集范围限定显式路径（文件或目录）
 scope = { $0 == sp || $0.hasPrefix(sp + "/") }
 scopeLabel = sp
 // 显式路径加回：若该路径下的源文件未进包（整体被 `[build] exclude` 排除），逐文件补载
 let covered = pkg.fileUnits.contains { $0.fileName == sp || $0.fileName.hasPrefix(sp + "/") }
 if !covered {
 var isDir: ObjCBool = false
 if FileManager.default.fileExists(atPath: sp, isDirectory: &isDir), isDir.boolValue {
 let files = try FileManager.default.subpathsOfDirectory(atPath: sp)
 .filter { $0.hasSuffix(LangConfig.sourceSuffix) && !$0.contains("__MACOSX") && !FileLoader.isInsideDotPath($0) }   // R5 点前缀不扫描
 .sorted()
 for rel in files {
 let full = (sp as NSString).appendingPathComponent(rel)
 let unit = try FileLoader.loadFile(path: full)
 pkg = Package(name: pkg.name, fileUnits: pkg.fileUnits + unit.fileUnits)
 }
 } else {
 let unit = try FileLoader.loadFile(path: sp)
 pkg = Package(name: pkg.name, fileUnits: pkg.fileUnits + unit.fileUnits)
 }
 }
 }

 try gateAndRunTests(pkg: pkg, scope: scope, scopeLabel: scopeLabel,
 ffiConfig: manifest?.ffi ?? .default)
}

/// G49：语义/类型门禁（整包，与 check 目录模式一致）→ 包级 runTests → 汇总报告。
private func gateAndRunTests(pkg: Package, scope: ((String) -> Bool)?, scopeLabel: String?,
 ffiConfig: FFIConfig) throws {
 do {
 let analyzer = SemanticAnalyzer()
 try analyzer.analyze(package: pkg)
 let checker = TypeChecker()
 try checker.check(package: pkg)
 } catch let err as SemanticError {
 handleSemanticError(err); exit(1)
 } catch let err as TypeError {
 handleTypeError(err); exit(1)
 }

 let interpreter = Interpreter(ffiConfig: ffiConfig)
 let results = try interpreter.runTests(package: pkg, fileScope: scope)

 if let label = scopeLabel {
 print("测试目标: 模块 \(pkg.name)（\(pkg.fileUnits.count) 个文件，范围 \(label)）")
 } else {
 print("测试目标: 模块 \(pkg.name)（\(pkg.fileUnits.count) 个文件）")
 }
 var passed = 0, failed = 0
 for r in results {
 if r.passed {
 passed += 1
 print(" ✓ \(r.name)")
 } else {
 failed += 1
 print(" ✗ \(r.name): \(r.message)")
 }
 }
 if results.isEmpty { print(" （未找到 |test 测试函数）") }
 print("结果: \(passed) 通过, \(failed) 失败")
 if failed > 0 { exit(1) }
}

/// G41 原单文件语义（模块外单文件向后兼容路径）。
private func runSingleFileTests(path: String) throws {
 let source = try readFile(path)
 let diagnostics = checkSingleFileDiagnostics(source: source, fileName: path)
 if !diagnostics.isEmpty {
 for d in diagnostics { FileHandle.standardError.write(Data((d + "\n").utf8)) }
 exit(1)
 }
 let lexer = Lexer(source: source, fileName: path)
 let tokens = try lexer.tokenize()
 let parser = Parser(tokens: tokens, fileName: path)
 let module = try parser.parseModule()
 // Phase 2b（ADR-017）：单文件测试若位于含清单的模块内，加载其 `[ffi]` 配置，
 // 使 foreign 块经 search_paths 解析到项目内依赖（如 vendored lib/），而非依赖 cwd 或系统库。
 let dir = (path as NSString).deletingLastPathComponent
 let manifest = try? FileLoader.loadManifest(directory: dir)
 let interpreter = Interpreter(ffiConfig: manifest?.ffi ?? .default)
 let results = try interpreter.runTests(module: module)
 var passed = 0, failed = 0
 print("测试文件: \(path)")
 for r in results {
 if r.passed {
 passed += 1
 print(" ✓ \(r.name)")
 } else {
 failed += 1
 print(" ✗ \(r.name): \(r.message)")
 }
 }
 if results.isEmpty { print(" （未找到 |test 测试函数）") }
 print("结果: \(passed) 通过, \(failed) 失败")
 if failed > 0 { exit(1) }
}

/// P4 Phase 5：check / build 接收文件或目录。
/// - 文件 → 单文件收集式 check（零回归）。
/// - 目录含 `pini.toml` → 显式多文件模块，跨文件 analyze/check（首个错误即报，见 Phase 3/4）。
/// - 目录无 `pini.toml` → 视为一组**独立程序**，逐 `.pini` 独立 check；
/// 跳过含自身 pini.toml 的嵌套模块子目录（避免 examples/multifile 被当独立文件误报未定义符号）。
func runCheckPath(_ path: String) {
 var isDir: ObjCBool = false
 guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
 printError("Error: 路径不存在：\(path)")
 exit(1)
 }

 if !isDir.boolValue {
 let source: String
 do { source = try readFile(path) } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 do {
 try runCheckCommand(source: source, fileName: path)
 } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 return
 }

 // —— 目录 ——
 let manifest: ModuleManifest?
 do { manifest = try FileLoader.loadManifest(directory: path) } catch {
 printError(formatCLIError(error: error, source: nil)); exit(1)
 }

 if let manifest = manifest {
 // 显式多文件模块
 let pkg: Package
 do { pkg = try FileLoader.loadDirectory(path: path, manifest: manifest) } catch {
 printError(formatCLIError(error: error, source: nil)); exit(1)
 }
 do {
 let analyzer = SemanticAnalyzer()
 try analyzer.analyze(package: pkg)
 let checker = TypeChecker()
 try checker.check(package: pkg)
 print("检查通过（模块 \(pkg.name)，\(pkg.fileUnits.count) 个文件）：\(path)")
 } catch let err as SemanticError {
 handleSemanticError(err); exit(1)
 } catch let err as TypeError {
 handleTypeError(err); exit(1)
 } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }
 return
 }

 // 无清单：独立程序逐文件 check
 let fm = FileManager.default
 let files: [String]
 do {
 files = try fm.subpathsOfDirectory(atPath: path)
 .filter { $0.hasSuffix(LangConfig.sourceSuffix) && !$0.contains("__MACOSX") && !FileLoader.isInsideDotPath($0) }   // R5 点前缀不扫描
 .filter { !isInsideNestedModule($0, root: path) }
 .sorted()
 } catch {
 printError("Error: \(error.localizedDescription)"); exit(1)
 }

 var failed: [String] = []
 for rel in files {
 let full = (path as NSString).appendingPathComponent(rel)
 let source: String
 do {
 source = try readFile(full)
 } catch {
 let base = (full as NSString).lastPathComponent
 failed.append(base)
 FileHandle.standardError.write(Data(("\(base): 读取失败：\(error.localizedDescription)\n").utf8))
 continue
 }
 let fileName = (full as NSString).lastPathComponent
 let diags = checkSingleFileDiagnostics(source: source, fileName: fileName)
 if !diags.isEmpty {
 failed.append(fileName)
 for d in diags {
 FileHandle.standardError.write(Data(("\(fileName): " + d + "\n").utf8))
 }
 }
 }
 if !failed.isEmpty { exit(1) }
 print("检查通过（\(files.count) 个独立文件）：\(path)")
}

/// 判断某 `.pini`（相对路径）是否位于「含自身 pini.toml 的嵌套模块目录」内；
/// 若是则其归属该嵌套模块，父级目录的逐文件 check 应跳过，避免误报未定义符号。
private func isInsideNestedModule(_ relativeBkPath: String, root: String) -> Bool {
 var dir = (root as NSString).appendingPathComponent(
 (relativeBkPath as NSString).deletingLastPathComponent)
 while dir != root {
 if FileManager.default.fileExists(
 atPath: (dir as NSString).appendingPathComponent("pini.toml")) {
 return true
 }
 let parent = (dir as NSString).deletingLastPathComponent
 if parent == dir { break }
 dir = parent
 }
 return false
}

/// #46-optional / Task #2：LLVM 管线先类型检查，再注入 typeInference 给 IRGenerator。
/// 与解释器对齐做静态校验（零类型信息的 codegen 无法解构 Optional.some，需此前提）。
/// 类型错误一次性同报并退出（沿用 `runCheckCommand` 的收集模式风格）。
private func typeCheckThenGenerate(source: String, fileName: String) throws -> String {
 let module = parseOrReport(source: source, fileName: fileName)
 let checker = TypeChecker()
 let typeErrors = checker.checkCollecting(module: module)
 if !typeErrors.isEmpty {
 for e in typeErrors {
 FileHandle.standardError.write(Data((ErrorFormatter.formatTypeError(e, source: source) + "\n").utf8))
 }
 exit(1)
 }
 let generator = IRGenerator()
 generator.typeInference = checker.typeInference
 // #46-optional：开启持久表兜底，使 codegen 重推 match scrutinee 类型时不受 check 后作用域 pop 影响。
 checker.typeInference.environment?.persistAcrossScopesForCodegen = true
 return try generator.generate(module: module)
}

func runEmitCommand(source: String, fileName: String, outputPath: String?) throws {
 let ir = try typeCheckThenGenerate(source: source, fileName: fileName)

 if let out = outputPath {
 try ir.write(toFile: out, atomically: true, encoding: .utf8)
 } else {
 print(ir)
 }
}

/// 定位集合运行时动态库（ADR-008 阶段1）。
/// 优先 env `PINI_RUNTIME_LIB`；否则取 CLI 可执行文件同级目录的
/// `libPiniRuntime.{dylib,so}`（swift build 产物默认同目录）。
/// 找不到时返回 nil —— 调用方据此 best-effort 跳过加载（非集合程序本就无需运行时）。
private func runtimeLibraryPath() -> String? {
 if let override = ProcessInfo.processInfo.environment["PINI_RUNTIME_LIB"],
 !override.isEmpty, FileManager.default.fileExists(atPath: override) {
 return override
 }
 let exe = CommandLine.arguments[0]
 let dir = (exe as NSString).deletingLastPathComponent
 for ext in ["dylib", "so"] {
 let cand = (dir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
 if FileManager.default.fileExists(atPath: cand) { return cand }
 }
 return nil
}

func runCompileCommand(source: String, fileName: String) throws {
 let ir = try typeCheckThenGenerate(source: source, fileName: fileName)

 let tmpIR = "/tmp/pini_\(UUID().uuidString).ll"
 let tmpBin = "/tmp/pini_\(UUID().uuidString)"
 try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

 defer {
 try? FileManager.default.removeItem(atPath: tmpIR)
 try? FileManager.default.removeItem(atPath: tmpBin)
 }

 guard let clang = LLVMToolchain.clangPath else {
 throw NSError(domain: "ToolchainError", code: -1,
 userInfo: [NSLocalizedDescriptionKey: "clang not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN."])
 }
 let process = Process()
 process.executableURL = URL(fileURLWithPath: clang)
 // ADR-008 阶段1：链接集合运行时（best-effort，找不到则跳过——非集合程序无需）。
 var clangArgs = ["-o", tmpBin, tmpIR]
 if let dylib = runtimeLibraryPath() {
 let dir = (dylib as NSString).deletingLastPathComponent
 clangArgs.insert(contentsOf: ["-L\(dir)", "-lPiniRuntime", "-Wl,-rpath,\(dir)"], at: 0)
 }
 process.arguments = clangArgs
 let pipe = Pipe()
 process.standardError = pipe

 try process.run()
 process.waitUntilExit()

 if process.terminationStatus != 0 {
 let data = pipe.fileHandleForReading.readDataToEndOfFile()
 let err = String(data: data, encoding: .utf8) ?? ""
 throw NSError(domain: "CompileError", code: Int(process.terminationStatus),
 userInfo: [NSLocalizedDescriptionKey: "clang failed: \(err)"])
 }

 let run = Process()
 run.executableURL = URL(fileURLWithPath: tmpBin)
 try run.run()
 run.waitUntilExit()
}

func runLLICommand(source: String, fileName: String) throws {
 let ir = try typeCheckThenGenerate(source: source, fileName: fileName)

 let tmpIR = "/tmp/pini_\(UUID().uuidString).ll"
 defer { try? FileManager.default.removeItem(atPath: tmpIR) }
 try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

 guard let lli = LLVMToolchain.lliPath else {
 throw NSError(domain: "ToolchainError", code: -1,
 userInfo: [NSLocalizedDescriptionKey: "lli not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN."])
 }
 var lliArgs = [tmpIR]
 // ADR-008 阶段1：加载集合运行时（best-effort，找不到则跳过——非集合程序无需）。
 if let dylib = runtimeLibraryPath() {
 lliArgs.insert("--dlopen=\(dylib)", at: 0)
 }
 let process = Process()
 process.executableURL = URL(fileURLWithPath: lli)
 process.arguments = lliArgs

 try process.run()
 process.waitUntilExit()
}

func handleSemanticError(_ error: SemanticError) {
 // T11（A4）：收敛消息源——check 多文件路径复用 ErrorFormatter（无单一 source，源码行省略）。
 printError(ErrorFormatter.formatSemanticError(error, source: ""))
}

func handleTypeError(_ error: TypeError) {
 printError(ErrorFormatter.formatTypeError(error, source: ""))
}


// MARK: - Error Helpers

func printError(_ message: String) {
 FileHandle.standardError.write(Data((message + "\n").utf8))
}

func formatCLIError(error: Error, source: String?) -> String {
 // T1（A3）：诊断驱动渲染——错误码 + 中文消息 + 跨度下划线 + 建议（DiagnosticProviding 协议元数据）。
 if let d = error as? any DiagnosticProviding {
 _ = d
 return ErrorFormatter.formatDiagnostic(error, source: source ?? "")
 }
 return "Error: \(error.localizedDescription)"
}

// MARK: - Main Entry Point

var args = CommandLine.arguments

// T11（A4）：--lang zh|en 诊断语言（TOML 资源驱动；默认 zh，未覆盖码回退 zh）。
// 解析后从 args 移除该参数对，避免干扰命令的路径/子参数解析。
if let langIdx = args.firstIndex(of: "--lang"), langIdx + 1 < args.count,
 let lang = DiagnosticLanguage(rawValue: args[langIdx + 1]) {
 DiagnosticResources.shared.setLanguage(lang)
 args.removeSubrange(langIdx...langIdx + 1)
}

if args.count < 2 {
 printHelp()
 exit(0)
}

let command = args[1]

switch command {
case "help", "--help", "-h":
 printHelp()
case "version", "--version", "-v":
 printVersion()
case "tokens":
 guard args.count >= 3 else {
 printError("Error: tokens command requires a file path")
 exit(1)
 }
 let filePath = args[2]
 let source: String
 do {
 source = try readFile(filePath)
 } catch {
 printError("Error: \(error.localizedDescription)")
 exit(1)
 }
 do {
 try runTokensCommand(source: source, fileName: filePath)
 } catch {
 printError(formatCLIError(error: error, source: source))
 exit(1)
 }
case "parse":
 guard args.count >= 3 else {
 printError("Error: parse command requires a file path")
 exit(1)
 }
 let filePath = args[2]
 let source: String
 do {
 source = try readFile(filePath)
 } catch {
 printError("Error: \(error.localizedDescription)")
 exit(1)
 }
 do {
 try runParseCommand(source: source, fileName: filePath)
 } catch {
 printError(formatCLIError(error: error, source: source))
 exit(1)
 }
case "run":
 guard args.count >= 3 else {
 printError("Error: run command requires a file or directory path")
 exit(1)
 }
 runRunPath(args[2])
case "repl":
 ReplSession().run()
 exit(0)
case "check", "build":
 guard args.count >= 3 else {
 printError("Error: \(command) command requires a file or directory path")
 exit(1)
 }
 runCheckPath(args[2])
case "test":
 // #46-E G41（R1）/ G49：测试子命令——path 可选；无参 = 收集当前目录所属模块根。
 runTestPath(args.count >= 3 ? args[2] : nil)
case "emit":
 guard args.count >= 3 else {
 printError("Error: emit command requires a file path")
 exit(1)
 }
 do {
 let source = try readFile(args[2])
 try runEmitCommand(source: source, fileName: args[2],
 outputPath: args.count >= 4 ? args[3] : nil)
 } catch {
 printError(formatCLIError(error: error, source: nil))
 exit(1)
 }
case "compile":
 guard args.count >= 3 else {
 printError("Error: compile command requires a file path")
 exit(1)
 }
 do {
 let source = try readFile(args[2])
 try runCompileCommand(source: source, fileName: args[2])
 } catch {
 printError(formatCLIError(error: error, source: nil))
 exit(1)
 }
case "run-llvm":
 guard args.count >= 3 else {
 printError("Error: run-llvm command requires a file path")
 exit(1)
 }
 do {
 let source = try readFile(args[2])
 try runLLICommand(source: source, fileName: args[2])
 } catch {
 printError(formatCLIError(error: error, source: nil))
 exit(1)
 }
case "lsp":
 let server = LSPServer()
 server.start()
case "debug":
 guard args.count >= 3 else {
 printError("Error: debug command requires a file path")
 exit(1)
 }
 runDebugPath(args[2])
case "dap":
 guard args.count >= 3 else {
 printError("Error: dap command requires a file path")
 exit(1)
 }
 let server = DAPServer()
 server.run()
default:
 printError("Error: Unknown command '\(command)'")
 printHelp()
 exit(1)
}