/// `*T` 目标的白名单：IR 能给它一个标量表示的那些名字。
/// 导入面、导出面、声明级三处判据读同一份；加名字前先确认 `IRType(from:)` 收得下。
/// 进了这张表不等于位置成立 —— 形参位、返回位、字段位各自的额外约束由调用方另判。
public enum CPointerTarget {

    /// 标量名与它的内存宽度。宽度同时是 `load` / `store` 的编解码宽度与 `p + n` 的步长。
    /// 只此一份：`RawPointerValue.stride` 与 `RuntimeOps` 都从这里取，运行时不再各写一张 switch。
    public static let scalarWidths: [String: Int] = [
        "I8": 1, "U8": 1, "I32": 4, "I64": 8, "U64": 8, "F64": 8, "Bool": 1,
    ]

    /// 能作 `*T` 目标的标量名，与 `IRType` 的标量分支一一对应。
    /// 两个方向都不许单边增删：加一个名字就要有对应的 IR 类型，删一个 IR 类型就要从这里删。
    public static let scalarNames: Set<String> = Set(scalarWidths.keys)

    /// C 面不透明字节指针的既有拼写：C 侧只当字节地址搬，不解读内容。
    public static let opaqueBytePointer = "U8"

    /// 语言层有宽度、IR 没有对应类型的名字：拒绝理由说「宽度」，不说「不认识」。
    public static let widthsOutsideIR: Set<String> = ["I16", "U16", "U32", "F32"]

    /// 标量的字节宽度；不在表里的名字返回 `nil`（未知宽度，调用方按 1 字节兜底或拒绝）。
    public static func width(of name: String) -> Int? { scalarWidths[name] }

    /// 名字能作 `*T` 目标时返回 `nil`，否则返回一句理由片段。
    /// 片段不带主语：调用方补上主语，嵌套位（`[*Foo]`）才点得准是哪个名字。
    public static func rejection(for name: String) -> String? {
        if scalarNames.contains(name) { return nil }
        if widthsOutsideIR.contains(name) {
            return "语言层有这个宽度，IR 没有对应类型"
        }
        if name == "CChar" {
            return "单字节字符没有独立的 IR 表示，用 `U8` 代替"
        }
        if name == "String" || name == "Char" {
            return "有运行时表示，C 侧没有对应布局；传字节缓冲用 `*U8`"
        }
        if name == "StringHandle" {
            return "本身已是不透明句柄，不许再套一层"
        }
        return "不在 C 兼容白名单里"
    }

    /// 三面共用的整句：导入、导出、声明级原样带上这一句，前置语各自不同。
    /// 同一个名字在一个面被拒、在另一个面被放行，正是「三处各写一套判据」留下的坑。
    public static func sentence(for name: String) -> String? {
        guard let reason = rejection(for: name) else { return nil }
        return "`\(name)` 不能作 `*T` 的目标：\(reason)"
    }
}
