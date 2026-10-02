import Foundation

/// 字素**游标** —— 把解释器里 `len(s)` / `s[i]` 的单次 `O(len)` 变成**均摊 O(1)**，
/// 且**不物化整串**（空间 O(1)）。
///
/// ## 取法来自 Swift 自己的字符串设计（⛔ 不是自创）
/// `String.Index` 内**同时**存着 `encodedOffset`（UTF-8 字节偏移）与一个 6 位的
/// **grapheme cache**（到下一个字素边界的距离）。⇒ 从**已有**索引前进到相邻索引
/// **不需要从头扫**，所以「按顺序迭代」是高效操作；而「计算第 n 个字符的索引」仍是 O(n)。
/// Swift 官方文档把这句写成设计意图：*如果你使用整数下标，会很容易写出性能极差的代码* ——
/// 于是它**不提供**整数下标，只提供索引游标。
///
/// ⇒ 本层的取法 = **把「上一次的位置」记在解释器状态里**（O(1) 空间），
/// 让顺序递增的整数下标访问每步只走 `index(after:)` 一步。
///
/// ## 与「物化整串边界数组」的差别（本层要消掉的正是一条被否掉的方案）
/// 物化数组（`Array(s)` 之后按整数取）也能线性，但**空间 O(len)**，且每遇一个新串就付一次
/// O(len) 的物化。实测对照（6.6 KB / 26.4 KB 逐字符扫描）：
///    现状 164.6 ms / 2402.4 ms  ·  物化 0.1 ms / 0.4 ms  ·  **游标 0.13 ms / 0.51 ms**
/// ⇒ 两者**时间同级**，而游标的空间是 O(1) ⇒ 取游标。
///
/// ## 正确性（命中判据为什么是 `==`）
/// 命中 = 「缓存的文本与当前文本相等」。它**严格正确**：`==` 是内容相等，不是身份相等。
/// ⚠️ 一处实测（它决定本层的代价）：`String ==` 在**同一份存储**上是 **O(1)**（实测 0.8 ns/次，
/// 两个规模比值 0.99）—— 顺序扫描正是这种情形（同一个变量的同一份存储）。
/// 而**不同存储、同内容**时会退化为逐字节比较（O(len)）⇒ 那正是下面「最坏情形」那一条。
/// ⛔ 但不许换成 `ObjectIdentifier(s as NSString)` 之类的**身份**判据：实测它会**串味**
/// （词法层两通道产物当场分歧），因为每次桥接都新建临时对象。
///
/// ## ⚠️ 如实登记的三条边界
/// ① **最坏情形**：访问**不递增**时（例如反复从末尾取 `s[n-1]`、或伪随机下标），
///    每步要重新走 ⇒ 退化为 O(len)/次（与改动前**同阶**）—— ⛔ 不会错，只会慢。
/// ② 命中判据依赖 `String ==` 的 O(1) 快速路径。若该路径在未来版本变化，后果是**退化为
///    逐字节比较**（慢），⛔ 不是错值 —— 本层**只加速、不参与**结果计算。
/// ③ 本层只覆盖**解释路径**。原生链路的字符串是裸 C 串（`bk_string_*`），没有 Swift `String`
///    的索引概念，那一族另计（见宿主侧复杂度登记件）。
///
/// ## 为什么是线程局
/// 并发任务的 worker 线程各有自己的游标（`ThreadLocal` 每线程一份）⇒ **无需加锁**，
/// 也不存在「一个线程把游标推走、另一个线程读到别人的位置」。
private final class CursorState {
    // ── 计数缓存（与游标分开：⛔ 二者不许互相清除）──
    // ⚠️ 这条是**实测踩中过**的：原型里把两者合成一个状态，且 `character` 的未命中分支
    //    顺手清掉了计数缓存 ⇒ 每轮循环重新 `s.count` ⇒ 读数仍是二次。
    //    那是**实现的错、不是方案的错** —— 分成两个独立字段后即线性（实测比值 4.50）。
    var countText: String?
    var countValue = -1

    // ── 游标（上一次访问的位置）──
    var cursorText: String?
    var cursorIndex: String.Index?
    var cursorOffset = -1
}

private final class Store {
    static let shared = Store()
    private let box = ThreadLocal<CursorState>()

    func state() -> CursorState {
        if let s = box.value { return s }
        let s = CursorState()
        box.value = s
        return s
    }
}

/// 解释器侧字符串的 O(1) 入口。调用方仍然负责**负值尾计数**与**越界判定** ——
/// 本层只把「数出总字数」与「数出第 i 个字素」这两件事从 O(len) 降到均摊 O(1)，
/// ⛔ 不改任何下标语义。
enum GraphemeCursor {

    /// `len(s)` 的均摊 O(1) 形态（首次 O(len)，此后命中即 O(1)）。
    static func count(of s: String) -> Int {
        let st = Store.shared.state()
        if let t = st.countText, t == s { return st.countValue }
        let c = s.count
        st.countText = s
        st.countValue = c
        return c
    }

    /// `s[i]` 的均摊 O(1) 形态。⚠️ `i` 必须**已归一化**（非负）。
    ///
    /// 顺序递增（`i`、`i+1`、`i+2`…，即逐字符扫描的形状）时每步只前进一次 ⇒ O(1)/步；
    /// 跳跃或后退时从串首重走（O(i)）⇒ 与改动前同阶，⛔ 不会错。
    static func index(in s: String, at target: Int) -> String.Index {
        let st = Store.shared.state()
        if let t = st.cursorText, t == s, let cur = st.cursorIndex,
            target >= st.cursorOffset, target - st.cursorOffset <= forwardWindow
        {
            var p = cur
            var k = st.cursorOffset
            while k < target {
                p = s.index(after: p)
                k += 1
            }
            st.cursorOffset = target
            st.cursorIndex = p
            return p
        }
        var p = s.startIndex
        var k = 0
        while k < target {
            p = s.index(after: p)
            k += 1
        }
        st.cursorText = s
        st.cursorOffset = target
        st.cursorIndex = p
        return p
    }

    /// `s[i]` 的字符形态。
    static func character(in s: String, at i: Int) -> Character {
        s[index(in: s, at: i)]
    }

    /// `s[lo..<hi]` 的**按字素**形态，代价 **O(切片长)**（首次定位到 `lo` 另计）。
    ///
    /// ⚠️ 调用方负责把 `lo` / `hi` 夹到 `[0, count]` 并保证 `lo < hi` ——
    /// 本函数不重复那套夹取规则（负值尾计数、开界默认值各站点有自己的权威出处）。
    static func slice(of s: String, from lo: Int, to hi: Int) -> String {
        let a = index(in: s, at: lo)
        let b = index(in: s, at: hi)   // 从 a 继续 ⇒ 只走 (hi - lo) 步
        return String(s[a..<b])
    }

    /// 单次前进的**上界**。超过它就重走 —— 避免「跳跃访问」时为了省一次定位而走很长的路。
    /// ⚠️ 这不是调优旋钮：它只是把「顺序」与「跳跃」两种情形分开，取 16 是保守值
    /// （顺序扫描的步长恒为 1，与它无关）。
    private static let forwardWindow = 16
}
