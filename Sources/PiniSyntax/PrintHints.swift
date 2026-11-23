/// 词法旁路：打印器要用、AST 里没有的三类信息——字面量原拼写、每行前导空格、每行上方的空行数。
/// 键取位置而非节点身份，故展开器复制的节点沿用原位置时自动继承同一份旁路；查不到走默认。
public struct PrintHints: Equatable, Sendable {

    /// 一个字面量的原文：含进制前缀与指数写法，不含前导空白。位置是该字面量起点。
    public struct Spelling: Equatable, Sendable {
        public let line: Int
        public let column: Int
        public let text: String

        public init(line: Int, column: Int, text: String) {
            self.line = line
            self.column = column
            self.text = text
        }
    }

    /// 按出现顺序登记的字面量原文。
    public let spellings: [Spelling]
    /// 源码行号 → 该行前导空格数。只登记代码行；空行与整行注释在计数之前就被跳过。
    public let indents: [Int: Int]
    /// 源码行号 → 该行正上方紧邻的空行数。它记录作者的排版分组，不参与缩进计算。
    public let blankAbove: [Int: Int]
    /// 文件级缩进步长，已量化到 2 / 4 / 8。合成块与无源行都沿用它，同一文件不会出现两种步长。
    public let step: Int

    /// 无源模式：没有原文可查，也没有源行可还原。展开产物与合成节点都用它。
    public static let empty = PrintHints()

    public init(
        spellings: [Spelling] = [], indents: [Int: Int] = [:],
        blankAbove: [Int: Int] = [:], step: Int = 4
    ) {
        self.spellings = spellings
        self.indents = indents
        self.blankAbove = blankAbove
        self.step = step
    }

    /// 按位置取原文。查不到说明该节点没有源行——折叠产物与合成节点都走调用方的值输出。
    public func spelling(at location: SourceLocation) -> String? {
        for entry in spellings where entry.line == location.line && entry.column == location.column {
            return entry.text
        }
        return nil
    }

    /// 该行正上方有几个空行；没登记即 0。
    public func blanks(at line: Int) -> Int {
        blankAbove[line] ?? 0
    }

    /// 源步长落档，就近取小：1–3 取 2，4–6 取 4，7 起取 8。档位之外的值在这里收口。
    public static func quantizedStep(_ raw: Int) -> Int {
        if raw <= 3 { return 2 }
        if raw <= 6 { return 4 }
        return 8
    }
}
