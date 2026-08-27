import Foundation

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
 /// `join` 运算符：由 `await`/`wait` 关键字前缀产生（ADR-012 逆转，取代旧 `<=` 前缀写法）。
 /// 阻塞当前线程直至操作数 Future 完成，求值为 `Result<T, Error>`（错误即数据，不抛出）。
 case join(Expression, SourceLocation)
 /// 草稿 A2（批次 1.4，D2）：`^` 右值糖——对 `Result<T, E>` 值解包。
 /// `ok(v)` → 得 v；`err(e)` → 控制返回当前函数，错误 e 注入返回元组末槽（errors-as-data）。
 /// 与类型糖 `^T`（= Result<T>，parseTypeAnnotation）及中缀位异或 `^` 靠位置消歧（前缀一元）。
 case resultUnwrap(operand: Expression, location: SourceLocation)
 /// Phase 2a（ADR-015 FFI， `unsafe`）：不安全消耗点前缀。
 /// 标记紧随其后的单次函数调用或指针操作；复合表达式须括号 `unsafe (加载(p) + 1)`。
 case unsafe(operand: Expression, location: SourceLocation)
 /// Phase 2a（ADR-015 FFI， `&`）：不安全取地址前缀。
 /// 仅在 unsafe 上下文可用（`|unsafe` 函数体或 `unsafe (...)` 消耗点内）。
 case addressOf(operand: Expression, location: SourceLocation)
}
