import Foundation
import PiniSyntax

/// 内建单点登记表：每个内建在此声明一次（名字 + 归组 + 各层登记开关），三个消费方从本表派生。
/// 语义层按 `definesSymbol` 登记符号、类型层按 `typeSignature` 登记签名、解释器按
/// `definesRuntimeValue` 定义函数值。本表只承载声明：指针、并发、枚举构造器走专属路径。
public enum BuiltinGroup: String, CaseIterable, Sendable {
    case collection
    case char
    case pointer
    case io
    case math
    case concurrency
    case value
    /// C 边界的字符串转换：出去那侧 `cstr` 是 shim 名（调用方在 foreign 块里声明），
    /// 回来那侧 `c字符串` 是这里的条目。
    case ffi
}

public struct BuiltinDecl: Sendable {
    public let name: String
    public let group: BuiltinGroup
    /// Interpreter 侧 FunctionValue 的形参名（须与既有分发实现一致）。
    ///  注意  值条目为空数组 —— 一个值没有形参可标。
    public let paramNames: [String]
    /// nil = 类型层签名由专属路径登记（泛型/指针/构造器特化），本表只记名与组
    public let typeSignature: (params: [TypeAnnotation], returns: [TypeAnnotation], isVariadic: Bool)?
    /// 本条目是**值**时它的类型；非 nil ⇒ 本条目不是函数。值是函数的第二种形态，理由不是方便，而是
    /// 语言里确有这样一批名字：它们本身就是值，按名读到即可，没有调用点、形参或「调用才得到值」。
    /// 消费方据此分流：语义层按值登记符号 · 类型层按值登记类型 · 降载层对它直出常量。
    public let valueType: TypeAnnotation?
    /// 是否由 SemanticAnalyzer 在符号表登记（调用点 undefinedFunction 检查依赖）
    public let definesSymbol: Bool
    /// 是否由 Interpreter.registerBuiltins 循环定义运行时函数值
    /// （false：由专属路径定义，如 registerPointerBuiltins / registerConcurrencyBuiltins）
    public let definesRuntimeValue: Bool

    public init(
        name: String,
        group: BuiltinGroup,
        paramNames: [String] = [],
        params: [TypeAnnotation]? = nil,
        returns: [TypeAnnotation]? = nil,
        isVariadic: Bool = false,
        valueType: TypeAnnotation? = nil,
        definesSymbol: Bool = true,
        definesRuntimeValue: Bool = true
    ) {
        self.name = name
        self.group = group
        self.paramNames = paramNames
        self.typeSignature = params.map { ($0, returns ?? [], isVariadic) }
        self.valueType = valueType
        self.definesSymbol = definesSymbol
        self.definesRuntimeValue = definesRuntimeValue
    }
}

public enum BuiltinRegistry {
    public static let builtinLocation = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

    /// 空句柄的语言可见名——策略层「队列为空」的返回值。单一出处：语义层（登记为变量）· 类型层
    /// （登记类型）· 降载层（裸名字直出常量）三处都从这里取，各写一份必然漂，且漂时无判据会变红。
    public static let emptyHandleName = "空句柄"

    /// 按名取内建**值**的类型；不是值（或没有这个名字）⇒ nil。
    ///
    /// 与 `member(typeName:name:)` 同形：消费方按需查询， 行不通  不各自遍历 `decls` 重写一遍判定。
    public static func builtinValueType(named name: String) -> TypeAnnotation? {
        for decl in decls where decl.valueType != nil && decl.name == name {
            return decl.valueType
        }
        return nil
    }

    private static func t(_ name: String) -> TypeAnnotation {
        .simple(name: name, location: builtinLocation)
    }

