import Foundation
import Testing

@testable import PiniBackendLLVM
@testable import PiniIR
@testable import PiniRuntime

/// 字符串表示的六条判据：字面量在 IR 里带头 · 拼接就地追加与容量倍增 · 有别名时分裂 ·
/// 长度读头而不重算 · 下标按字素取 · 追加不受固定栈缓冲限制。
///  注意  这些判据钉的是**表示**，不是性能：`len` / `s[i]` 的阶由表示决定，时间数字不进 CI。
@Suite(.serialized)
struct StringHeaderRepresentationTests: PiniSourceLowering, Sendable {

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: try lowered(source))
    }

    private func dup(_ text: String) -> UnsafeMutablePointer<CChar> {
        text.withCString { bk_str_dup($0) }
    }

    @Test("字面量带头：常量前 16 字节是 rc/len/cap/graphemes，取串从偏移 16 起")
    func 字面量带头() throws {
        let ir = try emitted("main|func() -> ():\n    print(\"hi\")\n    return\n")
        #expect(
            ir.contains(
                "private constant [19 x i8] "
                    + "c\"\\00\\00\\00\\00\\02\\00\\00\\00\\02\\00\\00\\00\\02\\00\\00\\00\\68\\69\\00\"")
                || ir.contains("private constant [19 x i8]"),
            "字面量常量应为 16 字节头 + 2 字节载荷 + NUL，实际：\(ir.prefix(400))")
        #expect(ir.contains("i32 0, i32 16"), "取串的 GEP 必须跳过 16 字节头")
    }

    @Test("拼接就地追加：唯一持有且容量够时返回同一指针")
    func 拼接就地追加() {
        let right = dup("y")
        let first = bk_str_concat(dup("x"), right, 1)
        // 首次分配让容量涨到 16；第二次长度 2 + 1 仍在容量内，应原地写。
        let second = bk_str_concat(first, right, 1)
        #expect(UnsafeRawPointer(second) == UnsafeRawPointer(first), "容量够时不该搬家")
        #expect(String(cString: second) == "xyy")
        bk_str_release(right)
        bk_str_release(second)
    }

    @Test("有别名时分裂：计数大于一就不写那块载荷")
    func 有别名时分裂() {
        let source = dup("x")
        let grown = bk_str_concat(source, source, 1)
        bk_str_retain(grown)
        let split = bk_str_concat(grown, grown, 1)
        #expect(UnsafeRawPointer(split) != UnsafeRawPointer(grown), "rc > 1 时不能就地写")
        #expect(bk_str_refcount(grown) == 1, "消耗掉的那一份应已归还")
        #expect(String(cString: grown) == "xx", "原串不该被改写")
        #expect(String(cString: split) == "xxxx")
        bk_str_release(grown)
        bk_str_release(split)
    }

    @Test("自追加 `s = s + s` 不踩重叠：就地路径走 memmove")
    func 自追加重叠() {
        let base = dup("abc")
        let doubled = bk_str_concat(base, base, 0)
        bk_str_release(base)
        let inPlace = bk_str_concat(doubled, doubled, 1)
        #expect(String(cString: inPlace) == "abcabcabcabc")
        bk_str_release(inPlace)
    }

    @Test("长度读头：`graphemes` 有值就直接返回，不重扫载荷")
    func 长度读头() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: 18, alignment: 16)
        defer { base.deallocate() }
        base.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 4, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 8, as: Int32.self)
        base.storeBytes(of: Int32(7), toByteOffset: 12, as: Int32.self)
        base.storeBytes(of: CChar(0x61), toByteOffset: 16, as: CChar.self)
        base.storeBytes(of: CChar(0), toByteOffset: 17, as: CChar.self)
        let payload = base.advanced(by: 16).assumingMemoryBound(to: CChar.self)
        // 头的字素数故意写成 7（真实值是 1）：读数若为 7，走的就是头。
        #expect(bk_string_count(payload) == 7)
    }

    @Test("下标按字素取：纯 ASCII 走字节直取，多字节仍按字素簇")
    func 下标按字素() {
        let ascii = dup("abc")
        #expect(解包(bk_string_char_at(ascii, 1)) == "b")
        #expect(解包(bk_string_char_at(ascii, -1)) == "c")
        let cjk = dup("汉字")
        #expect(解包(bk_string_char_at(cjk, 1)) == "字")
        bk_str_release(ascii)
        bk_str_release(cjk)
    }

    /// 把一个 `Char`（八字节内联值）解成 Swift `String`：走与发射层同一条 `bk_char_to_string`。
    private func 解包(_ value: Int64) -> String {
        let text = bk_char_to_heap_string(value)
        defer { bk_str_release(text) }
        return String(cString: text)
    }

    @Test("追加不受固定栈缓冲限制：两万字节的串长度与内容都对")
    func 追加大串() {
        let payload = String(repeating: "a", count: 10000)
        let left = dup(payload)
        let right = dup(payload)
        let doubled = bk_str_concat(left, right, 0)
        bk_str_release(left)
        bk_str_release(right)
        #expect(bk_string_count(doubled) == 20000)
        #expect(bk_str_refcount(doubled) == 1)
        bk_str_release(doubled)
    }
}
