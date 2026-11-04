/// 注释不进 token 流：词法跳过时往旁路表登记一条，打印器再按位置把它锚回输出。
/// `text` 从标记符（`;` 或 `#`）起到行尾，不含行首缩进与行尾空白——缩进由锚回位置决定。
public struct CommentEntry: Equatable, Sendable {
    /// 注释起点。整行注释是首个非空白列，行尾注释是标记符所在列。
    public let line: Int
    /// 一基列号。锚回时用它与前一处锚点的列比较，判别注释属块内还是块外。
    public let column: Int
    /// 原文，含前导标记符，已去行尾空白。
    public let text: String
    /// 该行除这条注释外没有 token。
    public let ownLine: Bool

    public init(line: Int, column: Int, text: String, ownLine: Bool) {
        self.line = line
        self.column = column
        self.text = text
        self.ownLine = ownLine
    }
}

/// 一个源文件的全部注释，按出现顺序。传空表即「无源文本模式」，打印器不插注释。
public typealias CommentTable = [CommentEntry]
