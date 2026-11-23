import Foundation
import PiniSyntax

/// 后端共享的高层 IR：带类型的树，每个表达式携带已解析的标量类型、每次变量访问携带声明类型。
/// 所有类型判定都在 `IRLowerer` 完成；消费方只做机械翻译、不再自己推类型，能力门禁拒掉其余情形。

/// IR 节点携带的已解析标量类型（切片集合）。
public indirect enum IRType: Equatable {
    case i32
    case i64
    /// `U64`：64 位无符号整数。LLVM 没有独立的无符号拼写，与 `I64` 同为 `i64`；
    /// 有无符号只体现在运算上。打印与解释器同口径：一个统一整数值，按 `%d` 输出。
    case u64
    /// `U8`：8 位无符号整数，与 `I8` 同为 `i8` 拼写；有无符号只体现在运算上。
    case u8
    /// `I8`：8 位有符号整数。切片面只覆盖结构字段、方法返回与字段读；
    /// 发射时 i8 运算加宽到 i32，因为解释器把所有整数建模为同一个值。
    case i8
    case f64
    case boolean
    case string
    /// `Char`：一个扩展字形簇，即用户感知的「一个字」，既不是码点也不是字节。
    /// 它与 `String` 共用表示，故 LLVM 拼写是 `i8*`，聚合、调用与运行时段都不新增 ABI；
    /// 「恰好一个字形簇」由类型系统保证。
    case char
    /// `Result<T, E>`：只静态携带 ok 载荷类型 —— Pini 的 `^T` 定住 T 而不约束 E，
    /// 故错误槽在 IR ABI 里擦除为一个机器字。
    case result(ok: IRType)
    /// `Future<T, E>`：`=>` 函数对外签名的返回类型 —— 运行中的并发进程句柄，表示是不透明句柄。
    /// 与 `result` 不可互换：那是已结算的值，这是未结算的句柄；发射层要静态分辨两者，否则一次异步调用
    /// 与「返回 Result 的同步调用」逐字相同。仅携带 ok 载荷，错误槽与 `result` 同口径（擦除为一个机器字）。
    case future(ok: IRType)
    /// `Array<T>`：数组本身是不透明运行时句柄（`%bk_array*`，并发后端抽象）；
    /// 元素经 `bk_array_*` 的 C ABI 装箱。嵌套数组按元素类型递归。
    case array(element: IRType)
    /// `Optional<T>`：标签聚合 `{ i64, T }`，标签 0 = some、1 = none。
    /// 解释器把 Optional 建模为带 `some` / `none` 用例的枚举；`none` 就是语言层的 nil（用户裁定）。
    case optional(wrapped: IRType)
    /// 用户名义类型：结构体（值布局，以栈指针携带，ABI 形态 `%struct.<mangled>*`）
    /// 或对象（引用，`%object.<mangled>*`）；两者头四格同为 {强计数, 弱计数, 类型标识, 旁表}。
    case nominal(name: String, isObject: Bool)
    /// 用户枚举：标签联合 `%enum.<mangled>*`，标签落在头四格之后（第 4 格），
    /// 载荷槽按最大元数的用例定型、直接按值存放。
    case enumeration(name: String)
    /// `Dictionary<K, V>`：不透明句柄 `%bk_dict*`，键与值经 `bk_dict_*` 的 C ABI 装箱。
    case dict(key: IRType, value: IRType)
    /// `LazyRef<T>`：不透明句柄 `%bk_lazyref*`，一次性求值的懒引用，复制语义为共享引用；
    /// 元素类型随行只为装箱 ABI（字节数 / 标签）与 `.value` 的读出类型。
    case lazyRef(element: IRType)
    /// `WeakRef<T>`：不增加强计数的弱引用句柄；`.value` 读取得 `Optional<T>`。
    case weakRef(element: IRType)
    /// `UnownedRef<T>`：不计数、不跟踪存活的无主引用，表示就是对象指针（`ptr`）。
    /// 解引用、调用与字段访问由检查面限定在 unsafe 上下文；它不进旁表，也没有销毁动作。
    case unownedRef(element: IRType)
    /// `Set<T>`：不透明句柄 `%bk_set*`，有序去重元素。
    case set(element: IRType)
    /// 带标签元组：寄存器聚合 `{ ... }`，成员按标签序号经 extractvalue 读取。
    case tuple(labels: [String?], fieldTypes: [IRType])
    /// 函数值：闭包、lambda 与作值使用的具名函数。统一胖指针 ABI `{ ptr, ptr }` = {code, env}；
    /// 形参与返回形状只作一致性核对 —— 调用协议固定，首参恒为 env 指针。
    case function(params: [IRType], returnType: IRType?, usingIndices: Set<Int>)
    /// C 函数指针：`(A, B) -> C`，LLVM 拼写是裸 `ptr`。
    /// 与 `function` 明确分开 —— 后者是 `{code, env}` 胖指针、调用先传 env，两者不可互换。
    case cFunction(params: [IRType], returnType: IRType?)
    /// `*T`：裸指针，LLVM 里是不透明 `ptr` —— load / store 取元素类型，取地址由 alloca 产出。
    /// 元素类型随行只为 load / store 定型，与解释器的快照 / 解码同口径：`*U8` 读出符号扩展成一个整数值。
    case pointer(element: IRType)
    /// `StringHandle`：运行时段持有的字符串拷贝，C 侧只拿不透明指针，Pini 侧只是一个 token。
    /// 与 `pointer` 分开 —— 它不是可 load / store 的字节地址，也不是计数串（计数在 C 那一侧）。
    case stringHandle

    /// 注解层形态：`IRType(from:)` 的反向那一支。codegen 重推表达式类型时把它交回类型环境，
    /// 使本函数的局部变量按本函数的声明解析。
    /// 转不回去的形态返回 nil —— 字典 / 集合 / 名义类型在注解层本就没有对应名字。
    var typeAnnotation: TypeAnnotation? {
        let at = SourceLocation(line: 0, column: 0, fileName: "")
        switch self {
        case .i8: return .simple(name: "I8", location: at)
        case .u8: return .simple(name: "U8", location: at)
        case .i32: return .simple(name: "I32", location: at)
        case .i64: return .simple(name: "I64", location: at)
        case .u64: return .simple(name: "U64", location: at)
        case .f64: return .simple(name: "F64", location: at)
        case .boolean: return .simple(name: "Bool", location: at)
        case .string: return .simple(name: "String", location: at)
        case .char: return .simple(name: "Char", location: at)
        case .stringHandle: return .simple(name: "StringHandle", location: at)
        case .result(let ok):
            guard let payload = ok.typeAnnotation else { return nil }
            return .generic(name: "Result", params: [payload], location: at)
        case .optional(let wrapped):
            guard let payload = wrapped.typeAnnotation else { return nil }
            return .generic(name: "Optional", params: [payload], location: at)
        case .array(let element):
            guard let payload = element.typeAnnotation else { return nil }
            return .generic(name: "Array", params: [payload], location: at)
        case .lazyRef(let element):
            guard let payload = element.typeAnnotation else { return nil }
            return .generic(name: "LazyRef", params: [payload], location: at)
        case .weakRef(let element):
            guard let payload = element.typeAnnotation else { return nil }
            return .generic(name: "WeakRef", params: [payload], location: at)
        case .unownedRef(let element):
            guard let payload = element.typeAnnotation else { return nil }
            return .generic(name: "UnownedRef", params: [payload], location: at)
        case .pointer(let element):
            guard let target = element.typeAnnotation else { return nil }
            return .pointer(element: target, location: at)
        case .tuple(let labels, let fieldTypes):
            var elements: [TypeAnnotation] = []
            for field in fieldTypes {
                guard let annotation = field.typeAnnotation else { return nil }
                elements.append(annotation)
            }
            return .tuple(labels: labels, elements: elements, location: at)
        case .function(let params, let returnType, let usingIndices):
            var annotations: [TypeAnnotation] = []
            for param in params {
                guard let annotation = param.typeAnnotation else { return nil }
                annotations.append(annotation)
            }
            let returns: [TypeAnnotation]
            if let returnType = returnType {
                guard let annotation = returnType.typeAnnotation else { return nil }
                returns = [annotation]
            } else {
                returns = []
            }
            return .function(
                params: annotations, returns: returns, captured: [],
                usingIndices: usingIndices, location: at)
        case .nominal(let name, _), .enumeration(let name):
            // 名义类型回到源码里的名字。注解层只为「本函数的局部叫什么类型」服务，
            // 反向的 `IRType(from:)` 认不出用户类型，仍走按表达式降载那条路。
            return .simple(name: name, location: at)
        case .dict, .cFunction, .future, .set:
            return nil
        }
    }

    /// 发射器使用的 LLVM 类型拼写。
    public var llvmSpelling: String {
        switch self {
        case .i8, .u8: return "i8"
        case .i32: return "i32"
        case .i64, .u64: return "i64"
        case .f64: return "double"
        case .boolean: return "i1"
        case .string: return "i8*"
        /// `Char` 是**八字节内联值**：七字节 UTF-8 载荷加一字节长度，超长才退化成带头堆指针。
        /// 槽宽与指针相同，且不经过分配器 —— `s[i]` 是一次整字读。
        case .char: return "i64"
        case .result(let ok):
            return "{ i64, \(ok.llvmSpelling), i64 }"
        case .future:
            // 不透明句柄，与其余 `bk_*` 家族同规：句柄形状属后端事务，没有载荷经它传递。
            return "ptr"
        case .array:
            return "%bk_array*"
        case .optional(let wrapped):
            return "{ i64, \(wrapped.llvmSpelling) }"
        case .nominal(let name, let isObject):
            return isObject ? "%object.\(IRName.mangle(name))*" : "%struct.\(IRName.mangle(name))*"
        case .enumeration(let name):
            return "%enum.\(IRName.mangle(name))*"
        case .dict:
            return "%bk_dict*"
        case .set:
            return "%bk_set*"
        case .lazyRef:
            return "%bk_lazyref*"
        case .weakRef:
            return "%bk_weakref*"
        case .unownedRef:
            // 无主引用就是对象指针本身：没有箱、没有旁表，运行时段不认第三种句柄。
            return "ptr"
        case .tuple(_, let fieldTypes):
            return "{ " + fieldTypes.map { $0.llvmSpelling }.joined(separator: ", ") + " }"
        case .function:
            return "{ ptr, ptr }"
        case .cFunction:
            return "ptr"
        case .pointer:
            return "ptr"
        case .stringHandle:
            return "ptr"
        }
    }

    /// Pini 面类型拼写，用于诊断消息；与 `llvmSpelling`（后端拼写）不可互换。
    /// 措辞与 `TypeAnnotation.describe()` 一致：`Optional<T>` / `Array<T>` / `(A, B) -> (C)`。
    /// 取用位以 `using ` 前标记出：它写在声明里、写不进标注，漏标则两侧为何不等看不出来。
    public func describe() -> String {
        switch self {
        case .i8: return "I8"
        case .u8: return "U8"
        case .i32: return "I32"
        case .i64: return "I64"
        case .u64: return "U64"
        case .f64: return "F64"
        case .boolean: return "Bool"
        case .string: return "String"
        case .char: return "Char"
        case .result(let ok):
            return "Result<\(ok.describe())>"
        case .future(let ok):
            return "Future<\(ok.describe())>"
        case .array(let element):
            return "Array<\(element.describe())>"
        case .optional(let wrapped):
            return "Optional<\(wrapped.describe())>"
        case .nominal(let name, _):
            return name
        case .enumeration(let name):
            return name
        case .dict(let key, let value):
            return "Dictionary<\(key.describe()), \(value.describe())>"
        case .lazyRef(let element):
            return "LazyRef<\(element.describe())>"
        case .weakRef(let element):
            return "WeakRef<\(element.describe())>"
        case .unownedRef(let element):
            return "UnownedRef<\(element.describe())>"
        case .set(let element):
            return "Set<\(element.describe())>"
        case .tuple(let labels, let fieldTypes):
            let parts = fieldTypes.enumerated().map { index, type -> String in
                if labels.indices.contains(index), let label = labels[index] {
                    return "\(label): \(type.describe())"
                }
                return type.describe()
            }
            return "(" + parts.joined(separator: ", ") + ")"
        case .function(let params, let returnType, let usingIndices):
            let marked = params.enumerated().map { index, type in
                usingIndices.contains(index) ? "using \(type.describe())" : type.describe()
            }
            let returned = returnType.map { $0.describe() } ?? ""
            return "(" + marked.joined(separator: ", ") + ") -> (\(returned))"
        case .cFunction(let params, let returnType):
            let returned = returnType.map { $0.describe() } ?? ""
            return "(" + params.map { $0.describe() }.joined(separator: ", ") + ") -> (\(returned)) [C]"
        case .pointer(let element):
            return "*\(element.describe())"
        case .stringHandle:
            return "StringHandle"
        }
    }

    /// alloca / GEP 用的无指针聚合拼写（名义类型与枚举）。
    public var nominalAggregateSpelling: String? {
        switch self {
        case .nominal, .enumeration:
            return String(llvmSpelling.dropLast())
        default:
            return nil
        }
    }

    /// 若本类型是 Result，返回其 ok 载荷类型。
    public var resultOkType: IRType? {
        if case .result(let ok) = self { return ok }
        return nil
    }

    /// Future 在汇合点结算后产出的 `Result` 类型。汇合消费句柄并得到已结算的值，
    /// 故该处的类型就是这个 Future 所代表的 Result；换算写在这里，两种类型才不会各走一路。
    public var joinedResultType: IRType? {
        if case .future(let ok) = self { return .result(ok: ok) }
        return nil
    }

    /// 若本类型是 Optional，返回被包裹的类型。
    public var optionalWrapped: IRType? {
        if case .optional(let wrapped) = self { return wrapped }
        return nil
    }

    /// 若本类型是 Array，返回元素类型。
    public var arrayElementType: IRType? {
        if case .array(let element) = self { return element }
        return nil
    }

    /// 本类型是否为 Array（不限元素）。
    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    /// 本类型是否属于「字符串面」：`String` 与 `Char`。
    /// 二者共用表示，故凡按「字符串」处理的通道（拼接、拼接式比较、常量池）都按本判定收；
    /// 逐处列 `.string` 漏一处，就会让 `Char` 落到某个 `default:` 上静默走错路。
    public var isStringFaced: Bool {
        switch self {
        case .string, .char: return true
        default: return false
        }
    }

    /// 本类型与给定类型是否构成 `Char` / `String` 相容对（对称）—— 二元运算与比较没有「哪一侧是期望」，
    /// 故不看方向；单方向的加宽判定在类型检查器（`Char → String`，反向拒绝）。
    public func formsCharStringPair(with other: IRType) -> Bool {
        (self == .char && other == .string) || (self == .string && other == .char)
    }

    public var isNumeric: Bool {
        switch self {
        case .i8, .u8, .i32, .i64, .u64, .f64: return true
        case .boolean, .string, .char, .result, .future, .array, .optional, .nominal, .enumeration, .dict, .set, .tuple, .function, .cFunction, .lazyRef, .weakRef, .unownedRef, .pointer, .stringHandle:
            return false
        }
    }

    /// 本类型是否为整数数值类型（除 F64 外的全部数值）。
    /// 它驱动声明宽度对齐：整数槽里的浮点字面量折成截断后的整数常量。
    public var isIntegerNumeric: Bool {
        switch self {
        case .i8, .u8, .i32, .i64, .u64: return true
        default: return false
        }
    }

    /// 相等判定抹掉两维不进类型恒等的装饰：元组标签只活在下标访问里，函数取用位只标「哪个参数位
    /// 由给定块填」。其余类型逐字相等 —— 递归到内部，故嵌套同规。
    public func isLabelInsensitivelyEqual(to other: IRType) -> Bool {
        if case .tuple(_, let mine) = self, case .tuple(_, let theirs) = other {
            guard mine.count == theirs.count else { return false }
            return zip(mine, theirs).allSatisfy { $0.isLabelInsensitivelyEqual(to: $1) }
        }
        if case .function(let mineParams, let mineReturn, _) = self,
            case .function(let theirsParams, let theirsReturn, _) = other
        {
            guard mineParams.count == theirsParams.count,
                zip(mineParams, theirsParams).allSatisfy({ $0.isLabelInsensitivelyEqual(to: $1) })
            else { return false }
            switch (mineReturn, theirsReturn) {
            case (nil, nil): return true
            case (let a?, let b?): return a.isLabelInsensitivelyEqual(to: b)
            default: return false
            }
        }
        return self == other
    }

    /// 赋值方向的接收判据：元组忽略标签、`Char` 放宽到 `String`（两者共用 `i8*`，不发出转换），
    /// 其余必须逐字相等；`String` 不接受 `Char`，加宽是单向的。降载的接收检查与验证器的值位
    /// 比对共用这一把尺子 —— 两处各写一份，漂的那一刻没有判据会变红。
    public func isAssignable(to target: IRType) -> Bool {
        isLabelInsensitivelyEqual(to: target) || (self == .char && target == .string)
    }
}

