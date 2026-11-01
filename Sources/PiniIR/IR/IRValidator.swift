import Foundation
import PiniSemantics
import PiniSyntax

/// IR 结构不变量验证器：在任何后端读取 `IRModule` 之前走一遍整棵树，逐条核出「后端假定成立、
/// 而 IR 自己从未检查过」的事实。它不判语义（那在降载之前已定），也不判能力（那属后端声明）；
/// 违约报 `E6-011` 并附源码位置，后端里的 `fatalError` 由此退为兜底。
public enum IRValidator {

    /// 诊断码：E6「IR 生成」域的第十一号槽。全部规则共用一码，按规则键区分 —— 与能力门控同规，
    /// 资源层据此分派而不是读消息文本。
    public static let code = "\(DiagnosticDomain.irgen.rawValue)-011"

    /// 一条规则：稳定的英文键 + 一句中文说明「查的是什么」。键进诊断文本，测试与巡检验按它断言，
    /// 故不随文案改动。规则与后端 `fatalError` 的前置条件一一对应，后端加了新假定而这里没有
    /// 对应规则，即为缺口。
    public enum Rule: String, CaseIterable, Sendable {
        case blockPositions = "block-positions"
        case undeclaredVariable = "undeclared-variable"
        case undeclaredTarget = "undeclared-target"
        case nodeShape = "node-shape"
        case unknownNominal = "unknown-nominal"
        case unknownField = "unknown-field"
        case unknownEnumCase = "unknown-enum-case"
        case enumPayloadArity = "enum-payload-arity"
        case matchCase = "match-case"
        case controlFlowDepth = "control-flow-depth"
        case captureVisibility = "capture-visibility"
        case closureShape = "closure-shape"
        case joinShape = "join-shape"
        case typeMismatch = "type-mismatch"
        case asyncBody = "async-body"

        /// 这条规则守的是什么，一句话。
        public var summary: String {
            switch self {
            case .blockPositions: return "语句位置表与语句表等长（否则诊断拿不到行号）"
            case .undeclaredVariable: return "读、写、取址的名字都在词法作用域内声明过"
            case .undeclaredTarget: return "try 的 ok 目标已分配"
            case .nodeShape: return "节点自称的类型与它的节点种类相符"
            case .unknownNominal: return "引用的具名类型与枚举已在模块里登记"
            case .unknownField: return "字段名在该类型的声明里"
            case .unknownEnumCase: return "用例名与标签对得上枚举声明"
            case .enumPayloadArity: return "载荷槽数、绑定数与用例元数相容"
            case .matchCase: return "match 的分支名与判别式种类相符"
            case .controlFlowDepth: return "break / continue 的深度不越过外围帧"
            case .captureVisibility: return "闭包捕获的名字在创建点可见"
            case .closureShape: return "闭包的形参名与形参类型等长"
            case .joinShape: return "等待与剪枝的操作数是任务句柄，站点类型是 Result"
            case .typeMismatch: return "值位的类型与接收位的类型可赋值"
            case .asyncBody: return "异步函数的返回类型是 Result"
            }
        }
    }

    /// 一处违约。位置来自语句块的位置表（`IRBlock.positions`），能取到就带上文件名与行列。
    public struct Issue: Equatable, Sendable, CustomStringConvertible, DiagnosticProviding {
        public let rule: Rule
        /// 出事的函数名（源码名，方法带 mangle 后的后缀）。
        public let function: String
        public let location: SourceLocation
        /// 具体到哪个名字、哪个类型、哪一层深度。
        public let detail: String

        public init(rule: Rule, function: String, location: SourceLocation, detail: String) {
            self.rule = rule
            self.function = function
            self.location = location
            self.detail = detail
        }

        public var description: String { "[\(rule.rawValue)] \(function): \(detail)" }

        public var diagnosticCode: String { IRValidator.code }
        public var diagnosticSeverity: DiagnosticSeverity { .error }
        public var suggestion: String? { nil }
        public var diagnosticLocation: SourceLocation { location }
    }

    /// 一次验证的全部违约。首处的码位与位置供诊断渲染，`issues` 供调用方与测试逐条读。
    public struct Failure: Error, Sendable, CustomStringConvertible, LocalizedError, DiagnosticProviding {
        public let issues: [Issue]

        public init(issues: [Issue]) {
            self.issues = issues
        }

        /// 一行一条，供不套诊断模板的调用方直出。
        public var report: String { issues.map(\.description).joined(separator: "；") }

        public var description: String { "IR 验证失败（\(issues.count) 处）：\(report)" }
        public var errorDescription: String? { description }

        public var diagnosticCode: String { IRValidator.code }
        public var diagnosticSeverity: DiagnosticSeverity { .error }
        public var suggestion: String? { nil }
        public var diagnosticLocation: SourceLocation {
            issues.first?.location ?? SourceLocation(line: 0, column: 0, fileName: "")
        }
    }

    /// 全量验证：一次走完，不在首错停下 —— 一处形状错会连带出它的下游，逐条给全才看得出根因。
    public static func validate(_ module: IRModule) -> [Issue] {
        var walker = Walker(module: module)
        walker.run()
        return walker.issues
    }

