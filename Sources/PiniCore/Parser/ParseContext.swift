import Foundation

/// 解析上下文
/// 区分当前解析位置期望的是类型注解（左值/类型位置）还是表达式（右值/值位置）
/// 用于符号消歧义：在类型位置下 `<` 总是泛型参数列表开始；
/// 在值位置下 `<` 默认是比较运算符，通过前瞻可能升级为泛型构造调用
public enum ParseContext: Equatable {
 case typePosition // 期望类型注解：var x: ___, 字段: ___, 参数: ___, -> (___)
 case valuePosition // 期望表达式/右值：var x = ___, print(___), return ___
}
