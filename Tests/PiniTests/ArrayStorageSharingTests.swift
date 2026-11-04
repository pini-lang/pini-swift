import Foundation
@testable import PiniRuntime
import Testing

/// 数组元素存储的共享与分裂：`bk_array_append` 的契约是「产出新数组、输入数组不受影响」，而新数组与输入
/// 共享元素存储（独占时就地增长、共享时不深拷）⇒ 输入侧长度与元素不变 · 共享本身可观测 · 写一侧不改另一侧 ·
/// 分裂时 retain 与 release 两端配对 · 追加过的槽归存储所有 · 两层分裂叠加不串味 · 跨扩容点的前沿与内容。
@Suite(.serialized)
struct ArrayStorageSharingTests: Sendable {

    // MARK: - 工具

    /// 元素标签的字面量。 注意  `_BkTag`（运行时段）是 `private`，测试读不到 ⇒ 在此照抄权威表：
    /// `i32 = 0` · `double = 1` · `bool = 2` · `str = 3` · `handle = 4` · `i64 = 5` · `rawPtr = 6`；
    /// 与发射层 `IREmitter.arrayElementABI` 用的是同一张表。
    private enum Tag {
        static let i32: Int32 = 0
        static let handle: Int32 = 4
    }

    /// 追加一个 `I32` 元素（照发射层的元素 ABI：宽 4 · tag 0）。
    private func appendI32(_ arr: UnsafeMutableRawPointer?, _ value: Int32) -> UnsafeMutableRawPointer {
        var v = value
        return withUnsafePointer(to: &v) { bk_array_append_unsafe(arr, $0, 4, Tag.i32) }
    }