    /// 内建归组表 归组清单（唯一事实源）。旧调用名全部保留，零破坏。
    public static let decls: [BuiltinDecl] = [
        // ---- collection ----
        BuiltinDecl(
            name: "len", group: .collection, paramNames: ["value"],
            params: [t("Any")], returns: [t("I32")]),

        // ---- value ----
        BuiltinDecl(
            name: "print", group: .value, paramNames: ["value"],
            params: [t("Any")], returns: [], isVariadic: true),
        BuiltinDecl(
            name: "assert", group: .value, paramNames: ["条件", "消息"],
            params: [t("Bool"), t("String")], returns: [], isVariadic: true),
        // ok/err/Error/CancelError：Result/错误构造器，专属路径
        // （registerEnumCaseConstructor / registerConcurrencyBuiltins）登记
        BuiltinDecl(name: "ok", group: .value, paramNames: ["value"], definesRuntimeValue: false),
        BuiltinDecl(name: "err", group: .value, paramNames: ["value"], definesRuntimeValue: false),
        BuiltinDecl(name: "Error", group: .value, paramNames: ["message"], definesRuntimeValue: false),
        // F64 值构造——没有它整型表达式无法参与浮点算术（E5-003 混合算术拒绝）。
        // 最小面：int→float、float 原样；字符串解析另行提案。
        BuiltinDecl(
            name: "F64", group: .value, paramNames: ["value"],
            params: [t("Any")], returns: [t("F64")]),
        BuiltinDecl(name: "CancelError", group: .value, paramNames: ["message"], definesRuntimeValue: false),

        // 字符谓词与 `ord` 取 `Char` 参数面；`chars` 仍收 `String`（契约是 len(chars(s)) == len(s)，
        // 收 `Char` 会退化成恒返回单元素数组）：只有元素类型是 `Char`；`chr` 返回 `Char`。
        BuiltinDecl(
            name: "is_letter", group: .char, paramNames: ["value"],
            params: [t("Char")], returns: [t("Bool")]),
        BuiltinDecl(
            name: "is_ascii_digit", group: .char, paramNames: ["value"],
            params: [t("Char")], returns: [t("Bool")]),
        BuiltinDecl(
            name: "is_number", group: .char, paramNames: ["value"],
            params: [t("Char")], returns: [t("Bool")]),
        BuiltinDecl(
            name: "chars", group: .char, paramNames: ["value"],
            params: [t("String")], returns: [.generic(name: "Array", params: [t("Char")], location: builtinLocation)]),
        /// 码点原语：解锁字符范围判定（hex 判定等）与 upper/lower 下沉；ord 取首 Unicode scalar，
        /// 对齐 grapheme 模型。`Char` 参数恒为 1 个字素，故 ord 的「空串」哨兵不可表达；
        /// `chr` 越界 / 代理区 panic（`RuntimeError.indexOutOfRange`，与 `s[i]` 同通道，不新增诊断码）。
        BuiltinDecl(
            name: "ord", group: .char, paramNames: ["value"],
            params: [t("Char")], returns: [t("I32")]),
        BuiltinDecl(
            name: "chr", group: .char, paramNames: ["code"],
            params: [t("I32")], returns: [t("Char")]),

        // ---- pointer（unsafe；专属路径 registerPointerBuiltins）----
        BuiltinDecl(name: "load", group: .pointer, paramNames: ["p"], definesRuntimeValue: false),
        BuiltinDecl(name: "store", group: .pointer, paramNames: ["p", "v"], definesRuntimeValue: false),
        BuiltinDecl(name: "addressof", group: .pointer, paramNames: ["value"], definesRuntimeValue: false),
        /// 本表第一个非函数条目：策略层的空句柄，即就绪队列为空时的返回值。队列元素是不透明标量句柄，
        /// 而语言目前构造不出这种值（`addressof` 未实现，`nil` 类型不匹配），且用户写自己的策略时也要
        /// 写空队列分支。`definesRuntimeValue: false`——它由降载层直出常量，解释器无新增求值分支。
        BuiltinDecl(
            name: emptyHandleName, group: .pointer,
            valueType: .pointer(element: t("U8"), location: builtinLocation),
            definesRuntimeValue: false),

        // ---- io ----
        // 程序基准查询——模块根（单文件=入口文件所在目录），绝对路径。
        BuiltinDecl(
            name: "moduleRoot", group: .io, paramNames: [],
            params: [], returns: [t("String")]),
        // F6：命令行参数透传（脚本路径之后的裸参数；LLVM 端暂 unsupported）。
        BuiltinDecl(
            name: "argv", group: .io, paramNames: [],
            params: [], returns: [t("Array")]),
        BuiltinDecl(
            name: "readFile", group: .io, paramNames: ["path"],
            params: [t("String")], returns: [t("String")]),
        // writeFile 无返回值：写失败即 panic，成功没有可回传的结果。
        BuiltinDecl(
            name: "writeFile", group: .io, paramNames: ["path", "content"],
            params: [t("String"), t("String")], returns: []),
        // appendFile：与 writeFile 是**两个名字两种语义**， 行不通  不是同一个函数的开关。
        // 目标不存在则创建（同 POSIX 的 `"a"`）；失败即 panic，与 writeFile 同姿态。
        BuiltinDecl(
            name: "appendFile", group: .io, paramNames: ["path", "content"],
            params: [t("String"), t("String")], returns: []),
        BuiltinDecl(
            name: "readLine", group: .io, paramNames: [],
            params: [], returns: [t("String")]),
        /// 目录枚举：`.pini` 源码经此才写得出「列出目录」，自举仓的 module 层要以目录为输入编译自身源码。
        /// 条目数无上限，列不全即报错，不静默截断（本仓「读入」类内建都不设上限，不平白引进任意数字）。
        /// 排序语义属语言语义：按 UTF-8 字节序升序——文件系统返回顺序不稳定，不排序则顺序类判据都是假绿。
        BuiltinDecl(
            name: "listDir", group: .io, paramNames: ["path"],
            params: [t("String")],
            returns: [.generic(name: "Array", params: [t("String")], location: builtinLocation)]),
        // 探测类：路径不存在是该类的**正常答案**， 行不通  不是错误 ⇒ 不 panic。
        // 与 listDir / readFile 的操作类语义相反；两者同走 readFile 的路径解析。
        BuiltinDecl(
            name: "exists", group: .io, paramNames: ["path"],
            params: [t("String")], returns: [t("Bool")]),
        BuiltinDecl(
            name: "isDir", group: .io, paramNames: ["path"],
            params: [t("String")], returns: [t("Bool")]),
        /// 可接住的 IO：三个 `try*` 与陷阱版并存，不是替代——失败形态由调用点写的名字决定，不是运行时开关。
        /// 载荷：读是文件内容，写与追加是空元组（写成功不产生值，不编造字节数——它恒为入参的 UTF-8 长度）。
        /// 与 `ok`/`err` 同族：走专属降载，不登记解释器函数值。
        BuiltinDecl(
            name: "tryReadFile", group: .io, paramNames: ["path"],
            params: [t("String")],
            returns: [
                .generic(
                    name: "Result",
                    params: [t("String"), t("Error")],
                    location: builtinLocation)
            ],
            definesRuntimeValue: false),
        BuiltinDecl(
            name: "tryWriteFile", group: .io, paramNames: ["path", "content"],
            params: [t("String"), t("String")],
            returns: [
                .generic(
                    name: "Result",
                    params: [
                        .tuple(labels: [], elements: [], location: builtinLocation),
                        t("Error"),
                    ],
                    location: builtinLocation)
            ],
            definesRuntimeValue: false),
        BuiltinDecl(
            name: "tryAppendFile", group: .io, paramNames: ["path", "content"],
            params: [t("String"), t("String")],
            returns: [
                .generic(
                    name: "Result",
                    params: [
                        .tuple(labels: [], elements: [], location: builtinLocation),
                        t("Error"),
                    ],
                    location: builtinLocation)
            ],
            definesRuntimeValue: false),

        // ---- math ----
        BuiltinDecl(
            name: "abs", group: .math, paramNames: ["x"],
            params: [t("I32")], returns: [t("I32")]),
        BuiltinDecl(
            name: "min", group: .math, paramNames: ["a", "b"],
            params: [t("I32"), t("I32")], returns: [t("I32")]),
        BuiltinDecl(
            name: "max", group: .math, paramNames: ["a", "b"],
            params: [t("I32"), t("I32")], returns: [t("I32")]),
        BuiltinDecl(
            name: "sqrt", group: .math, paramNames: ["x"],
            params: [t("F64")], returns: [t("F64")]),
        BuiltinDecl(
            name: "sin", group: .math, paramNames: ["x"],
            params: [t("F64")], returns: [t("F64")]),
        BuiltinDecl(
            name: "cos", group: .math, paramNames: ["x"],
            params: [t("F64")], returns: [t("F64")]),
        BuiltinDecl(
            name: "tan", group: .math, paramNames: ["x"],
            params: [t("F64")], returns: [t("F64")]),

        // ---- concurrency ----
        BuiltinDecl(
            name: "sleep", group: .concurrency, paramNames: ["ms"],
            params: [t("I32")], returns: []),
        // isCancel/joinAll/joinWithin：类型签名带泛型/通配位，由
        // registerConcurrencyBuiltins 专属路径登记，本表只记名与组
        BuiltinDecl(name: "isCancel", group: .concurrency, paramNames: ["e"], definesRuntimeValue: false),
        BuiltinDecl(name: "joinAll", group: .concurrency, paramNames: ["futures"], definesRuntimeValue: false),
        BuiltinDecl(name: "joinWithin", group: .concurrency, paramNames: ["future", "ms"], definesRuntimeValue: false),

        // ---- ffi ----
        /// 取回：C 串复制成 Pini 串。与 `cstr` 反向；`cstr` 是 shim 名（由调用方在 foreign 块里声明），
        /// 本条目是语言内建，不需要声明。读 NUL 为止，空指针按空串处理。
        BuiltinDecl(
            name: "c字符串", group: .ffi, paramNames: ["p"],
            params: [.pointer(element: t("U8"), location: builtinLocation)],
            returns: [t("String")], definesRuntimeValue: false),
    ]

