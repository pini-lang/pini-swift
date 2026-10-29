import Foundation

/// 解析上下文：区分当前位置期望类型注解（左值/类型位置）还是表达式（右值/值位置）。
/// 符号消歧用：类型位置下 `<` 总是泛型参数列表开始；值位置下 `<` 默认是比较运算符，
/// 经前瞻才可能升级为泛型构造调用。
public enum ParseContext: Equatable {
    case typePosition  // 期望类型注解：var x: ___, 字段: ___, 参数: ___, -> (___)
    case valuePosition  // 期望表达式/右值：var x = ___, print(___), return ___
}
