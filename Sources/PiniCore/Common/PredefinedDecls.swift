import Foundation
import PiniSyntax

/// 语言预置声明：一批既不来自用户源码、也不来自被解析的源的声明，由宿主提供。本件是它们的
/// 唯一出处——类型层与降载层都从这里取，不各写一份（两份迟早会漂，且漂时没有判据会变红）。
/// 位置人造、不写成路径形态以免有人去磁盘上找文件；将来改由 Pini 源提供时只换本件内容。
enum PredefinedDecls {

    /// 预置声明的来源标记。
    static let sourceName = "<预置声明>"

    /// 预置声明的**位置**。行列为 0：它不对应任何真实字符。
    static var location: SourceLocation {
        SourceLocation(line: 0, column: 0, fileName: sourceName)
    }

    /// 调度特征的预置给定块：语言提供的默认调度实例。一个名字两种角色——特征是接口（`实现:` 位可
    /// 引用），给定块是默认实例的类型（取用点只认给定块，只给特征则 `using` 形参在降载期解析不出）。
    /// 字段 `名称` / `可让出` / `元素` 分别是取到哪个实例、能否交回线程（不能则退化为占用）、待跑哪些任务。
    static var schedulerGivenBlock: TopLevelDecl {
        let loc = location
        let handleType = TypeAnnotation.pointer(
            element: .simple(name: "U8", location: loc), location: loc)
        /// 策略层方法的真实现住在这份声明自己身上：方法是声明的组成部分，故这份声明让位（用户声明同名块）
        /// 时方法跟着让位，无需额外机制；挂在扩展块上则会归并到用户那份声明上，而那里没有队列字段。
        /// 给定块体内本不许写方法（解析层拒），本处由宿主构造、不经解析器；形参表不含 `self`。
        let selfExpr = Expression.selfKeyword(location: loc)
        let queueRead = Expression.member(object: selfExpr, name: queueField, location: loc)
        let acceptTask = FuncDecl(
            name: acceptMethodName,
            modifiers: [],
            genericParams: [],
            params: [Parameter(name: "任务", typeAnnotation: handleType)],
            returnTypes: [],
            body: Block(
                statements: [
                    //  注意  队列字段走**函数式**更新（`append` 返回新数组）⇒ 必须写回字段，
                    // 否则收到的任务静默丢掉，而调用方看不出任何异常。
                    .assign(
                        target: .member(object: selfExpr, name: queueField),
                        value: .call(
                            callee: .member(object: queueRead, name: "append", location: loc),
                            arguments: [
                                CallArgument(expression: .identifier(name: "任务", location: loc))
                            ],
                            location: loc),
                        location: loc)
                ],
                location: loc),
            location: loc)
        /// 另一个方法的真实现：取队首并移出队列（先进先出）。必须有真实现，不能只靠特征默认体——
        /// 默认体只满足一致性校验，不产生该类型的成员方法，调用点会在降载层报「该类型没有这个方法」。
        let pickNext = FuncDecl(
            name: pickMethodName,
            modifiers: [],
            genericParams: [],
            params: [],
            returnTypes: [handleType],
            body: Block(
                statements: [
                    .varDecl(
                        name: "队首", typeAnnotation: nil,
                        initializer: .call(
                            callee: .member(object: queueRead, name: "get", location: loc),
                            arguments: [
                                CallArgument(expression: .integerLiteral(value: 0, location: loc))
                            ],
                            location: loc),
                        isMutable: false, location: loc),
                    //  注意  取出来的**是 Optional**（`get` 的契约：越界给 none）⇒ 必须解包。
                    // 两支都返回 `*U8`：有货给货，无货给空句柄 —— 空队列那一格就落在这里。
                    .matchStatement(
                        value: .identifier(name: "队首", location: loc),
                        cases: [
                            MatchCase(
                                pattern: .enumCase("some"),
                                bindings: [MatchBinding(paramName: nil, varName: "任务")],
                                block: Block(
                                    statements: [
                                        // 取走了就得**移走**：队列字段是函数式更新，
                                        // 漏了这一步，下一次还会拿到同一个任务。
                                        .assign(
                                            target: .member(object: selfExpr, name: queueField),
                                            value: .call(
                                                callee: .member(
                                                    object: queueRead, name: "slice", location: loc),
                                                arguments: [
                                                    CallArgument(expression: .integerLiteral(value: 1, location: loc)),
                                                    CallArgument(expression: .call(
                                                        callee: .identifier(name: "len", location: loc),
                                                        arguments: [CallArgument(expression: queueRead)],
                                                        location: loc)),
                                                ],
                                                location: loc),
                                            location: loc),
                                        .returnStatement(
                                            value: .identifier(name: "任务", location: loc),
                                            location: loc),
                                    ],
                                    location: loc),
                                location: loc),
                            MatchCase(
                                pattern: .enumCase("none"), bindings: [],
                                block: Block(
                                    statements: [
                                        .returnStatement(
                                            value: .identifier(
                                                name: BuiltinRegistry.emptyHandleName, location: loc),
                                            location: loc)
                                    ],
                                    location: loc),
                                location: loc),
                        ],
                        location: loc),
                ],
                location: loc),
            location: loc)
        return .givenDecl(
            GivenDecl(
                name: schedulerTypeName,
                genericParams: [],
                fields: [
                    FieldDecl(
                        name: "名称",
                        typeAnnotation: .simple(name: "String", location: loc),
                        initializer: .stringLiteral(value: "默认", location: loc),
                        location: loc
                    ),
                    FieldDecl(
                        name: yieldCapabilityField,
                        typeAnnotation: .simple(name: "Bool", location: loc),
                        initializer: .boolLiteral(value: true, location: loc),
                        location: loc
                    ),
                    //  重要  就绪队列 —— 策略层的**状态**，也是「选择下一个任务」可挑的那个集合。
                    // 元素是**不透明标量句柄** ⇒ 本层不解释它指向什么。
                    //  注意  初值空数组就是「刚建好的调度器」的实况，不是占位。
                    FieldDecl(
                        name: queueField,
                        typeAnnotation: .generic(
                            name: "Array", params: [handleType], location: loc),
                        initializer: .arrayLiteral(elements: [], location: loc),
                        location: loc
                    ),
                ],
                methods: [acceptTask, pickNext],
                traits: [schedulerTypeName],
                location: loc
            )
        )
    }