    /// 验证并在有违约时抛出。CLI 与解释器入口用它，后端拿到的模块因此已经过一遍。
    public static func check(_ module: IRModule) throws {
        let issues = validate(module)
        guard issues.isEmpty else { throw Failure(issues: issues) }
    }
}

// MARK: - 行走

/// 一次验证的游标：模块级名字表 + 逐函数的作用域栈与控制流深度。
/// 作用域模型与发射器逐条同规（同名遮蔽、闭包体重置、try 的错误变量登记在当前帧）——
/// 判据是「发射器会不会在这里找不到槽」，不是「语言是否该允许」。
private typealias Issue = IRValidator.Issue
private typealias Rule = IRValidator.Rule

private struct Walker {

    let module: IRModule
    /// 已知函数名：源码名与 mangle 名各收一份，函数值取哪一种拼法都算数。
    let functionNames: Set<String>
    /// 按名取函数体：判「这次调用是不是派发」要读被调者自己的 `isAsync`，类型回答不了。
    let functions: [String: IRFunction]
    let types: [String: IRTypeDecl]
    let enums: [String: IREnumDecl]

    var issues: [Issue] = []

    var functionName = ""
    var fallbackLocation = SourceLocation(line: 0, column: 0, fileName: "")
    var returnType: IRType?
    var scopes: [[String: IRType]] = []
    var breakableFrames = 0
    var loopFrames = 0

    init(module: IRModule) {
        self.module = module
        var names: Set<String> = []
        var table: [String: IRTypeDecl] = [:]
        var bodies: [String: IRFunction] = [:]
        for function in module.functions {
            names.insert(function.name)
            names.insert(IRName.mangle(function.name))
            bodies[function.name] = function
            bodies[IRName.mangle(function.name)] = function
        }
        for type in module.types {
            table[type.name] = type
            for method in type.methods {
                names.insert(method.name)
                names.insert(IRName.mangle(method.name))
                bodies[method.name] = method
                bodies[IRName.mangle(method.name)] = method
            }
        }
        var enumTable: [String: IREnumDecl] = [:]
        for decl in module.enums { enumTable[decl.name] = decl }
        self.functionNames = names
        self.functions = bodies
        self.types = table
        self.enums = enumTable
    }

    mutating func run() {
        var seen: Set<String> = []
        for function in module.functions where seen.insert(function.name).inserted {
            walk(function)
        }
        for type in module.types {
            for method in type.methods where seen.insert(method.name).inserted {
                walk(method)
            }
        }
        walkFieldDefaults()
    }

    /// 字段初值在构造点求值，取不到任何局部槽：以空作用域验，函数名记作 `类型.字段`。
    mutating func walkFieldDefaults() {
        for type in module.types {
            for field in type.fields {
                guard let defaultValue = field.defaultValue else { continue }
                functionName = "\(type.name).\(field.name)"
                fallbackLocation = SourceLocation(line: 0, column: 0, fileName: "")
                returnType = nil
                scopes = [[:]]
                breakableFrames = 0
                loopFrames = 0
                walk(defaultValue, at: nil)
            }
        }
    }

    mutating func report(_ rule: Rule, _ detail: String, at location: SourceLocation?) {
        issues.append(
            Issue(rule: rule, function: functionName, location: location ?? fallbackLocation, detail: detail))
    }

    mutating func walk(_ function: IRFunction) {
        functionName = function.name
        fallbackLocation = SourceLocation(line: 0, column: 0, fileName: function.sourceFile)
        returnType = function.returnType
        breakableFrames = 0
        loopFrames = 0
        scopes = [[:]]
        for parameter in function.params { scopes[0][parameter.name] = parameter.type }
        if function.isAsync, function.returnType?.resultOkType == nil {
            report(
                .asyncBody,
                "异步函数的返回类型是 \(function.returnType.map(\.display) ?? "空")，不是 Result",
                at: nil)
        }
        walkStatements(function.body, inherited: nil)
    }

    // MARK: 作用域

    func lookup(_ name: String) -> IRType? {
        for frame in scopes.reversed() {
            if let type = frame[name] { return type }
        }
        return nil
    }

    /// 值位上的类型：在节点的 `staticType` 之外修正一处 —— 调用节点带的是被调方**体内**产出的类型
    /// （异步函数是 `Result`），而调用点拿到的是句柄 `Future`。判据取被调者自己的 `isAsync`：
    /// 「这次调用是不是派发」只有函数自己的事实能回答，类型不能。
    func effectiveType(of expr: IRExpr) -> IRType? {
        if case .call(let name, _, let bodyReturn) = expr,
            let callee = functions[name], callee.isAsync,
            let ok = bodyReturn?.resultOkType
        {
            return .future(ok: ok)
        }
        return expr.staticType
    }