/// 切片集合内的二元运算符。
public enum IRBinaryOp: Equatable {
    case add, subtract, multiply, divide, modulo
    case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
    /// 位运算族：整数操作数；`and`/`or`/`xor`/`shl`/`ashr` 与 LLVM 整数指令一一对应。
    /// 解释器同口径：只收 int×int，布尔操作数被解释器的求值表拒绝。
    case bitwiseAnd, bitwiseOr, bitwiseXor, leftShift, rightShift
    /// `min(a, b)` / `max(a, b)` 内建 —— I32 的 select 形态。
    case minOf, maxOf

    /// 比较运算符产出 `boolean`，其余产出操作数类型。
    public var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return true
        default:
            return false
        }
    }

    public var llvmPredicate: String? {
        switch self {
        case .equal: return "eq"
        case .notEqual: return "ne"
        case .lessThan: return "slt"
        case .lessThanOrEqual: return "sle"
        case .greaterThan: return "sgt"
        case .greaterThanOrEqual: return "sge"
        default: return nil
        }
    }
}

/// 短路逻辑运算：`&&` / `||`。左操作数定下结果时，右操作数不求值。
/// 与 `IRBinaryOp` 分开，因为带控制流：发射层要按左值分流，而不是算一个二元指令。
public enum IRLogicalOp: Equatable {
    case and, or
}