    /// 调度特征的**语言可见名**。类型层登记的那个特征与上面的给定块同名。
    static let schedulerTypeName = "调度器"

    /// 策略层两个方法的语言可见名。名字住在这里而不是读取处：声明方与各后端的调用方都要用它拼
    /// 方法表里的键，三处各写一份字面量，改名时必然对不上，而那一刻不会有一条判据变红。
    static let acceptMethodName = "收下"
    static let pickMethodName = "选择下一个任务"

    /// 语言侧声明「本调度器能否让出」的字段名。名字住在这里而不是读取处：字段名是声明的一部分，
    /// 读取方与声明方各写一份，迟早在改名时对不上而无一条判据变红。
    static let yieldCapabilityField = "可让出"

    /// 就绪队列的字段名。名字住在这里而不是读取处：声明方与扩展块里的两个真实现都要用它，
    /// 各写一份必然在改名时对不上，而那一刻不会有一条判据变红。
    static let queueField = "元素"

    /// 全部预置声明。两个消费者都从这里取。
    static var all: [TopLevelDecl] { [schedulerGivenBlock] }

    /// 本模块**占用**了哪些顶级名字（占用 ⇒ 预置声明让位）。这里是这条规则的唯一定义：类型层的
    /// 值位诊断与降载层的名义表 / 类型表都从本函数取。判据取「占用名字」而非「同名且同类」，因为
    /// 用户同名函数也会被当成构造调用而静默换义；扩展块与 `foreign` 块名刻意不算占名。
    static func claimedNames(in declarations: [TopLevelDecl]) -> Set<String> {
        var names: Set<String> = []
        for decl in declarations {
            switch decl {
            case .funcDecl(let d): names.insert(d.name)
            case .structDecl(let d): names.insert(d.name)
            case .objectDecl(let d): names.insert(d.name)
            case .givenDecl(let d): names.insert(d.name)
            case .enumDecl(let d): names.insert(d.name)
            case .traitDecl(let d): names.insert(d.name)
            case .foreignDecl(let d):
                for foreignFunc in d.funcs { names.insert(foreignFunc.name) }
            case .varDecl(let statement), .statement(let statement):
                if case .varDecl(let name, _, _, _, _) = statement { names.insert(name) }
            case .extensionDecl, .importDecl, .exportDecl: break
            }
        }
        return names
    }

    /// 预置声明里，**名字未被本模块占用**的那些。**让位规则的唯一落点。**
    ///
    ///  注意  局部名不参与判定：同名的局部变量 / 形参本就由作用域遮蔽类型名，与此无关。
    static func effective(in declarations: [TopLevelDecl]) -> [TopLevelDecl] {
        let claimed = claimedNames(in: declarations)
        return all.filter { decl in
            guard case .givenDecl(let given) = decl else { return true }
            return !claimed.contains(given.name)
        }
    }

    /// 生效的预置给定块名字，供「给定块类型名不是值」那条诊断用。它与 `effective` 同源而非第二份
    /// 判定：那句诊断问的正是「这个名字现在是不是一个给定块」，亦即「预置那份有没有让位」。
    static func effectiveGivenBlockNames(in declarations: [TopLevelDecl]) -> Set<String> {
        var names: Set<String> = []
        for decl in effective(in: declarations) {
            if case .givenDecl(let given) = decl { names.insert(given.name) }
        }
        return names
    }
}