    /// 下标位的容器：数组按元素类型算，字典的值类型就是「这一层拆出来的子容器」。
    /// 字典那一路由 `bk_dict_*` 自己拷键、定值，元素类型那一栏不参与，故不比对。
    mutating func checkSubscriptContainer(
        _ container: IRExpr, elementType: IRType, writing: Bool, at location: SourceLocation?
    ) {
        guard let containerType = effectiveType(of: container) else { return }
        switch containerType {
        case .array(let element):
            if !element.isAssignable(to: elementType), !elementType.isAssignable(to: element) {
                report(
                    .typeMismatch,
                    "下标位的元素类型是 \(elementType.display)，容器元素类型是 \(element.display)",
                    at: location)
            }
        case .dict:
            break
        default:
            report(
                .nodeShape,
                "下标位的容器是 \(containerType.display)，既不是 Array 也不是 Dict",
                at: location)
        }
    }

    mutating func declare(_ name: String, _ type: IRType) {
        scopes[scopes.count - 1][name] = type
    }

    mutating func walkStatements(_ block: IRBlock, inherited: SourceLocation?) {
        if !block.positions.isEmpty, block.positions.count != block.statements.count {
            report(
                .blockPositions,
                "块有 \(block.statements.count) 条语句、\(block.positions.count) 个位置",
                at: inherited)
        }
        for (index, statement) in block.statements.enumerated() {
            walk(statement, at: block.position(at: index) ?? inherited)
        }
    }

    /// 子块：自身一帧，退出即弹。
    mutating func walk(_ block: IRBlock, at location: SourceLocation?) {
        scopes.append([:])
        walkStatements(block, inherited: location)
        scopes.removeLast()
    }

    // MARK: 语句

