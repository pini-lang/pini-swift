public struct SourceLocation: Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let endLine: Int
    public let endColumn: Int
    public let fileName: String

    /// 单点位置（end 默认 = 同一点，跨度退化为单字符）。
    public init(line: Int, column: Int, fileName: String) {
        self.line = line
        self.column = column
        self.endLine = line
        self.endColumn = column
        self.fileName = fileName
    }

    /// 带结束点的位置（T1 诊断：跨度下划线渲染需要 end）。
    public init(line: Int, column: Int, endLine: Int, endColumn: Int, fileName: String) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.fileName = fileName
    }
}

extension SourceLocation {
    /// 行号为 0 是执行层的占位位置：语句没有携带源码位置时用它，报告据此退回「只带文件」。
    public var isPlaceholder: Bool { line == 0 }

    /// 报告位置串 `文件:行:列`。解释器侧拼报告、发射侧把它嵌进产物，两处必须同一种写法。
    public var reportPosition: String { "\(fileName):\(line):\(column)" }
}