/// 切片集合内的一元运算符。
public enum IRUnaryOp: Equatable {
    case negate
    case logicalNot
    /// `~v` —— I32 按位取反。与 `logicalNot`（`!`）不同。
    case bitwiseNot
    /// `abs(v)` —— I32 的 select(0-v, v<0)。
    case abs
    /// `v as T` — 数值显式转换。结果类型在节点的 `type` 上，源类型由操作数的 IR 类型给出；
    /// 发什么指令（截断 / 符号扩展 / 零扩展 / 整数浮点互转 / 精度舍入）由这两者共同决定。
    case cast
}

/// 带类型的表达式树（切片集合）。
public indirect enum IRExpr: Equatable {
    case intConst(value: Int, type: IRType)
    case floatConst(value: Double)
    case boolConst(value: Bool)
    case stringConst(value: String)
    /// 读变量值；`type` 是变量的声明类型。
    case load(name: String, type: IRType)
    case binary(op: IRBinaryOp, lhs: IRExpr, rhs: IRExpr, type: IRType)
    /// 逻辑短路的求值形态：左侧已能定下结果时，右侧不求值。`.binary` 是两侧都求值的按值运算，
    /// 二者不可互换 —— 换过去会丢掉右操作数的求值与否，副作用与陷阱随之改变。
    case shortCircuit(op: IRLogicalOp, lhs: IRExpr, rhs: IRExpr, type: IRType)
    case unary(op: IRUnaryOp, operand: IRExpr, type: IRType)
    /// 调用模块级函数；空返回的调用 `returnType` 为 nil。
    case call(function: String, arguments: [IRExpr], returnType: IRType?)
    /// 内建 `print(expr)` —— 一个标量实参，无返回值。
    case printCall(argument: IRExpr)
    /// `ok(v)` / `err(e)` 的 Result 构造。err 载荷在发射时加宽到一个机器字（ABI 上类型擦除）。
    /// `errorBaseCode` 是载荷所属错误类型的码基址；`errorTagged` 表示载荷是枚举、tag 要由运行时读；
    /// `errorCodes` 非 nil 时改用按 tag 索引的码表（稳定码类型），此时基址只作兜底。
    case resultConstruct(
        isOk: Bool, payload: IRExpr, errorBaseCode: Int32, errorTagged: Bool,
        errorCodes: [Int32]?, type: IRType)
    /// 数组字面量 `[e1, e2, ...]`。`type` 是 `.array(element:)`；发射器经 `bk_array_create`
    /// 与逐元素 `bk_array_set` 建句柄（元素走 C ABI 装箱）。
    case arrayLiteral(elements: [IRExpr], type: IRType)
    /// 下标读 `container[index]`。越界在运行时段 panic（`bk_array_get`），与解释器的断言通道同规；
    /// 容错通道（`.get` → Optional）是独立的节点。
    case subscriptGet(container: IRExpr, index: IRExpr, type: IRType)
    /// 内建 `len(array)` —— 运行时 `bk_array_len`，i32 结果。
    case lenCall(argument: IRExpr)
    /// 容错读通道 `container.get(index)`：越界得 `none`（语言层 nil），界内得 `some(value)`。
    /// 发射为围绕 `bk_array_len/get` 的带界检查内联分支。
    case optionalGet(container: IRExpr, index: IRExpr, type: IRType)
    /// `Optional` 构造：`isSome=false` 即 `none` 字面量（切片糖的开放边界以 `Optional.none` 抵达），
    /// `isSome=true` 携带被包裹的载荷。与 `resultConstruct` 同形。
    case optionalConstruct(isSome: Bool, payload: IRExpr?, type: IRType)
    /// `container.slice(start, end)` —— 切片糖的脱糖结果。`type` 是 `.array(element:)` 或 `.string`；
    /// 开放边界以 `optionalConstruct(isSome: false, ...)` 抵达。语义取已沉淀的标准库切片：
    /// 尾部计数负界、夹到 [0, len]、hi < lo 得空结果。
    case sliceCall(container: IRExpr, start: IRExpr, end: IRExpr, type: IRType)
    /// 名义构造 `名()`。字段取声明默认值（无默认则取零）；构造实参不在切片面内。
    /// 对象额外写入引用计数头（= 1）。
    case construct(type: IRType)
    /// 枚举用例构造 `Case(p1, p2, ...)`：标签取用例的声明序下标；
    /// 载荷按值存进标签联合的定型槽位。
    case enumConstruct(enumName: String, caseName: String, tag: Int, payloads: [IRExpr], payloadTypes: [IRType], type: IRType)
    /// 判别式读：枚举 / `Optional` / `Result` 的标签位，结果为 `i32`。
    /// 三个族的槽位不同（枚举在箱头之后，`Optional` 与 `Result` 是值聚合的首槽），由值自身的类型分辨。
    case enumTagGet(value: IRExpr)
    /// 关联值读：该值当前用例的第 `index` 个载荷；`caseName` 是调用方匹配到的用例，
    /// `type` 是载荷的静态类型。用例名与标签不符即读错了用例，验证期按声明核对载荷数与类型。
    case enumPayloadGet(value: IRExpr, caseName: String, index: Int, type: IRType)
    /// 具名字段读 `base.field`：`slot` 是字段在声明序里的位置，槽位基准见契约第 6 节；
    /// 名字只在降载期当查找键，不进节点 —— 后端因此不必自己数序号。
    case fieldGet(base: IRExpr, slot: Int, type: IRType)
    /// 字典 / 集合字面量。条目携带已降载的键值对；构造经运行时 C ABI。
    case dictLiteral(entries: [IRDictEntry], type: IRType)
    case setLiteral(elements: [IRExpr], type: IRType)
    /// 带标签元组构造。
    case tupleConstruct(labels: [String?], elements: [IRExpr], type: IRType)
    /// 元组成员读 `base.label` —— 按字段序号 extractvalue。
    case tupleIndexGet(base: IRExpr, index: Int, type: IRType)

    // MARK: 闭包与高阶函数

    /// 闭包值：`func` 字面量降载后的体，加创建点的捕获表 —— 按首次使用排序，各带声明类型；
    /// 捕获按引用（env 字段指向变量的槽位）。`paramNames` 与 `paramTypes` 平行，未标注的形参取推断类型。
    case closureLiteral(
        id: Int, paramNames: [String], paramTypes: [IRType], returnType: IRType?,
        captures: [IRCapture], body: IRBlock, type: IRType)
    /// 作值使用的具名顶层函数：经忽略 env 的适配器胖指针（`@__adapter_<mangled>`）发射，
    /// 使直接调用点与间接调用点共用一套调用约定。
    case functionValue(functionName: String, type: IRType)
    /// 顶层自由函数的地址，作为 C 函数指针传出去：发射成 `ptr @mangled`，不包一层适配器 ——
    /// 包一层就多了一个 C 侧看不见的名字，而 C 要的正是这个函数的符号。
    case cFunctionAddress(functionName: String, type: IRType)
    /// 经函数值间接调用：恒用闭包 ABI `call ret code(ptr env, args...)` ——
    /// `callee` 是 closureLiteral / functionValue / 函数类型变量的 load。
    case indirectCall(callee: IRExpr, arguments: [IRExpr], returnType: IRType?)

    // MARK: FFI 指针原语

    /// `load(p)`：经 `*T` 指针读出元素值。`type` 是元素的 IRType，与解释器 decodePointer 同口径：
    /// U8 读出符号扩展进一个统一整数值。
    case pointerLoad(pointer: IRExpr, type: IRType)
    /// `store(p, v)`：按指针的元素类型写入。与解释器 encode 同口径：窄元素为截断存储。
    /// 本节点是值表达式。
    case pointerStore(pointer: IRExpr, value: IRExpr, type: IRType)
    /// `&x`：变量 alloca 槽的地址 —— 真正的指针语义。解释器的快照别名缺口
    /// （回写不更新原变量）是已登记的分歧，由只读语料覆盖。
    case addressOfVar(name: String, type: IRType)
    /// 外部数据符号的地址：符号自身的存储位置，不是它的值的快照。
    /// 读走 `pointerLoad`、写走 `pointerStore`，与 `&变量` 的区别只在地址来源。
    case foreignDataAddress(name: String, type: IRType)
    /// `print(a, b, ...)`：逐实参字符串化后以单个空格拼成一行；发射器产出同一字节流
    /// （值、空格、值……、换行）。
    case printMulti(arguments: [IRExpr])
    /// `assert(cond)` / `assert(cond, message)`：布尔陷阱 —— 条件为 false 时带消息触发运行时 panic。
    /// 只为让 `|test` 块能降载；差分测试台从不执行它们。
    case assertCall(condition: IRExpr, message: IRExpr?)

    // MARK: 文件 IO

    /// `writeFile(path, content)` —— 整段内容就地写入（截断、跟随符号链接、失败即报）。不产出值。
    case fileWrite(path: IRExpr, content: IRExpr)
    /// `appendFile(path, content)` —— 整段内容追加到末尾，文件不存在则创建（POSIX `a`），
    /// 跟随符号链接、失败即报。不产出值。
    /// 与 `fileWrite` 分成两个节点而不合成一个开关：目标已存在时两者语义相反。
    case fileAppend(path: IRExpr, content: IRExpr)
    /// `readFile(path)`：读全文、不设上限，产出 String。读怎么发射属实现细节，归发射器；
    /// 节点不带缓冲区大小或上限。
    case fileRead(path: IRExpr)

    // MARK: 可接住的 IO（`Result` 形态）

    /// 三个 `try*` 内建与陷阱版并存，而不是给陷阱版加开关：同一个操作在「失败怎么办」上有两种答案，
    /// 而答案属于调用者 —— 一次调用只能有一种，选哪种由源码写的名字决定，不是运行时参数。
    /// 成功载荷：读是文件内容，写与追加是空元组（写成功不产生值，不编造字节数）；载荷类型由类型层推。

    /// `tryWriteFile(path, content)` —— 就地截断写；失败**返回** `err` 而不触发陷阱。
    case fileTryWrite(path: IRExpr, content: IRExpr)
    /// `tryAppendFile(path, content)` —— 追加写（目标不存在则创建）；失败**返回** `err`。
    case fileTryAppend(path: IRExpr, content: IRExpr)
    /// `tryReadFile(path)` —— 读全文；失败**返回** `err`，成功载荷是内容。
    case fileTryRead(path: IRExpr)

    // MARK: 内建

    /// `readLine()`：从 stdin 读一行，产出 String —— `fgets` 进 256 字节栈缓冲，值即缓冲指针，
    /// 故行尾换行**不**剥除。解释器会剥除；该分歧已登记，差分用例注入不带换行的 stdin。
    case readLine
    /// `is_ascii_digit(s)`：首字节落在 ASCII [0-9]。C 串语义 —— 空串读到的是自己的 NUL 终止符，
    /// 故为 false，与解释器在 ASCII 域内的「首字形簇」规则一致；域外由字形簇模型接管，
    /// 其余 Unicode 谓词保持 fail-loud。
    case isAsciiDigit(argument: IRExpr)

    // MARK: 字符串深化

    /// `s.upper()` / `s.lower()` —— 先 memcpy 出副本再逐字节 toupper/tolower（原串不动）。
    case stringCase(isUpper: Bool, receiver: IRExpr)
    /// `s.contains(needle)` —— `strstr != null`，按字节语义。
    case stringContains(receiver: IRExpr, needle: IRExpr)
    /// `s.substring(start, length)` —— 从原串 memcpy 出指定段。
    case stringSubstring(receiver: IRExpr, start: IRExpr, length: IRExpr)
    /// `s.split(delim)` —— 真的 `Array<String>`（与解释器同形，不是格式化串）：
    /// strtok 循环把切出的 token 经 strdup 喂给 bk_array_create/set。
    case stringSplit(receiver: IRExpr, delim: IRExpr, type: IRType)
    /// `s.trimLeft()` —— 剥掉前导 ASCII 空格（只认 U+0020；制表符等其它空白不剥）。
    /// 空格是单字形簇，逐字节扫描即精确；尾部由运行时 shim 切片。返回新串，原串不动；全空格得空串。
    case stringTrimLeft(receiver: IRExpr)
    /// `s.trimRight()` —— 剥掉**尾部** ASCII 空格，规则同 `stringTrimLeft`（只认 U+0020，不含制表符）。
    case stringTrimRight(receiver: IRExpr)
    /// `s.indexOf(needle)`：首次出现的字形簇下标；空 needle 得 0，不存在得 -1。
    /// 与 `stringContains` 同一趟字形簇扫描，只是报位置而非存在性。
    case stringIndexOf(receiver: IRExpr, needle: IRExpr)
    /// `arr.join(sep)` —— 字符串数组元素用 sep 逐个 strcat。
    case arrayJoin(receiver: IRExpr, separator: IRExpr)
    /// `s1 + s2` 字符串拼接 —— 两条 C 串经 malloc 拼合（字节语义，与已沉淀的拼接通道一致）。
    case stringConcat(lhs: IRExpr, rhs: IRExpr)
    /// 字符串插值 `"x=\(expr)"`：各部分已是降载后的表达式，类型为标量 / 字符串 / 数组；
    /// 各自转成 C 串后 strcat 进栈缓冲。F64 经 `bk_double_to_string`（最短往返）渲染，不用 `%f`。
    case interpString(parts: [IRExpr])

    // MARK: 懒引用（LazyRef）

    /// `LazyRef<T>(closure)`：经 `bk_lazyref_create(wrapper, code, env, bytes, tag)` 建一次性求值的句柄。
    /// `closure` 是降载后的初始化胖指针；逐元素类型的 wrapper 由发射器在模块末尾补齐。
    case lazyRefConstruct(closure: IRExpr, type: IRType)
    /// `handle.value`：`bk_lazyref_value(handle)` 返回缓存的元素箱，调用方按元素类型读出。
    case lazyRefValue(handle: IRExpr, type: IRType)

    // MARK: 弱引用

    /// `weak 对象`：建弱引用句柄，不增加对象的强计数。`type` 是 `weakRef(T)`。
    case weakRefConstruct(target: IRExpr, type: IRType)
    /// `handle.value`：目标存活得 `some`，已销毁得 `none`；`type` 是 `Optional<T>`。
    case weakRefValue(handle: IRExpr, type: IRType)
    /// `UnownedRef(对象)`：建无主引用，不住旁表、不碰计数；`type` 是 `unownedRef(T)`。
    case unownedRefConstruct(target: IRExpr, type: IRType)
    /// 解引用：取出无主引用指向的对象，不做存活检查；`type` 是 `T`。
    case unownedRefValue(handle: IRExpr, type: IRType)

    // MARK: 汇合

    /// `await f` / `wait f`：挂起语义所依附的节点。`future` 求值得 `Future`；结算后汇合点拆出携带的 ok / err，
    /// 故 `type` 是它产出的 Result。`form` 记录源码写的是哪个关键字 —— 这是区分两者的唯一依据，后端必须读它。
    case join(future: IRExpr, type: IRType, form: JoinForm)

    // MARK: - 默认实例取用

    /// 取某类型的默认实例：该实例由类型决定 —— 编译器按类型解析，无运行时查找、无 vtable；
    /// 惰性物化、恰一次、地址稳定；取到的是实例本身（非副本、非模板）。它与 `lazyRefValue` 不是一件事：
    /// 后者是字段内的细粒度缓冲，本条是类型级取用。目前无降载入口，两台引擎起步 fail-loud。
    case givenInstance(type: IRType)
}

