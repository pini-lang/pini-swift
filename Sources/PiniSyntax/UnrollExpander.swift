import Foundation

/// `unroll` 的展开错误。展开在类型检查之前跑，故本类型留在 PiniSyntax；码与文案在语义侧登记。
public enum UnrollError: Error, Equatable {
    /// 表不是写在原地的字面量集合：要求数组字面量，元素是标量字面量或元组字面量。
    case tableNotLiteral(location: SourceLocation)
    /// 某一行分量数与模式长度不符。
    case rowMismatch(row: Int, expected: Int, actual: Int, location: SourceLocation)
    /// 体内对某个名字的用法展开后不成立：与模式同名、跨轮重名、或把模式名当赋值目标。
    case bodyNameConflict(name: String, reason: String, location: SourceLocation)
    /// 表里一行也没有。
    case emptyTable(location: SourceLocation)
    /// 行数超过上限。
    case tooManyRows(count: Int, limit: Int, location: SourceLocation)
}

/// 展开 `unroll`：按表的行克隆语句体，模式名在表达式位替换成该行的字面量。
/// 产物不含 `unrollStatement`——类型检查、降载、打印都看不见这个构造。
public enum UnrollExpander {

    /// 一次展开的整批错误：收齐再抛，只报第一处会让作者改一轮跑一轮。
    public struct Failure: Error, Equatable {
        public let errors: [UnrollError]

        public init(errors: [UnrollError]) {
            self.errors = errors
        }
    }

    /// 行数上限。再多就不是「省几行」，而是生成代码失控。
    public static let rowLimit = 256

    /// 展开整模块。无 `unroll` 时原样返回，不动其他节点。
    public static func expand(_ module: Module) throws(Failure) -> Module {
        let worker = Worker()
        let expanded = worker.module(module)
        guard worker.errors.isEmpty else { throw Failure(errors: worker.errors) }
        return expanded
    }
}

// MARK: - 遍历与展开

extension UnrollExpander {

    /// 遍历器：走遍全部块，把 `unroll` 就地摊成多轮。错误累积在这里，最后一次性抛出。
    /// `map` 为 nil 是常规遍历，非 nil 是克隆替换——两件事共用一套分支，漏一个分支会编译失败。
    final class Worker {
        private(set) var errors: [UnrollError] = []

        func module(_ m: Module) -> Module {
            Module(
                declarations: m.declarations.map { declaration($0, map: nil) },
                imports: m.imports,
                exports: m.exports,
                location: m.location)
        }

        func declaration(_ d: TopLevelDecl, map: [String: Expression]?) -> TopLevelDecl {
            switch d {
            case .structDecl(let node):
                return .structDecl(
                    StructDecl(
                        name: node.name, genericParams: node.genericParams,
                        fields: node.fields.map { field($0, map: map) },
                        methods: node.methods.map { funcDecl($0, map: map) },
                        composedType: node.composedType, traits: node.traits, location: node.location))
            case .objectDecl(let node):
                return .objectDecl(
                    ObjectDecl(
                        name: node.name, genericParams: node.genericParams,
                        fields: node.fields.map { field($0, map: map) },
                        methods: node.methods.map { funcDecl($0, map: map) },
                        traits: node.traits, location: node.location))
            case .givenDecl(let node):
                return .givenDecl(
                    GivenDecl(
                        name: node.name, genericParams: node.genericParams,
                        fields: node.fields.map { field($0, map: map) },
                        methods: node.methods.map { funcDecl($0, map: map) },
                        traits: node.traits, location: node.location))
            case .enumDecl(let node):
                let cases = node.cases.map { item in
                    EnumCase(
                        name: item.name,
                        associatedParams: item.associatedParams.map { param in
                            AssociatedParam(
                                name: param.name, type: param.type,
                                defaultValue: param.defaultValue.map { expression($0, map: map) })
                        },
                        location: item.location)
                }
                return .enumDecl(
                    EnumDecl(
                        name: node.name, genericParams: node.genericParams, cases: cases,
                        methods: node.methods.map { funcDecl($0, map: map) }, traits: node.traits,
                        location: node.location))
            case .funcDecl(let node):
                return .funcDecl(funcDecl(node, map: map))
            case .traitDecl(let node):
                return .traitDecl(
                    TraitDecl(
                        name: node.name, genericParams: node.genericParams,
                        signatures: node.signatures.map { funcDecl($0, map: map) },
                        location: node.location))
            case .extensionDecl(let node):
                return .extensionDecl(
                    ExtensionDecl(
                        kind: node.kind, targetType: node.targetType,
                        genericParams: node.genericParams,
                        targetTypeAnnotation: node.targetTypeAnnotation,
                        methods: node.methods.map { funcDecl($0, map: map) }, location: node.location))
            case .foreignDecl(let node):
                return .foreignDecl(node)
            case .varDecl(let statement):
                return .varDecl(self.statement(statement, map: map))
            case .statement(let statement):
                return .statement(self.statement(statement, map: map))
            case .importDecl(let node):
                return .importDecl(node)
            case .exportDecl(let node):
                return .exportDecl(node)
            }
        }

