import Foundation
import PiniCore
import PiniSyntax
import PiniSemantics
import PiniIR
import PiniBackendLLVM
import PiniHost

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
    case .function(let params, let returns, _, _, _):
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
    case .join(let inner, _, let form):
        return "\(indent)join(\(form.keyword)):\n" + describeExpression(inner, indent: indent + " ")
    case .tryExpression(let operand, let errorVar, let handler, _):
        var result = "\(indent)tryExpression(try-else, errorVar=\(errorVar)):\n"
        result += describeExpression(operand, indent: indent + " ") + "\n"
        result += "\(indent) handler:\n"
        for s in handler.statements {
            result += describeStatement(s, indent: indent + " ") + "\n"
        }
        return String(result.dropLast())
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
    case .dotCaseRef(let name, _):
        return "\(indent)dotCaseRef(.): \(name)"
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
    case .whileStatement(let condition, let body, let step, let label, _):
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
        // step 块与 body 同形渲染：`step:` 段内每条语句一行，缩进与 body 一致。
        if let step = step {
            result += "\n\(indent) step:\n"
            for s in step.statements {
                result += describeStatement(s, indent: indent + " ") + "\n"
            }
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
        // `case _:` 通配作为 case 进入 cases，无独立 default/wildcard 块。
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
    case .captureStatement(let name, _):
        return "\(indent)capture \(name)"
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
    var result = "\(indent)field \(field.name): \(describeTypeAnnotation(field.typeAnnotation))"
    // 字段带初始化器时追加 ` = <表达式>`。
    if let initExpr = field.initializer {
        result += " = \(describeExpression(initExpr, indent: ""))"
    }
    return result
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

/// 给定块的 AST dump（`pini parse` 面）：与对象同构，故同形渲染。
func describeGivenDecl(_ givenDecl: GivenDecl, indent: String = "") -> String {
    var result = "\(indent)given \(givenDecl.name)"

    if !givenDecl.genericParams.isEmpty {
        result += "<" + givenDecl.genericParams.map { $0.name }.joined(separator: ", ") + ">"
    }

    result += ":\n"

    for field in givenDecl.fields {
        result += describeFieldDecl(field, indent: indent + " ") + "\n"
    }

    for method in givenDecl.methods {
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

    if !enumDecl.traits.isEmpty {
        result += "\(indent) 实现: " + enumDecl.traits.joined(separator: ", ") + "\n"
    }

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
    case .givenDecl(let givenDecl):
        return describeGivenDecl(givenDecl, indent: indent)
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
        // 块形式 import 的 dump 形态：`import 别名 = 路径`，一行一条。
        return "\(indent)import \(importDecl.alias) = \(importDecl.packagePath)"
    case .exportDecl(let exportDecl):
        // dump 形态：`export 名|c = 原符号`；pini 目标省略标签，与源码默认一致。
        var out = ""
        for entry in exportDecl.entries {
            let target = entry.target == .c ? "|c" : ""
            out += "\(indent)export \(entry.name)\(target) = \(entry.symbol)\n"
        }
        return out.hasSuffix("\n") ? String(out.dropLast()) : out
    case .extensionDecl(let ext):
        var result = "\(indent)extension \(ext.targetType):\n"
        for m in ext.methods {
            result += describeFuncDecl(m, indent: indent + " ") + "\n"
        }
        return String(result.dropLast())
    case .foreignDecl(let fd):
        var result = "\(indent)foreign \(fd.name):\n"
        for symbol in fd.symbols {
            let flags = symbol.flags.map { "|" + $0 }.joined()
            result += "\(indent) \(symbol.name)\(flags): \(symbol.annotation.describe())\n"
        }
        return String(result.dropLast())
    }
}

func describeAST(_ module: Module) -> String {
    var result = "Module:\n"
    // import/export 存于 `Module.imports`/`exports` 而非 `declarations`，故在此单独遍历。
    // 宿主未保留三者交错的顺序，固定按 imports → declarations → exports 输出。
    for imp in module.imports {
        result += describeTopLevelDecl(.importDecl(imp), indent: " ") + "\n"
    }
    for decl in module.declarations {
        result += describeTopLevelDecl(decl, indent: " ") + "\n"
    }
    for exp in module.exports {
        result += describeTopLevelDecl(.exportDecl(exp), indent: " ") + "\n"
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
    print(" build --shared <path> [-o out] Link the export block's |c entries into lib<file>.{dylib,so}")
    print(" test [path] Collect and run |test blocks; no path = whole module, file/dir narrows scope (G41/G49; assert-based)")
    print(" test-llvm [path] Same collection, gates and report as `test`; runs through the LLVM backend (native binary)")
    print(" parse <file.pini> Parse and print the AST")
    print(" parse --sig <file.pini> Parse and print statement signature (SIG) lines")
    print(" tokens <file.pini> Print tokens from lexical analysis")
    print(" emit <file.pini> [-o <out>] [--backend <name>] Emit a target listing to stdout or the given file")
    print(" backends [--tsv] Print the backend capability matrix (family x channel)")
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

/// 后端能力表：行是节点族，列是装配表里的通道。表由各通道自述，此处不做核对。
func printBackendMatrix(tsv: Bool) {
    let registry = Backends.registry
    let channels = registry.entries.compactMap { registry.make($0.identifier) }
    let families = BackendCapabilities.Family.allCases
    if tsv {
        print((["family"] + registry.identifiers).joined(separator: "\t"))
        var outputs = ["output"]
        for channel in channels {
            outputs.append(type(of: channel).capabilities.output.rawValue)
        }
        print(outputs.joined(separator: "\t"))
        for family in families {
            var row = [family.rawValue]
            for channel in channels {
                row.append(type(of: channel).capabilities.supports(family) ? "yes" : "no")
            }
            print(row.joined(separator: "\t"))
        }
        return
    }
    var header = ["family"]
    for name in registry.identifiers { header.append(name) }
    print(header.joined(separator: "\t"))
    for family in families {
        var row = [family.rawValue]
        for channel in channels {
            row.append(type(of: channel).capabilities.supports(family) ? "yes" : "no")
        }
        print(row.joined(separator: "\t"))
    }
}

func printVersion() {
    // CLI 版本号对齐 spec 版本语义（历史曾滞后于 spec minor）。
    print("Pini \(PiniVersion.current)")
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

func runParseCommand(source: String, fileName: String, signaturesOnly: Bool = false) throws {
    let module = parseOrReport(source: source, fileName: fileName)
    if signaturesOnly {
        for line in SignatureSerializer.signatureLines(module: module) {
            print(line)
        }
        return
    }
    print(describeAST(module))
}

// `pini mod {tidy, refresh, verify, graph}`：依赖清单的离线维护入口。
// tidy 对齐 [require] ↔ 代码 import；refresh 重解版本并写 `pini-summary.toml`（远程 tap 报错退出）；
// verify 只读比对锁文件校验和；graph 输出依赖树，`--cycles` 时列环路径。
func runModCommand(_ rest: [String]) {
    guard let sub = rest.first else {
        print("用法: pini mod {tidy|refresh|verify|graph} [--cycles] [模块根]")
        exit(1)
    }
    let flags = Set(rest.dropFirst().filter { $0.hasPrefix("--") })
    let pathArg = rest.dropFirst().first { !$0.hasPrefix("--") }

    do {
        let root: String
        if let p = pathArg {
            root = absoluteProgramBase(p)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            guard let found = try FileLoader.locateModuleRoot(for: cwd) else {
                printError("Error: \(cwd) 不属于任何模块（向上未找到清单）；请在模块内运行或显式指定模块根")
                exit(1)
            }
            root = found
        }
        guard let manifest = try FileLoader.loadManifest(directory: root) else {
            printError("Error: \(root) 不含 pini.toml")
            exit(1)
        }

        switch sub {
        case "tidy":
            let pkg = try FileLoader.loadDirectory(path: root, manifest: manifest)
            let report = try ModuleToolchain.tidy(rootDir: root, manifest: manifest, package: pkg)
            if report.isEmpty {
                print("tidy：[require] 已与 import 对齐（\(report.kept) 条），无改动")
            } else {
                if !report.added.isEmpty { print("tidy：新增 \(report.added.joined(separator: ", "))（约束 *，由 refresh 回填）") }
                if !report.removed.isEmpty { print("tidy：移除 \(report.removed.joined(separator: ", "))（代码中已无 import）") }
                print("tidy：保留 \(report.kept) 条既有约束。下一步：pini mod refresh")
            }
        case "refresh":
            let text = try ModuleToolchain.refresh(
                rootDir: root, manifest: manifest,
                toolchainVersion: "pini \(PiniVersion.current) (spec 0.1)")
            print("refresh：pini-summary.toml 已生成（\(text.components(separatedBy: "\n").count) 行）。须提交进版本库（G52 R3）")
        case "verify":
            let report = try ModuleToolchain.verify(rootDir: root)
            if report.isOK {
                print("verify：\(report.checked) 项校验和全部匹配")
            } else {
                printError("verify：发现 \(report.mismatches.count) 处不符：")
                for m in report.mismatches { FileHandle.standardError.write(Data((" - " + m + "\n").utf8)) }
                exit(1)
            }
        case "graph":
            let (tree, cycles) = try ModuleToolchain.graph(rootDir: root, manifest: manifest)
            if flags.contains("--cycles") {
                if cycles.isEmpty {
                    print("无环（require 图为 DAG）")
                } else {
                    for c in cycles { print(c.joined(separator: " → ")) }
                    exit(1)
                }
            } else {
                print(tree)
                print("---")
                print("环：\(cycles.isEmpty ? "无" : "\(cycles.count) 个（--cycles 查看）")")
            }
        default:
            print("用法: pini mod {tidy|refresh|verify|graph} [--cycles] [模块根]")
            exit(1)
        }
    } catch {
        printError("Error: \(error.localizedDescription)")
        exit(1)
    }
}

/// 警告的中文消息。CLI 的三个出口共用这一份：switch 分三处写，改文案时必有漏网。
func semanticWarningMessage(_ warning: SemanticWarning) -> String {
    switch warning {
    case .implicitAliasNameMismatch(let alias, let target, _):
        return "隐式别名 '\(alias)' 与目标模块名 '\(target)' 不一致（仅提醒）"
    case .unusedVariable(let name, _):
        return "未使用的变量 '\(name)'"
    case .givenCycle:
        return "给定块物化环：" + (warning.cyclePathText ?? "")
    case .automaticErrorCode(let typeName, let code, _):
        return
            "类型 '\(typeName)' 未指定错误码，已自动分配 \(code)。该码不保证跨版本稳定；"
            + "要固定它，在扩展块写 `码() -> (I32,)` 返回一个常量"
    case .duplicateErrorCode(let code, let first, let others, _):
        return
            "错误码 \(code) 同时属于 '\(first)' 与 \(others)：C 侧无法据此区分两者。"
            + "改掉其中一个手写码；若有意合并成同一个状态，可忽略"
    case .variadicForeignSymbol(let name, _):
        return
            "外部函数 '\(name)' 声明为变参：变参调用只在 `run-llvm` 上成立，"
            + "解释器会在调用点拒绝。要两通道都能跑，请在 C 侧写一个固定参数的 shim"
    case .stringHandleForeignSymbol(let name, _):
        return
            "外部函数 '\(name)' 用了字符串句柄：句柄由运行时段持有，只在 `run-llvm` 与 "
            + "`build --shared` 上成立，解释器会在调用点拒绝"
    }
}

/// 一条警告的完整渲染：一个出口写 stderr，另一个并进 check 结果，源码片段两处都要。
func renderedWarning(_ warning: SemanticWarning, source: String) -> String {
    ErrorFormatter.format(
        errorType: "语义警告", message: semanticWarningMessage(warning),
        location: warning.diagnosticLocation, source: source,
        code: warning.diagnosticCode, severity: .warning, suggestion: warning.suggestion)
}

// 输出语义警告（E7 段，弱警告不阻断 run/check，exit 0）。走 stderr，不污染 stdout——
// golden 测试按 stdout 对账。
func emitSemanticWarnings(_ analyzer: SemanticAnalyzer) {
    for w in analyzer.warnings { emitSemanticWarning(w) }
}

func emitSemanticWarning(_ warning: SemanticWarning) {
    FileHandle.standardError.write(Data((renderedWarning(warning, source: sourceFor(warning)) + "\n").utf8))
}

/// 诊断所在文件的源码。模块检查没有单一 source，但位置自带文件名 —— 回读一次比传一份全文省事。
/// 读不到（预置声明、文件已不在）就返回空串，渲染退回无片段的形态。
func sourceFor(_ error: Error) -> String {
    guard let diagnostic = error as? any DiagnosticProviding else { return "" }
    return (try? readFile(diagnostic.diagnosticLocation.fileName)) ?? ""
}

/// 给定块声明的位置表：键是块名。环警告要指到声明处，而边表里只有名字。
func givenBlockLocations(in declarations: [TopLevelDecl]) -> [String: SourceLocation] {
    var locations: [String: SourceLocation] = [:]
    for decl in declarations {
        if case .givenDecl(let given) = decl { locations[given.name] = given.location }
    }
    return locations
}

/// 环 → 警告：位置取环起点（旋转后的最小给定块）的声明处。预置块不在声明表里，取不到位置就跳过。
func givenCycleWarnings(
    references: [String: [String]], calls: [String: [String]],
    declarations: [TopLevelDecl], labels: [String: String]
) -> [SemanticWarning] {
    let locations = givenBlockLocations(in: declarations)
    // 给定块的名单取自声明面，不从边表推：图上函数名与给定块名混在一起，值面已分不出谁是谁。
    var edges = references
    for (name, targets) in calls { edges[name, default: []] += targets }
    return GivenCycleDetector.cycles(in: edges, givenBlocks: Set(locations.keys)).compactMap { path in
        guard let start = path.first, let location = locations[start] else { return nil }
        // 环的身份仍用 IR 名（去重与旋转都按它），只在呈现时翻成源码写法。
        return .givenCycle(path: path.map { labels[$0] ?? $0 }, location: location)
    }
}

/// 空降载一次，取边表找环。降载抛错就静默跳过 —— check 不看降载层错误，显示它们会收窄通过面。
/// 代价明写：含其他降载错误的文件拿不到环检测。
func givenCycleWarnings(module: Module, checker: TypeChecker) -> [SemanticWarning] {
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    /// 宏常量求不出就照样跳过环检测：这条通道本来就是 best-effort，缺值不该把它变成错误。
    guard
        let constants = try? evaluateForeignMacros(
            symbols: foreignSymbols(in: module), config: .default),
        let ir = try? IRLowerer.lower(
            module: module, typeInference: checker.typeInference,
            foreignConstants: constants, requiresMain: false)
    else { return [] }
    return givenCycleWarnings(
        references: ir.givenReferences, calls: ir.callReferences,
        declarations: module.declarations, labels: ir.displayNames)
}

/// 整包版本：环只可能在同一模块内出现，位置取各文件声明的并集（import 进来的外部声明不参与）。
func givenCycleWarnings(package: Package, checker: TypeChecker) -> [SemanticWarning] {
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    guard
        let constants = try? evaluateForeignMacros(
            symbols: package.fileUnits.flatMap { foreignSymbols(in: $0.module) },
            config: .default),
        let ir = try? IRLowerer.lower(
            package: package, typeInference: checker.typeInference,
            foreignConstants: constants, requiresMain: false)
    else { return [] }
    return givenCycleWarnings(
        references: ir.givenReferences, calls: ir.callReferences,
        declarations: package.fileUnits.flatMap { $0.module.declarations },
        labels: ir.displayNames)
}

// 程序基准：相对给定的文件/目录路径求绝对基准——目录取自身，文件取所在目录。
// 相对输入先按当前 CWD 绝对化并标准化。
func absoluteProgramBase(_ path: String) -> String {
    var abs = path
    if !abs.hasPrefix("/") {
        abs = FileManager.default.currentDirectoryPath + "/" + abs
    }
    abs = (abs as NSString).standardizingPath
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue {
        abs = (abs as NSString).deletingLastPathComponent
    }
    return abs
}

// MARK: - 执行引擎

// 引擎开关随 AST 走查一并退役：走查删除后只剩一台引擎，「选哪台」没有第二个答案。
// 取值合法性检查也一并消失——它防的是「静默回退到另一台引擎跑出结果」，没有第二台就没这个失败方式。
// 刻意不做「读到 ast 就报错」的兼容闸：本项目不设 CLI 兼容开关，已无意义的变量名不构成契约。

// 单文件走 IR 执行引擎；目录/模块由 `runIRPackageEngine` 整包 lower 再执行。
// 前段与 `typeCheckThenGenerate` 一致：lowering 需要 checker 的 `typeInference`，故本路径必须跑
// 类型检查（IR 是类型化树，没有推断出的类型就 lower 不出来）。`programBase` 取入口文件所在目录。
private func runIREngine(
    module: Module, source: String, programBase: String?,
    argv: [String] = []
) throws {
    let checker = TypeChecker()
    let typeErrors = checker.checkCollecting(module: module)
    if !typeErrors.isEmpty {
        for e in typeErrors {
            printError(ErrorFormatter.formatTypeError(e, source: source))
        }
        exit(1)
    }
    // 与 emit / compile / run-llvm 同款：lowering 会在 checker 弹出作用域之后重推
    // match scrutinee 的类型，需持久表兜底。
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    let irModule = try IRLowerer.lower(
        module: module, typeInference: checker.typeInference,
        foreignConstants: try evaluateForeignMacros(
            symbols: foreignSymbols(in: module), config: .default))
    let executor = IRExecutor(programBase: programBase)
    executor.processArguments = argv
    try executor.run(module: irModule)
}

// IR 引擎的包运行入口：整包降载（`IRLowerer.lower(package:)`）后交给 IR 执行器，
// 与单文件路径同走「共享前端 → 执行」；调用方必须已完成包级语义与类型检查。
// `moduleRoot` 取含清单的目录：IO 的非前缀相对路径须两通道解析到同一份文件，否则静默读错。
private func runIRPackageEngine(
    package: Package, moduleRoot: String,
    typeInference: TypeInference,
    ffiConfig: FFIConfig,
    argv: [String] = []
) throws {
    let irModule = try IRLowerer.lower(
        package: package, typeInference: typeInference,
        foreignConstants: try evaluateForeignMacros(
            symbols: package.fileUnits.flatMap { foreignSymbols(in: $0.module) },
            config: ffiConfig))
    let executor = IRExecutor(programBase: absoluteProgramBase(moduleRoot), ffiConfig: ffiConfig)
    executor.processArguments = argv
    try executor.run(module: irModule)
}

// run 接收文件或目录：文件 → 单文件运行（零回归）；目录含 `pini.toml` → 多文件模块运行
// （跨文件运行时链接）；目录无清单 → 无法定位单一入口，报错（运行一组独立程序无意义）。
func runRunPath(_ path: String, argv: [String] = []) {
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
        // 单文件 run 过语义门禁（仅语义层 E3）；类型层维持单文件宽松，不假装全检。
        do {
            let analyzer = SemanticAnalyzer()
            try analyzer.analyze(module: module)
            emitSemanticWarnings(analyzer)
        } catch {
            printError(formatCLIError(error: error, source: source)); exit(1)
        }
        // 单文件基准 = 入口文件所在目录：IO 节点的非前缀相对路径以此为根，
        // 否则会在 IR 侧静默读到 CWD 里的同名文件。
        let programBase = absoluteProgramBase(path)
        do { try runIREngine(module: module, source: source, programBase: programBase, argv: argv) } catch { printError(formatCLIError(error: error, source: source)); exit(1) }
        return
    }

    // 目录/包路径：与单文件共用同一前端（清单 / 漂移 / 语义 / 类型），
    // 之后由 `runIRPackageEngine` 整包 lower 再执行。
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
    // build 时校验 require ↔ import 一致性（与 verify 的防篡改是两个检查）。
    // 仅对采用依赖通道的清单生效；不符报错并提示 `pini mod tidy`。
    let driftResult = Result {
        try ModuleToolchain.checkRequireImportAlignment(
            rootDir: absoluteProgramBase(path), manifest: manifest, package: pkg)
    }
    if case .success(.some(let drift)) = driftResult, drift.hasDrift {
        var parts: [String] = []
        if !drift.missingInRequire.isEmpty {
            parts.append("import 了但 [require] 缺失：\(drift.missingInRequire.joined(separator: ", "))")
        }
        if !drift.extraInRequire.isEmpty {
            parts.append("[require] 有但未 import：\(drift.extraInRequire.joined(separator: ", "))")
        }
        printError("Error: 依赖清单与代码漂移——\(parts.joined(separator: "；"))。请运行 `pini mod tidy`")
        exit(1)
    }
    // 与 runCheckPath 模块分支对齐：run 前先做语义 + 类型层可见性 enforce，
    // 使 `pini run` 同样受 4 级访问控制约束；门禁通过后才执行，与单文件路径同形。
    do {
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(package: pkg)
        emitSemanticWarnings(analyzer)
        let checker = TypeChecker()
        try checker.check(package: pkg)
        // 降载会在 checker 弹出作用域之后重推 match scrutinee 的类型，
        // 需持久表兜底（与单文件、emit、compile 三条路径同款）。
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        // 模块基准 = 模块根（含 pini.toml 的目录），IO 相对路径以此为根。
        try runIRPackageEngine(
            package: pkg, moduleRoot: path,
            typeInference: checker.typeInference,
            ffiConfig: manifest.ffi ?? .default, argv: argv)
    } catch {
        printError(formatCLIError(error: error, source: nil)); exit(1)
    }
}

// MARK: - 调试器（P7-4）

/// 从 stdin 读取命令的调试驱动。
struct CLIDebugDriver: DebugDriver {
    func nextCommand(_ event: StopEvent) -> DebugCommand {
        while true {
            print("debug> ", terminator: "")
            guard let line = readLine() else {
                return .quit  // EOF：结束调试会话
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

// 单文件调试：直接解析并用 SourceMap(sources:) 承载该文件源码。引擎走 `check → lower → execute`，
// 调试入口是该能力的唯一实现、没有第二条臂可换，故换引擎时必须先把它接上（否则能力净减）。
private func runDebugFile(_ path: String) {
    let source: String
    do { source = try readFile(path) } catch {
        printError("Error: \(error.localizedDescription)"); exit(1)
    }
    let module = parseOrReport(source: source, fileName: path)
    let sources = [path: source]
    let checker = TypeChecker()
    let errors = checker.checkCollecting(module: module)
    guard errors.isEmpty else {
        printError(
            errors.map { ErrorFormatter.formatTypeError($0, source: source) }
                .joined(separator: "\n"))
        exit(1)
    }
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    let executor = IRExecutor(programBase: absoluteProgramBase(path))
    startDebugger(
        run: DebugRun(host: executor) {
            let ir = try IRLowerer.lower(
                module: module, typeInference: checker.typeInference,
                foreignConstants: try evaluateForeignMacros(
                    symbols: foreignSymbols(in: module), config: .default))
            try executor.run(module: ir)
        }, sources: sources, primaryName: path)
}

// 目录/模块调试：用 FileLoader 载入包，按 `unit.fileName` 收集各文件源码，供 SourceMap 跨文件
// 展示断点上下文；运行时 `SourceLocation.fileName` 为全路径，由 `Debugger.breakpointMatches` 容差匹配。
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
    let checker = TypeChecker()
    do { try checker.check(package: pkg) } catch {
        printError(formatCLIError(error: error, source: nil))
        exit(1)
    }
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    let executor = IRExecutor(programBase: absoluteProgramBase(path))
    startDebugger(
        run: DebugRun(host: executor) {
            let ir = try IRLowerer.lower(
                package: pkg, typeInference: checker.typeInference,
                foreignConstants: try evaluateForeignMacros(
                    symbols: pkg.fileUnits.flatMap { foreignSymbols(in: $0.module) },
                    config: .default))
            try executor.run(module: ir)
        }, sources: sources, primaryName: sources.keys.first ?? path)
}

// 装配一次调试会话：入参是 `DebugRun` 而非具体引擎，装配只认协议面与「开始跑」的动作，
// 故同一份样板同时服务两条输入形状，换默认引擎时这里不动——引擎由调用方选并随启动动作交进来。
private func startDebugger(run: DebugRun, sources: [String: String], primaryName: String) {
    let debugger = Debugger(driver: CLIDebugDriver())
    debugger.stopAtEntry = true
    debugger.sourceMap = SourceMap(sources: sources)
    run.host.debugHook = { ctx in
        try debugger.consult(ctx)
    }
    do {
        try run.start()
    } catch is DebuggerError {
        print("调试会话已结束。")
    } catch {
        printError(formatCLIError(error: error, source: sources[primaryName])); exit(1)
    }
}

/// 单文件 check 的结果：诊断行按输出顺序排好，另带一位「有没有阻断性诊断」。
/// 警告与错误混在一个数组会逼调用方按「非空」定退出码 ⇒ 一条未使用变量就让 check 返回 1。
/// 退出码只认这一位；输出顺序与文案不变。
struct FileCheckResult {
    var diagnostics: [String] = []
    var hasBlockingDiagnostics = false
}

/// 单文件收集式 check：返回诊断与阻断位，**不在此处退出**——
/// 供目录逐文件聚合场景复用（见 `runCheckPath`）。
/// 模块里声明的全部外部符号（各 foreign 块摊平）。
func foreignSymbols(in module: Module) -> [ForeignSymbol] {
    module.declarations.flatMap { decl -> [ForeignSymbol] in
        guard case .foreignDecl(let block) = decl else { return [] }
        return block.symbols
    }
}

/// 求值宏常量：没有 `|macro` 的模块不碰工具链，返回值恒空。
/// check 与运行路径都先过这一关，免得「check 通过、run 才报宏展不开」。
func evaluateForeignMacros(
    symbols: [ForeignSymbol], config: FFIConfig
) throws -> [IRForeignConstant] {
    guard symbols.contains(where: { $0.flags.contains("macro") }) else { return [] }
    return try ForeignMacroEvaluator.evaluate(symbols: symbols, config: config)
}

func checkSingleFileDiagnostics(source: String, fileName: String) -> FileCheckResult {
    let module = parseOrReport(source: source, fileName: fileName)

    let analyzer = SemanticAnalyzer()
    let semanticErrors = analyzer.analyzeCollecting(module: module)
    var result = FileCheckResult()
    result.diagnostics = semanticErrors.map {
        ErrorFormatter.formatSemanticError($0, source: source)
    }
    result.hasBlockingDiagnostics = !semanticErrors.isEmpty
    // 语义警告随单文件 check 一并输出（E7 段，弱警告不阻断）。
    for w in analyzer.warnings {
        result.diagnostics.append(renderedWarning(w, source: source))
    }

    // 类型检查阶段（P2-4 收尾）：收集模式一次性同报多错；
    // 仅在无语义错误时进入（语义层已能多错同报，类型层不重复污染）。
    if semanticErrors.isEmpty {
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        result.diagnostics += typeErrors.map {
            ErrorFormatter.formatTypeError($0, source: source)
        }
        if typeErrors.isEmpty {
            /// 宏常量：单文件没有 `pini.toml`，声明了就只能报「缺 headers」—— 值没有别的来源。
            do {
                _ = try evaluateForeignMacros(
                    symbols: foreignSymbols(in: module), config: .default)
            } catch {
                result.diagnostics.append("Error: \(error)")
                result.hasBlockingDiagnostics = true
            }
            for w in givenCycleWarnings(module: module, checker: checker) {
                result.diagnostics.append(renderedWarning(w, source: source))
            }
        } else {
            result.hasBlockingDiagnostics = true
        }
    }
    return result
}

func runCheckCommand(source: String, fileName: String) throws {
    let result = checkSingleFileDiagnostics(source: source, fileName: fileName)
    for d in result.diagnostics {
        FileHandle.standardError.write(Data((d + "\n").utf8))
    }
    if result.hasBlockingDiagnostics { exit(1) }
    print("检查通过：\(fileName)")
    CommentStyleHint.emit()
}

// 测试执行通道：同一套收集范围与门禁，两条后端。它只决定最后一步怎么跑（解释器执行 / 发射后运行），
// 不影响「收集哪些」与「门禁怎么做」——那两件事两条通道共用同一份代码，否则「两后端一致」没有载体。
enum TestChannel {
    case interpreter
    case llvm

    /// 消息里要用的子命令名 —— 提示得说对用户刚敲的那一个。
    var commandName: String {
        switch self {
        case .interpreter: return "test"
        case .llvm: return "test-llvm"
        }
    }
}

// `pini test [path]`：收集顶级 `|test` 函数块逐一执行并汇总报告，收集单位 = 模块（向上定位清单）。
// 无 path → 模块全量；目录 / 文件 → 限定范围（显式 path 可加回 `[build] exclude`）；模块外单文件保持单文件行为。
// 模块模式整包语义/类型门禁，失败退出 1；全通过 0、有失败测试 1、文件/解析/框架错误 2。
func runTestPath(_ path: String?, channel: TestChannel = .interpreter) {
    do {
        // 无参：收集当前目录所属模块根
        guard let path = path else {
            let cwd = FileManager.default.currentDirectoryPath
            guard let root = try FileLoader.locateModuleRoot(for: cwd) else {
                printError("Error: \(cwd) 不属于任何模块（向上未找到清单）；请在模块内运行 `pini \(channel.commandName)`，或显式指定路径")
                exit(1)
            }
            try runModuleTests(moduleRoot: root, scopePath: nil, channel: channel)
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
            try runModuleTests(moduleRoot: root, scopePath: abs, channel: channel)
            return
        }

        if isDir.boolValue {
            // 模块外目录：聚合为包后全量收集（隐式根模块兜底）
            let pkg = try FileLoader.loadDirectory(path: abs)
            try gateAndRunTests(
                pkg: pkg, scope: nil, scopeLabel: nil, ffiConfig: .default,
                programBase: absoluteProgramBase(abs), channel: channel)
            return
        }

        // 模块外单文件：单文件行为（G41 原语义，向后兼容）
        try runSingleFileTests(path: abs, channel: channel)
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
private func runModuleTests(moduleRoot: String, scopePath: String?, channel: TestChannel) throws {
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
                    .filter { $0.hasSuffix(LangConfig.sourceSuffix) && !$0.contains("__MACOSX") && !FileLoader.isInsideDotPath($0) }  // R5 点前缀不扫描
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

    try gateAndRunTests(
        pkg: pkg, scope: scope, scopeLabel: scopeLabel,
        ffiConfig: manifest?.ffi ?? .default,
        programBase: absoluteProgramBase(moduleRoot), channel: channel)
}

/// G49：语义/类型门禁（整包，与 check 目录模式一致）→ 包级测试 → 汇总报告。
///
/// `channel` 只影响**最后怎么跑**这一步；门禁、报告首行、以及「跑哪些」的收窄两条通道同规。
private func gateAndRunTests(
    pkg: Package, scope: ((String) -> Bool)?, scopeLabel: String?,
    ffiConfig: FFIConfig, programBase: String? = nil,
    channel: TestChannel = .interpreter
) throws {
    do {
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(package: pkg)
        emitSemanticWarnings(analyzer)
        let checker = TypeChecker()
        try checker.check(package: pkg)
    } catch let err as SemanticError {
        handleSemanticError(err); exit(1)
    } catch let err as TypeError {
        handleTypeError(err); exit(1)
    }

    // 报告首行：两条通道是**同一个字符串** —— 解释器打印它，LLVM 把它交给产物自己打印。
    //  注意  两边各拼一次就迟早会不一致，故这里只拼一处。
    let header: String
    if let label = scopeLabel {
        header = "测试目标: 模块 \(pkg.name)（\(pkg.fileUnits.count) 个文件，范围 \(label)）"
    } else {
        header = "测试目标: 模块 \(pkg.name)（\(pkg.fileUnits.count) 个文件）"
    }

    // 测试运行注入程序基准（模块根 / 显式目录），IO 相对路径与 run 一致。
    let runner = ProgramRunner(ffiConfig: ffiConfig, programBase: programBase)

    switch channel {
    case .interpreter:
        let results = try runner.runTests(package: pkg, fileScope: scope)
        print(header)
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

    case .llvm:
        //  重要  降载走 `lowerTests` —— 与上面那条通道**同一份**降载（理由见它的注释）。
        let lowered = try runner.lowerTests(package: pkg)
        try emitAndRunLLVMTests(
            module: lowered, fileScope: scope, header: header, programBase: programBase,
            ffiConfig: ffiConfig)
    }
}

/// G41 原单文件语义（模块外单文件向后兼容路径）。
private func runSingleFileTests(path: String, channel: TestChannel = .interpreter) throws {
    let source = try readFile(path)
    let checkResult = checkSingleFileDiagnostics(source: source, fileName: path)
    for d in checkResult.diagnostics {
        FileHandle.standardError.write(Data((d + "\n").utf8))
    }
    if checkResult.hasBlockingDiagnostics { exit(1) }
    let lexer = Lexer(source: source, fileName: path)
    let tokens = try lexer.tokenize()
    let parser = Parser(tokens: tokens, fileName: path)
    let module = try parser.parseModule()
    // Phase 2b（解释器 dlsym 加载）：单文件测试若位于含清单的模块内，加载其 `[ffi]` 配置，
    // 使 foreign 块经 search_paths 解析到项目内依赖（如 vendored lib/），而非依赖 cwd 或系统库。
    let dir = (path as NSString).deletingLastPathComponent
    let manifest = try? FileLoader.loadManifest(directory: dir)
    // 单文件测试基准 = 该文件所在目录。
    let runner = ProgramRunner(
        ffiConfig: manifest?.ffi ?? .default,
        programBase: absoluteProgramBase(path))

    // 报告首行：两条通道同一个字符串（同 `gateAndRunTests` 的理由）。
    let header = "测试文件: \(path)"

    switch channel {
    case .interpreter:
        let results = try runner.runTests(module: module)
        var passed = 0, failed = 0
        print(header)
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

    case .llvm:
        let lowered = try runner.lowerTests(module: module)
        try emitAndRunLLVMTests(
            module: lowered, fileScope: nil, header: header,
            programBase: absoluteProgramBase(path),
            ffiConfig: manifest?.ffi)
    }
}

// LLVM 通道的测试运行：发射（测试模式）→ 建链 → 运行 → 退出码透传。本函数不产出报告，
// 报告由产物自己给出（发射侧按测试模式合成），故它只剩落盘 `.ll`、调 clang、交子进程状态三件事。
// 退出码必须透传（丢掉会让 abort 被读成 rc=0、判据恒绿）；测试模式允许模块无 `main`，入口由发射器合成。
func emitAndRunLLVMTests(
    module: IRModule, fileScope: ((String) -> Bool)?, header: String, programBase: String?,
    ffiConfig: FFIConfig? = nil
) throws {
    // 选中面：与解释器同规 —— 按文件收窄的是**跑哪些**， 行不通  不是「能看到什么」。
    //  注意  清单顺序即执行顺序；取不到时（`fileScope` 为空）为 nil，由发射器按模块声明序全收。
    try IRValidator.check(module)
    let selection: [String]? = fileScope.map { scope in
        module.functions.filter { $0.isTest && scope($0.sourceFile) }.map { $0.name }
    }

    let emitter = IREmitter()
    emitter.programBase = programBase
    emitter.testReportHeader = header
    emitter.testSelection = selection
    let ir = try emitter.emit(module: module)

    let tmpIR = "/tmp/pini_\(UUID().uuidString).ll"
    let tmpBin = "/tmp/pini_\(UUID().uuidString)"
    try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)
    // 调试出口：把测试模式的产物留一份（与本文件既有 `PINI_RUNTIME_LIB` / 借助 `PINI_LLVM_BIN`
    // 的惯例同规）。 注意  存在的理由很具体：本通道的产物是**合成**出来的（驱动器 + 入口），
    // 出问题时 clang 的报错只给行号，而临时文件随后就被删了 —— 没有这一手就只能靠猜。
    if let keep = ProcessInfo.processInfo.environment["PINI_TEST_LLVM_IR"] {
        try? ir.write(toFile: keep, atomically: true, encoding: .utf8)
    }
    defer {
        try? FileManager.default.removeItem(atPath: tmpIR)
        try? FileManager.default.removeItem(atPath: tmpBin)
    }

    guard let clang = LLVMToolchain.clangPath else {
        throw NSError(
            domain: "ToolchainError", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "clang not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN."])
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clang)
    var clangArgs = ["-o", tmpBin, tmpIR]
    if let dylib = runtimeLibraryPath() {
        let dir = (dylib as NSString).deletingLastPathComponent
        clangArgs.insert(contentsOf: ["-L\(dir)", "-lPiniRuntime", "-Wl,-rpath,\(dir)"], at: 0)
    }
    // 测试跑在 LLVM 通道上时，foreign 符号同样要靠清单里的 `libs` 落定。
    let foreign = foreignLinkArguments(ffiConfig)
    if !foreign.isEmpty { clangArgs.insert(contentsOf: foreign, at: 0) }
    process.arguments = clangArgs
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readAllData()
        let err = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
            domain: "CompileError", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "clang failed: \(err)"])
    }

    let run = Process()
    run.executableURL = URL(fileURLWithPath: tmpBin)
    try run.run()
    run.waitUntilExit()
    exit(childExitStatus(of: run))
}

// check / build 接收文件或目录：文件 → 单文件收集式 check；目录含 `pini.toml` → 显式多文件模块，
// 跨文件 analyze/check 首个错误即报；目录无清单 → 逐 `.pini` 独立 check，并跳过嵌套模块子目录。
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
        // build 漂移检查（run 同款；仅对采用依赖通道的清单生效）。
        let driftResult = Result {
            try ModuleToolchain.checkRequireImportAlignment(
                rootDir: absoluteProgramBase(path), manifest: manifest, package: pkg)
        }
        if case .success(.some(let drift)) = driftResult, drift.hasDrift {
            var parts: [String] = []
            if !drift.missingInRequire.isEmpty {
                parts.append("import 了但 [require] 缺失：\(drift.missingInRequire.joined(separator: ", "))")
            }
            if !drift.extraInRequire.isEmpty {
                parts.append("[require] 有但未 import：\(drift.extraInRequire.joined(separator: ", "))")
            }
            printError("Error: 依赖清单与代码漂移——\(parts.joined(separator: "；"))。请运行 `pini mod tidy`")
            exit(1)
        }
        do {
            let analyzer = SemanticAnalyzer()
            try analyzer.analyze(package: pkg)
            emitSemanticWarnings(analyzer)
            let checker = TypeChecker()
            try checker.check(package: pkg)
            /// 宏常量在检查阶段就求值：值展不开是声明或配置的问题，不该等到运行才显形。
            _ = try evaluateForeignMacros(
                symbols: pkg.fileUnits.flatMap { foreignSymbols(in: $0.module) },
                config: manifest.ffi ?? .default)
            for warning in givenCycleWarnings(package: pkg, checker: checker) {
                emitSemanticWarning(warning)
            }
            print("检查通过（模块 \(pkg.name)，\(pkg.fileUnits.count) 个文件）：\(path)")
            CommentStyleHint.emit()
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
            .filter { $0.hasSuffix(LangConfig.sourceSuffix) && !$0.contains("__MACOSX") && !FileLoader.isInsideDotPath($0) }  // R5 点前缀不扫描
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
        let checkResult = checkSingleFileDiagnostics(source: source, fileName: fileName)
        if !checkResult.diagnostics.isEmpty {
            for d in checkResult.diagnostics {
                FileHandle.standardError.write(Data(("\(fileName): " + d + "\n").utf8))
            }
        }
        if checkResult.hasBlockingDiagnostics { failed.append(fileName) }
    }
    if !failed.isEmpty { exit(1) }
    print("检查通过（\(files.count) 个独立文件）：\(path)")
    CommentStyleHint.emit()
}

/// 判断某 `.pini`（相对路径）是否位于「含自身 pini.toml 的嵌套模块目录」内；
/// 若是则其归属该嵌套模块，父级目录的逐文件 check 应跳过，避免误报未定义符号。
private func isInsideNestedModule(_ relativeBkPath: String, root: String) -> Bool {
    var dir = (root as NSString).appendingPathComponent(
        (relativeBkPath as NSString).deletingLastPathComponent)
    while dir != root {
        if FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("pini.toml"))
        {
            return true
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return false
}

/// 入口要求的三种口径：`main` 只有「要落地成进程」时才必需，库模块没有它是常态。
/// 判「是不是库」只看 export 块里有没有 `|c` 条目 —— 那是模块对外发布 C 面的唯一声明。
private enum EntryPolicy {
    /// 可执行程序：`compile` 与 `run-llvm` 都要跑起来，缺 `main` 就到不了。
    case required
    /// 发布面：带 `|c` 条目时放行，其余模块照旧要求入口，免得漏写 `main` 的程序安静出产物。
    case waivedForLibrary
    /// 共享库：产物是库，与模块内容无关。
    case notRequired

    func requiresMain(hasCSurface: Bool) -> Bool {
        switch self {
        case .required:
            return true
        case .waivedForLibrary:
            return !hasCSurface
        case .notRequired:
            return false
        }
    }
}

/// 模块里有没有 `|c` 条目：这是「算不算 C 库」的唯一判据，单文件与包共用。
private func hasCSurface(_ exports: [ExportDecl]) -> Bool {
    exports.contains { block in
        block.entries.contains { $0.target == .c }
    }
}

/// LLVM 管线先类型检查，再以类型推断结果降载到 IR：零类型信息的 codegen 解构不了 Optional.some。
/// 与解释器同一套静态校验；类型错误一次性同报并退出（同 `runCheckCommand` 的收集模式）。
/// - Parameter policy: 入口要求，由命令决定；判据见 `EntryPolicy`。
private func lowerSingleFile(
    source: String, fileName: String, policy: EntryPolicy
) throws -> IRModule {
    let module = parseOrReport(source: source, fileName: fileName)
    // The semantic layer gates here for the same reason `check` runs it before the type layer:
    // it enforces capture declarations, undefined names and visibility. A check that runs ahead of
    // only one backend is not a check, it is a backend trait -- it hides E3-008 divergences.
    let analyzer = SemanticAnalyzer()
    let semanticErrors = analyzer.analyzeCollecting(module: module)
    if !semanticErrors.isEmpty {
        for e in semanticErrors {
            FileHandle.standardError.write(
                Data((ErrorFormatter.formatSemanticError(e, source: source) + "\n").utf8))
        }
        exit(1)
    }
    let checker = TypeChecker()
    let typeErrors = checker.checkCollecting(module: module)
    if !typeErrors.isEmpty {
        for e in typeErrors {
            FileHandle.standardError.write(Data((ErrorFormatter.formatTypeError(e, source: source) + "\n").utf8))
        }
        exit(1)
    }
    // 开启持久表兜底：codegen 重推 match scrutinee 类型时不受 check 后作用域 pop 影响。
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    let irModule = try IRLowerer.lower(
        module: module, typeInference: checker.typeInference,
        foreignConstants: try evaluateForeignMacros(
            symbols: foreignSymbols(in: module), config: .default),
        requiresMain: policy.requiresMain(hasCSurface: hasCSurface(module.exports)))
    /// 结构不变量先过一遍：后端读 IR 时按它们取槽、取字段、取用例，破了就是进程信号而不是诊断。
    try IRValidator.check(irModule)
    return irModule
}

/// - Parameter policy: 入口要求，与 `lowerSingleFile` 同一口径。
private func typeCheckThenGenerate(
    source: String, fileName: String, policy: EntryPolicy, backend: any PiniBackend = IREmitter()
) throws -> String {
    let irModule = try lowerSingleFile(source: source, fileName: fileName, policy: policy)
    // 注入程序基准，与解释器同规则。需要它的通道自己覆写，其余保持默认。
    backend.setProgramBase(absoluteProgramBase(fileName))
    return try backend.emit(module: irModule)
}

func runEmitCommand(
    source: String, fileName: String, outputPath: String?, backend: any PiniBackend = IREmitter()
) throws {
    // 发布面两种模块都收：程序有 `main`，库有 `|c` 条目，各自都是完整声明，故按内容判入口。
    let ir = try typeCheckThenGenerate(
        source: source, fileName: fileName, policy: .waivedForLibrary, backend: backend)

    if let out = outputPath {
        try ir.write(toFile: out, atomically: true, encoding: .utf8)
    } else {
        print(ir)
    }
}

// If `path` sits inside a manifest module (a `pini.toml` at or above its directory), load that
// whole module as a `Package` -- the same entry `pini run <dir>` uses; nil for a bare file or a
// directory path. Nested dirs resolve upward like the checker; the root returns with the package.
private func loadOwningPackageIfModule(path: String) throws -> (package: Package, moduleRoot: String)? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
        !isDir.boolValue
    else { return nil }
    guard let moduleRoot = try FileLoader.locateModuleRoot(for: path) else { return nil }
    let manifest = try FileLoader.loadManifest(directory: moduleRoot)
    return try (FileLoader.loadDirectory(path: moduleRoot, manifest: manifest), moduleRoot)
}

// Package-level IR emit: package semantic + type-check, then `IRLowerer.lower(package:)` ->
// IREmitter. The checker already enforced visibility (D4), so the IR channel re-enforces nothing.
// `moduleRoot` is the package's own directory: the whole package is lowered as one unit.
private func runIRPackageEmit(
    package: Package, moduleRoot: String, outputPath: String?,
    backend: any PiniBackend = IREmitter()
) throws {
    let irModule = try lowerPackage(package: package, moduleRoot: moduleRoot, policy: .waivedForLibrary)
    // 模块基准 = 模块根，与解释器模块路径一致。
    backend.setProgramBase(absoluteProgramBase(moduleRoot))
    let ir = try backend.emit(module: irModule)
    if let out = outputPath {
        try ir.write(toFile: out, atomically: true, encoding: .utf8)
    } else {
        print(ir)
    }
}

/// 包级降载：语义 → 类型 → IR → 结构校验。`emit` 与 `build --shared` 共用这一份 —— 各抄一份就会在
/// 「少一次语义分析」这类分叉上静默漂移，而两条命令读的必须是同一棵树。
/// - Parameter policy: 入口要求，与 `lowerSingleFile` 同一口径。
private func lowerPackage(
    package: Package, moduleRoot: String, policy: EntryPolicy
) throws -> IRModule {
    let analyzer = SemanticAnalyzer()
    try analyzer.analyze(package: package)
    let checker = TypeChecker()
    try checker.check(package: package)
    // Same persistent-table fallback as the single-file pipeline.
    checker.typeInference.environment?.persistAcrossScopesForCodegen = true
    let irModule = try IRLowerer.lower(
        package: package, typeInference: checker.typeInference,
        foreignConstants: try evaluateForeignMacros(
            symbols: package.fileUnits.flatMap { foreignSymbols(in: $0.module) },
            config: (try? FileLoader.loadManifest(directory: moduleRoot))?.ffi ?? .default),
        requiresMain: policy.requiresMain(
            hasCSurface: package.fileUnits.contains { hasCSurface($0.module.exports) }))
    try IRValidator.check(irModule)
    return irModule
}

// 定位集合运行时动态库：优先 env `PINI_RUNTIME_LIB`，否则取 CLI 可执行文件
// 同级目录的 `libPiniRuntime.{dylib,so}`；找不到返回 nil，调用方据此 best-effort 跳过加载。
private func runtimeLibraryPath() -> String? {
    if let override = ProcessInfo.processInfo.environment["PINI_RUNTIME_LIB"],
        !override.isEmpty, FileManager.default.fileExists(atPath: override)
    {
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


/// 清单 `[ffi]` 的链接口径。块名不参与：foreign 块名只决定解释器默认加载 `lib<块名>`，
/// 与链接哪几个库无关 —— 库名由 `libs` 显式给出，两者可以脱钩。
/// 没有清单或清单没写 `[ffi]` 时答 nil：没有声明过的库，就没有链接参数可加。
private func foreignConfig(around path: String) throws -> FFIConfig? {
    guard let root = try FileLoader.locateModuleRoot(for: path) else { return nil }
    return try FileLoader.loadManifest(directory: root)?.ffi
}

/// `search_paths` → `-L`（非系统目录另加 rpath），`libs` → `-l`。
/// rpath 只给非系统目录：vendored 库的 install name 常是裸文件名，缺它在编译期看不出来，
/// 运行期才报找不到映像。
private func foreignLinkArguments(_ config: FFIConfig?) -> [String] {
    guard let config else { return [] }
    let systemDirs: Set<String> = ["/usr/lib", "/usr/local/lib"]
    var args: [String] = []
    for dir in config.searchPaths where FileManager.default.fileExists(atPath: dir) {
        args.append("-L\(dir)")
        if !systemDirs.contains(dir) { args.append("-Wl,-rpath,\(dir)") }
    }
    args += config.libs.map { "-l\($0)" }
    return args
}

/// 按 `search_paths` 找 `lib<名称>.{dylib,so}`，与解释器 `FFILoader` 的命名同规。
private func libraryPath(named name: String, in searchPaths: [String]) -> String? {
    for dir in searchPaths {
        for ext in ["dylib", "so"] {
            let candidate = (dir as NSString).appendingPathComponent("lib\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
    }
    return nil
}

func runCompileCommand(source: String, fileName: String) throws {
    let ir = try typeCheckThenGenerate(source: source, fileName: fileName, policy: .required)

    let tmpIR = "/tmp/pini_\(UUID().uuidString).ll"
    let tmpBin = "/tmp/pini_\(UUID().uuidString)"
    try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

    defer {
        try? FileManager.default.removeItem(atPath: tmpIR)
        try? FileManager.default.removeItem(atPath: tmpBin)
    }

    guard let clang = LLVMToolchain.clangPath else {
        throw NSError(
            domain: "ToolchainError", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "clang not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN."])
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clang)
    // 并发后端抽象 阶段1：链接集合运行时（best-effort，找不到则跳过——非集合程序无需）。
    var clangArgs = ["-o", tmpBin, tmpIR]
    if let dylib = runtimeLibraryPath() {
        let dir = (dylib as NSString).deletingLastPathComponent
        clangArgs.insert(contentsOf: ["-L\(dir)", "-lPiniRuntime", "-Wl,-rpath,\(dir)"], at: 0)
    }
    // `[ffi]` 声明的外部库：解释器经 dlsym，这里经链接器，两条通道读同一份清单。
    let foreign = foreignLinkArguments(try foreignConfig(around: fileName))
    if !foreign.isEmpty { clangArgs.insert(contentsOf: foreign, at: 0) }
    process.arguments = clangArgs
    let pipe = Pipe()
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readAllData()
        let err = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
            domain: "CompileError", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "clang failed: \(err)"])
    }

    let run = Process()
    run.executableURL = URL(fileURLWithPath: tmpBin)
    try run.run()
    run.waitUntilExit()
    // 把子进程的退出码交出去：丢掉它会让 `pini compile` 对一个 abort 掉的程序报 rc=0，而本仓门禁
    // 正是看退出码（三态 0/1/2），任何建在 `compile` / `run-llvm` 上的判据都会恒绿。
    exit(childExitStatus(of: run))
}

/// 子进程的退出码，按 **shell 惯例**归一：被信号杀死 ⇒ `128 + 信号`（`abort()` ⇒ 134），
/// 而不是 `terminationStatus` 直接给出的裸信号号（那会是 6）。两者都非零、都能判失败，
/// 但惯例那一支才是调用方（与人）预期的数。
func childExitStatus(of process: Process) -> Int32 {
    if process.terminationReason == .uncaughtSignal {
        return 128 + process.terminationStatus
    }
    return process.terminationStatus
}

// MARK: - 共享库产物

/// `build --shared` 的失败面：路径、C 面、工具链与链接器各一类，消息直接指向下一步动作。
struct SharedBuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `build --shared` 一条命令出库：降载 → 发 IR → clang 链成动态库。库没有进程入口，故不要求 `main`。
/// 产物名取自 export 块的文件名（已转写成 C 标识符），调用方按同一个名字写 `-l`。
func runBuildShared(path: String, outputPath: String?) {
    do {
        let (irModule, programBase) = try lowerForShared(path: path)
        guard let export = irModule.export else {
            throw SharedBuildError(
                message: "模块没有带 `|c` 条目的 export 块 —— C 符号由条目决定，产物名取文件名")
        }
        let emitter = IREmitter()
        emitter.setProgramBase(programBase)
        let ir = try emitter.emit(module: irModule)
        let irPath = NSTemporaryDirectory() + "pini_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: irPath) }
        try ir.write(toFile: irPath, atomically: true, encoding: .utf8)
        let libraryPath = sharedLibraryPath(outputPath, blockName: export.name)
        // 父目录不存在时先建：`-o out/libx.dylib` 是最常见的写法，让链接器去报 open() 失败读不出原因。
        let parent = (libraryPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true)
        }
        try linkSharedLibrary(
            irPath: irPath, outputPath: libraryPath, ffiConfig: try foreignConfig(around: path))
        print("已生成 \(libraryPath)")
        CommentStyleHint.emit()
    } catch {
        printError(formatCLIError(error: error, source: nil))
        exit(1)
    }
}

/// 共享库的降载入口：单文件、模块内文件、含 `pini.toml` 的目录三条路都收。
/// 目录没有清单时拒绝 —— 散放的多份文件各是独立程序，拼不出一个 C 面。
private func lowerForShared(path: String) throws -> (module: IRModule, programBase: String) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        throw SharedBuildError(message: "路径不存在：\(path)")
    }
    if isDir.boolValue {
        guard let manifest = try FileLoader.loadManifest(directory: path) else {
            throw SharedBuildError(
                message: "目录里没有 pini.toml：共享库要一个模块，散放的多份文件各是独立程序")
        }
        let package = try FileLoader.loadDirectory(path: path, manifest: manifest)
        return (
            try lowerPackage(package: package, moduleRoot: path, policy: .notRequired),
            absoluteProgramBase(path)
        )
    }
    if let loaded = try loadOwningPackageIfModule(path: path) {
        return (
            try lowerPackage(
                package: loaded.package, moduleRoot: loaded.moduleRoot, policy: .notRequired),
            absoluteProgramBase(loaded.moduleRoot)
        )
    }
    let source = try readFile(path)
    return (
        try lowerSingleFile(source: source, fileName: path, policy: .notRequired),
        absoluteProgramBase(path)
    )
}

