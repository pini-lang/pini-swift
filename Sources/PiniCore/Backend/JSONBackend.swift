/// 哑后端：把 `IRModule` 转成结构转储，不产目标码。价值不在输出，在**穷尽分派** —— `IRStmt` 的
/// 17 条与 `IRExpr` 的 53 条逐一列出、不留 `default`，新增节点时这里编不过。这就是「节点集是否被
/// 完整消费」的编译期判据，也是接缝的验收器械：跑通全部语料 = 没有任何节点被漏掉。
public struct JSONBackend: PiniBackend {

    public static var identifier: String { "json" }
    public static var capabilities: BackendCapabilities { .structural }

    public init() {}

    public func emit(module: IRModule) -> String {
        var out = "{\"backend\":\"json\",\"output\":\"structuralDump\""
        out += ",\"layout\":{\"headerSlots\":\(module.layout.headerSlotCount)"
        out += ",\"resultSlots\":\(module.layout.resultSlotCount)"
        out += ",\"optionalSlots\":\(module.layout.optionalSlotCount)"
        out += ",\"enumTagSlot\":\(module.layout.enumTagSlot)}"
        out += ",\"types\":" + array(module.types.map { "\"\(escape($0.name))\"" })
        out += ",\"enums\":" + array(module.enums.map { "\"\(escape($0.name))\"" })
        out += ",\"functions\":"
        out += array(module.functions.map(functionJSON))
        out += "}"
        return out
    }

    // MARK: - 模块结构