        private func field(_ node: FieldDecl, map: [String: Expression]?) -> FieldDecl {
            FieldDecl(
                name: node.name, typeAnnotation: node.typeAnnotation,
                initializer: node.initializer.map { expression($0, map: map) }, location: node.location)
        }

        private func funcDecl(_ node: FuncDecl, map: [String: Expression]?) -> FuncDecl {
            FuncDecl(
                name: node.name, modifiers: node.modifiers, genericParams: node.genericParams,
                params: node.params, returnTypes: node.returnTypes, returnLabels: node.returnLabels,
                isAsync: node.isAsync, body: node.body.map { block($0, map: map) },
                location: node.location, captured: node.captured)
        }

        func block(_ node: Block, map: [String: Expression]?) -> Block {
            Block(statements: statements(node.statements, map: map), location: node.location)
        }

        /// 语句列表是唯一能摊开 `unroll` 的位置：一轮展开可能一变多，只有列表容得下。
        func statements(_ list: [Statement], map: [String: Expression]?) -> [Statement] {
            guard map == nil else { return list.map { statement($0, map: map) } }

            var out: [Statement] = []
            for item in list {
                if case .unrollStatement(let pattern, let table, let body, let location) = item {
                    out.append(contentsOf: expand(pattern: pattern, table: table, body: body, location: location))
                } else {
                    out.append(statement(item, map: nil))
                }
            }
            return out
        }

        func statement(_ node: Statement, map: [String: Expression]?) -> Statement {
            switch node {
            case .varDecl(let name, let type, let initializer, let isMutable, let loc):
                return .varDecl(
                    name: name, typeAnnotation: type, initializer: initializer.map { expression($0, map: map) },
                    isMutable: isMutable, location: loc)
            case .varDestructure(let names, let type, let initializer, let isMutable, let loc):
                return .varDestructure(
                    names: names, typeAnnotation: type, initializer: initializer.map { expression($0, map: map) },
                    isMutable: isMutable, location: loc)
            case .assign(let target, let value, let loc):
                return .assign(
                    target: assignTarget(target, map: map), value: expression(value, map: map), location: loc)
            case .returnStatement(let value, let loc):
                return .returnStatement(value: value.map { expression($0, map: map) }, location: loc)
            case .breakStatement, .continueStatement, .passStatement, .captureStatement:
                return node
            case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, let loc):
                return .ifStatement(
                    condition: expression(condition, map: map), thenBlock: block(thenBlock, map: map),
                    elifs: elifs.map {
                        ElifBranch(
                            condition: expression($0.condition, map: map),
                            block: block($0.block, map: map), location: $0.location)
                    },
                    elseBlock: elseBlock.map { block($0, map: map) }, label: label, location: loc)
            case .whileStatement(let condition, let body, let step, let label, let loc):
                return .whileStatement(
                    condition: expression(condition, map: map), body: block(body, map: map),
                    step: step.map { block($0, map: map) }, label: label, location: loc)
            case .forStatement(let pattern, let iterable, let body, let step, let label, let loc):
                return .forStatement(
                    pattern: pattern, iterable: expression(iterable, map: map), body: block(body, map: map),
                    step: step.map { block($0, map: map) }, label: label, location: loc)
            case .matchStatement(let value, let cases, let loc):
                return .matchStatement(
                    value: expression(value, map: map),
                    cases: cases.map {
                        MatchCase(
                            pattern: $0.pattern, bindings: $0.bindings,
                            block: block($0.block, map: map), location: $0.location)
                    },
                    location: loc)
            case .scopedBlock(let label, let body, let loc):
                return .scopedBlock(label: label, body: block(body, map: map), location: loc)
            case .detachStatement(let expr, let loc):
                return .detachStatement(expression: expression(expr, map: map), location: loc)
            case .expressionStmt(let expr, let loc):
                return .expressionStmt(expr: expression(expr, map: map), location: loc)
            case .deferStatement(let inner, let loc):
                return .deferStatement(statement: statement(inner, map: map), location: loc)
            case .unrollStatement(let pattern, let table, let body, let loc):
                // 克隆期（map 非 nil）只替换表与体；摊开留给随后的常规遍历。
                return .unrollStatement(
                    pattern: pattern, table: expression(table, map: map), body: block(body, map: map),
                    location: loc)
            }
        }