/// 产物落点：`-o` 说了算；没给时按块名落在当前目录。`-o` 指到已存在的目录时，文件名仍按块名补。
private func sharedLibraryPath(_ outputPath: String?, blockName: String) -> String {
    #if os(macOS)
    let suffix = "dylib"
    #else
    let suffix = "so"
    #endif
    let fileName = "lib\(blockName).\(suffix)"
    guard let outputPath, !outputPath.isEmpty else {
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(fileName)
    }
    var isDir: ObjCBool = false
    let pointsAtDirectory =
        (FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDir) && isDir.boolValue)
        || outputPath.hasSuffix("/")
    if pointsAtDirectory {
        return (outputPath as NSString).appendingPathComponent(fileName)
    }
    return outputPath
}

/// 交给 clang 链成动态库：运行时动态链接，并把它的目录写进 rpath，否则调用方加载时找不到符号。
/// 缺 clang 或运行时直接失败 —— 发一个注定加载不了的库，比不发更难排查。
private func linkSharedLibrary(
    irPath: String, outputPath: String, ffiConfig: FFIConfig? = nil
) throws {
    guard let clang = LLVMToolchain.clangPath else {
        throw SharedBuildError(
            message: "clang not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN.")
    }
    guard let runtime = runtimeLibraryPath() else {
        throw SharedBuildError(
            message: "找不到 libPiniRuntime.{dylib,so}：它与 pini 可执行文件同目录，或用 PINI_RUNTIME_LIB 指定")
    }
    let runtimeDir = (runtime as NSString).deletingLastPathComponent
    var clangArgs = [
        "-shared", "-o", outputPath, irPath,
        "-L\(runtimeDir)", "-lPiniRuntime", "-Wl,-rpath,\(runtimeDir)",
    ]
    // 库自己也可能调外部 C：`[ffi]` 的 `libs` 决定链接什么，缺了它符号落不下来。
    clangArgs.insert(contentsOf: foreignLinkArguments(ffiConfig), at: 0)
    #if !os(macOS)
    // Darwin 的 `-shared` 默认就要求符号全部落定；GNU ld 相反，不加这条会把缺符号的库静默发出去。
    clangArgs.insert("-Wl,--no-undefined", at: 0)
    #endif
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clang)
    process.arguments = clangArgs
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    let errData = pipe.fileHandleForReading.readAllData()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let err = String(decoding: errData, as: UTF8.self)
        throw SharedBuildError(
            message: "clang 链接失败（rc=\(process.terminationStatus)）：\(err)")
    }
}

