import Foundation
import Testing

@testable import PiniBackendLLVM
@testable import PiniIR
@testable import PiniRuntime
@testable import PiniSemantics
@testable import PiniSyntax

/// 容器元素所有权的六条回归：集合去重归还写入方那一份 · 字典既有键归还新键那一份 · 裸指针不参与串计数 ·
/// 新造键写入后仍有效 · 指针元素走 tag 6 · 切片元素自带一份。前三问运行时计数，后三问产物结构。
@Suite(.serialized)
struct ContainerElementOwnershipTests: PiniSourceLowering, Sendable {

    /// 与运行时段 `_BkTag` 同一张表（该 enum 是 `private`，测试读不到）。只列本件用到的三格。
    private enum Tag {
        static let string: Int32 = 3
        static let handle: Int32 = 4
        static let rawPtr: Int32 = 6
    }

    /// 造一个带计数头的 C 串。载荷由调用方写，与 `bk_str_alloc` 的契约一致。
    private func makeString(_ text: String) -> UnsafeMutablePointer<CChar> {
        let bytes = Array(text.utf8)
        let p = bk_str_alloc(Int64(bytes.count + 1))
        for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
        p[bytes.count] = 0
        return p
    }

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: lowered(source))
    }

    // MARK: - 运行时：写入方带来的那一份有归宿

    @Test("集合重复插入：写入方为重复元素带来的那一份被归还")
    func 集合去重归还份额() {
        let h = bk_array_create(0)
        var holder: UnsafeMutableRawPointer? = h
        var set = bk_set_create()

        bk_handle_retain(h)  // 第一次写入随带的 adopt
        set = withUnsafePointer(to: &holder) { bk_set_add_unsafe(set, $0, 8, Tag.handle) } ?? set
        bk_handle_retain(h)  // 第二次写入随带的 adopt，元素重复、不落槽
        set = withUnsafePointer(to: &holder) { bk_set_add_unsafe(set, $0, 8, Tag.handle) } ?? set

        bk_set_destroy(set)
        #expect(bk_handle_shares(h) == 1, "重复插入吞掉了写入方那一份 ⇒ 集合销毁后份额应回到 1")
        bk_handle_release(h)
    }

    @Test("字典既有键重写：新键那一份被归还，键计数回到基线")
    func 字典键重写归还份额() {
        let key = makeString("k")
        var keyHolder: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(key)
        var value: Int32 = 7
        var dict = bk_dict_create()

        bk_str_retain(key)  // 第一次写入随带的 adopt
        dict = withUnsafePointer(to: &keyHolder) { kp in
            withUnsafePointer(to: &value) { vp in
                bk_dict_set_unsafe(dict, kp, 8, Tag.string, vp, 4, 0)
            }
        } ?? dict

        bk_str_retain(key)  // 第二次写入随带的 adopt，键已存在、新键不落槽
        dict = withUnsafePointer(to: &keyHolder) { kp in
            withUnsafePointer(to: &value) { vp in
                bk_dict_set_unsafe(dict, kp, 8, Tag.string, vp, 4, 0)
            }
        } ?? dict

        bk_dict_destroy(dict)
        #expect(bk_str_refcount(key) == 1, "键已存在时新键那份被丢弃 ⇒ 销毁后计数应回到 1")
        bk_str_release(key)
    }

    @Test("裸指针元素：数组销毁不动它指向的串计数")
    func 裸指针不参与串计数() {
        let s = makeString("hello")
        var arr = bk_array_create(1)
        var ptr: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(s)

        arr = withUnsafePointer(to: &ptr) { bk_array_set_unsafe(arr, 0, $0, 8, Tag.rawPtr) } ?? arr
        bk_array_destroy(arr)

        #expect(bk_str_refcount(s) == 1, "裸指针元素不该被当成串归还")
        bk_str_release(s)
    }

    // MARK: - 产物形状：键在写入之后仍然有效

    /// 键 box 的第二个实参（`bk_dict_set(ptr 字典, ptr 键box, ...)`）。
    private func keyBoxArgument(_ line: String) -> String? {
        guard let open = line.range(of: "@bk_dict_set(") else { return nil }
        let args = line[open.upperBound...].prefix { $0 != ")" }
        let parts = args.components(separatedBy: ", ")
        guard parts.count >= 2, parts[1].hasPrefix("ptr ") else { return nil }
        return String(parts[1].dropFirst("ptr ".count))
    }

    /// 写入某个 box 的那条 `store i8* %键, ptr %box`，返回键的 SSA 名。
    private func storedValue(into box: String, before index: Int, in lines: [String]) -> String? {
        for i in stride(from: index - 1, through: 0, by: -1) {
            let line = lines[i]
            guard line.contains("ptr \(box)"), let start = line.range(of: "store i8* ") else { continue }
            let rest = line[start.upperBound...]
            guard let comma = rest.range(of: ", ptr \(box)") else { continue }
            return String(rest[..<comma.lowerBound])
        }
        return nil
    }

    @Test("字典下标写：新造键在 bk_dict_set 之后不再被释放")
    func 新造键写入后仍有效() throws {
        let listing = try emitted(
            """
            键|func(n: I32,) -> (String,):
                return "k\\(n)"

            main|func() -> ():
                var d = {"a"= 1}
                d[键(1)] = 2
                print(d["k1"])
                return
            """)
        let lines = listing.components(separatedBy: "\n")
        var checked = 0
        for (index, line) in lines.enumerated() where line.contains("@bk_dict_set(") {
            guard let box = keyBoxArgument(line),
                let key = storedValue(into: box, before: index, in: lines)
            else { continue }
            checked += 1
            let released = lines[(index + 1)...].contains { $0.contains("@bk_str_release(ptr \(key))") }
            #expect(!released, "键 \(key) 在 bk_dict_set 之后被释放 ⇒ 字典留下悬垂键")
        }
        #expect(checked >= 1, "产物里没有可判的字典写 ⇒ 本判据会空转")
    }

    @Test("指针数组：元素走裸指针 tag（6），不走串那一格")
    func 指针元素走裸指针标签() throws {
        let listing = try emitted(
            """
            main|func() -> ():
                var n = 1
                var p = unsafe &n
                var a = [p]
                print(len(a))
                return
            """)
        #expect(listing.contains("i32 8, i32 6"), "指针元素应写 tag 6")
        #expect(!listing.contains("i32 8, i32 3"), "指针元素不该与串共用 tag 3")
    }

    /// 元素 box 的第三个实参（`bk_array_set(ptr 数组, i32 下标, ptr 元素箱, ...)`）。
    private func elementBoxArgument(_ line: String) -> String? {
        guard let open = line.range(of: "@bk_array_set(") else { return nil }
        let args = line[open.upperBound...].prefix { $0 != ")" }
        let parts = args.components(separatedBy: ", ")
        guard parts.count >= 3, parts[2].hasPrefix("ptr ") else { return nil }
        return String(parts[2].dropFirst("ptr ".count))
    }

    @Test("字符串数组切片：拷贝出的元素自带一份计数")
    func 切片元素自带份额() throws {
        let listing = try emitted(
            """
            main|func() -> ():
                var a = ["aa", "bb", "cc"]
                var b = a[0:2]
                print(b[0])
                return
            """)
        let lines = listing.components(separatedBy: "\n")
        /// 只看用户函数：运行时内建（调度器的指针数组切片）也在同一份产物里，tag 6 本就不该 retain。
        guard let start = lines.firstIndex(where: { $0.hasPrefix("define i32 @main()") }),
            let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" })
        else {
            Issue.record("产物里没有 main ⇒ 本判据会空转")
            return
        }
        var checked = 0
        for index in (start..<end) where lines[index].contains("@bk_array_set(") {
            guard let box = elementBoxArgument(lines[index]),
                let source = lines[start..<index].lastIndex(where: {
                    $0.contains("\(box) = call ptr @bk_array_get(")
                })
            else { continue }
            checked += 1
            let retained = lines[source...index].contains(where: { $0.contains("@bk_str_retain(") })
            #expect(retained, "切片拷贝的元素没有 retain ⇒ 新旧两个数组共用一份串计数")
        }
        #expect(checked >= 1, "产物里没有可判的切片写 ⇒ 本判据会空转")
    }
}
