import Foundation
@testable import PiniRuntime
import Testing

/// **原生字符串的引用计数所有权**（`N76`）—— 运行时段侧的配对性判据。
///
/// **这一件测什么**：`N76` 之前 native 字符串是裸 `char*`、**没有任何释放入口**，
/// 于是「拼接结果被覆盖或被丢弃」就等于永久滞留（整包面实测 4.2 GB 且仍在涨）。
/// 修法给分配加了计数头，并导出 `bk_str_retain` / `bk_str_release`。本件守的是那套机制的
/// **配对性**——⚠️ 而它**测不出泄漏**：既有全量回归与「产物能编能跑」对泄漏一律无感
/// （泄漏不改任何可观察行为），所以这一条必须由引用计数自身来判。
///
/// | 不变量 | 用例 |
/// |---|---|
/// | 新分配的串计数恰为 1（调用方接管那一份） | `分配即计数一` |
/// | retain / release 在读数上成对加减 | `计数成对加减` |
/// | 归零 ⇒ 摘出登记表（读数回 0，⛔ 不是停在 1） | `归零后读数回零` |
/// | **非本运行时段分配的串**：retain 与 release **都是无操作** | `外来串是惰性的` |
/// | 双重释放是无操作（第二次查表即失配，⛔ 不崩） | `重复释放是惰性的` |
/// | 数组元素槽的 `.str` 与容器句柄走**同一条**配对通道 | `元素槽在销毁时还掉那一份` |
///
/// ⚠️ **手段是 ABI 直调**（与 `ArrayStorageSharingTests` 同法）：被测对象是运行时段自身，
/// 不经发射层。发射层那侧的接线（别名点 retain / 槽退出与覆盖时 release / 拼接操作数就地还）
/// 另有端到端判据（`check-codegen*` 两腿对照与整包面），⛔ 本件不替代它。
/// ⚠️ `.serialized` 不是风格选择：`_bkStrLive` 是**进程级**可变全局，并行会让用例互相看见
/// 对方分配的串，判据变成偶然。
///
/// ⭐ 第二条不变量（`外来串是惰性的`）是整套设计的**安全支点**：全局字符串常量是
/// `@.strN` 的 GEP，它前面没有任何计数头（读到的是别的常量字节）⇒ 判据若靠读魔数就是野读。
/// 靠登记表判定，常量串在所有所有权路径上自动退化成空操作 —— 这条用例把它钉住。
@Suite(.serialized)
struct StringOwnershipRuntimeTests {

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

    @Test("归零后读数回零：指针已摘出登记表，⛔ 不是停在 1")
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
            bk_str_release(base)  // ⛔ 不崩，也不释放
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

    /// ⚠️ **如实登记本条判据的一个弱点**：`bk_str_refcount` 对「已归零（已摘出登记表）」
    /// 与「根本不是本运行时段分配的」**返回同一个 `0`** —— 两种状态在该读数上**同形**。
    /// 故 `归零后不复活` 与 `外来串是惰性的` 两条靠的是「**不崩 + 计数不回升**」，
    /// ⛔ 不是「0 与 1 的差别」。要更强地区分它们，得另加一个「分配/回收计数」诊断入口 ——
    /// 本批没做，如实留在这里，⛔ 别把这两条读成能区分那两种状态。
    @Test("重复释放是惰性的：第二次查表即失配，⛔ 不崩")
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
        // ⚠️ `bk_array_set` 对元素内容是**移动语义**（不 retain）：那一份由槽接管。
        withUnsafeBytes(of: &payload) { raw in
            _ = bk_array_set(arr, 0, raw.baseAddress!, 8, 3)
        }
        #expect(bk_str_refcount(s) == 1, "写入是移动语义 ⇒ 计数不该涨")
        bk_array_destroy(arr)
        #expect(bk_str_refcount(s) == 0, "槽销毁时该把那一份还掉")
    }
}
