import PiniSyntax

/// `Foundation` 在 macOS 15 起也导出一个 `Expression`（谓词表达式），与语法树节点同名。
/// 本模块的顶层别名优先于导入名，故无前缀的 `Expression` 一律指语法树节点；
/// 对包外保留 `PiniCore.Expression` 这一拼写，调用方不必改指 `PiniSyntax`。
public typealias Expression = PiniSyntax.Expression