func runLLICommand(source: String, fileName: String) throws {
    let ir = try typeCheckThenGenerate(source: source, fileName: fileName, policy: .required)

    let tmpIR = "/tmp/pini_\(UUID().uuidString).ll"
    defer { try? FileManager.default.removeItem(atPath: tmpIR) }
    try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

    guard let lli = LLVMToolchain.lliPath else {
        throw NSError(
            domain: "ToolchainError", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "lli not found. Install LLVM (e.g. `brew install llvm`) or set PINI_LLVM_BIN."])
    }
    var lliArgs = [tmpIR]
    // 并发后端抽象 阶段1：加载集合运行时（best-effort，找不到则跳过——非集合程序无需）。
    if let dylib = runtimeLibraryPath() {
        lliArgs.insert("--dlopen=\(dylib)", at: 0)
    }
    // `[ffi]` 的库：lli 没有链接期，只能把映像预载进 JIT。找不到的不报错 ——
    // 系统库在 macOS 上位于共享缓存、磁盘上没有文件，抢先报错会误伤它们；
    // 真缺符号时 lli 自己的 undefined symbol 更准确。
    let ffi = try foreignConfig(around: fileName)
    for lib in ffi?.libs ?? [] {
        if let path = libraryPath(named: lib, in: ffi?.searchPaths ?? []) {
            lliArgs.insert("--dlopen=\(path)", at: 0)
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lli)
    process.arguments = lliArgs

    try process.run()
    process.waitUntilExit()
    // 同上（`runCompileCommand` 的注释有完整理由）：状态必须交出去， 行不通  不能丢。
    exit(childExitStatus(of: process))
}