    /// 读第 `i` 个 `I32` 元素。
    private func loadI32(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> Int32 {
        bk_array_get(arr, i).load(as: Int32.self)
    }

    /// 读第 `i` 个句柄型元素。
    private func loadHandle(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> UnsafeMutableRawPointer? {
        bk_array_get(arr, i).load(as: UnsafeMutableRawPointer?.self)
    }

    /// 造一个内容为 `values` 的数组。**刻意按发射形态的次序**：追加 → 释放旧句柄 → 用新句柄
    /// （`IREmitter.emitArrayAppend` 那一族的发射序）⇒ 本件连「旧句柄当场被丢」这个前提一起压。
    private func makeI32Array(_ values: [Int32]) -> UnsafeMutableRawPointer {
        var arr = bk_array_create(0)
        for v in values {
            let next = appendI32(arr, v)
            bk_array_destroy(arr)
            arr = next
        }
        return arr
    }

    // MARK: - 不变量一：输入侧不受影响

    @Test("追加不改变输入侧：长度与既有元素逐位不变，新数组多出末格")
    func appendLeavesTheInputUntouched() {
        /// 意图：这条是 `append` 契约的**底线**，也是「就地增长」这条路最容易走错的地方 ——
        /// 若实现图省事把输入也一起变长（共用同一块存储 + 拿存储容量当长度），
        /// 第一条断言即红。 注意  反向也要压：新数组的既有两格必须与输入逐位相同（不是零值）。
        let a = makeI32Array([1, 2])
        defer { bk_array_destroy(a) }
        let b = appendI32(a, 3)
        defer { bk_array_destroy(b) }

        #expect(bk_array_len(a) == 2, "输入侧长度必须仍是 2，实际 \(bk_array_len(a))")
        #expect(loadI32(a, 0) == 1 && loadI32(a, 1) == 2, "输入侧元素必须原样")
        #expect(bk_array_len(b) == 3, "新数组长度应为 3，实际 \(bk_array_len(b))")
        #expect(loadI32(b, 0) == 1 && loadI32(b, 1) == 2 && loadI32(b, 2) == 3, "新数组内容应为 1,2,3")
    }

    // MARK: - 不变量二：「共享」可观测（快路的判据）

    @Test("两个数组同一槽的元素框是同一个 ⇒ 共享存储真的生效")
    func appendSharesTheElementStorage() {
        /// 意图：唯一能把「快路在跑」与「仍旧每次深拷」区分开的判据 —— 深拷实现下两侧同一槽的地址必不相同，
        /// 共享存储之后必然相同。缺了本条，整套用例在「有人把快路撤掉」时照样全绿（本仓在册的空绿形态）。
        /// 故这里断言机制本身（共享是同址的充分条件），不是实现细节的偶然。
        let a = makeI32Array([7])
        defer { bk_array_destroy(a) }
        let b = appendI32(a, 8)
        defer { bk_array_destroy(b) }

        #expect(bk_array_get(a, 0) == bk_array_get(b, 0), "共享存储 ⇒ 第 0 槽应是同一个元素框")
        #expect(bk_array_get(a, 0) != bk_array_get(b, 1), "新追加的那一格必是新框")
    }

    // MARK: - 不变量三：共享对语言层不可见

    @Test("共享存储不可见：写新数组不污染输入侧，写输入侧也不污染新数组")
    func writesSplitTheSharedStorage() {
        /// 意图：共享存储是一种别名（与变量槽别名并列）。缺了写入前的分裂，本条前两个断言即红（两侧互相看见）——
        /// 而那是值语义这条语言承诺的底线。后半段刻意换方向再压一次：两次分裂时两侧的 `count` 不同（2 与 3），
        /// 只压一个方向会漏掉「分裂时拷错长度」这类错法。
        let a = makeI32Array([1, 2])
        defer { bk_array_destroy(a) }
        var b = appendI32(a, 3)
        defer { bk_array_destroy(b) }

        var nine: Int32 = 9
        withUnsafePointer(to: &nine) { b = bk_array_set_unsafe(b, 0, $0, 4, Tag.i32) ?? b }
        #expect(loadI32(b, 0) == 9, "写进新数组的必须生效")
        #expect(loadI32(a, 0) == 1, " 行不通  输入侧不许看到新数组的写")
        #expect(bk_array_len(a) == 2, "输入侧长度不变")

        var seven: Int32 = 7
        _ = withUnsafePointer(to: &seven) { bk_array_set_unsafe(a, 1, $0, 4, Tag.i32) }
        #expect(loadI32(a, 1) == 7, "写进输入侧的必须生效")
        #expect(loadI32(b, 1) == 2, " 行不通  新数组不许看到输入侧的写")
        #expect(bk_array_len(b) == 3, "新数组长度不变")
    }

    // MARK: - 不变量四：分裂时的嵌套句柄记账

    @Test("写句柄槽：分裂的深拷 retain 与被覆盖旧框的 release 两端配对")
    func writingAHandleSlotBalancesTheInnerShareCount() {
        /// 意图：分裂要深拷元素框，而句柄型元素在深拷时要 retain 一份（+1）、被覆盖的旧框释放时减一份（−1）。
        /// 只做一半的症状不是行为错，而是内层容器永不回收或悬垂 —— 两者都只有份额计数看得见 ⇒ 以 `bk_handle_shares`
        /// 的基线不变为判据。测试自己补一次别名点 retain（与发射层同规），否则基线本身就不对。
        let inner = makeI32Array([11])
        bk_handle_retain(inner)
        defer { bk_handle_release(inner) }
        let other = makeI32Array([22])
        bk_handle_retain(other)
        defer { bk_handle_release(other) }

        var innerPtr: UnsafeMutableRawPointer? = inner
        var otherPtr: UnsafeMutableRawPointer? = other
        //  注意  中间那个空数组句柄**必须释放**（与发射形态同序）：不释放则它仍持有那块存储
        // ⇒ 下一次追加看到「存储被共享」而走深拷路 —— 本用例第一版正是这么写错的，红在下面那条前置断言。
        let empty = bk_array_create(0)
        let o1 = withUnsafePointer(to: &innerPtr) { bk_array_append_unsafe(empty, $0, 8, Tag.handle) }
        bk_array_destroy(empty)
        var o2 = withUnsafePointer(to: &otherPtr) { bk_array_append_unsafe(o1, $0, 8, Tag.handle) }
        defer { bk_array_destroy(o1); bk_array_destroy(o2) }
        #expect(bk_array_get(o1, 0) == bk_array_get(o2, 0), "前置：两侧此时共享存储")

        let base = bk_handle_shares(inner)
        /// 写入也是一次「把句柄放进容器」⇒ 与发射层同规补一次 adopt.retain。少了这一笔，`o2` 的槽
        /// 会在销毁时多减一份份额，`defer` 再释放它就成了 UAF（分配器是否立刻复用决定崩不崩）。
        bk_handle_retain(other)
        withUnsafePointer(to: &otherPtr) { o2 = bk_array_set_unsafe(o2, 0, $0, 8, Tag.handle) ?? o2 }
        let after = bk_handle_shares(inner)
        #expect(after == base, " 行不通  内层份额必须回到基线（深拷 +1 与新框释放 −1 配对）：base=\(base) after=\(after)")
        #expect(bk_array_get(o1, 0) != bk_array_get(o2, 0), "写后必须已分裂（各自私有元素框）")
        #expect(loadHandle(o1, 0) == inner, "输入侧的槽仍指向内层原句柄")
        #expect(loadHandle(o2, 0) == other, "新数组的槽指向被写入的那个句柄")
    }

    // MARK: - 不变量五：前沿大于长度

    @Test("丢弃更长者之后再追加：残留槽被覆盖，两侧长度仍各自正确")
    func appendingAfterDiscardingTheNewerArrayReusesTheSlot() {
        /// 意图：追加过的槽归存储所有（前沿可大于某个持有者的长度）—— 这正是「长度必须记在 box 上、
        /// 不能拿存储容量当长度」的原因。本条走「丢弃更长的那个、留住更短的那个，然后再追加」：
        /// 若实现判错槽是否空闲（或漏掉残留槽里旧元素的释放），症状是长度/内容错或泄漏，前三条断言即红。
        let a = makeI32Array([1, 2])
        defer { bk_array_destroy(a) }
        let b = appendI32(a, 3)
        bk_array_destroy(b)  // 丢掉更长的那个（模拟作用域结束）

        let c = appendI32(a, 4)
        defer { bk_array_destroy(c) }
        #expect(bk_array_len(a) == 2, "a 仍是两格")
        #expect(bk_array_len(c) == 3, "c 应是三格，实际 \(bk_array_len(c))")
        #expect(loadI32(c, 0) == 1 && loadI32(c, 1) == 2 && loadI32(c, 2) == 4, " 行不通  末格必须是新追加的值")
        #expect(loadI32(a, 0) == 1 && loadI32(a, 1) == 2, "a 的内容不被覆盖")
    }

    // MARK: - 不变量六：两层分裂叠加

    @Test("句柄分裂与存储共享叠加：副本长度/内容与源一致，且写副本不动源")
    func boxLevelSplitOnSharedStorage() {
        /// 意图：数组有两层分裂（变量槽别名、元素存储共享）。两层叠加最容易出的错是「分裂时把长度拷成容量」
        /// 或「复制时丢长度」⇒ 本条以「副本长度/内容与源逐位相同」为判据。
        let a = makeI32Array([1, 2])
        defer { bk_array_destroy(a) }
        let b = appendI32(a, 3)  // b 与 a 共享存储
        defer { bk_array_destroy(b) }

        bk_handle_retain(b)  // 别名：两个变量槽持同一句柄（发射层在别名绑定处发）
        guard let copy = bk_handle_ensure_unique(b) else {
            Issue.record("bk_handle_ensure_unique 回空")
            return
        }
        defer { bk_array_destroy(copy) }
        #expect(bk_array_len(copy) == 3, "副本长度应为 3，实际 \(bk_array_len(copy))")
        #expect(loadI32(copy, 0) == 1 && loadI32(copy, 1) == 2 && loadI32(copy, 2) == 3, "副本内容须与源一致")
        #expect(bk_array_len(b) == 3, "源侧长度不变")

        var nine: Int32 = 9
        _ = withUnsafePointer(to: &nine) { bk_array_set_unsafe(copy, 2, $0, 4, Tag.i32) }
        #expect(loadI32(copy, 2) == 9, "写副本必须生效")
        #expect(loadI32(b, 2) == 3, " 行不通  源侧不许看到副本的写")
    }

    // MARK: - 不变量七：跨扩容点

    @Test("跨过倍增点的多次追加：长度与抽样内容正确")
    func repeatedAppendKeepsTheLength() {
        /// 意图：容量倍增路径（前沿 / 覆盖 / 长度）只在跨过扩容点时才现形 —— 容量 1→2→4→… 每一步都要拷前缀
        /// 并保住长度，小规模用例压不到这些点。本条不是计时判据：量取 8192 是因为它等于名字索引的容量，
        /// 判据本身只是长度与内容。
        var arr = bk_array_create(0)
        var expected: [Int32] = []
        for i in 0..<8192 {
            let next = appendI32(arr, Int32(i % 1000))
            bk_array_destroy(arr)
            arr = next
            expected.append(Int32(i % 1000))
        }
        defer { bk_array_destroy(arr) }

        #expect(bk_array_len(arr) == Int32(expected.count), "长度应为 \(expected.count)")
        for i in [0, 1, 999, 1000, 4095, 4096, 8191] {
            #expect(loadI32(arr, Int32(i)) == expected[i], "第 \(i) 格内容不符")
        }
    }
}
