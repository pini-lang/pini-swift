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
    /// ⛔ **字段表只有两个字段，不是遗漏**：策略自身的状态
    /// （队列 · 优先级 · 归约阈值）的形状，依附于「**任务在语言里怎么表示**」这一面，
    /// 而那一面今天还没有载体 ⇒ 在此预置字段等于替一个未决的形状做承诺。
    ///
    /// 两个字段各回答一个问题 —— `名称`：**取到的是哪一个默认实例**；
    /// `可让出`：**这个调度器能不能真的把线程交回去**。
    ///
    /// ⭐ 后者**不是策略**，而是执行策略里唯一有一个**可用替代值**的那一格：
    /// 声明不能让出时，等待退化为占用线程、程序照常跑完（既有规范纪律：降级而不失败）。
    /// ⇒ 它是这条语言侧接线今天唯一能承重的载荷 —— 派发点读了它，行为**可观测地**不同。
    ///
    /// ⛔ **不声明 `实现:` 它自己的特征**：该特征的抽象方法集今天为空，
    /// 此刻声明这条遵循关系**不携带任何内容**。待方法集随任务载体定下时，
    /// 应当**连同默认方法体一起**作一次决定 —— 那时这条遵循关系才有内容可约束。
    static var schedulerGivenBlock: TopLevelDecl {
        let loc = location
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
                ],
                methods: [],
                traits: [],
                location: loc
            )
        )
    }

    /// 调度特征的**语言可见名**。类型层登记的那个特征与上面的给定块同名。
    static let schedulerTypeName = "调度器"

    /// 语言侧声明「本调度器能否让出」的字段名。
    ///
    /// 名字住在这里而不是读取处：字段名是**声明**的一部分，
    /// 读取方与声明方各写一份，迟早在改名时对不上而无一条判据变红。
    static let yieldCapabilityField = "可让出"

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