        private func assignTarget(_ target: AssignTarget, map: [String: Expression]?) -> AssignTarget {
            switch target {
            case .identifier:
                // 模式名在这里已被预检挡下；其余名字原样保留，成员名与下标照常替换。
                return target
            case .member(let object, let name):
                return .member(object: expression(object, map: map), name: name)
            case .subscript(let expr, let index):
                return .subscript(
                    expr: expression(expr, map: map), index: expression(index, map: map))
            }
        }

        func expression(_ node: Expression, map: [String: Expression]?) -> Expression {
            switch node {
            case .identifier(let name, _):
                return map?[name] ?? node
            case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral,
                .selfKeyword, .selfTypeKeyword, .dotCaseRef:
                return node
            case .stringInterpolation(let segments, let loc):
                return .stringInterpolation(
                    segments: segments.map { segment in
                        if case .expression(let inner) = segment {
                            return .expression(expression(inner, map: map))
                        }
                        return segment
                    },
                    location: loc)
            case .binary(let left, let op, let right, let loc):
                return .binary(
                    left: expression(left, map: map), op: op, right: expression(right, map: map), location: loc)
            case .unary(let op, let operand, let loc):
                return .unary(op: op, operand: expression(operand, map: map), location: loc)
            case .call(let callee, let arguments, let loc):
                return .call(
                    callee: expression(callee, map: map),
                    arguments: arguments.map { argument($0, map: map) }, location: loc)
            case .member(let object, let name, let loc):
                return .member(object: expression(object, map: map), name: name, location: loc)
            case .tupleIndex(let object, let index, let loc):
                return .tupleIndex(object: expression(object, map: map), index: index, location: loc)
            case .tuple(let labels, let elements, let loc):
                return .tuple(
                    labels: labels, elements: elements.map { expression($0, map: map) }, location: loc)
            case .arrayLiteral(let elements, let loc):
                return .arrayLiteral(elements: elements.map { expression($0, map: map) }, location: loc)
            case .dictionaryLiteral(let entries, let loc):
                return .dictionaryLiteral(
                    entries: entries.map {
                        DictEntry(
                            key: expression($0.key, map: map),
                            value: expression($0.value, map: map),
                            valueType: $0.valueType)
                    },
                    location: loc)
            case .setLiteral(let elements, let loc):
                return .setLiteral(elements: elements.map { expression($0, map: map) }, location: loc)
            case .subscript(let expr, let index, let loc):
                return .subscript(
                    expr: expression(expr, map: map), index: expression(index, map: map), location: loc)
            case .funcLiteral(let decl, let loc):
                return .funcLiteral(decl: funcDecl(decl, map: map), location: loc)
            case .genericConstruct(let typeName, let typeArgs, let arguments, let loc):
                return .genericConstruct(
                    typeName: typeName, typeArgs: typeArgs,
                    arguments: arguments.map { argument($0, map: map) }, location: loc)
            case .join(let inner, let loc, let form):
                return .join(expression(inner, map: map), loc, form)
            case .tryExpression(let operand, let errorVar, let handler, let loc):
                return .tryExpression(
                    operand: expression(operand, map: map), errorVar: errorVar,
                    handler: block(handler, map: map), location: loc)
            case .unsafe(let operand, let loc):
                return .unsafe(operand: expression(operand, map: map), location: loc)
            case .addressOf(let operand, let loc):
                return .addressOf(operand: expression(operand, map: map), location: loc)
            }
        }

        private func argument(_ node: CallArgument, map: [String: Expression]?) -> CallArgument {
            CallArgument(label: node.label, expression: expression(node.expression, map: map))
        }
    }
}

// MARK: - 单条 unroll 的展开

extension UnrollExpander.Worker {