    /// 内建类型 conformance 声明面：使 String/Array 在类型环境中可查询「遵循 collection」。
    /// 特征方法派发落地前，成员方法仍走 evaluateMember 既有路径。方法集为 append/pop/slice/join/
    /// contains 加 len（len 现为自由函数）；下标读属运算符通道，不入方法表。
    public static let conformances: [String: [String]] = [
        "String": ["collection"],
        "Array": ["collection"],
    ]

    // MARK: - 内建成员方法表（内建特征化 步骤 B）

    /// 内建成员方法声明：类型层签名与运行时派发共用同一张表。
    public struct MemberDecl: Sendable {
        public let typeName: String
        public let name: String
        public let paramNames: [String]
        public let params: [TypeAnnotation]
        public let returns: [TypeAnnotation]
        /// 是否属于 collection 特征方法面（D1 最小集）
        public let inTrait: Bool

        init(
            typeName: String, name: String, paramNames: [String],
            params: [TypeAnnotation], returns: [TypeAnnotation], inTrait: Bool
        ) {
            self.typeName = typeName
            self.name = name
            self.paramNames = paramNames
            self.params = params
            self.returns = returns
            self.inTrait = inTrait
        }
    }

    /// 内建成员方法全集（唯一事实源：TypeChecker.defineMethod 与 Interpreter.evaluateMember 都从
    /// 本表派生）。`inTrait = true` 的方法属 collection 特征面，其余为类型扩展面；slice 参数用 Any
    /// 通配——开放边界传 nil = Optional.none。
    public static let memberMethods: [MemberDecl] = [
        // String（collection 子集：contains/slice；扩展面：upper/lower/substring/split）
        MemberDecl(
            typeName: "String", name: "upper", paramNames: [],
            params: [], returns: [t("String")], inTrait: false),
        MemberDecl(
            typeName: "String", name: "lower", paramNames: [],
            params: [], returns: [t("String")], inTrait: false),
        MemberDecl(
            typeName: "String", name: "contains", paramNames: ["sub"],
            params: [t("String")], returns: [t("Bool")], inTrait: true),
        MemberDecl(
            typeName: "String", name: "substring", paramNames: ["start", "end"],
            params: [t("I32"), t("I32")], returns: [t("String")], inTrait: false),
        MemberDecl(
            typeName: "String", name: "split", paramNames: ["sep"],
            params: [t("String")], returns: [TypeAnnotation.generic(name: "Array", params: [t("String")], location: builtinLocation)], inTrait: false),
        MemberDecl(
            typeName: "String", name: "slice", paramNames: ["start", "end"],
            params: [t("Any"), t("Any")], returns: [t("String")], inTrait: true),
        /// String trim/index builtins: leading/trailing ASCII space stripping (U+0020 only — a tab is NOT
        /// stripped) and grapheme-indexed first occurrence (empty needle yields 0, absent yields -1).
        /// `inTrait = false`: extension surface, not the collection trait face.
        MemberDecl(
            typeName: "String", name: "trimLeft", paramNames: [],
            params: [], returns: [t("String")], inTrait: false),
        MemberDecl(
            typeName: "String", name: "trimRight", paramNames: [],
            params: [], returns: [t("String")], inTrait: false),
        MemberDecl(
            typeName: "String", name: "indexOf", paramNames: ["needle"],
            params: [t("String")], returns: [t("I32")], inTrait: false),
        /// 三通道取值：安全可选通道 `.get(i)` 与不安全通道 `.getUnchecked(i)`。下标 `a[i]` 是安全断言
        /// （越界 panic），容错取值须显式走 `get`；`getUnchecked` 供已证明界内的热路径跳过检查，
        /// 调用方以 `unsafe` 消耗点承担义务。`inTrait = false`，故用户类型不被要求实现这两个方法。
        MemberDecl(
            typeName: "String", name: "get", paramNames: ["index"],
            params: [t("I32")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("Char")], location: builtinLocation)], inTrait: false),
        MemberDecl(
            typeName: "String", name: "getUnchecked", paramNames: ["index"],
            params: [t("I32")], returns: [t("Char")], inTrait: false),
        // Array（collection 子集：append/pop/slice/join；扩展面：last）
        /// `T` 是内建容器的元素类型占位：查询时按接收者的类型实参回填，故 `Array<I32>.append` 收 I32、
        /// 回 `Array<I32>`。它不是 `genericTypes` 里的类型参数 —— Array 没有泛型声明，别处看不见这个名。
        MemberDecl(
            typeName: "Array", name: "join", paramNames: ["sep"],
            params: [t("String")], returns: [t("String")], inTrait: true),
        MemberDecl(
            typeName: "Array", name: "append", paramNames: ["value"],
            params: [t("T")], returns: [TypeAnnotation.generic(name: "Array", params: [t("T")], location: builtinLocation)], inTrait: true),
        MemberDecl(
            typeName: "Array", name: "slice", paramNames: ["start", "end"],
            params: [t("Any"), t("Any")], returns: [TypeAnnotation.generic(name: "Array", params: [t("T")], location: builtinLocation)], inTrait: true),
        MemberDecl(
            typeName: "Array", name: "last", paramNames: [],
            params: [], returns: [t("T")], inTrait: false),
        MemberDecl(
            typeName: "Array", name: "pop", paramNames: [],
            params: [],
            returns: [
                .tuple(
                    labels: [nil, nil],
                    elements: [TypeAnnotation.generic(name: "Array", params: [t("T")], location: builtinLocation), t("T")],
                    location: builtinLocation)
            ], inTrait: true),
        MemberDecl(
            typeName: "Array", name: "get", paramNames: ["index"],
            params: [t("I32")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("T")], location: builtinLocation)], inTrait: false),
        MemberDecl(
            typeName: "Array", name: "getUnchecked", paramNames: ["index"],
            params: [t("I32")], returns: [t("T")], inTrait: false),
        // Dictionary 的成员面只有 `get`/`getUnchecked`（下标是语法级的）——缺失键与越界同义。
        MemberDecl(
            typeName: "Dictionary", name: "get", paramNames: ["key"],
            params: [t("K")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("V")], location: builtinLocation)], inTrait: false),
        MemberDecl(
            typeName: "Dictionary", name: "getUnchecked", paramNames: ["key"],
            params: [t("K")], returns: [t("V")], inTrait: false),
    ]

    /// 内建容器的类型参数占位名，按位置对应类型实参：`Array<T>` 一个、`Dictionary<K, V>` 两个。
    /// `memberMethods` 的签名用这些名字写占位，查询时按接收者实参回填 —— 两张表必须同名同序，
    /// 否则回填落空，签名会把占位名当普通类型名带进调用点。
    public static let containerPlaceholders: [String: [String]] = [
        "Array": ["T"],
        "Dictionary": ["K", "V"],
    ]

    public static func member(typeName: String, name: String) -> MemberDecl? {
        return memberMethods.first(where: { $0.typeName == typeName && $0.name == name })
    }
}
