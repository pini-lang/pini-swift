/// 展开会按表的行克隆体内语句：同一处错误会随副本各出现一次，位置与内容完全相同。
/// 去重键取渲染后的整条诊断——位置相同但内容不同的两条仍各留一份，不把真错误折成一条。
enum DiagnosticDedupe {
    static func unique<T>(_ items: [T]) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(String(describing: $0)).inserted }
    }
}