    /// 一条 `unroll` 换成若干轮语句。任何一步不过关就整条丢掉：错误已登记，残缺展开没有意义。
    func expand(
        pattern: [String], table: Expression, body: Block, location: SourceLocation
    ) -> [Statement] {
        let before = errors.count
        guard let rows = rows(of: table) else { return [] }
        checkBody(body, pattern: pattern)
        guard errors.count == before else { return [] }

        var out: [Statement] = []
        for (index, row) in rows.enumerated() {
            guard row.count == pattern.count else {
                errors.append(
                    .rowMismatch(
                        row: index + 1, expected: pattern.count, actual: row.count,
                        location: rowLocation(row) ?? location))
                continue
            }
            var map: [String: Expression] = [:]
            for (slot, name) in pattern.enumerated() where name != "_" {
                map[name] = row[slot]
            }
            let clone = block(body, map: map)
            out.append(contentsOf: statements(clone.statements, map: nil))
        }
        return out
    }

    /// 表求值：只认数组字面量，元素是标量字面量或由标量构成的元组。
    /// 返回 nil 表示「不是字面量集合」，此时错误已登记。
    private func rows(of table: Expression) -> [[Expression]]? {
        guard case .arrayLiteral(let elements, let loc) = table else {
            errors.append(.tableNotLiteral(location: table.location))
            return nil
        }
        if elements.isEmpty {
            errors.append(.emptyTable(location: table.location))
            return nil
        }
        if elements.count > UnrollExpander.rowLimit {
            errors.append(
                .tooManyRows(count: elements.count, limit: UnrollExpander.rowLimit, location: loc))
            return nil
        }
        var out: [[Expression]] = []
        for element in elements {
            if case .tuple(_, let components, _) = element {
                guard components.allSatisfy(isScalar) else {
                    errors.append(.tableNotLiteral(location: element.location))
                    return nil
                }
                out.append(components)
                continue
            }
            guard isScalar(element) else {
                errors.append(.tableNotLiteral(location: element.location))
                return nil
            }
            out.append([element])
        }
        return out
    }

    /// 标量字面量：整数 / 浮点 / 布尔 / 字符串。负数是「负号 + 数字字面量」，一并认。
    private func isScalar(_ node: Expression) -> Bool {
        switch node {
        case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
            return true
        case .unary(let op, let operand, _):
            guard op == .minus else { return false }
            if case .integerLiteral = operand { return true }
            if case .floatLiteral = operand { return true }
            return false
        default:
            return false
        }
    }

    private func rowLocation(_ row: [Expression]) -> SourceLocation? {
        row.first?.location
    }
}

// MARK: - 同名预检

extension UnrollExpander.Worker {

    /// 展开体里不许出现与模式同名的绑定，也不许在体顶层声明局部变量。
    /// 前者会让替换结果静默走样；后者因各轮铺在同一条语句列表里，跨轮必然重名。
    func checkBody(_ body: Block, pattern: [String]) {
        let names = Set(pattern.filter { $0 != "_" })
        for item in body.statements { check(item, names: names, topLevel: true) }
    }

    private func conflict(_ name: String, names: Set<String>, topLevel: Bool, _ loc: SourceLocation) {
        if names.contains(name) {
            errors.append(
                .bodyNameConflict(
                    name: name, reason: "与模式同名，替换后会被静默覆盖", location: loc))
        } else if topLevel {
            errors.append(
                .bodyNameConflict(
                    name: name, reason: "各轮铺在同一条语句列表里，局部声明会跨轮重名", location: loc))
        }
    }

