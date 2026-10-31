import Foundation
@testable import PiniRuntime
import Testing

/// 原生字符串的引用计数所有权：分配带计数头，`bk_str_retain` / `bk_str_release` 成对加减（本件走 ABI 直调，
/// 不经发射层）。守的是机制的配对性 —— 它测不出泄漏（泄漏不改任何可观察行为），故由引用计数自身判：新分配恰为 1 ·
/// 归零后读数回 0 · 外来串与双重释放都是无操作 · 元素槽与容器句柄同通道 —— 常量串没有计数头，靠登记表判定才不野读。
@Suite(.serialized)
struct StringOwnershipRuntimeTests: Sendable {

    /// 分配一个 `count` 字节的串（载荷由调用方写；本入口与 `malloc` 同契约）。
    private func alloc(_ count: Int64) -> UnsafeMutablePointer<CChar> {
        return bk_str_alloc(count)
    }

    @Test("分配即计数一：新串由调用方接管那一份")
    func 分配即计数一() {
        let s = alloc(2)
        #expect(bk_str_refcount(s) == 1)
        bk_str_release(s)
    }

    @Test("计数成对加减：retain 加一、release 减一")
    func 计数成对加减() {
        let s = alloc(2)
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

    @Test("归零后读数回零：指针已摘出登记表， 行不通  不是停在 1")
    func 归零后读数回零() {
        let s = alloc(2)
        bk_str_release(s)
        #expect(bk_str_refcount(s) == 0)
    }

    @Test("外来串是惰性的：非本运行时段分配的指针，retain / release 都无操作")
    func 外来串是惰性的() {
        // 栈上的一条 C 串 —— 形态与全局常量（`@.strN` 的 GEP）同类：它前面没有计数头。
        var buf = [CChar](repeating: 0, count: 4)
        buf[0] = 0x61  // "a"
        buf.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else {
                Issue.record("栈缓冲取址失败")
                return
            }
            bk_str_retain(base)
            #expect(bk_str_refcount(base) == 0, "外来串不该有计数")
            bk_str_release(base)  //  行不通  不崩，也不释放
            #expect(bk_str_refcount(base) == 0)
        }
    }

    @Test("归零即摘出：此后 retain 不再把它复活")
    func 归零后不复活() {
        let s = alloc(2)
        bk_str_release(s)
        bk_str_retain(s)
        #expect(bk_str_refcount(s) == 0)
    }

    ///  注意  如实登记本条判据的一个弱点：`bk_str_refcount` 对「已归零（已摘出登记表）」与「根本不是本运行时段
    /// 分配的」返回同一个 `0`，两种状态在该读数上同形 ⇒ `归零后不复活` 与 `外来串是惰性的` 靠的是「不崩 +
    /// 计数不回升」，不是「0 与 1 的差别」。要更强地区分得另加分配/回收计数入口；别把这两条读成能区分那两态。
    @Test("重复释放是惰性的：第二次查表即失配， 行不通  不崩")
    func 重复释放是惰性的() {
        let s = alloc(2)
        bk_str_release(s)
        bk_str_release(s)
        bk_str_release(s)
        #expect(bk_str_refcount(s) == 0)
    }

    @Test("元素槽在销毁时还掉那一份：`.str` 与容器句柄走同一条配对通道")
    func 元素槽在销毁时还掉那一份() {
        let s = alloc(2)
        s[0] = 0x61
        s[1] = 0
        var payload: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(s)
        let arr = bk_array_create(1)
        // tag 3 = `.str`、宽度 8 —— 与发射器 `arrayElementABI` 钉的那一格一致。
        //  注意  `bk_array_set` 对元素内容是**移动语义**（不 retain）：那一份由槽接管。
        withUnsafeBytes(of: &payload) { raw in
            _ = bk_array_set(arr, 0, raw.baseAddress!, 8, 3)
        }
        #expect(bk_str_refcount(s) == 1, "写入是移动语义 ⇒ 计数不该涨")
        bk_array_destroy(arr)
        #expect(bk_str_refcount(s) == 0, "槽销毁时该把那一份还掉")
    }
}
