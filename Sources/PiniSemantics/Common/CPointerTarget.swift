/// `*T` 目标的白名单：IR 能给它一个标量表示的那些名字。
/// 导入面、导出面、声明级三处判据读同一份；加名字前先确认 `IRType(from:)` 收得下。
/// 进了这张表不等于位置成立 —— 形参位、返回位、字段位各自的额外约束由调用方另判。
public enum CPointerTarget {

    /// 能作 `*T` 目标的标量名，与 `IRType` 的标量分支一一对应。
    /// 两个方向都不许单边增删：加一个名字就要有对应的 IR 类型，删一个 IR 类型就要从这里删。
    public static let scalarNames: Set<String> = ["I8", "U8", "I32", "I64", "U64", "F64", "Bool"]

    /// C 面不透明字节指针的既有拼写：C 侧只当字节地址搬，不解读内容。
    public static let opaqueBytePointer = "U8"

    /// 语言层有宽度、IR 没有对应类型的名字：拒绝理由说「宽度」，不说「不认识」。
    public static let widthsOutsideIR: Set<String> = ["I16", "U16", "U32", "F32"]

    /// 名字能作 `*T` 目标时返回 `nil`，否则返回一句自成句子的理由。
    /// 理由点名那个名字：只答「不兼容」会让作者分不清是拼错还是形状不对。
    public static func rejection(for name: String) -> String? {
        if scalarNames.contains(name) { return nil }
        if widthsOutsideIR.contains(name) {
            return "`\(name)` 有语言层宽度，IR 没有对应类型"
        }
        if name == "String" || name == "Char" {
            return "`\(name)` 有运行时表示，不能作 `*T` 的目标；传字节缓冲用 `*U8`"
        }
        if name == "StringHandle" {
            return "`StringHandle` 本身已是不透明句柄，指针目标不许再套一层"
        }
        return "`\(name)` 不在 C 兼容白名单里"
    }
}