    private func check(_ node: Statement, names: Set<String>, topLevel: Bool) {
        switch node {
        case .varDecl(let name, _, _, _, let loc):
            conflict(name, names: names, topLevel: topLevel, loc)
        case .varDestructure(let list, _, _, _, let loc):
            for name in list { conflict(name, names: names, topLevel: topLevel, loc) }
        case .captureStatement(let name, let loc):
            conflict(name, names: names, topLevel: topLevel, loc)
        case .assign(let target, let value, let loc):
            if case .identifier(let name) = target, names.contains(name) {
                errors.append(
                    .bodyNameConflict(
                        name: name, reason: "模式名会被替换成字面量，不能作赋值目标", location: loc))
            }
            if case .member(let object, _) = target { scan(object, names: names) }
            if case .subscript(let expr, let index) = target {
                scan(expr, names: names)
                scan(index, names: names)
            }
            scan(value, names: names)
        case .returnStatement(let value, _):
            if let value { scan(value, names: names) }
        case .breakStatement, .continueStatement, .passStatement:
            break
        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
            scan(condition, names: names)
            for item in thenBlock.statements { check(item, names: names, topLevel: false) }
            for branch in elifs {
                scan(branch.condition, names: names)
                for item in branch.block.statements { check(item, names: names, topLevel: false) }
            }
            for item in elseBlock?.statements ?? [] { check(item, names: names, topLevel: false) }
        case .whileStatement(let condition, let body, let step, _, _):
            scan(condition, names: names)
            for item in body.statements { check(item, names: names, topLevel: false) }
            for item in step?.statements ?? [] { check(item, names: names, topLevel: false) }
        case .forStatement(let pattern, let iterable, let body, let step, _, let loc):
            for name in pattern { conflict(name, names: names, topLevel: false, loc) }
            scan(iterable, names: names)
            for item in body.statements { check(item, names: names, topLevel: false) }
            for item in step?.statements ?? [] { check(item, names: names, topLevel: false) }
        case .matchStatement(let value, let cases, _):
            scan(value, names: names)
            for item in cases {
                for binding in item.bindings {
                    conflict(binding.varName, names: names, topLevel: false, item.location)
                }
                for statement in item.block.statements { check(statement, names: names, topLevel: false) }
            }
        case .scopedBlock(_, let body, _):
            for item in body.statements { check(item, names: names, topLevel: false) }
        case .detachStatement(let expr, _):
            scan(expr, names: names)
        case .expressionStmt(let expr, _):
            scan(expr, names: names)
        case .deferStatement(let inner, _):
            check(inner, names: names, topLevel: false)
        case .unrollStatement(let pattern, let table, let body, let loc):
            for name in pattern { conflict(name, names: names, topLevel: false, loc) }
            scan(table, names: names)
            for item in body.statements { check(item, names: names, topLevel: false) }
        }
    }

    private func scan(_ node: Expression, names: Set<String>) {
        switch node {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral,
            .selfKeyword, .selfTypeKeyword, .dotCaseRef:
            break
        case .stringInterpolation(let segments, _):
            for segment in segments {
                if case .expression(let inner) = segment { scan(inner, names: names) }
            }
        case .binary(let left, _, let right, _):
            scan(left, names: names)
            scan(right, names: names)
        case .unary(_, let operand, _):
            scan(operand, names: names)
        case .call(let callee, let arguments, _):
            scan(callee, names: names)
            for item in arguments { scan(item.expression, names: names) }
        case .member(let object, _, _):
            scan(object, names: names)
        case .tupleIndex(let object, _, _):
            scan(object, names: names)
        case .tuple(_, let elements, _):
            for item in elements { scan(item, names: names) }
        case .arrayLiteral(let elements, _), .setLiteral(let elements, _):
            for item in elements { scan(item, names: names) }
        case .dictionaryLiteral(let entries, _):
            for entry in entries {
                scan(entry.key, names: names)
                scan(entry.value, names: names)
            }
        case .subscript(let expr, let index, _):
            scan(expr, names: names)
            scan(index, names: names)
        case .genericConstruct(_, _, let arguments, _):
            for item in arguments { scan(item.expression, names: names) }
        case .join(let inner, _, _), .unsafe(let inner, _), .addressOf(let inner, _):
            scan(inner, names: names)
        case .funcLiteral(let decl, _):
            for param in decl.params { conflict(param.name, names: names, topLevel: false, decl.location) }
            for item in decl.body?.statements ?? [] { check(item, names: names, topLevel: false) }
        case .tryExpression(let operand, let errorVar, let handler, _):
            scan(operand, names: names)
            conflict(errorVar, names: names, topLevel: false, handler.location)
            for item in handler.statements { check(item, names: names, topLevel: false) }
        }
    }
}

// MARK: - 表达式的报错位置

extension Expression {
    /// 表达式起点的源位置。只有报错要用，故不追求覆盖全部语义，按分支取自身位置。
    var location: SourceLocation {
        switch self {
        case .identifier(_, let loc), .integerLiteral(_, let loc), .floatLiteral(_, let loc),
            .stringLiteral(_, let loc), .boolLiteral(_, let loc),
            .selfKeyword(let loc), .selfTypeKeyword(let loc), .dotCaseRef(_, let loc),
            .stringInterpolation(_, let loc), .binary(_, _, _, let loc),
            .unary(_, _, let loc), .call(_, _, let loc), .member(_, _, let loc),
            .tupleIndex(_, _, let loc), .tuple(_, _, let loc), .arrayLiteral(_, let loc),
            .dictionaryLiteral(_, let loc), .setLiteral(_, let loc), .subscript(_, _, let loc),
            .funcLiteral(_, let loc), .genericConstruct(_, _, _, let loc),
            .join(_, let loc, _), .tryExpression(_, _, _, let loc), .unsafe(_, let loc),
            .addressOf(_, let loc):
            return loc
        }
    }
}