    private func functionJSON(_ function: IRFunction) -> String {
        let params = function.params.map {
            "{\"name\":\"\(escape($0.name))\",\"type\":\"\(escape(spell($0.type)))\"}"
        }
        var out = "{\"name\":\"\(escape(function.name))\""
        out += ",\"params\":" + array(params)
        out += ",\"returnType\":\(function.returnType.map { "\"\(escape(spell($0)))\"" } ?? "null")"
        out += ",\"async\":\(function.isAsync),\"test\":\(function.isTest)"
        out += ",\"body\":" + array(rows(of: function.body, depth: 0))
        out += "}"
        return out
    }

    /// 语句按出现顺序平铺，嵌套块展开到其后并加深一层。深度只用于阅读 —— 它不是语义，
    /// 判据是「每一层里的每个节点都出现在转储里」。
    private func rows(of block: IRBlock, depth: Int) -> [String] {
        var out: [String] = []
        for statement in block {
            let described = describe(statement)
            out.append(
                "{\"kind\":\"\(described.kind)\",\"depth\":\(depth)"
                    + ",\"detail\":\"\(escape(described.detail))\"}")
            for child in childBlocks(of: statement) {
                out.append(contentsOf: rows(of: child, depth: depth + 1))
            }
        }
        return out
    }

    /// 17 条语句的嵌套块。穷尽列出、不留 `default`。
    private func childBlocks(of statement: IRStmt) -> [IRBlock] {
        switch statement {
        case .ifStmt(_, _, let thenBody, let elseBody):
            return [thenBody] + (elseBody.map { [$0] } ?? [])
        case .whileStmt(_, let body, let step):
            return [body] + (step.map { [$0] } ?? [])
        case .forInStmt(_, _, _, _, let body, let step):
            return [body] + (step.map { [$0] } ?? [])
        case .deferStmt(let body):
            return [body]
        case .tryStmt(_, _, let handler, _, _):
            return [handler]
        case .matchStmt(_, let cases, _):
            return cases.map(\.body)
        case .allocVar, .storeVar, .returnStmt, .exprStmt, .subscriptStore, .breakStmt,
            .continueStmt, .panicStmt, .fieldStore, .captureMarker, .detachStmt:
            return []
        }
    }

    // MARK: - 节点分派

    /// 一条语句的转储。17 条逐一列出、不留 `default` —— 新增语句节点时这里编不过。
    private func describe(_ statement: IRStmt) -> (kind: String, detail: String) {
        switch statement {
        case .allocVar(let name, let type, let mutable, let initializer, let adopt):
            return ("allocVar", "\(name): \(spell(type)) mutable=\(mutable) adopt=\(adopt) "
                + "init=\(initializer.map(exprKind) ?? "-")")
        case .storeVar(let name, let type, let value, let adopt, let releaseOld):
            return ("storeVar", "\(name): \(spell(type)) adopt=\(adopt) releaseOld=\(releaseOld) "
                + "value=\(exprKind(value))")
        case .ifStmt(let label, let condition, _, _):
            return ("ifStmt", "label=\(label ?? "-") cond=\(exprKind(condition))")
        case .whileStmt(let condition, _, _):
            return ("whileStmt", "cond=\(exprKind(condition))")
        case .forInStmt(let pattern, _, let kind, let iterable, _, _):
            return ("forInStmt", "pattern=[\(pattern.joined(separator: ","))] kind=\(kind) "
                + "iterable=\(exprKind(iterable))")
        case .returnStmt(let value, let adopt):
            return ("returnStmt", "adopt=\(adopt) value=\(value.map(exprKind) ?? "-")")
        case .exprStmt(let expr):
            return ("exprStmt", exprKind(expr))
        case .deferStmt:
            return ("deferStmt", "-")
        case .tryStmt(let operand, let errorVar, _, let okTarget, let type):
            return ("tryStmt", "\(okTarget ?? "-"): \(spell(type)) errorVar=\(errorVar) "
                + "operand=\(exprKind(operand))")
        case .subscriptStore(_, _, let value, let elementType, let adopt):
            return ("subscriptStore", "element=\(spell(elementType)) adopt=\(adopt) "
                + "value=\(exprKind(value))")
        case .breakStmt(let depth):
            return ("breakStmt", "depth=\(depth)")
        case .continueStmt(let depth):
            return ("continueStmt", "depth=\(depth)")
        case .panicStmt(let message):
            return ("panicStmt", message)
        case .matchStmt(let scrutinee, let cases, let scrutineeType):
            return ("matchStmt", "\(spell(scrutineeType)) cases=\(cases.count) "
                + "scrutinee=\(exprKind(scrutinee))")
        case .fieldStore(_, let field, let value, let fieldType, let adopt, let releaseOld):
            return ("fieldStore", ".\(field): \(spell(fieldType)) adopt=\(adopt) "
                + "releaseOld=\(releaseOld) value=\(exprKind(value))")
        case .captureMarker(let name):
            return ("captureMarker", name)
        case .detachStmt(let inner):
            return ("detachStmt", "inner=\(exprKind(inner))")
        }
    }

    /// 53 条表达式逐一列出、不留 `default`。分支体为空是刻意的：本函数要的只是「编译器确认这一条
    /// 被处理过」，名字从 `String(describing:)` 的前缀取，避免手抄一份节点名表 —— 那会成为第二份
    /// 节点表，而它正是本文件要防的东西。
    private func exprKind(_ expr: IRExpr) -> String {
        switch expr {
        case .intConst, .floatConst, .boolConst, .stringConst, .load, .binary, .unary,
            .call, .printCall, .resultConstruct, .arrayLiteral, .subscriptGet, .lenCall,
            .optionalGet, .optionalConstruct, .sliceCall, .construct, .enumConstruct,
            .fieldGet, .dictLiteral, .setLiteral, .tupleConstruct, .tupleIndexGet,
            .closureLiteral, .functionValue, .indirectCall, .pointerLoad, .pointerStore,
            .addressOfVar, .printMulti, .assertCall, .fileWrite, .fileAppend, .fileRead,
            .fileTryWrite, .fileTryAppend, .fileTryRead, .readLine, .isAsciiDigit,
            .stringCase, .stringContains, .stringSubstring, .stringSplit, .stringTrimLeft,
            .stringTrimRight, .stringIndexOf, .arrayJoin, .stringConcat, .interpString,
            .lazyRefConstruct, .lazyRefValue, .join, .givenInstance:
            break
        }
        return String(String(describing: expr).prefix(while: { $0 != "(" }))
    }

    // MARK: - 文本

    /// 类型的写法。转储要能读，又不该借用某个具体后端的拼写 ⇒ 用类型自身的描述。
    private func spell(_ type: IRType) -> String { String(describing: type) }

    private func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    private func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out
    }
}
