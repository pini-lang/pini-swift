/// 词法旁路：打印器要用、AST 里没有的两类信息——字面量原拼写、每行前导空格数。
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

    /// 无源模式：没有原文可查，也没有源行可还原。展开产物与合成节点都用它。
    public static let empty = PrintHints()

    public init(spellings: [Spelling] = [], indents: [Int: Int] = [:]) {
        self.spellings = spellings
        self.indents = indents
    }
}
