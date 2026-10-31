import PiniSyntax

/// `Foundation` 自 macOS 15 起导出同名 `Expression`（谓词表达式），与语法树节点撞车。
/// 层内统一走这条别名，正文便不必逐处限定；它不导出包外，故不参与包外的名字解析。
typealias Expression = PiniSyntax.Expression
