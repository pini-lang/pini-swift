/// embedded_min 的 26 条指令：寄存器式，操作数内联 —— 寄存器 `rN` · 常量 `kN` · 标签 `LN`。
/// 发射器只许用这一集，故清单就是 profile 的边界；新增一条要同时改本枚举与 `opcodeCount` 判据。
public enum EmbeddedMinOpcode: String, CaseIterable, Sendable {

    // 常量与变量
    case loadK = "LOADK"
    case loadVar = "LOADVAR"
    case storeVar = "STOREVAR"

    // 算术
    case add = "ADD"
    case subtract = "SUB"
    case multiply = "MUL"
    case divide = "DIV"
    case modulo = "MOD"
    case negate = "NEG"
    case logicalNot = "NOT"

    // 比较（六种关系，两种跳转各管一半）
    case equal = "EQ"
    case notEqual = "NE"
    case lessThan = "LT"
    case lessThanOrEqual = "LE"
    case greaterThan = "GT"
    case greaterThanOrEqual = "GE"

    // 控制流
    case jump = "JUMP"
    case jumpIf = "JUMPIF"
    case jumpIfNot = "JUMPIFNOT"
    case call = "CALL"
    case ret = "RET"
    case halt = "HALT"
    case panic = "PANIC"

    // 字符串与展示
    case concat = "CONCAT"
    case toStr = "TOSTR"
    case print = "PRINT"

    /// 清单条数。profile 声明 26 条，判据以此为读数。
    public static var count: Int { allCases.count }
}
