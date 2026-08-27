public struct SourceLocation: Equatable {
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