extension IRExpr {
    /// 节点产出的值类型；`nil` 表示这个位置不产出值（`print`、写文件、`store` 一类）。
    /// 唯一判据是节点自带的 `type`，不从用法或上下文再推一次（契约 5.1）；两个消费方
    /// （发射器、验证器）都取这里，不各写一份 switch。
    public var staticType: IRType? {
        switch self {
        case .intConst(_, let type): return type
        case .floatConst: return .f64
        case .boolConst: return .boolean
        case .stringConst: return .string
        case .load(_, let type): return type
        case .binary(_, _, _, let type): return type
        case .shortCircuit(_, _, _, let type): return type
        case .unary(_, _, let type): return type
        case .call(_, _, let returnType): return returnType
        case .printCall: return nil
        case .resultConstruct(_, _, _, _, _, let type): return type
        case .arrayLiteral(_, let type): return type
        case .subscriptGet(_, _, let type): return type
        case .lenCall: return .i32
        case .optionalGet(_, _, let type): return type
        case .optionalConstruct(_, _, let type): return type
        case .sliceCall(_, _, _, let type): return type
        case .construct(let type): return type
        case .fieldGet(_, _, let type): return type
        case .enumConstruct(_, _, _, _, _, let type): return type
        case .enumTagGet: return .i32
        case .enumPayloadGet(_, _, _, let type): return type
        case .dictLiteral(_, let type): return type
        case .setLiteral(_, let type): return type
        case .tupleConstruct(_, _, let type): return type
        case .tupleIndexGet(_, _, let type): return type
        case .stringCase: return .string
        case .stringContains: return .boolean
        case .stringSubstring: return .string
        case .stringSplit(_, _, let type): return type
        case .stringTrimLeft, .stringTrimRight: return .string
        case .stringIndexOf: return .i32
        case .arrayJoin: return .string
        case .stringConcat: return .string
        case .interpString: return .string
        case .closureLiteral(_, _, _, _, _, _, let type): return type
        case .functionValue(_, let type): return type
        case .cFunctionAddress(_, let type): return type
        case .indirectCall(_, _, let returnType): return returnType
        case .lazyRefConstruct(_, let type): return type
        case .lazyRefValue(_, let type): return type
        case .weakRefConstruct(_, let type): return type
        case .weakRefValue(_, let type): return type
        case .unownedRefConstruct(_, let type): return type
        case .unownedRefValue(_, let type): return type
        case .pointerLoad(_, let type): return type
        case .pointerStore: return nil
        case .addressOfVar(_, let type): return .pointer(element: type)
        case .foreignDataAddress(_, let type): return .pointer(element: type)
        case .printMulti: return nil
        case .assertCall: return nil
        case .fileWrite, .fileAppend: return nil
        case .fileRead: return .string
        /// 写成功的载荷是空元组：写不产出值，也不编造字节数。
        case .fileTryWrite, .fileTryAppend: return .result(ok: .tuple(labels: [], fieldTypes: []))
        case .fileTryRead: return .result(ok: .string)
        case .readLine: return .string
        case .isAsciiDigit: return .boolean
        case .join(_, let type, _): return type
        case .givenInstance(let type): return type
        }
    }
}