    mutating func walk(_ statement: IRStmt, at location: SourceLocation?) {
        switch statement {
        case .allocVar(let name, let type, _, let initializer, _):
            /// 登记排在初值求值之后：`var x = x` 的右边取的是外层那个 x，不是刚分配的空槽。
            if let initializer {
                if let valueType = effectiveType(of: initializer), !valueType.isAssignable(to: type) {
                    report(
                        .typeMismatch,
                        "变量 '\(name)' 的初值是 \(valueType.display)，槽类型是 \(type.display)",
                        at: location)
                }
                walk(initializer, at: location)
            }
            declare(name, type)

        case .storeVar(let name, let type, let value, _, _):
            if let declared = lookup(name) {
                if !declared.isAssignable(to: type), !type.isAssignable(to: declared) {
                    report(
                        .typeMismatch,
                        "赋值给 '\(name)' 的槽类型是 \(type.display)，声明是 \(declared.display)",
                        at: location)
                }
            } else {
                report(.undeclaredVariable, "赋值的目标 '\(name)' 不可见", at: location)
            }
            if let valueType = effectiveType(of: value), !valueType.isAssignable(to: type) {
                report(
                    .typeMismatch,
                    "赋给 '\(name)' 的值是 \(valueType.display)，槽类型是 \(type.display)",
                    at: location)
            }
            walk(value, at: location)

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            if let conditionType = effectiveType(of: condition), conditionType != .boolean {
                report(.typeMismatch, "if 的条件是 \(conditionType.display)，不是 Boolean", at: location)
            }
            walk(condition, at: location)
            if label != nil { breakableFrames += 1 }
            walk(thenBody, at: location)
            if let elseBody { walk(elseBody, at: location) }
            if label != nil { breakableFrames -= 1 }

        case .whileStmt(let condition, let body, let step):
            if let conditionType = effectiveType(of: condition), conditionType != .boolean {
                report(.typeMismatch, "while 的条件是 \(conditionType.display)，不是 Boolean", at: location)
            }
            walk(condition, at: location)
            breakableFrames += 1
            loopFrames += 1
            walk(body, at: location)
            if let step { walk(step, at: location) }
            loopFrames -= 1
            breakableFrames -= 1

        case .forInStmt(let pattern, let elementTypes, let kind, let iterable, let body, let step):
            if pattern.count != elementTypes.count {
                report(
                    .typeMismatch,
                    "for 模式有 \(pattern.count) 个名字、\(elementTypes.count) 个元素类型",
                    at: location)
            }
            checkIterable(kind: kind, iterable, at: location)
            walk(iterable, at: location)
            breakableFrames += 1
            loopFrames += 1
            walk(pattern: pattern, elementTypes: elementTypes, block: body, at: location)
            if let step {
                walk(pattern: pattern, elementTypes: elementTypes, block: step, at: location)
            }
            loopFrames -= 1
            breakableFrames -= 1

        case .returnStmt(let value, _):
            if let value {
                if let declared = returnType {
                    if let valueType = effectiveType(of: value), !valueType.isAssignable(to: declared) {
                        report(
                            .typeMismatch,
                            "返回值的类型是 \(valueType.display)，函数声明的返回类型是 \(declared.display)",
                            at: location)
                    }
                } else {
                    report(.typeMismatch, "无返回值的函数里出现了带值的 return", at: location)
                }
                walk(value, at: location)
            } else if let declared = returnType {
                report(
                    .typeMismatch,
                    "返回类型是 \(declared.display)，这条 return 却没带值",
                    at: location)
            }

        case .exprStmt(let expression):
            walk(expression, at: location)

        case .deferStmt(let body):
            walk(body, at: location)

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, let type):
            if let operandType = effectiveType(of: operand), operandType.resultOkType == nil {
                report(
                    .nodeShape,
                    "try 的操作数是 \(operandType.display)，不是 Result",
                    at: location)
            }
            if type.resultOkType == nil {
                report(.nodeShape, "tryStmt 的 type 是 \(type.display)，不是 Result", at: location)
            }
            walk(operand, at: location)
            /// 错误变量登记在当前帧：发射层在分派前就把它写进作用域，handler 与后续语句都看得见。
            declare(errorVar, .i64)
            walk(handler, at: location)
            if let okTarget, lookup(okTarget) == nil {
                report(.undeclaredTarget, "try 的 ok 目标 '\(okTarget)' 不可见", at: location)
            }

        case .subscriptStore(let container, let index, let value, let elementType, _):
            checkSubscriptContainer(container, elementType: elementType, writing: true, at: location)
            walk(container, at: location)
            walk(index, at: location)
            walk(value, at: location)

        case .breakStmt(let depth):
            if depth < 1 || depth > breakableFrames {
                report(
                    .controlFlowDepth,
                    "break 的深度是 \(depth)，外围只有 \(breakableFrames) 层可中断帧",
                    at: location)
            }

        case .continueStmt(let depth):
            if depth < 1 || depth > loopFrames {
                report(
                    .controlFlowDepth,
                    "continue 的深度是 \(depth)，外围只有 \(loopFrames) 层循环",
                    at: location)
            }

        case .panicStmt:
            break

        case .matchStmt(let scrutinee, let cases, let scrutineeType):
            if let actual = effectiveType(of: scrutinee), !actual.isAssignable(to: scrutineeType) {
                report(
                    .typeMismatch,
                    "match 的判别式是 \(actual.display)，节点写的判别类型是 \(scrutineeType.display)",
                    at: location)
            }
            walk(scrutinee, at: location)
            walk(cases: cases, scrutineeType: scrutineeType, at: location)

        case .fieldStore(let base, let fieldName, let value, let fieldType, _, _):
            checkField(base: base, field: fieldName, type: fieldType, at: location)
            if let valueType = effectiveType(of: value), !valueType.isAssignable(to: fieldType) {
                report(
                    .typeMismatch,
                    "字段 '\(fieldName)' 的值是 \(valueType.display)，字段类型是 \(fieldType.display)",
                    at: location)
            }
            walk(base, at: location)
            walk(value, at: location)

        case .captureMarker:
            break

        case .detachStmt(let inner):
            if let innerType = effectiveType(of: inner), case .future = innerType {} else {
                report(
                    .joinShape,
                    "detach 的操作数是 \(effectiveType(of: inner)?.display ?? "空")，不是任务句柄",
                    at: location)
            }
            walk(inner, at: location)
        }
    }

    mutating func walk(pattern: [String], elementTypes: [IRType], block: IRBlock, at location: SourceLocation?) {
        scopes.append([:])
        for (index, name) in pattern.enumerated() where index < elementTypes.count {
            if name != "_" { declare(name, elementTypes[index]) }
        }
        walkStatements(block, inherited: location)
        scopes.removeLast()
    }

    mutating func walk(cases: [IRMatchCase], scrutineeType: IRType, at location: SourceLocation?) {
        switch scrutineeType {
        case .enumeration(let name):
            guard let decl = enums[name] else {
                report(.unknownNominal, "match 的判别类型是未登记的枚举 '\(name)'", at: location)
                for matchCase in cases { walk(matchCase: matchCase, payloadTypes: [], at: location) }
                return
            }
            for matchCase in cases {
                var payloadTypes: [IRType] = []
                if matchCase.caseName != "_" {
                    guard let enumCase = decl.cases.first(where: { $0.name == matchCase.caseName }) else {
                        report(
                            .matchCase,
                            "枚举 '\(name)' 没有用例 '\(matchCase.caseName)'",
                            at: location)
                        continue
                    }
                    payloadTypes = enumCase.payloadTypes
                }
                if matchCase.bindings.count > payloadTypes.count {
                    report(
                        .enumPayloadArity,
                        "分支 '\(matchCase.caseName)' 有 \(matchCase.bindings.count) 个绑定，用例只有 "
                            + "\(payloadTypes.count) 个载荷槽",
                        at: location)
                }
                walk(matchCase: matchCase, payloadTypes: payloadTypes, at: location)
            }

        case .optional(let wrapped):
            for matchCase in cases {
                if matchCase.bindings.count > 1 {
                    report(
                        .enumPayloadArity,
                        "Optional 分支 '\(matchCase.caseName)' 有 \(matchCase.bindings.count) 个绑定，只有一个载荷",
                        at: location)
                }
                walk(matchCase: matchCase, payloadTypes: [wrapped], at: location)
            }

        case .result(let ok):
            /// 分派面与发射层同规：ok 取载荷槽 1（ok 类型），err 取槽 2（类型擦除的错误字）。
            for matchCase in cases {
                let bindingType: IRType?
                switch matchCase.caseName {
                case "ok": bindingType = ok
                case "err": bindingType = .i64
                case "_": bindingType = nil
                default:
                    report(
                        .matchCase,
                        "Result 的分支名是 '\(matchCase.caseName)'，只认 ok / err / _",
                        at: location)
                    bindingType = nil
                }
                if matchCase.bindings.count > 1 {
                    report(
                        .enumPayloadArity,
                        "Result 分支 '\(matchCase.caseName)' 有 \(matchCase.bindings.count) 个绑定，只有一个载荷",
                        at: location)
                }
                walk(
                    matchCase: matchCase, payloadTypes: bindingType.map { [$0] } ?? [],
                    at: location)
            }

        default:
            /// 裸值分支的绑定取判别式本身的类型 —— 与降载同一条规则：分支体引用它时要看得见。
            for matchCase in cases {
                let payloadTypes = Array(repeating: scrutineeType, count: matchCase.bindings.count)
                walk(matchCase: matchCase, payloadTypes: payloadTypes, at: location)
            }
        }
    }

    mutating func walk(matchCase: IRMatchCase, payloadTypes: [IRType], at location: SourceLocation?) {
        scopes.append([:])
        for (index, name) in matchCase.bindings.enumerated() where index < payloadTypes.count {
            if let name { declare(name, payloadTypes[index]) }
        }
        walkStatements(matchCase.body, inherited: location)
        scopes.removeLast()
    }

    mutating func checkIterable(kind: IRForIterableKind, _ iterable: IRExpr, at location: SourceLocation?) {
        guard let type = effectiveType(of: iterable) else { return }
        let matches: Bool
        switch kind {
        case .array: matches = type.isArray
        case .set: if case .set = type { matches = true } else { matches = false }
        case .dict: if case .dict = type { matches = true } else { matches = false }
        }
        if !matches {
            report(
                .nodeShape,
                "for 的遍历种类与之不符，容器是 \(type.display)",
                at: location)
        }
    }

    mutating func checkField(base: IRExpr, field: String, type: IRType, at location: SourceLocation?) {
        guard let baseType = effectiveType(of: base) else { return }
        guard case .nominal(let name, _) = baseType else {
            report(.nodeShape, "字段位的基类型是 \(baseType.display)，不是名义类型", at: location)
            return
        }
        guard let decl = types[name] else {
            report(.unknownNominal, "字段位的基类型 '\(name)' 未登记", at: location)
            return
        }
        guard let declared = decl.fields.first(where: { $0.name == field }) else {
            report(.unknownField, "具名类型 '\(name)' 没有字段 '\(field)'", at: location)
            return
        }
        if !declared.type.isAssignable(to: type), !type.isAssignable(to: declared.type) {
            report(
                .typeMismatch,
                "字段 '\(name).\(field)' 声明为 \(declared.type.display)，节点写的是 \(type.display)",
                at: location)
        }
    }

    // MARK: 表达式

    mutating func walk(_ expr: IRExpr, at location: SourceLocation?) {
        switch expr {
        case .intConst, .floatConst, .boolConst, .stringConst, .readLine:
            break

        case .load(let name, let type):
            checkName(name, declaredType: type, node: "读", at: location)

        case .addressOfVar(let name, let type):
            checkName(name, declaredType: type, node: "取址", at: location)

        case .binary(_, let lhs, let rhs, _):
            walk(lhs, at: location)
            walk(rhs, at: location)

        case .unary(_, let operand, _):
            walk(operand, at: location)

        case .call(_, let arguments, _):
            for argument in arguments { walk(argument, at: location) }

        case .printCall(let argument):
            walk(argument, at: location)

        case .printMulti(let arguments):
            for argument in arguments { walk(argument, at: location) }

        case .resultConstruct(_, let payload, let type):
            if type.resultOkType == nil {
                report(.nodeShape, "ok/err 构造成员的 type 是 \(type.display)，不是 Result", at: location)
            }
            walk(payload, at: location)

        case .optionalConstruct(_, let payload, let type):
            if type.optionalWrapped == nil {
                report(.nodeShape, "Optional 构造成员的 type 是 \(type.display)，不是 Optional", at: location)
            }
            if let payload { walk(payload, at: location) }

        case .arrayLiteral(let elements, let type):
            if type.arrayElementType == nil {
                report(.nodeShape, "数组字面量的 type 是 \(type.display)，不是 Array", at: location)
            }
            for element in elements { walk(element, at: location) }

        case .subscriptGet(let container, let index, let type):
            if let containerType = effectiveType(of: container) {
                switch containerType {
                case .array(let element):
                    if !element.isAssignable(to: type), !type.isAssignable(to: element) {
                        report(
                            .typeMismatch,
                            "下标读的结果类型是 \(type.display)，容器元素类型是 \(element.display)",
                            at: location)
                    }
                case .dict(_, let value):
                    if !value.isAssignable(to: type) {
                        report(
                            .typeMismatch,
                            "字典下标读的结果类型是 \(type.display)，值类型是 \(value.display)",
                            at: location)
                    }
                default:
                    report(
                        .nodeShape,
                        "下标读的容器是 \(containerType.display)，既不是 Array 也不是 Dict",
                        at: location)
                }
            }
            walk(container, at: location)
            walk(index, at: location)

        case .lenCall(let argument):
            walk(argument, at: location)

        case .optionalGet(let container, let index, let type):
            if let containerType = effectiveType(of: container) {
                switch containerType {
                case .array(let element):
                    if type.optionalWrapped.map({ !element.isAssignable(to: $0) }) ?? true {
                        report(
                            .nodeShape,
                            "宽松下标读的 type 是 \(type.display)，元素类型是 \(element.display)",
                            at: location)
                    }
                case .string, .char:
                    /// 字符串的下标是字素簇，与数组同一形态，但元素不是容器里的槽。
                    if let wrapped = type.optionalWrapped, wrapped != .char, wrapped != .string {
                        report(
                            .typeMismatch,
                            "字符串宽松下标读的 type 是 \(type.display)，元素应是 Char",
                            at: location)
                    }
                default:
                    report(
                        .nodeShape,
                        "宽松下标读的容器是 \(containerType.display)，既不是 Array 也不是 String",
                        at: location)
                }
            }
            walk(container, at: location)
            walk(index, at: location)

        case .sliceCall(let container, let start, let end, let type):
            if let containerType = effectiveType(of: container) {
                switch containerType {
                case .array(let element):
                    if !type.isAssignable(to: .array(element: element)) {
                        report(
                            .typeMismatch,
                            "切片的 type 是 \(type.display)，容器的元素类型是 \(element.display)",
                            at: location)
                    }
                case .string, .char:
                    if type != .string { report(.typeMismatch, "字符串切片的 type 是 \(type.display)", at: location) }
                default:
                    report(.nodeShape, "切片的对象是 \(containerType.display)，既不是 Array 也不是 String", at: location)
                }
            }
            walk(container, at: location)
            walk(start, at: location)
            walk(end, at: location)

        case .construct(let type):
            requireNominal(type, node: "构造", at: location)

        case .enumConstruct(let enumName, let caseName, let tag, let payloads, let payloadTypes, let type):
            if case .enumeration(let named) = type {
                if named != enumName {
                    report(
                        .nodeShape,
                        "枚举构造的 type 是 \(type.display)，节点写的枚举是 '\(enumName)'",
                        at: location)
                }
            } else {
                report(.nodeShape, "枚举构造的 type 是 \(type.display)，不是枚举", at: location)
            }
            if let decl = enums[enumName] {
                if let enumCase = decl.cases.first(where: { $0.name == caseName }) {
                    if enumCase.tag != tag {
                        report(
                            .unknownEnumCase,
                            "用例 '\(enumName).\(caseName)' 的标签是 \(enumCase.tag)，节点写 \(tag)",
                            at: location)
                    }
                    if enumCase.payloadTypes.count != payloads.count || payloadTypes.count != payloads.count {
                        report(
                            .enumPayloadArity,
                            "用例 '\(enumName).\(caseName)' 有 \(enumCase.payloadTypes.count) 个载荷槽，"
                                + "节点带 \(payloads.count) 个值 / \(payloadTypes.count) 个类型",
                            at: location)
                    }
                } else {
                    report(.unknownEnumCase, "枚举 '\(enumName)' 没有用例 '\(caseName)'", at: location)
                }
            } else {
                report(.unknownNominal, "枚举 '\(enumName)' 未登记", at: location)
            }
            for payload in payloads { walk(payload, at: location) }

        case .fieldGet(let base, let fieldName, let type):
            checkField(base: base, field: fieldName, type: type, at: location)
            walk(base, at: location)

        case .dictLiteral(let entries, let type):
            if case .dict = type {} else {
                report(.nodeShape, "字典字面量的 type 是 \(type.display)，不是 Dict", at: location)
            }
            for entry in entries {
                walk(entry.key, at: location)
                walk(entry.value, at: location)
            }

        case .setLiteral(let elements, let type):
            if case .set = type {} else {
                report(.nodeShape, "集合字面量的 type 是 \(type.display)，不是 Set", at: location)
            }
            for element in elements { walk(element, at: location) }

        case .tupleConstruct(let labels, let elements, let type):
            if labels.count != elements.count {
                report(
                    .nodeShape,
                    "元组有 \(labels.count) 个标签、\(elements.count) 个元素",
                    at: location)
            }
            if case .tuple(_, let fieldTypes) = type {
                if fieldTypes.count != elements.count {
                    report(
                        .nodeShape,
                        "元组的 type 有 \(fieldTypes.count) 个字段，节点带 \(elements.count) 个元素",
                        at: location)
                }
            } else {
                report(.nodeShape, "元组构造的 type 是 \(type.display)，不是 Tuple", at: location)
            }
            for element in elements { walk(element, at: location) }

        case .tupleIndexGet(let base, let index, let type):
            if let baseType = effectiveType(of: base) {
                if case .tuple(_, let fieldTypes) = baseType {
                    if index < 0 || index >= fieldTypes.count {
                        report(
                            .nodeShape,
                            "元组下标 \(index) 越过了 \(fieldTypes.count) 个字段",
                            at: location)
                    } else if !fieldTypes[index].isAssignable(to: type), !type.isAssignable(to: fieldTypes[index]) {
                        report(
                            .typeMismatch,
                            "元组下标的 type 是 \(type.display)，第 \(index) 个字段是 \(fieldTypes[index].display)",
                            at: location)
                    }
                } else {
                    report(.nodeShape, "元组下标的基类型是 \(baseType.display)，不是 Tuple", at: location)
                }
            }
            walk(base, at: location)

        case .closureLiteral(_, let paramNames, let paramTypes, let closureReturn, let captures, let body, let type):
            walkClosure(
                paramNames: paramNames, paramTypes: paramTypes, returnType: closureReturn,
                captures: captures, body: body, type: type, at: location)

        case .functionValue(let name, _):
            if !functionNames.contains(name) {
                report(.closureShape, "函数值引用了未知函数 '\(name)'", at: location)
            }

        case .indirectCall(let callee, let arguments, _):
            if let calleeType = effectiveType(of: callee), case .function = calleeType {} else {
                report(
                    .closureShape,
                    "间接调用的被调者是 \(effectiveType(of: callee)?.display ?? "空")，不是函数值",
                    at: location)
            }
            walk(callee, at: location)
            for argument in arguments { walk(argument, at: location) }

        case .pointerLoad(let pointer, let type):
            if let pointerType = effectiveType(of: pointer) {
                if case .pointer(let element) = pointerType {
                    if element != type {
                        report(
                            .typeMismatch,
                            "指针读的 type 是 \(type.display)，指针的元素类型是 \(element.display)",
                            at: location)
                    }
                } else {
                    report(.nodeShape, "指针读的对象是 \(pointerType.display)，不是指针", at: location)
                }
            }
            walk(pointer, at: location)

        case .pointerStore(let pointer, let value, let type):
            if let pointerType = effectiveType(of: pointer) {
                if case .pointer(let element) = pointerType {
                    if element != type {
                        report(
                            .typeMismatch,
                            "指针写的 type 是 \(type.display)，指针的元素类型是 \(element.display)",
                            at: location)
                    }
                } else {
                    report(.nodeShape, "指针写的对象是 \(pointerType.display)，不是指针", at: location)
                }
            }
            if let valueType = effectiveType(of: value), !valueType.isAssignable(to: type) {
                report(
                    .typeMismatch,
                    "指针写的值是 \(valueType.display)，目标元素类型是 \(type.display)",
                    at: location)
            }
            walk(pointer, at: location)
            walk(value, at: location)

        case .assertCall(let condition, let message):
            walk(condition, at: location)
            if let message { walk(message, at: location) }

        case .fileWrite(let path, let content), .fileAppend(let path, let content),
            .fileTryWrite(let path, let content), .fileTryAppend(let path, let content):
            walk(path, at: location)
            walk(content, at: location)

        case .fileRead(let path), .fileTryRead(let path):
            walk(path, at: location)

        case .isAsciiDigit(let argument):
            walk(argument, at: location)

        case .stringCase(_, let receiver), .stringTrimLeft(let receiver), .stringTrimRight(let receiver):
            walk(receiver, at: location)

        case .stringContains(let receiver, let needle), .stringIndexOf(let receiver, let needle):
            walk(receiver, at: location)
            walk(needle, at: location)

        case .stringSubstring(let receiver, let start, let length):
            walk(receiver, at: location)
            walk(start, at: location)
            walk(length, at: location)

        case .stringSplit(let receiver, let delim, let type):
            if type.arrayElementType != .string {
                report(.nodeShape, "split 的 type 是 \(type.display)，不是 Array<String>", at: location)
            }
            walk(receiver, at: location)
            walk(delim, at: location)

        case .arrayJoin(let receiver, let separator):
            walk(receiver, at: location)
            walk(separator, at: location)

        case .stringConcat(let lhs, let rhs):
            walk(lhs, at: location)
            walk(rhs, at: location)

        case .interpString(let parts):
            for part in parts { walk(part, at: location) }

        case .lazyRefConstruct(let closure, let type):
            if case .lazyRef = type {} else {
                report(.nodeShape, "LazyRef 构造的 type 是 \(type.display)，不是 LazyRef", at: location)
            }
            if let closureType = effectiveType(of: closure), case .function = closureType {} else {
                report(
                    .closureShape,
                    "LazyRef 的初值是 \(effectiveType(of: closure)?.display ?? "空")，不是闭包",
                    at: location)
            }
            walk(closure, at: location)

        case .lazyRefValue(let handle, let type):
            if let handleType = effectiveType(of: handle) {
                if case .lazyRef(let element) = handleType {
                    if !element.isAssignable(to: type) {
                        report(
                            .typeMismatch,
                            "LazyRef 取值的 type 是 \(type.display)，元素类型是 \(element.display)",
                            at: location)
                    }
                } else {
                    report(.nodeShape, "LazyRef 取值的手柄是 \(handleType.display)，不是 LazyRef", at: location)
                }
            }
            walk(handle, at: location)

        case .join(let future, let type, let form):
            if type.resultOkType == nil {
                report(.nodeShape, "等待站点的 type 是 \(type.display)，不是 Result", at: location)
            }
            if let operandType = effectiveType(of: future) {
                switch operandType {
                case .future(let ok):
                    if let settled = type.resultOkType, !ok.isAssignable(to: settled) {
                        report(
                            .joinShape,
                            "等待站点的 ok 载荷是 \(settled.display)，句柄携带的是 \(ok.display)",
                            at: location)
                    }
                case .result(let ok):
                    /// 已在结算值上等待（`wait joinAll(...)` 这类）：发射层原样透传，故站点类型要与它一致。
                    if form == .awaits {
                        report(
                            .joinShape,
                            "await 的操作数是已结算的 \(operandType.display)，不是任务句柄",
                            at: location)
                    } else if let settled = type.resultOkType, !ok.isAssignable(to: settled) {
                        report(
                            .joinShape,
                            "等待站点的 ok 载荷是 \(settled.display)，操数携带的是 \(ok.display)",
                            at: location)
                    }
                default:
                    report(
                        .joinShape,
                        "等待的操作数是 \(operandType.display)，既不是任务句柄也不是 Result",
                        at: location)
                }
            }
            walk(future, at: location)

        case .givenInstance(let type):
            requireNominal(type, node: "默认实例取用", at: location)
        }
    }

    mutating func checkName(_ name: String, declaredType: IRType, node: String, at location: SourceLocation?) {
        guard let declared = lookup(name) else {
            report(.undeclaredVariable, "\(node) 引用了不可见的名字 '\(name)'", at: location)
            return
        }
        if !declared.isAssignable(to: declaredType), !declaredType.isAssignable(to: declared) {
            report(
                .typeMismatch,
                "\(node) '\(name)' 用的类型是 \(declaredType.display)，声明是 \(declared.display)",
                at: location)
        }
    }

    mutating func requireNominal(_ type: IRType, node: String, at location: SourceLocation?) {
        guard case .nominal(let name, _) = type else {
            report(.nodeShape, "\(node) 的 type 是 \(type.display)，不是名义类型", at: location)
            return
        }
        if types[name] == nil {
            report(.unknownNominal, "\(node) 引用了未登记的具名类型 '\(name)'", at: location)
        }
    }

    /// 闭包体是**自己的函数**：作用域、控制流深度与返回类型全部重来，只有捕获与形参可见。
    mutating func walkClosure(
        paramNames: [String], paramTypes: [IRType], returnType closureReturn: IRType?,
        captures: [IRCapture], body: IRBlock, type: IRType, at location: SourceLocation?
    ) {
        if paramNames.count != paramTypes.count {
            report(
                .closureShape,
                "闭包有 \(paramTypes.count) 个形参类型、\(paramNames.count) 个形参名",
                at: location)
        }
        if case .function = type {} else {
            report(.nodeShape, "闭包值的 type 是 \(type.display)，不是函数类型", at: location)
        }
        for capture in captures {
            if let declared = lookup(capture.name) {
                if !declared.isAssignable(to: capture.type), !capture.type.isAssignable(to: declared) {
                    report(
                        .typeMismatch,
                        "捕获 '\(capture.name)' 记作 \(capture.type.display)，外层是 \(declared.display)",
                        at: location)
                }
            } else {
                report(.captureVisibility, "捕获 '\(capture.name)' 在闭包创建点不可见", at: location)
            }
        }
        let savedScopes = scopes
        let savedBreakable = breakableFrames
        let savedLoops = loopFrames
        let savedReturn = returnType
        scopes = [[:]]
        breakableFrames = 0
        loopFrames = 0
        returnType = closureReturn
        for (index, name) in paramNames.enumerated() where index < paramTypes.count {
            scopes[0][name] = paramTypes[index]
        }
        for capture in captures { scopes[0][capture.name] = capture.type }
        walkStatements(body, inherited: location)
        scopes = savedScopes
        breakableFrames = savedBreakable
        loopFrames = savedLoops
        returnType = savedReturn
    }
}

