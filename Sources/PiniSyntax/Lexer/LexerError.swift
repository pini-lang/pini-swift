public enum LexerError: Error, Equatable {
    case invalidCharacter(String, SourceLocation)
    case unterminatedString(SourceLocation)
    case indentationError(SourceLocation)
    /// 源码里出现不可见字符。宽松词法对它不适用：零宽与双向控制字符会让同一段源码
    /// 在不同编辑器里读成不同程序，故在词法层直接拒绝，消息带码点。
    case invisibleCharacter(String, SourceLocation)
    /// 组合附加符号出现在标识符首字符位。它可作续字符，但不能起头。
    case misplacedCombiningMark(String, SourceLocation)
    /// 标识符混用多个高风险脚本：拉丁、西里尔与希腊互写会让名字看起来像另一个词。
    case mixedScriptIdentifier(String, SourceLocation)
}