/// 一条名义类型声明：布局 + 降载后的字段默认值 + 方法（各已按 self 参数化，IR 名已 mangled）。
public struct IRTypeDecl: Equatable {
    public struct Field: Equatable {
        public let name: String
        public let type: IRType
        public let defaultValue: IRExpr?

        public init(name: String, type: IRType, defaultValue: IRExpr?) {
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
        }
    }

    public let name: String
    public let isObject: Bool
    public let fields: [Field]
    public let methods: [IRFunction]

    public init(name: String, isObject: Bool, fields: [Field], methods: [IRFunction]) {
        self.name = name
        self.isObject = isObject
        self.fields = fields
        self.methods = methods
    }
}

/// 字典字面量的一条条目。用 struct 而非 Swift 元组，是因为元组无法为 IR 树携带条件 Equatable 一致性。
public struct IRDictEntry: Equatable {
    public let key: IRExpr
    public let value: IRExpr

    public init(key: IRExpr, value: IRExpr) {
        self.key = key
        self.value = value
    }
}

/// 闭包的一处引用捕获：被捕获外部变量的名字与声明类型。env 字段存指向变量存储槽的指针，
/// 故此后对外部变量的写入透过闭包仍可见（与解释器的 currentEnv 同口径）。
public struct IRCapture: Equatable {
    public let name: String
    public let type: IRType

