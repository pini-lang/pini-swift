import Foundation
import PiniCore
import Testing

/// 参考件 §12.8（宿主 IO）与登记表的一致性判据。
///
/// 意图：这一节是**读者唯一的说明书**，写错等于把错的签名交给使用者；而新增 io 内建时
/// 最容易漏的也正是这一节。判据把「文档列的」与「登记表里的」直接对成集合。
/// 驳回性：漏写 `appendFile`、或把 `exists` 误写成返回值非 `Bool` 的名字，集合就不相等。
struct ReferenceIODocTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // 本文件所在目录
            .deletingLastPathComponent()  // 套件目录
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // 仓库根
    }

    /// 取 §12.8 一节的行（到下一个二 / 三级标题为止）。
    private func section128(_ text: String) -> [String] {
        var inside = false
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("### 12.8") { inside = true; continue }
            if inside, line.hasPrefix("### ") || line.hasPrefix("## ") { break }
            if inside { out.append(line) }
        }
        return out
    }

    @Test("参考件 §12.8 列出的 io 内建与登记表逐个相等")
    func sectionListsExactlyTheRegistryIOBuiltins() throws {
        /// ⚠️ 只取以 ``| ` `` 开头的表格行：本节另有一张「路径解析」表，其首列不是内建名。
        let text = try String(
            contentsOf: repoRoot().appendingPathComponent("docs/spec/pini-reference-v0.md"),
            encoding: .utf8)
        let section = section128(text)
        #expect(!section.isEmpty, "没有找到 §12.8 —— 章节标题被改名或删除时本判据必须红")

        let documented = Set(
            section.filter { $0.hasPrefix("| `") }.compactMap { row -> String? in
                guard let open = row.firstIndex(of: "`") else { return nil }
                let rest = row[row.index(after: open)...]
                guard let paren = rest.firstIndex(of: "(") else { return nil }
                return String(rest[..<paren])
            })

        let registry = Set(BuiltinRegistry.decls.filter { $0.group == .io }.map(\.name))
        #expect(
            documented == registry,
            "文档多出 \(documented.subtracting(registry).sorted())；文档漏掉 \(registry.subtracting(documented).sorted())")
    }
}
