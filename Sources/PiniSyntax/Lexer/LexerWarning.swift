/// 词法警告：扫描照常推进、记号照常产出，只把源码里看不见的风险记下来。
/// 与 `LexerError` 分成两个类型，因为处置不同：错误让调用方拿不到记号，警告要让编译继续。
public enum LexerWarning: Error, Equatable, Sendable {

    /// 注释或字符串内容里出现双向控制字符。它不改变词法结构，但会改变这段文字在编辑器与终端里的显示顺序。
    case bidirectionalControl(label: String, role: TextRole, location: SourceLocation)

    /// 承载文字的两种源码位置：注释与字符串是源码里仅有的两处允许任意文字、不做语法解释的地方。
    public enum TextRole: String, Equatable, Sendable {
        case comment
        case string
    }
}
