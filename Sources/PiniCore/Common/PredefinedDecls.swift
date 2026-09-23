import Foundation

/// 语言预置声明 —— **由宿主给出**的那份声明表。
///
/// 语言里有一批名字既不来自用户源码、也不来自任何被解析的源：它们的声明由宿主提供。
/// 本件是**它们的唯一出处** —— 类型层与降载层都从这里取，⛔ 不各写一份
/// （两份迟早会漂，而漂的那一刻不会有任何一条判据变红）。
///
/// ⭐ **一处接缝，专为自举留的余量**：今天这份声明由 Swift 构造、初值也在 Swift 里定下；
/// 将来若改由 Pini 源提供，**只换本件的内容** —— 取用点、调用方、判据都不动。
/// ⇒ 判据因此只针对「默认实例可取得、且其可观测面读得出」，⛔ 不断言它由谁构造。
///
/// ⚠️ 预置声明的**位置**不是文件位置：它给一个人造名，且**不写成路径形态** ——
/// 写成路径会让人去磁盘上找一份并不存在的文件。
enum PredefinedDecls {

    /// 预置声明的来源标记。
    static let sourceName = "<预置声明>"

    /// 预置声明的**位置**。行列为 0：它不对应任何真实字符。
    static var location: SourceLocation {
        SourceLocation(line: 0, column: 0, fileName: sourceName)
    }

