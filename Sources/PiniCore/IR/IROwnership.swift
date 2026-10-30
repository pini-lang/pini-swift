/// 所有权分类：一个类型在存储点上的接收规则。它是 IR 事实，不是目标表示 —— 后端据此选动作与运行时
/// 符号，不再按 LLVM 拼写反推。拼写属后端，换表示（改聚合形态、换目标）时它会变，而分类一变，
/// 失效的形态是「某一族悄悄不再释放」，不是报错。
public enum IROwnershipClass: Equatable, Sendable {
    /// 不握份额：标量 · 外部指针 · 任务句柄。落槽零动作，退出不释放。
    case inert
    /// 寄存器聚合：`Result` · `Optional` · 元组 · 函数值。整块按值搬移。
    ///  注意  聚合内部的计数成员尚未单独保留，是契约第 4 节登记的缺口，不是「它们可以不要份额」。
    case aggregate
    /// 名义结构体：堆上带计数头的箱，但值语义 —— 变量 / 字段 / 返回落槽要拷出独立的一份；
    /// 装进容器元素时按箱共享，保留一份。对象与枚举不属此类：它们按引用共享。
    case valueBox
    /// 计数族：落槽要保留一份，覆盖或退出要释放一份。细分只决定用哪套运行时符号。
    case retained(IRShareKind)
}

/// 计数族的细分。七种都按「保留 / 释放」计数，只是符号不同 —— 故它不改变所有权规则。
public enum IRShareKind: Equatable, Sendable {
    /// `String` · `Char`：带计数头的 C 串，两者同构。
    case string
    /// `Array<T>`：不透明句柄，写入前唯一化。
    case array
    /// `Dictionary<K, V>`：键值有序的不透明句柄。
    case dict
    /// `Set<T>`：有序去重的不透明句柄。
    case set
    /// 引用语义的名义类型（对象）。
    case object
    /// 用户枚举：标签联合箱，按引用共享。
    case enumeration
    /// `LazyRef<T>`：一次性求值的共享句柄。
    case lazyRef
}

extension IRType {
    /// 这个类型的接收规则。每个 case 逐一表态，不留 `default`：新增类型必须在这里选一族，
    /// 否则编不过 —— 兜底归族会让新类型静默继承一套它未必成立的所有权。
    public var ownershipClass: IROwnershipClass {
        switch self {
        case .i8, .u8, .i32, .i64, .u64, .f64, .boolean: return .inert
        case .string, .char: return .retained(.string)
        case .array: return .retained(.array)
        case .dict: return .retained(.dict)
        case .set: return .retained(.set)
        case .lazyRef: return .retained(.lazyRef)
        case .nominal(_, let isObject): return isObject ? .retained(.object) : .valueBox
        case .enumeration: return .retained(.enumeration)
        case .result, .optional, .tuple, .function: return .aggregate
        case .future, .pointer: return .inert
        }
    }

    /// 这个类型的一个值落进存储点时，接收方要做的动作。三种输入决定它：目标类型（要不要占份额）·
    /// 来源是否别名（占的话拷贝还是保留）· 其余情况移交。标量与聚合一律 `.none`，不记账。
    /// `sharingStructs` 给容器元素用：容器元素按箱共享（保留），变量 / 字段 / 返回才拷出独立的箱。
    public func adoption(of source: IRExpr?, sharingStructs: Bool = false) -> IRAdopt {
        guard let source else { return .none }
        switch ownershipClass {
        case .inert, .aggregate: return .none
        case .valueBox:
            guard source.yieldsAlias else { return .take }
            return sharingStructs ? .retain : .copyStruct
        case .retained: return source.yieldsAlias ? .retain : .take
        }
    }

    /// 这个类型的槽 / 字段是否握着一份份额 —— 覆盖它之前要先释放旧值。与 `adoption` 分开：
    /// 那个说「新值怎么进来」，这个说「旧值要不要走」。
    public var holdsAShare: Bool {
        switch ownershipClass {
        case .valueBox, .retained: return true
        case .inert, .aggregate: return false
        }
    }
}

/// 存储点的接收动作。它由中端填、后端翻译 —— 后端不再自己判「这里该 retain 还是直接接管」。
public enum IRAdopt: Equatable, Sendable {
    /// 不接份额：标量 · 聚合 · 外部指针。落槽零动作。
    case none
    /// 移交：来源是临时值，份额直接转给存储点，零额外动作。
    case take
    /// 拷贝：来源是结构体别名，值语义要求拷出独立的一份。
    case copyStruct
    /// 保留：来源是计数族的别名，来源仍握着自己那一份。
    case retain
}

extension IRExpr {
    /// 这个表达式读的是别处的持有位置（别名点）：变量读 · 下标读 · 字段读 · 可空读。
    /// 它的补集是「本次求值新造出来的值」，那类值可以把份额直接交出去。
    public var yieldsAlias: Bool {
        switch self {
        case .load, .subscriptGet, .fieldGet, .optionalGet: return true
        default: return false
        }
    }
}
