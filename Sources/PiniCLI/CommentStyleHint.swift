import Foundation

/// 注释规范的常驻提示：随 `check` / `build` 的成功输出打到标准错误。
/// 门禁只认列出的形态，提示补的是「写之前先看见」这一层，两者覆盖面不同。
/// `PINI_NO_HINTS` 非空时静默：对账脚本按 stderr 形状判定，需要干净读数。
enum CommentStyleHint {
    static let text =
        "注释规范：每块 ≤3 行、每行 ≤120 字；"
        + "只写代码现状与结构意图，不写批号 / 日期 / 版本 / 行号 / 文档名 / 改动史"

    static func emit() {
        guard ProcessInfo.processInfo.environment["PINI_NO_HINTS"] == nil else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
