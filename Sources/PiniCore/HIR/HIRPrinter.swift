import Foundation

/// Human-readable dump of a lowered HIR module. Debug aid for differential
/// troubleshooting: when the new pipeline and the interpreter disagree, this
/// dump shows exactly what the lowerer produced before emission.
public enum HIRPrinter {

    public static func dump(module: HIRModule) -> String {
        var out: [String] = []
        for function in module.functions {
            out.append(signatureLine(of: function))
            out.append(contentsOf: dumpBody(function.body, indent: 1))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func signatureLine(of function: HIRFunction) -> String {
        let params = function.params
            .map { "\($0.name): \($0.type.llvmSpelling)" }
            .joined(separator: ", ")
        let ret = function.returnType.map { " -> \($0.llvmSpelling)" } ?? ""
        return "func \(function.name)(\(params))\(ret):"
    }

    private static func dumpBody(_ body: HIRBlock, indent: Int) -> [String] {
        body.flatMap { dumpStmt($0, indent: indent) }
    }

    private static func indent(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }

    private static func dumpStmt(_ statement: HIRStmt, indent level: Int) -> [String] {
        let pad = indent(level)
        switch statement {
        case .allocVar(let name, let type, let mutable, let initializer):
            let kw = mutable ? "var" : "let"
            let initPart = initializer.map { " = \(exprText($0))" } ?? ""
            return ["\(pad)\(kw) \(name): \(type.llvmSpelling)\(initPart)"]
        case .storeVar(let name, _, let value):
            return ["\(pad)\(name) = \(exprText(value))"]
        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            // ADR-039: a labeled `if` prints its label, mirroring the source
            // form `label|if cond:`. An unlabeled `if` prints exactly as
            // before, so existing printer snapshots do not move.
            let labelPart = label.map { "\($0)|" } ?? ""
            var lines = ["\(pad)\(labelPart)if \(exprText(condition)):"]
            lines.append(contentsOf: dumpBody(thenBody, indent: level + 1))
            if let elseBody = elseBody {
                lines.append("\(pad)else:")
                lines.append(contentsOf: dumpBody(elseBody, indent: level + 1))
            }
            return lines
        case .whileStmt(let condition, let body, let step):
            var lines = ["\(pad)while \(exprText(condition)):"]
            lines.append(contentsOf: dumpBody(body, indent: level + 1))
            if let step = step {
                lines.append("\(pad)step:")
                lines.append(contentsOf: dumpBody(step, indent: level + 1))
            }
            return lines
        case .forInStmt(let pattern, let elementTypes, let kind, let iterable, let body, let step):
            let bindings = pattern.enumerated()
                .map { index, name in
                    let type = index < elementTypes.count ? elementTypes[index].llvmSpelling : "?"
                    return "\(name): \(type)"
                }
                .joined(separator: ", ")
            var lines = ["\(pad)for (\(bindings)) in \(kind) \(exprText(iterable)):"]
            lines.append(contentsOf: dumpBody(body, indent: level + 1))
            if let step = step {
                lines.append("\(pad)step:")
                lines.append(contentsOf: dumpBody(step, indent: level + 1))
            }
            return lines
        case .returnStmt(let value):
            return ["\(pad)return\(value.map { " " + exprText($0) } ?? "")"]
        case .exprStmt(let expression):
            return ["\(pad)\(exprText(expression))"]
        case .deferStmt(let body):
            var lines = ["\(pad)defer:"]
            lines.append(contentsOf: dumpBody(body, indent: level + 1))
            return lines
        case .tryStmt(let operand, let errorVar, let handler, let okTarget, _):
            let bind = okTarget.map { " -> \($0)" } ?? ""
            var lines = ["\(pad)try \(exprText(operand)) else \(errorVar)\(bind):"]
            lines.append(contentsOf: dumpBody(handler, indent: level + 1))
            return lines
        case .subscriptStore(let container, let index, let value, _):
            return ["\(pad)\(exprText(container))[\(exprText(index))] = \(exprText(value))"]
        case .breakStmt(let depth):
            return ["\(pad)break\(depth > 1 ? " (x\(depth))" : "")"]
        case .continueStmt(let depth):
            return ["\(pad)continue\(depth > 1 ? " (x\(depth))" : "")"]
        case .panicStmt(let message):
            return ["\(pad)panic(\"\(message)\")"]
        case .matchStmt(let scrutinee, let cases, _):
            var lines = ["\(pad)match \(exprText(scrutinee)):"]
            for matchCase in cases {
                let binds = matchCase.bindings.map { $0 ?? "_" }.joined(separator: ", ")
                let bind = binds.isEmpty ? "" : "(\(binds))"
                lines.append("\(pad)    case \(matchCase.caseName)\(bind):")
                lines.append(contentsOf: dumpBody(matchCase.body, indent: level + 2))
            }
            return lines
        case .fieldStore(let base, let field, let value, _):
            return ["\(pad)\(exprText(base)).\(field) = \(exprText(value))"]
        case .captureMarker(let name):
            return ["\(pad)capture \(name)"]
        }
    }

    private static func exprText(_ expression: HIRExpr) -> String {
        switch expression {
        case .intConst(let value, _): return "\(value)"
        case .floatConst(let value): return "\(value)"
        case .boolConst(let value): return value ? "true" : "false"
        case .stringConst(let value): return "\"\(value)\""
        case .load(let name, let type): return "\(name)@\(type.llvmSpelling)"
        case .binary(let op, let lhs, let rhs, _):
            return "(\(exprText(lhs)) \(symbol(of: op)) \(exprText(rhs)))"
        case .unary(let op, let operand, _):
            return "(\(op == .negate ? "-" : "!")\(exprText(operand)))"
        case .call(let function, let arguments, _):
            let args = arguments.map(exprText).joined(separator: ", ")
            return "\(function)(\(args))"
        case .printCall(let argument):
            return "print(\(exprText(argument)))"
        case .resultConstruct(let isOk, let payload, _):
            return "\(isOk ? "ok" : "err")(\(exprText(payload)))"
        case .arrayLiteral(let elements, _):
            let items = elements.map(exprText).joined(separator: ", ")
            return "[\(items)]"
        case .subscriptGet(let container, let index, _):
            return "\(exprText(container))[\(exprText(index))]"
        case .lenCall(let argument):
            return "len(\(exprText(argument)))"
        case .optionalGet(let container, let index, _):
            return "\(exprText(container)).get(\(exprText(index)))"
        case .optionalConstruct(let isSome, let payload, _):
            if isSome, let payload = payload {
                return "some(\(exprText(payload)))"
            }
            return "none"
        case .sliceCall(let container, let start, let end, _):
            return "\(exprText(container)).slice(\(exprText(start)), \(exprText(end)))"
        case .construct(let type):
            return "\(type.llvmSpelling)()"
        case .enumConstruct(_, let caseName, _, let payloads, _, _):
            let items = payloads.map(exprText).joined(separator: ", ")
            return "\(caseName)(\(items))"
        case .dictLiteral(let entries, _):
            let items = entries.map { "\(exprText($0.key)) = \(exprText($0.value))" }.joined(separator: ", ")
            return "[\(items)]"
        case .setLiteral(let elements, _):
            let items = elements.map(exprText).joined(separator: ", ")
            return "{\(items)}"
        case .tupleConstruct(let labels, let elements, _):
            let items = elements.enumerated().map { index, element in
                let label = labels[index].map { "\($0) = " } ?? ""
                return label + exprText(element)
            }.joined(separator: ", ")
            return "(\(items))"
        case .tupleIndexGet(let base, let index, _):
            return "\(exprText(base)).#\(index)"
        case .fieldGet(let base, let field, let type):
            return "\(exprText(base)).\(field)@\(type.llvmSpelling)"
        case .stringCase(let isUpper, let receiver):
            return "\(exprText(receiver)).\(isUpper ? "upper" : "lower")()"
        case .stringContains(let receiver, let needle):
            return "\(exprText(receiver)).contains(\(exprText(needle)))"
        case .stringSubstring(let receiver, let start, let length):
            return "\(exprText(receiver)).substring(\(exprText(start)), \(exprText(length)))"
        case .stringSplit(let receiver, let delim, _):
            return "\(exprText(receiver)).split(\(exprText(delim)))"
        case .arrayJoin(let receiver, let separator):
            return "\(exprText(receiver)).join(\(exprText(separator)))"
        case .stringConcat(let lhs, let rhs):
            return "\(exprText(lhs)) + \(exprText(rhs))"
        case .interpString(let parts):
            let joined = parts.map { part in
                if case .stringConst(let text) = part { return text }
                return "{\(exprText(part))}"
            }.joined()
            return "\"\(joined)\""
        case .closureLiteral(let id, _, _, _, let captures, _, _):
            let names = captures.map { $0.name }.joined(separator: ", ")
            return "closure#\(id)(capture: \(names))"
        case .functionValue(let functionName, _):
            return "func@\(functionName)"
        case .indirectCall(let callee, let arguments, _):
            let args = arguments.map(exprText).joined(separator: ", ")
            return "\(exprText(callee))(\(args))"
        case .lazyRefConstruct(let closure, _):
            return "LazyRef(\(exprText(closure)))"
        case .lazyRefValue(let handle, _):
            return "\(exprText(handle)).value"
        case .pointerLoad(let pointer, _):
            return "load(\(exprText(pointer)))"
        case .pointerStore(let pointer, let value, _):
            return "store(\(exprText(pointer)), \(exprText(value)))"
        case .addressOfVar(let name, _):
            return "&\(name)"
        case .printMulti(let arguments):
            let items = arguments.map(exprText).joined(separator: ", ")
            return "print(\(items))"
        case .assertCall(let condition, let message):
            let msg = message.map { ", \(exprText($0))" } ?? ""
            return "assert(\(exprText(condition))\(msg))"
        case .fileWrite(let path, let content):
            return "writeFile(\(exprText(path)), \(exprText(content)))"
        case .fileRead(let path):
            return "readFile(\(exprText(path)))"
        case .readLine:
            return "readLine()"
        case .isAsciiDigit(let argument):
            return "is_ascii_digit(\(exprText(argument)))"
        case .join(let future, _):
            return "join(\(exprText(future)))"
        }
    }

    private static func symbol(of op: HIRBinaryOp) -> String {
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
        case .minOf: return "min"
        case .maxOf: return "max"
        }
    }
}