    /// 调度特征的预置给定块 —— 语言提供的**默认调度实例**。
    ///
    /// ⭐ **一个名字两种角色**（实测二者并存、零诊断）：
    /// **特征**是接口（`实现:` 位的可引用对象），**给定块**是默认实例的类型
    /// （取用点只认给定块 —— 只有特征形态时，`using` 形参在降载期解析不出类型）。
    ///
    /// 三个字段各回答一个问题 —— `名称`：**取到的是哪一个默认实例**；
    /// `可让出`：**这个调度器能不能真的把线程交回去**；`元素`：**它手上待跑的是哪些任务**。
    ///
    /// ⭐ `可让出`**不是策略**，而是执行策略里唯一有一个**可用替代值**的那一格：
    /// 声明不能让出时，等待退化为占用线程、程序照常跑完（既有规范纪律：降级而不失败）。
    /// ⇒ 它是这条语言侧接线今天唯一能承重的载荷 —— 派发点读了它，行为**可观测地**不同。
    ///
    /// ⭐ 声明 `实现:` 它自己的特征 —— 一个名字的两种角色在此合流：特征给接口、
    /// 给定块给默认实例，而这条遵循关系让「默认实例满足那份接口」成为**可校验**的。
    /// ⚠️ 它不要求本处提供任何方法：那个特征的两个签名都带默认体，而一致性校验只对
    /// **无体**签名要求实现 ⇒ 默认实例不必自己再写一遍。真实现住在**预置扩展块**里 ——
    /// 只有目标类型具体的扩展块写得出 `self.元素`（特征没有「字段要求」机制）。
    static var schedulerGivenBlock: TopLevelDecl {
        let loc = location
        let handleType = TypeAnnotation.pointer(
            element: .simple(name: "U8", location: loc), location: loc)
        // ⭐ 策略层方法的**真实现**住在这份声明**自己**身上 —— 这不是省事，是**让位规则使然**：
        // 方法是声明的组成部分 ⇒ 这份声明让位（用户自己声明同名块）时，方法**跟着让位**，
        // 不需要任何额外机制。⚠️ 挂在扩展块上则不然：目标被顶掉后方法仍会归并到**用户那份**
        // 声明上，而那里没有队列字段 —— 实测形态就是「找不到字段」与「响亮拒绝」两种。
        //
        // ⚠️ 给定块**体内**不许写方法，那是**解析层**拒的形态；本处由宿主构造、不经解析器。
        // ⚠️ 形参表**不含** `self`：体内方法是隐式 self（扩展块才要求显式写），
        // 而调用点校验按本表算实参个数。
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
                    // ⚠️ 队列字段走**函数式**更新（`append` 返回新数组）⇒ 必须写回字段，
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
        // ⭐ 另一个方法的真实现：取队首并把它移出队列（先进先出）。
        //
        // ⚠️ 它**必须**有真实现，不能只靠特征默认体：默认体只满足一致性校验，
        // **不产生这个类型的成员方法** ⇒ 调用点在降载层报「该类型没有这个方法」。
        // 实测形态就是那条判据的读数。
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
                    // ⚠️ 取出来的**是 Optional**（`get` 的契约：越界给 none）⇒ 必须解包。
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
                    // ⭐ 就绪队列 —— 策略层的**状态**，也是「选择下一个任务」可挑的那个集合。
                    // 元素是**不透明标量句柄** ⇒ 本层不解释它指向什么。
                    // ⚠️ 初值空数组就是「刚建好的调度器」的实况，不是占位。
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

    /// 策略层两个方法的**语言可见名**。
    ///
    /// ⭐ 名字住在这里而不是读取处（与 `yieldCapabilityField` / `queueField` 同一条纪律）：
    /// 本文件里的声明方要用它们，而**两条腿各自的调用方**也要用它们拼方法表里的键 ——
    /// 三处各写一份字面量，改名时必然对不上，而那一刻**不会有一条判据变红**。
    static let acceptMethodName = "收下"
    static let pickMethodName = "选择下一个任务"

    /// 语言侧声明「本调度器能否让出」的字段名。
    ///
    /// 名字住在这里而不是读取处：字段名是**声明**的一部分，
    /// 读取方与声明方各写一份，迟早在改名时对不上而无一条判据变红。
    static let yieldCapabilityField = "可让出"

    /// 就绪队列的字段名。
    ///
    /// 名字住在这里而不是读取处，理由同上：声明方与扩展块里的两个真实现都要用它，
    /// 各写一份必然在改名时对不上，而那一刻**不会有一条判据变红**。
    static let queueField = "元素"

    /// 全部预置声明。两个消费者都从这里取。
    static var all: [TopLevelDecl] { [schedulerGivenBlock] }

    /// 本模块**占用**了哪些顶级名字。占用了 ⇒ 预置声明让位。
    ///
    /// ⭐ **这里是这条规则的唯一定义**：类型层（值位诊断）与降载层（名义表 · 类型表）
    /// 都从本函数取 —— 各写一份必然漂，而漂的那一刻**不会有一条判据变红**。
    ///
    /// ⚠️ 为什么判据是「**占用名字**」这么宽，而不是「同名且同类」：反例是用户自己写一个
    /// 同名**函数**并在调用点用它 —— 只按同类判会漏掉它，而漏掉的后果是那处调用被解析成
    /// 「该类型的构造」⇒ **既有程序静默换义**（报的是「构造函数不支持实参」这类**下游**错误，
    /// 读起来像语法缺功能，而不像名字冲突）。这类名字的处置是**软关键字**：它**不作保留字**。
    ///
    /// ⚠️ 两处**刻意不**算占名的形态：
    /// - **扩展块** —— 它挂在一个别处声明的类型上（给预置块加方法正是正当用法）；
    ///   把扩展算成占名，会让这种用法反过来把预置声明挤掉。
    /// - **`foreign` 块名** —— 那个名字按定义只作组织名、不参与符号解析；
    ///   真正占名的是块内的外部函数，故取它们的名字。
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
    /// ⚠️ 局部名不参与判定：同名的局部变量 / 形参本就由作用域遮蔽类型名，与此无关。
    static func effective(in declarations: [TopLevelDecl]) -> [TopLevelDecl] {
        let claimed = claimedNames(in: declarations)
        return all.filter { decl in
            guard case .givenDecl(let given) = decl else { return true }
            return !claimed.contains(given.name)
        }
    }

    /// 生效的预置**给定块**名字。给那条「给定块类型名不是值」的诊断用。
    ///
    /// ⚠️ 它与 `effective` 同源，不是第二份判定 —— 那句诊断问的正是「这个名字现在是不是
    /// 一个给定块」，而那与「预置那份有没有让位」是同一个问题。
    static func effectiveGivenBlockNames(in declarations: [TopLevelDecl]) -> Set<String> {
        var names: Set<String> = []
        for decl in effective(in: declarations) {
            if case .givenDecl(let given) = decl { names.insert(given.name) }
        }
        return names
    }
}