func handleSemanticError(_ error: SemanticError) {
    // T11（A4）：收敛消息源——check 多文件路径复用 ErrorFormatter，源码按诊断位置回读。
    printError(ErrorFormatter.formatSemanticError(error, source: sourceFor(error)))
}

func handleTypeError(_ error: TypeError) {
    printError(ErrorFormatter.formatTypeError(error, source: sourceFor(error)))
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
    // 通道拒绝不是语言诊断：它说的是「这条路走不了」，故按通道自己的话说，不套诊断码。
    if let backend = error as? BackendError {
        return "Error: \(backend.description)"
    }
    return "Error: \(error.localizedDescription)"
}

// MARK: - Main Entry Point

// 执行线程栈放大：深递归命令在主线程 8MB 栈上被递归守卫限深（单帧 ≈47–80KB，有效深度 ~85）。
// 守卫语义健康（1/8 栈安全垫 + 实况读数），瓶颈是栈供给 ⇒ 把 CLI 逻辑搬进 64MB 栈的工作线程
// 重入一次，守卫读实况自动适配（深度 ×8），语义零改动；重入标记走 setenv，主线程 wait 后统一退。
let alreadyWidened = ProcessInfo.processInfo.environment["PINI_STACK_WIDENED"] != nil
if !alreadyWidened {
    setenv("PINI_STACK_WIDENED", "1", 1)
    let sem = DispatchSemaphore(value: 0)
    let cliThread = Thread {
        cliMain()
        sem.signal()
    }
    cliThread.stackSize = 256 * 1024 * 1024
    cliThread.name = "pini-cli-256MB"
    cliThread.start()
    sem.wait()
    exit(0)
}

