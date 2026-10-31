import Foundation

/// 字素游标：把解释器里 `len(s)` / `s[i]` 的单次 O(len) 降为均摊 O(1)，空间 O(1)，不物化整串。
/// 做法是照 `String.Index` 的顺序前进（它自带字节偏移与字素边界缓存），把上一次位置按线程记在状态里，故无需加锁。
/// 命中判据必须用 `String ==`（内容相等）而非身份：换 `ObjectIdentifier` 会串味。访问不递增时退化为 O(len)，只会慢。
private final class CursorState {
    // 计数缓存与游标必须是两个独立字段，不许互相清除：`character` 未命中时若顺手清了计数缓存，
    // 每轮循环都会重新 `s.count`，读数回到二次方。
    var countText: String?
    var countValue = -1

    // ── 游标（上一次访问的位置）──
    var cursorText: String?
    var cursorIndex: String.Index?
    var cursorOffset = -1
}

private final class Store: @unchecked Sendable {
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
///  行不通  不改任何下标语义。
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

    /// `s[i]` 的均摊 O(1) 形态。`i` 必须已归一化（非负）。顺序递增时每步只前进一次；
    /// 跳跃或后退从串首重走（O(i)），与朴素实现同阶，结果不变。
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

    /// `s[lo..<hi]` 的按字素形态，代价 O(切片长)，首次定位到 `lo` 另计。
    /// 调用方负责把 `lo` / `hi` 夹到 `[0, count]` 并保证 `lo < hi`；本函数不重复那套夹取规则。
    static func slice(of s: String, from lo: Int, to hi: Int) -> String {
        let a = index(in: s, at: lo)
        let b = index(in: s, at: hi)   // 从 a 继续 ⇒ 只走 (hi - lo) 步
        return String(s[a..<b])
    }

    /// 单次前进的**上界**。超过它就重走 —— 避免「跳跃访问」时为了省一次定位而走很长的路。
    ///  注意  这不是调优旋钮：它只是把「顺序」与「跳跃」两种情形分开，取 16 是保守值
    /// （顺序扫描的步长恒为 1，与它无关）。
    private static let forwardWindow = 16
}