extension IRType {
    /// 诊断文本里的紧凑拼写：`Array<I32>` / `Result<String>`；容器递归，标量取源码名。
    var display: String {
        switch self {
        case .i8: return "I8"
        case .u8: return "U8"
        case .i32: return "I32"
        case .i64: return "I64"
        case .u64: return "U64"
        case .f64: return "F64"
        case .boolean: return "Boolean"
        case .string: return "String"
        case .char: return "Char"
        case .result(let ok): return "Result<\(ok.display)>"
        case .future(let ok): return "Future<\(ok.display)>"
        case .array(let element): return "Array<\(element.display)>"
        case .optional(let wrapped): return "Optional<\(wrapped.display)>"
        case .nominal(let name, _): return name
        case .enumeration(let name): return name
        case .dict(let key, let value): return "Dict<\(key.display), \(value.display)>"
        case .set(let element): return "Set<\(element.display)>"
        case .lazyRef(let element): return "LazyRef<\(element.display)>"
        case .tuple(let labels, let fieldTypes):
            let fields = zip(labels, fieldTypes).map { pair in
                pair.0.map { "\($0): \(pair.1.display)" } ?? pair.1.display
            }
            return "(" + fields.joined(separator: ", ") + ")"
        case .function(let params, let returnType, _):
            let inputs = params.map(\.display).joined(separator: ", ")
            return "(\(inputs)) -> \(returnType?.display ?? "()")"
        case .pointer(let element): return "*\(element.display)"
        }
    }
}