func cliMain() {
var args = CommandLine.arguments

// T11（A4）：--lang zh|en 诊断语言（TOML 资源驱动；默认 zh，未覆盖码回退 zh）。
// 解析后从 args 移除该参数对，避免干扰命令的路径/子参数解析。
if let langIdx = args.firstIndex(of: "--lang"), langIdx + 1 < args.count,
    let lang = DiagnosticLanguage(rawValue: args[langIdx + 1])
{
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
    var parseRest = Array(args.dropFirst(2))
    let signaturesOnly = parseRest.contains("--sig")
    if signaturesOnly {
        parseRest.removeAll { $0 == "--sig" }
    }
    guard let filePath = parseRest.first else {
        printError("Error: parse command requires a file path")
        exit(1)
    }
    let source: String
    do {
        source = try readFile(filePath)
    } catch {
        printError("Error: \(error.localizedDescription)")
        exit(1)
    }
    do {
        try runParseCommand(source: source, fileName: filePath, signaturesOnly: signaturesOnly)
    } catch {
        printError(formatCLIError(error: error, source: source))
        exit(1)
    }
case "run":
    guard args.count >= 3 else {
        printError("Error: run command requires a file or directory path")
        exit(1)
    }
    runRunPath(args[2], argv: Array(args.dropFirst(3)))
case "mod":
    runModCommand(Array(args.dropFirst(2)))
case "repl":
    ReplSession().run()
    exit(0)
case "check":
    guard args.count >= 3 else {
        printError("Error: \(command) command requires a file or directory path")
        exit(1)
    }
    if let unknown = args.dropFirst(3).first(where: { $0.hasPrefix("--") }) {
        printError("Error: \(unknown)")
        printError("  合法用法：pini \(command) <路径>")
        exit(1)
    }
    runCheckPath(args[2])
case "build":
    var shared = false
    var outputPath: String?
    var positional: [String] = []
    var cursor = 2
    while cursor < args.count {
        switch args[cursor] {
        case "--shared":
            shared = true
            cursor += 1
        case "-o":
            guard cursor + 1 < args.count else {
                printError("Error: -o 需要一个输出路径")
                exit(1)
            }
            outputPath = args[cursor + 1]
            cursor += 2
        default:
            guard !args[cursor].hasPrefix("-") else {
                printError("Error: \(args[cursor])")
                printError("  合法用法：pini build <路径>｜pini build --shared <路径> [-o <产物路径>]")
                exit(1)
            }
            positional.append(args[cursor])
            cursor += 1
        }
    }
    guard let path = positional.first else {
        printError("Error: build command requires a file or directory path")
        exit(1)
    }
    if shared {
        runBuildShared(path: path, outputPath: outputPath)
    } else {
        guard outputPath == nil else {
            printError("Error: -o 只跟 --shared 一起用")
            exit(1)
        }
        runCheckPath(path)
    }
case "test":
    // 测试子命令：path 可选；无参 = 收集当前目录所属模块根。
    runTestPath(args.count >= 3 ? args[2] : nil)
case "test-llvm":
    // 与 `test` **同一套**收集范围、门禁与报告；差别只在最后一步跑在 LLVM 通道上
    // （发射成原生程序再运行）。命名照 `run` / `run-llvm` 的既有惯例。
    runTestPath(args.count >= 3 ? args[2] : nil, channel: .llvm)
case "backends":
    printBackendMatrix(tsv: args.contains("--tsv"))
case "emit":
    guard args.count >= 3 else {
        printError("Error: emit command requires a file path")
        exit(1)
    }
    do {
        // 选项从位置参数里挑出来：`--backend <name>` 与 `-o <path>`，剩下的是源文件与可选输出文件。
        //  注意  不认识的 `-` 开头参数一律报错 —— 当成路径收下会静默写到错误的名字上。
        var backendName = Backends.registry.defaultIdentifier
        var flagOutput: String?
        var positional: [String] = []
        var cursor = 2
        while cursor < args.count {
            switch args[cursor] {
            case "--backend":
                guard cursor + 1 < args.count else {
                    printError("Error: --backend 需要一个名字")
                    exit(1)
                }
                backendName = args[cursor + 1]
                cursor += 2
            case "-o":
                guard cursor + 1 < args.count else {
                    printError("Error: -o 需要一个输出路径")
                    exit(1)
                }
                flagOutput = args[cursor + 1]
                cursor += 2
            default:
                guard !args[cursor].hasPrefix("-") else {
                    printError("Error: \(args[cursor])")
                    printError("  合法用法：pini emit <file.pini> [-o <输出路径>] [--backend <name>]")
                    exit(1)
                }
                positional.append(args[cursor])
                cursor += 1
            }
        }
        guard let backend = Backends.registry.make(backendName) else {
            printError(
                "Error: unknown backend '\(backendName)'. Available: "
                    + Backends.registry.identifiers.joined(separator: ", "))
            exit(1)
        }
        guard let path = positional.first else {
            printError("Error: emit command requires a file path")
            exit(1)
        }
        guard positional.count <= 2 else {
            printError("Error: emit 只收一个源文件与一个输出文件")
            printError("  合法用法：pini emit <file.pini> [-o <输出路径>] [--backend <name>]")
            exit(1)
        }
        guard !(flagOutput != nil && positional.count == 2) else {
            printError("Error: 输出路径给了两次（位置参数与 -o）")
            exit(1)
        }
        let outputPath = flagOutput ?? (positional.count == 2 ? positional[1] : nil)
        // A file inside a manifest module runs through the package pipeline, which lowers the whole
        // package; a bare file outside any module keeps single-file behavior. Directory arguments are
        // not accepted here, so no directory branch is added.
        if let loaded = try loadOwningPackageIfModule(path: path) {
            try runIRPackageEmit(
                package: loaded.package, moduleRoot: loaded.moduleRoot,
                outputPath: outputPath, backend: backend)
        } else {
            let source = try readFile(path)
            try runEmitCommand(
                source: source, fileName: path, outputPath: outputPath, backend: backend)
        }
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
}