    public init(name: String, type: IRType) {
        self.name = name
        self.type = type
    }
}

/// 一条匹配臂。`caseName` 是主语标签所比对的用例名（Optional 主语为 "some" / "none"；
/// 用户枚举用例走同一节点）。`bindings` 是按载荷位置排列的变量名（`nil` 表示 `_` 占位），臂体内可见。
public struct IRMatchCase: Equatable {
    public let caseName: String
    /// 裸主语的匹配臂里那个字面量模式操作数；枚举用例臂与通配臂为 nil（那些在 `caseName` 里）。
    /// 详见 `IRMatchLiteral`。
    public let literal: IRMatchLiteral?
    public let bindings: [String?]
    public let body: IRBlock

    public init(caseName: String, literal: IRMatchLiteral? = nil, bindings: [String?], body: IRBlock) {
        self.caseName = caseName
        self.literal = literal
        self.bindings = bindings
        self.body = body
    }
}

/// 裸（既非 Optional 也非枚举）主语上的字面量模式操作数 —— `case 1:` / `case "hi":` /
/// `case 1.5:` / `case true:`。解释器按值比较这类臂，故发射器必须据此分派；操作数按结构携带，不重新解析。
public enum IRMatchLiteral: Equatable {
    case int(Int)
    case float(Double)
    case string(String)
    case boolean(Bool)
}

