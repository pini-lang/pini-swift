import Foundation

public enum UnaryOperator: Equatable {
 case minus
 case plus
 case logicalNot
 case bitwiseNot
 case increment
 case decrement
 case not
 /// 后缀强制解包运算符 `!`（设计决策 2026-08-28）：操作数须为 `Optional<T>`，产出 `T`；
 /// 对 `none` 运行时 trap。与 `&` 取地址同构，须处于 unsafe 上下文
 /// （`|unsafe` 函数体或 `unsafe (...)` 消耗点）。解析器按位置区分：
 /// 前缀 `!` → `.not`（逻辑非），后缀 `!` → `.forceUnwrap`。
 case forceUnwrap
}