import Foundation

/// ADR-020 D3/D4：内建单点登记表。
///
/// 每个内建在此**声明一次**（名字 + 归组 + 各层登记开关），三个消费方从本表派生：
/// - `SemanticAnalyzer.registerBuiltins`：符号表登记（`definesSymbol`）
/// - `TypeChecker.registerBuiltinTypes`：静态签名登记（`typeSignature` 非空）
/// - `Interpreter.registerBuiltins`：运行时 FunctionValue（`definesRuntimeValue`）
///
/// 本表只承载「声明」，不承载「实现」：运行时分发仍由 Interpreter 按函数值名字分派。
/// 专属路径（指针内建 `registerPointerBuiltins`、并发 `registerConcurrencyBuiltins`、
/// 枚举构造器 `registerEnumCaseConstructor`）保留原有登记，表中以开关位标记归属，
/// 使本表同时是 ADR-020 D4 归组清单的**唯一事实源**。
public enum BuiltinGroup: String, CaseIterable {
 case collection
 case char
 case pointer
 case io
 case math
 case concurrency
 case value
}

public struct BuiltinDecl {
 public let name: String
 public let group: BuiltinGroup
 /// Interpreter 侧 FunctionValue 的形参名（须与既有分发实现一致）
 public let paramNames: [String]
 /// nil = 类型层签名由专属路径登记（泛型/指针/构造器特化），本表只记名与组
 public let typeSignature: (params: [TypeAnnotation], returns: [TypeAnnotation], isVariadic: Bool)?
 /// 是否由 SemanticAnalyzer 在符号表登记（调用点 undefinedFunction 检查依赖）
 public let definesSymbol: Bool
 /// 是否由 Interpreter.registerBuiltins 循环定义运行时函数值
 /// （false：由专属路径定义，如 registerPointerBuiltins / registerConcurrencyBuiltins）
 public let definesRuntimeValue: Bool

 public init(
 name: String,
 group: BuiltinGroup,
 paramNames: [String],
 params: [TypeAnnotation]? = nil,
 returns: [TypeAnnotation]? = nil,
 isVariadic: Bool = false,
 definesSymbol: Bool = true,
 definesRuntimeValue: Bool = true
 ) {
 self.name = name
 self.group = group
 self.paramNames = paramNames
 self.typeSignature = params.map { ($0, returns ?? [], isVariadic) }
 self.definesSymbol = definesSymbol
 self.definesRuntimeValue = definesRuntimeValue
 }
}

public enum BuiltinRegistry {
 public static let builtinLocation = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

 private static func t(_ name: String) -> TypeAnnotation {
 .simple(name: name, location: builtinLocation)
 }