/// for-in 的可迭代族：容器种类决定用哪个运行时访问器读第 i 个元素 ——
/// 单字段模式用 `bk_array_get` / `bk_set_at`，两字段 `(k, v)` 用 `bk_dict_key_at` / `bk_dict_val_at`。
public enum IRForIterableKind: Equatable {
    case array, set, dict
}

/// 语句表 + 每条语句的源码位置：`positions` 与 `statements` 平行，未带位置时为空（测试里手搭的 IR），
/// `position(at:)` 那时返回 nil 而不是编一行。位置挂在块级而非每个节点上 —— 只在 `lowerBlock` 落地，
/// 故与解释器同粒度、同起点。`Equatable` 只比语句：让坐标参与比较会让既有结构断言全部依赖位置。
public struct IRBlock: Equatable, ExpressibleByArrayLiteral, RandomAccessCollection {
    public typealias Element = IRStmt
    public typealias Index = Int

    public var statements: [IRStmt]
    /// 与 `statements` 平行；为空表示「本块不带位置」。
    public var positions: [SourceLocation]

    public init(_ statements: [IRStmt] = [], positions: [SourceLocation] = []) {
        self.statements = statements
        self.positions = positions
    }

    public init(arrayLiteral elements: IRStmt...) {
        self.init(elements)
    }

    /// 让块内每条语句携带同一源码位置的构造 —— 一条源码语句降载成多条 IR 语句时用它。
    /// `defer` 体与 try-else 处理器即此类：`lowerStatement` 就地展开它们，不经 `lowerBlock`。
    public static func at(_ statements: [IRStmt], _ location: SourceLocation) -> IRBlock {
        IRBlock(
            statements,
            positions: Array(repeating: location, count: statements.count)
        )
    }

