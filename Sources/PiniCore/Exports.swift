// 伞 target：只做重导出，不含实现。包外 import PiniCore 一处即拿到全部层；
// 包内各层之间必须显式声明依赖，越界引用在编译期就写不出来。

// 这里不新增任何逻辑 —— 一旦添了函数，伞就会重新长成第二个 PiniCore，分层随即失效。
@_exported import PiniSyntax
@_exported import PiniSemantics
@_exported import PiniIR
@_exported import PiniBackendKit
@_exported import PiniBackendLLVM
@_exported import PiniBackendEmbedded
@_exported import PiniBackends
@_exported import PiniHost

/// `Foundation` 自 macOS 15 起导出同名 `Expression`（谓词表达式）。包外按
/// `PiniCore.Expression` 取语法树节点时，走的是这一条显式别名。
public typealias Expression = PiniSyntax.Expression