 /// ADR-020 D4 归组清单（唯一事实源）。旧调用名全部保留，零破坏。
 public static let decls: [BuiltinDecl] = [
 // ---- collection ----
 BuiltinDecl(name: "len", group: .collection, paramNames: ["value"],
 params: [t("Any")], returns: [t("I32")]),

 // ---- value ----
 BuiltinDecl(name: "print", group: .value, paramNames: ["value"],
 params: [t("Any")], returns: [], isVariadic: true),
 BuiltinDecl(name: "assert", group: .value, paramNames: ["条件", "消息"],
 params: [t("Bool"), t("String")], returns: [], isVariadic: true),
 // ok/err/Error/CancelError：Result/错误构造器，专属路径
 // （registerEnumCaseConstructor / registerConcurrencyBuiltins）登记
 BuiltinDecl(name: "ok", group: .value, paramNames: ["value"], definesRuntimeValue: false),
 BuiltinDecl(name: "err", group: .value, paramNames: ["value"], definesRuntimeValue: false),
 BuiltinDecl(name: "Error", group: .value, paramNames: ["message"], definesRuntimeValue: false),
 // G-P1（自举探针批次 4）：F64 值构造——此前无 I32→F64 转换路径，
 // 整型表达式无法参与浮点算术（E5-003 混合算术拒绝）；按 ADR-020
 // 内建快速路径补齐（最小面：int→float、float 原样，字符串解析另行提案）。
 BuiltinDecl(name: "F64", group: .value, paramNames: ["value"],
 params: [t("Any")], returns: [t("F64")]),
 BuiltinDecl(name: "CancelError", group: .value, paramNames: ["message"], definesRuntimeValue: false),

 // ---- char ----
 BuiltinDecl(name: "is_letter", group: .char, paramNames: ["value"],
 params: [t("String")], returns: [t("Bool")]),
 BuiltinDecl(name: "is_ascii_digit", group: .char, paramNames: ["value"],
 params: [t("String")], returns: [t("Bool")]),
 BuiltinDecl(name: "is_number", group: .char, paramNames: ["value"],
 params: [t("String")], returns: [t("Bool")]),
 BuiltinDecl(name: "chars", group: .char, paramNames: ["value"],
 params: [t("String")], returns: [.generic(name: "Array", params: [t("String")], location: builtinLocation)]),
 // 词法门禁 H1（lexer 缺口审计）：码点原语——解锁字符范围判定（hex 判定等）
 // 与 upper/lower 下沉。grapheme 模型对齐（ADR-019 D1）：ord 取首 Unicode
 // scalar；空串哨兵 -1（errors-as-data 风，与 is_letter("") 同调）；
 // chr 越界/代理区返回空串。
 BuiltinDecl(name: "ord", group: .char, paramNames: ["value"],
 params: [t("String")], returns: [t("I32")]),
 BuiltinDecl(name: "chr", group: .char, paramNames: ["code"],
 params: [t("I32")], returns: [t("String")]),

 // ---- pointer（unsafe；专属路径 registerPointerBuiltins）----
 BuiltinDecl(name: "load", group: .pointer, paramNames: ["p"], definesRuntimeValue: false),
 BuiltinDecl(name: "store", group: .pointer, paramNames: ["p", "v"], definesRuntimeValue: false),
 BuiltinDecl(name: "addressof", group: .pointer, paramNames: ["value"], definesRuntimeValue: false),

 // ---- io ----
 BuiltinDecl(name: "readFile", group: .io, paramNames: ["path"],
 params: [t("String")], returns: [t("String")]),
 BuiltinDecl(name: "writeFile", group: .io, paramNames: ["path", "content"],
 params: [t("String"), t("String")], returns: []),
 BuiltinDecl(name: "readLine", group: .io, paramNames: [],
 params: [], returns: [t("String")]),

 // ---- math ----
 BuiltinDecl(name: "abs", group: .math, paramNames: ["x"],
 params: [t("I32")], returns: [t("I32")]),
 BuiltinDecl(name: "min", group: .math, paramNames: ["a", "b"],
 params: [t("I32"), t("I32")], returns: [t("I32")]),
 BuiltinDecl(name: "max", group: .math, paramNames: ["a", "b"],
 params: [t("I32"), t("I32")], returns: [t("I32")]),
 BuiltinDecl(name: "sqrt", group: .math, paramNames: ["x"],
 params: [t("F64")], returns: [t("F64")]),
 BuiltinDecl(name: "sin", group: .math, paramNames: ["x"],
 params: [t("F64")], returns: [t("F64")]),
 BuiltinDecl(name: "cos", group: .math, paramNames: ["x"],
 params: [t("F64")], returns: [t("F64")]),
 BuiltinDecl(name: "tan", group: .math, paramNames: ["x"],
 params: [t("F64")], returns: [t("F64")]),

 // ---- concurrency ----
 BuiltinDecl(name: "sleep", group: .concurrency, paramNames: ["ms"],
 params: [t("I32")], returns: []),
 // isCancel/joinAll/joinWithin：类型签名带泛型/通配位，由
 // registerConcurrencyBuiltins 专属路径登记，本表只记名与组
 BuiltinDecl(name: "isCancel", group: .concurrency, paramNames: ["e"], definesRuntimeValue: false),
 BuiltinDecl(name: "joinAll", group: .concurrency, paramNames: ["futures"], definesRuntimeValue: false),
 BuiltinDecl(name: "joinWithin", group: .concurrency, paramNames: ["future", "ms"], definesRuntimeValue: false),
 ]

 /// ADR-020 步骤 A（D1/D7）：内建类型 conformance 声明（声明面）。
 /// 特征方法派发（步骤 B）落地前，成员方法仍走 evaluateMember 既有路径；
 /// 此处仅使 String/Array 在类型环境中可查询「遵循 collection」。
 /// 方法面 = D1 最小集的成员方法部分（append/pop/slice/join/contains）+
 /// len（现为自由函数，方法化随步骤 B 裁决）；下标读属运算符通道，不入方法表。
 public static let conformances: [String: [String]] = [
 "String": ["collection"],
 "Array": ["collection"],
 ]

 // MARK: - 内建成员方法表（ADR-020 步骤 B）

 /// 内建成员方法声明：类型层签名与运行时派发共用同一张表。
 public struct MemberDecl {
 public let typeName: String
 public let name: String
 public let paramNames: [String]
 public let params: [TypeAnnotation]
 public let returns: [TypeAnnotation]
 /// 是否属于 collection 特征方法面（D1 最小集）
 public let inTrait: Bool