    public var isEmpty: Bool { statements.isEmpty }
    public var count: Int { statements.count }
    public var startIndex: Int { statements.startIndex }
    public var endIndex: Int { statements.endIndex }
    public subscript(position: Int) -> IRStmt { statements[position] }

    /// 第 `index` 条语句的源码位置；本块不带位置（或下标越界）时为 nil。
    public func position(at index: Int) -> SourceLocation? {
        guard positions.count == statements.count, positions.indices.contains(index) else {
            return nil
        }
        return positions[index]
    }

    /// 只比语句、不比位置 —— 理由见类型上的说明。
    public static func == (lhs: IRBlock, rhs: IRBlock) -> Bool {
        lhs.statements == rhs.statements
    }
}

public indirect enum IRStmt: Equatable {
    /// 变量槽。发射时分配槽位；初始化器非 nil 则在分配后立即写入。`adopt` 是初始化器的接收动作。
    case allocVar(name: String, type: IRType, mutable: Bool, initializer: IRExpr?, adopt: IRAdopt)
    /// 写入已存在的变量；`type` 是变量的声明类型。`releaseOld` 表示槽里已持有一份份额，
    /// 故新值立住之后要丢掉旧值。
    case storeVar(name: String, type: IRType, value: IRExpr, adopt: IRAdopt, releaseOld: Bool)
    /// `[label|] if cond: then [else: else]`。`label` 使该帧可被中断：`break <label>` 可以离开 `if` 块，
    /// 而 `continue` 只接受循环标签。标签文本运行时不读 —— 只带已解析的深度，后端判的是 `label != nil`。
    case ifStmt(label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?)
    /// `while cond: body [step: block]`。step 块每轮在体之后执行一次 —— 正常完成与无标签 `continue`
    /// 都执行（与解释器同口径）；`break` 跳过它。
    case whileStmt(condition: IRExpr, body: IRBlock, step: IRBlock?)
    /// `for (pattern,) in iterable: body [step: block]`。`kind` 选择运行时访问器族；
    /// `elementTypes` 与 `pattern` 平行（`"_"` 项仍占一槽并携带其类型）。break / continue 的 step 契约同 `whileStmt`。
    case forInStmt(
        pattern: [String],
        elementTypes: [IRType],
        kind: IRForIterableKind,
        iterable: IRExpr,
        body: IRBlock,
        step: IRBlock?
    )
    /// 切片集合：单值返回；空返回函数为 nil。`adopt` 是返回值的接收动作。
    case returnStmt(value: IRExpr?, adopt: IRAdopt)
    case exprStmt(IRExpr)
    /// `defer stmt`：包裹的语句在所属块作用域退出时按 LIFO 执行（每轮循环结束也算一次退出）。
    /// 块的每个出口都关闭作用域，故 `break` 与 `return` 的解栈路径同样会跑 defer。
    case deferStmt(body: IRBlock)
    /// `try operand else errorVar: handler`。操作数类型是 `result(ok:)`；错误路径把擦除后的错误字绑到 `errorVar`
    /// 并执行 `handler`。表达式位置设 `okTarget`（ok 载荷存到那里），语句位置为 nil。
    case tryStmt(operand: IRExpr, errorVar: String, handler: IRBlock, okTarget: String?, type: IRType)
    /// 下标写 `container[index] = value`。容器可以是嵌套下标链（发射器走 COW 拆分链）；
    /// 复合赋值（`a[i] += k`）用同一节点降载为读改写。`elementType` 是装箱元素的静态类型，`adopt` 是其接收动作。
    case subscriptStore(container: IRExpr, index: IRExpr, value: IRExpr, elementType: IRType, adopt: IRAdopt)
    /// `break`，含带标签形态。`depth` = 要解开的循环层数（1 = 最内层）；
    /// 带标签的 `break outer` 降载为降载器从标签栈解析出的深度。
    /// 解析不到目标时降载为 `panicStmt` —— 解释器在顶层报错，故此处 fail-loud。
    case breakStmt(depth: Int)
    /// `continue`。`depth` 与 breakStmt 同规：1 = 最内层循环的条件复测；N = 第 N 层循环的头部
    /// （带标签 continue）。解析不到目标时与 break 一样 panic。
    case continueStmt(depth: Int)
    /// 带固定消息的无条件运行时陷阱。用于解释器只能在运行时才发现的控制流逃逸
    /// （循环外的 break / continue）。块就此终止。
    case panicStmt(message: String)
    /// `match scrutinee: case name(binding): body ...`。主语类型决定标签 ABI：Optional 臂比较
    /// `{ i64, T }` 的标签（some=0、none=1）；枚举主语经同一节点走自己的标签布局。
    /// 未匹配的值运行时 panic（与解释器 matchNotExhaustive 同口径）。
    case matchStmt(scrutinee: IRExpr, cases: [IRMatchCase], scrutineeType: IRType)
    /// 具名字段写 `base.field = value`：`slot` 与 `fieldGet` 同一口径（声明序）。
    /// `releaseOld` 与 `storeVar` 同规：字段是持有位置，覆盖即丢旧值。
    case fieldStore(base: IRExpr, slot: Int, value: IRExpr, fieldType: IRType, adopt: IRAdopt, releaseOld: Bool)
    /// `capture name`：闭包体内的标记语句。捕获本身在闭包字面量的创建点解析，
    /// 故此语句降载为什么都不做 —— 它的存在只是让该语句种类在降载后的体内被接受，而非被门禁拒掉。
    case captureMarker(name: String)
    /// `detach <expr>` —— 把任务从父级剪枝，父级返回时不再取消它（fire-and-forget 的唯一正当出口）。
    /// 操作数必须求值为 `Future`；非 Future 属运行时类型不符，不是降载错误。不带 `type`：语句不产值。
    case detachStmt(inner: IRExpr)
    /// 归还并作废一个函数内槽：释放旧值后该槽不再由出口归还。降载用它给合成的临时局部
    /// 提前失效（匹配主语用完即弃），否则可选 / 结果里的计数载荷会拖到函数出口才松手。
    case releaseVar(name: String, type: IRType)
}
