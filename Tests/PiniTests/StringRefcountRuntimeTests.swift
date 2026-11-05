import Foundation
@testable import PiniRuntime
import Testing

/// 原生字符串的引用计数：分配带 16 字节头，`bk_str_retain` / `bk_str_release` 成对加减（本件走 ABI 直调，
/// 不经发射层）。守的是配对性：新分配恰为 1 · 只读段常量（`rc == 0`）上两个动作都空转 · 元素槽与句柄同通道。
///  注意  计数归零即归还内存，此后读那个指针是未定义行为：双重释放不再是无操作。
@Suite(.serialized)
struct StringRefcountRuntimeTests: Sendable {

    /// 造一条带头串：走 `bk_str_dup`，长度与字素数由运行时一并写进头。
    private func alloc(_ text: String = "a") -> UnsafeMutablePointer<CChar> {
        return text.withCString { bk_str_dup($0) }
    }

    @Test("分配即计数一：新串由调用方接管那一份")
    func 分配即计数一() {
        let s = alloc()
        #expect(bk_str_refcount(s) == 1)
        bk_str_release(s)
    }

    @Test("计数成对加减：retain 加一、release 减一")
    func 计数成对加减() {
        let s = alloc()
        bk_str_retain(s)
        #expect(bk_str_refcount(s) == 2)
        bk_str_retain(s)
        #expect(bk_str_refcount(s) == 3)
        bk_str_release(s)
        #expect(bk_str_refcount(s) == 2)
        bk_str_release(s)
        #expect(bk_str_refcount(s) == 1)
        bk_str_release(s)
    }

    @Test("头长只有一份事实源：运行时导出的常数与发射层的常量一致")
    func 头长一致() {
        #expect(bk_str_header_bytes() == 16)
    }

    /// 字面量在发射层是 `rc = 0` 的只读常量，与堆串同形但这个格永不加减。
    /// 本件手工摆出同一形状（16 字节头 + 载荷），验证两个入口都不写那一格。
    @Test("只读段常量是惰性的：`rc == 0` 上 retain / release 都不写计数格")
    func 常量是惰性的() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: 18, alignment: 16)
        defer { base.deallocate() }
        base.storeBytes(of: Int32(0), toByteOffset: 0, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 4, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 8, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 12, as: Int32.self)
        base.storeBytes(of: CChar(0x61), toByteOffset: 16, as: CChar.self)
        base.storeBytes(of: CChar(0), toByteOffset: 17, as: CChar.self)
        let payload = base.advanced(by: 16).assumingMemoryBound(to: CChar.self)
        bk_str_retain(payload)
        bk_str_release(payload)
        #expect(bk_str_refcount(payload) == 0, "常量串的计数恒为 0")
        #expect(base.load(fromByteOffset: 0, as: Int32.self) == 0, "计数格不能被写")
    }

    @Test("元素槽在销毁时还掉那一份：`.str` 与容器句柄走同一条配对通道")
    func 元素槽在销毁时还掉那一份() {
        let s = alloc()
        var payload: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(s)
        let arr = bk_array_create(1)
        // tag 3 = `.str`、宽度 8 —— 与发射器 `arrayElementABI` 钉的那一格一致。
        //  注意  `bk_array_set` 对元素内容是**移动语义**（不 retain）：那一份由槽接管。
        withUnsafeBytes(of: &payload) { raw in
            _ = bk_array_set_unsafe(arr, 0, raw.baseAddress!, 8, 3)
        }
        #expect(bk_str_refcount(s) == 1, "写入是移动语义 ⇒ 计数不该涨")
        bk_array_destroy(arr)
    }
}
