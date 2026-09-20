import Foundation

/// 一次 join 站点由哪个关键字引入。
///
/// 这是语法对两种形态所作的**唯一**区分：`await` 在异步函数体内使用、可以让出当前任务；
/// `wait` 在任意上下文使用、占用当前线程直到 `Future` 决。
/// ⚠️ 该区分**曾在管线中被丢弃** —— 两个关键字产出同一个节点、关键字当场丢掉，
/// 运行时只能去问一个**在生产面从未被赋值**的模式开关；开关随停用而退役之后，
/// 两种形态就再无任何可分之处。本类型是那个区分的载体。
public enum JoinForm: String, Sendable, Equatable {
    /// `await` —— 异步函数体内，允许挂起等待。
    case awaits = "await"
    /// `wait` —— 任意上下文，阻塞直至决。
    case waits = "wait"

    /// 关键字字面量（诊断与打印用）。
    public var keyword: String { rawValue }
}

/// 函数调用参数（支持命名参数）
public struct CallArgument: Equatable {
    public let label: String?
    public let expression: Expression

    public init(label: String? = nil, expression: Expression) {
        self.label = label
        self.expression = expression
    }
}

/// 字典字面量条目（用于规避元组类型不支持 Equatable 的限制）
public struct DictEntry: Equatable {
    public let key: Expression
    public let value: Expression

    public init(key: Expression, value: Expression) {
        self.key = key
        self.value = value
    }
}

/// 字符串插值段（literal 为普通文本，expression 为待求值子表达式）
public enum InterpolationSegment: Equatable {
    case literal(String)
    case expression(Expression)
}

/// 表达式 AST 节点
public indirect enum Expression: Equatable {
    case identifier(name: String, location: SourceLocation)
    case integerLiteral(value: Int, location: SourceLocation)
    case floatLiteral(value: Double, location: SourceLocation)
    case stringLiteral(value: String, location: SourceLocation)
    case stringInterpolation(segments: [InterpolationSegment], location: SourceLocation)
    case boolLiteral(value: Bool, location: SourceLocation)
    case binary(left: Expression, op: BinaryOperator, right: Expression, location: SourceLocation)
    case unary(op: UnaryOperator, operand: Expression, location: SourceLocation)
    case call(callee: Expression, arguments: [CallArgument], location: SourceLocation)
    case member(object: Expression, name: String, location: SourceLocation)
    /// 元组位置访问 `.0` / `.1`（草稿 A2，批次 1）：`object.index` 取元组第 index 个元素。
    /// 与 `member` 的区分：`.名称` 走 member（字段/方法/命名元组标签），`.数字` 走 tupleIndex（位置访问）。
    case tupleIndex(object: Expression, index: Int, location: SourceLocation)
    /// 元组字面量。labels[i] 对应 elements[i] 的可选标签（nil = 位置元素）；
    /// 命名元组 `(a: 1, b: 2,)` 的 labels = ["a", "b"]（草稿 A2，批次 1.3，D1）。
    case tuple(labels: [String?], elements: [Expression], location: SourceLocation)
    case arrayLiteral(elements: [Expression], location: SourceLocation)
    case dictionaryLiteral(entries: [DictEntry], location: SourceLocation)
    case setLiteral(elements: [Expression], location: SourceLocation)
    /// 括号分组 `paren` 已在语法边界（Parser.parseTupleOrParen）消解，不再作为核心节点：
    /// 语义为零的纯语法构造，不进入类型检查 / 解释 / 代码生成。
    case `subscript`(expr: Expression, index: Expression, location: SourceLocation)
    /// 匿名函数（spec G29：统一为 `func` 关键字 + 块体，与具名函数 FuncDecl 同构）。
    /// `decl.name` 为占位（无名字），`decl.params`/`decl.returnTypes`/`decl.isAsync`/`decl.body` 完整复用。
    case funcLiteral(decl: FuncDecl, location: SourceLocation)
    case selfKeyword(location: SourceLocation)
    case selfTypeKeyword(location: SourceLocation)
    case genericConstruct(typeName: String, typeArgs: [TypeAnnotation], arguments: [CallArgument], location: SourceLocation)
    /// `join` 运算符：由 `await`/`wait` 关键字前缀产生（异步 join 表层 逆转，取代旧 `<=` 前缀写法）。
    /// 阻塞当前线程直至操作数 Future 完成，求值为 `Result<T, Error>`（错误即数据，不抛出）。
    /// `form` 记录**是哪个关键字写的** —— 它决定该站点可否让出（见 `JoinForm`）。
    case join(Expression, SourceLocation, JoinForm)
    /// try-else（try-else 迁移 迁移批 M2，取代旧 `try`/`except` 语句与 `^` 右值糖，spec『try-else 错误传播』节）：
    /// 错误传播唯一原语，语句位与表达式位双形态（语句位由 Parser 包装为 expressionStmt）。
    /// operand 静态要求 `Result<T, E>`：`ok(v)` → 表达式值为 v；`err(e)` → 绑定 errorVar
    /// 后执行 handler（限控制流：return/break/continue/pass，pass 仅语句位吞错）。
    /// `^` 右值糖为定义性脱糖：`^e` ≡ `try e else err: return err`（Parser 层展开）。
    case tryExpression(operand: Expression, errorVar: String, handler: Block, location: SourceLocation)
    /// Phase 2a（FFI 子系统， `unsafe`）：不安全消耗点前缀。
    /// 标记紧随其后的单次函数调用或指针操作；复合表达式须括号 `unsafe (加载(p) + 1)`。
    case unsafe(operand: Expression, location: SourceLocation)
    /// Phase 2a（FFI 子系统， `&`）：不安全取地址前缀。
    /// 仅在 unsafe 上下文可用（`|unsafe` 函数体或 `unsafe (...)` 消耗点内）。
    case addressOf(operand: Expression, location: SourceLocation)
    /// 点号用例构造（proposal-dot-case-construction-2026-08-30，D-1 裁决采纳）：
    /// 前导点 `.caseName` = 成员意图标记，与 Swift `UnresolvedMemberExpr` 同构——
    /// 解析期专用未解析节点（仅携带名字），决议在类型检查阶段按期望类型完成
    /// （期望类型命中 → 该枚举；唯一父枚举 → 回退；歧义/无 → 报错要求限定或期望类型）。
    /// `.caseName(args)` 解析为 `.call(.dotCaseRef, args)`（实参挂外层 call，与 Swift 同构）；
    /// `.caseName`（无实参）解析为裸 `dotCaseRef`（零关联值用例直接构造，带关联值则为构造器值）。
    case dotCaseRef(name: String, location: SourceLocation)
}