 init(typeName: String, name: String, paramNames: [String],
 params: [TypeAnnotation], returns: [TypeAnnotation], inTrait: Bool) {
 self.typeName = typeName
 self.name = name
 self.paramNames = paramNames
 self.params = params
 self.returns = returns
 self.inTrait = inTrait
 }
 }

 /// 内建成员方法全集（唯一事实源；TypeChecker.defineMethod 与
 /// Interpreter.evaluateMember 均从本表派生）。
 /// `inTrait = true` 的方法属于 collection 特征面（D1）；其余为类型扩展面。
 /// slice 参数用 Any 通配——开放边界传 nil = Optional.none（P2-B）。
 public static let memberMethods: [MemberDecl] = [
 // String（collection 子集：contains/slice；扩展面：upper/lower/substring/split）
 MemberDecl(typeName: "String", name: "upper", paramNames: [],
 params: [], returns: [t("String")], inTrait: false),
 MemberDecl(typeName: "String", name: "lower", paramNames: [],
 params: [], returns: [t("String")], inTrait: false),
 MemberDecl(typeName: "String", name: "contains", paramNames: ["sub"],
 params: [t("String")], returns: [t("Bool")], inTrait: true),
 MemberDecl(typeName: "String", name: "substring", paramNames: ["start", "end"],
 params: [t("I32"), t("I32")], returns: [t("String")], inTrait: false),
 MemberDecl(typeName: "String", name: "split", paramNames: ["sep"],
 params: [t("String")], returns: [TypeAnnotation.generic(name: "Array", params: [t("String")], location: builtinLocation)], inTrait: false),
 MemberDecl(typeName: "String", name: "slice", paramNames: ["start", "end"],
 params: [t("Any"), t("Any")], returns: [t("String")], inTrait: true),
 // 批 2（G48 三通道）：安全可选通道 `.get(i)` 与不安全通道 `.getUnchecked(i)`。
 // 动因：下标 `a[i]` 已改为安全断言通道（越界 panic），需要容错取值的显式通道；
 // `getUnchecked` 供已证明界内的热路径跳过检查（调用方以 `unsafe` 消耗点承担义务）。
 // `inTrait = false`：不作为 collection 特征面，避免用户类型被要求实现这两个方法。
 MemberDecl(typeName: "String", name: "get", paramNames: ["index"],
 params: [t("I32")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("String")], location: builtinLocation)], inTrait: false),
 MemberDecl(typeName: "String", name: "getUnchecked", paramNames: ["index"],
 params: [t("I32")], returns: [t("String")], inTrait: false),
 // Array（collection 子集：append/pop/slice/join；扩展面：last）
 MemberDecl(typeName: "Array", name: "join", paramNames: ["sep"],
 params: [t("String")], returns: [t("String")], inTrait: true),
 MemberDecl(typeName: "Array", name: "append", paramNames: ["value"],
 params: [t("Any")], returns: [TypeAnnotation.generic(name: "Array", params: [t("Any")], location: builtinLocation)], inTrait: true),
 MemberDecl(typeName: "Array", name: "slice", paramNames: ["start", "end"],
 params: [t("Any"), t("Any")], returns: [TypeAnnotation.generic(name: "Array", params: [t("Any")], location: builtinLocation)], inTrait: true),
 MemberDecl(typeName: "Array", name: "last", paramNames: [],
 params: [], returns: [t("Any")], inTrait: false),
 MemberDecl(typeName: "Array", name: "pop", paramNames: [],
 params: [], returns: [t("Any")], inTrait: true),
 MemberDecl(typeName: "Array", name: "get", paramNames: ["index"],
 params: [t("I32")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("Any")], location: builtinLocation)], inTrait: false),
 MemberDecl(typeName: "Array", name: "getUnchecked", paramNames: ["index"],
 params: [t("I32")], returns: [t("Any")], inTrait: false),
 // Dictionary：此前无成员面（下标为语法级）。批 2 依 D-5（三通道对三种容器一致）
 // 补 `get`/`getUnchecked`——缺失键与越界同义。
 MemberDecl(typeName: "Dictionary", name: "get", paramNames: ["key"],
 params: [t("Any")], returns: [TypeAnnotation.generic(name: "Optional", params: [t("Any")], location: builtinLocation)], inTrait: false),
 MemberDecl(typeName: "Dictionary", name: "getUnchecked", paramNames: ["key"],
 params: [t("Any")], returns: [t("Any")], inTrait: false),
 ]

 public static func member(typeName: String, name: String) -> MemberDecl? {
 return memberMethods.first(where: { $0.typeName == typeName && $0.name == name })
 }
}
