/// MiniTOML——批 6（G52 批 3）：清单（`pini.toml`）与锁文件（`pini-summary.toml`）共用的
/// 最小 TOML 两级收集器。从 `FileLoader.parseManifest` 抽出（原实现仅服务清单）。
///
/// 覆盖面：`[a]` / `[a.b]` 平表（点分即嵌套路径，按字符串键保存）、`[[a]]` 数组表（G52 §5.1，
/// 锁文件 `[[module]]`/`[[resource]]` 用）、`key = "value"` / `key = ["a", "b"]` 内联数组、
/// `#` 注释（整行与行内，引号感知——行内剥离修复见
/// 工单 issue-minitoml-inline-comment-2026-09-07）。**不做**：多行字符串、类型系统（一切值皆字符串）、转义序列。
/// 未知表**容错保留**（调用方自行取舍——清单解析忽略未知表，锁文件解析全量消费）。
internal enum MiniTOML {

    /// 引号感知地剥离一行内的行内注释：首个「未处于引号串内」的 `#` 起截断。
    /// MiniTOML 不支持转义序列——`"` 简单翻转引号态即可。整行注释剥空后由调用方按
    /// 空行跳过（工单 issue-minitoml-inline-comment-2026-09-07：原实现只跳
    /// 整行注释，行内残片污染值致 G52 Def-3 入口校验误报 E5-018）。
    static func strippingInlineComment(_ line: String) -> String {
        var inQuote = false
        for (offset, ch) in line.enumerated() {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == "#", !inQuote {
                return String(line[line.startIndex..<line.index(line.startIndex, offsetBy: offset)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return line
    }

    internal struct Document {
        var tables: [String: [String: String]] = [:]
        /// 数组表：名 → 按出现顺序的条目列表。
        var arrayTables: [String: [[String: String]]] = [:]

        /// 平表取值；不存在返回空字典。
        func plain(_ table: String) -> [String: String] { tables[table] ?? [:] }

        /// 点分前缀的子表集合（`[require.core]` → prefix="require" 下键 "core"）。
        func subTables(_ prefix: String) -> [String: [String: String]] {
            var out: [String: [String: String]] = [:]
            for (name, kv) in tables where name.hasPrefix(prefix + ".") {
                out[String(name.dropFirst(prefix.count + 1))] = kv
            }
            return out
        }
    }

    /// 解析文本。语法非法的行（无 `=` 的非表行）容错跳过——与既有清单解析行为一致。
    static func parse(_ text: String) -> Document {
        var doc = Document()
        var current: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = strippingInlineComment(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[["), line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                doc.arrayTables[name, default: []].append([:])
                current = line  // 保留 `[[...]]` 原形，条目写入时再剥壳
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            guard let eq = line.firstIndex(of: "="), let sec = current else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted = value.stripQuotes()

            if sec.hasPrefix("[[") {
                // 数组表条目：写入最近开启的条目（先拷出末条改完再写回，避免独占访问冲突）。
                let name = String(sec.dropFirst(2).dropLast(2))
                var list = doc.arrayTables[name] ?? []
                if !list.isEmpty {
                    var last = list.removeLast()
                    last[key] = unquoted
                    list.append(last)
                    doc.arrayTables[name] = list
                }
            } else {
                var t = doc.tables[sec] ?? [:]
                t[key] = unquoted
                doc.tables[sec] = t
            }
        }
        return doc
    }

    /// 解析 TOML 内联数组字面量 `["a", "b"]` → 字符串数组；非数组原样返回单元素。
    static func parseArray(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return [trimmed.stripQuotes()] }
        let inner = trimmed.dropFirst().dropLast()
        return
            inner
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).stripQuotes() }
            .filter { !$0.isEmpty }
    }
}
