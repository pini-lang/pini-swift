import Foundation

/// 语句 AST 节点
public indirect enum Statement: Equatable, Sendable {
    case varDecl(name: String, typeAnnotation: TypeAnnotation?, initializer: Expression?, isMutable: Bool, location: SourceLocation)
    /// 元组解构 `var (t, e) = rhs`（草稿 A1，批次 1）：左值模式元组逐分量绑定右值元组；
    /// `_` 为占位（不定义变量）。names 与右值元组分量一一对应。
    case varDestructure(names: [String], typeAnnotation: TypeAnnotation?, initializer: Expression?, isMutable: Bool, location: SourceLocation)
    case assign(target: AssignTarget, value: Expression, location: SourceLocation)
    case returnStatement(value: Expression?, location: SourceLocation)
    case breakStatement(label: String?, location: SourceLocation)
    case continueStatement(label: String?, location: SourceLocation)
    case ifStatement(condition: Expression, thenBlock: Block, elifs: [ElifBranch], elseBlock: Block?, label: String?, location: SourceLocation)
    case whileStatement(condition: Expression, body: Block, step: Block?, label: String?, location: SourceLocation)
    case forStatement(pattern: [String], iterable: Expression, body: Block, step: Block?, label: String?, location: SourceLocation)
    /// match 子块结构：case 缩进进 match 子块，通配写作 `case _:`，没有独立的 default 或通配子块。
    case matchStatement(value: Expression, cases: [MatchCase], location: SourceLocation)
    case scopedBlock(label: String?, body: Block, location: SourceLocation)
    /// 错误传播由 `Expression.tryExpression` 单点承载，语句位只是 expressionStmt 包装，没有独立的 try/except 语句。
    /// detach 语句 `detach <expr>` 把子任务从父 scope 剪枝、不再由父任务收回（fire-and-forget 的唯一合法出口），
    /// expr 求值为 Future。
    case detachStatement(expression: Expression, location: SourceLocation)
    case expressionStmt(expr: Expression, location: SourceLocation)
    case deferStatement(statement: Statement, location: SourceLocation)
    case passStatement(location: SourceLocation)
    /// capture 声明：匿名函数体内部、每行恰一个外部标识符，显式声明闭包捕获。
    /// 仅在匿名函数体顶层语句位合法（解析器强制）；须先于所列名字在体内的首次使用（语义层强制）。
    case captureStatement(name: String, location: SourceLocation)
}
