import Foundation
// 字符串引用计数走裸内存上的原子格（`Atomic<Int32>` 的布局与 `Int32` 同宽），
// 故不再需要保护登记表的锁；`Synchronization` 在 Apple 平台与 Linux 工具链上都有。
import Synchronization

// POSIX 线程本地存储（`pthread_key_t`）的取用口。与 `Sources/PiniHost/Common/ThreadLocal.swift`
// 用同一套系统头，理由相同：`Thread.current.threadDictionary` 只在 Apple 平台存在，
// 而运行时组件是**跨平台**目标（见 `Package.swift`）。
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - 并发后端抽象 阶段1：集合/COW 运行时 shim（Swift 实现，C ABI 边界）

// MARK: - 显式 share count 与写时复制（COW）基础设施
// 句柄的 share count 住在运行时而非 ARC：LLVM 后端里 `var b = a` 只把不透明句柄（裸 `ptr`）复制到另一个
// alloca 槽，ARC 看不见这次别名 ⇒ `isKnownUniquelyReferenced` 恒真；故按 `shares` 判分裂：别名点 retain、写前 ensure_unique。

// 份额契约（codegen 与运行时的分工）：`bk_*_create` 产出 shares == 1 的 box，归还责任随句柄走 —— 变量槽或
// 被写入的父容器。写入口只搬字节、不 retain，故调用方须自带一份（别名先 retain），入口必消费：落槽则接管、
// 不落槽（重复元素 / 既有键）则归还。box `deinit` 对句柄型元素递减一份 share。

/// 所有容器 box 的公共基类：携带 share count 与深拷协议。
/// 以基类承载使 `bk_handle_*` 系列可类型无关地操作任意容器句柄（`fromOpaque` 后动态转型），
/// 无需 IR 侧按类型分派 retain/split，也免去查三张 live 表的 O(n) 判型。
private class _BkBox {
    /// 持有此句柄的「变量槽」数目（显式 share count）。
    /// 创建时为 1；`bk_handle_retain` 递增；分裂或 `bk_*_destroy` 递减。
    var shares: Int = 1

    /// 深拷自身用于 COW 分裂：新 box `shares == 1`，且对每个 `tag == .handle` 的
    /// 嵌套元素调用 retain（内层由此变为共享，后续内层写会再次分裂——即「递归分裂」）。
    func cowCopy() -> _BkBox { fatalError("_BkBox.cowCopy 未实现") }
}

/// 活动句柄统一登记表（数组/字典/集合共用）：平衡 `bk_*_create` 的 `passRetained`。
/// 统一表使 `bk_handle_*` 与 `bk_runtime_cleanup` 无需按类型分派。
/// 建句柄与释放句柄都可能落在任一任务线程，故表的增删由 `_liveHandlesLock` 守护；释放动作在锁外做。
nonisolated(unsafe) private var _liveHandles: [Unmanaged<_BkBox>] = []
private let _liveHandlesLock = NSLock()

/// 登记新建 box，返回其不透明句柄。
private func _bkRegister(_ box: _BkBox) -> UnsafeMutableRawPointer {
    let u = Unmanaged.passRetained(box)
    _liveHandlesLock.lock()
    _liveHandles.append(u)
    _liveHandlesLock.unlock()
    return u.toOpaque()
}

/// 递减句柄的 share count；归零则先摘出登记表、再 release（release 触发 `deinit`，会递归回到本函数）。
/// 先摘出使递归修改落在数组访问之外，不触发独占性冲突。
/// 不查在册：同一句柄释放两次，第二次会在已回收的 box 上读计数（双释放是调用方错误）。
private func _bkReleaseShare(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    let box = Unmanaged<_BkBox>.fromOpaque(h).takeUnretainedValue()
    box.shares -= 1
    guard box.shares <= 0 else { return }
    // 摘出在锁内、释放在锁外：release 触发的 deinit 会递归回到这里，持锁递归必自锁。
    _liveHandlesLock.lock()
    let idx = _liveHandles.firstIndex(where: { $0.toOpaque() == h })
    let removed = idx.map { _liveHandles.remove(at: $0) }
    _liveHandlesLock.unlock()
    removed?.release()
}

/// 元素 box 内容若为可计数引用（嵌套句柄或字符串），递增其计数；供 `cowCopy` 用：字节复制会让两个
/// 容器持有同一内层值，必须计入共享。`.str` 与 `.handle` 同走这一条通道，差别只在计数住在哪
/// （容器在 `_BkBox.shares`，字符串在自己的头格）；常量串的 retain 是无操作，故不必分辨。
private func _bkRetainIfHandle(_ elemBox: UnsafeRawPointer, _ tag: Int32) {
    if _BkTag(rawValue: tag) == .str {
        bk_str_retain(elemBox.load(as: UnsafeMutablePointer<CChar>?.self))
        return
    }
    guard _BkTag(rawValue: tag) == .handle else { return }
    let inner = elemBox.load(as: UnsafeMutableRawPointer?.self)
    guard let inner else { return }
    Unmanaged<_BkBox>.fromOpaque(inner).takeUnretainedValue().shares += 1
}

/// 元素 box 内容若为可计数引用（嵌套句柄或字符串），递减其计数（供 `deinit` / `releaseAllElements`）。
/// `tag` 必须与 box 内容一致：`.str` 与 `.handle` 记在不同计数上，错 tag 会让两族的计数互串。
private func _bkReleaseIfHandle(_ elemBox: UnsafeRawPointer, _ tag: Int32) {
    if _BkTag(rawValue: tag) == .str {
        bk_str_release(elemBox.load(as: UnsafeMutablePointer<CChar>?.self))
        return
    }
    if _BkTag(rawValue: tag) == .char {
        bk_char_release(elemBox.load(as: Int64.self))
        return
    }
    guard _BkTag(rawValue: tag) == .handle else { return }
    _bkReleaseShare(elemBox.load(as: UnsafeMutableRawPointer?.self))
}

/// 分配并 memcpy 一个元素 box（运行时拥有，稳定指针）。
private func _bkAllocBox(_ src: UnsafeRawPointer, _ bytes: Int) -> UnsafeMutableRawPointer {
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<Int>.alignment)
    buf.copyMemory(from: src, byteCount: bytes)
    return buf
}

/// 写入前确保句柄独占：`shares <= 1` 原样返回；否则分裂出深拷副本并返回**新句柄**。
///
/// 调用方（codegen 或运行时 `set`）**必须**使用返回值替换原句柄槽，否则写入会落在旧 box 上。
private func _bkEnsureUnique(_ h: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let box = Unmanaged<_BkBox>.fromOpaque(h).takeUnretainedValue()
    guard box.shares > 1 else { return h }
    box.shares -= 1
    return _bkRegister(box.cowCopy())
}

/// 数组元素存储——可由多个数组 box 共享的槽表；长度不在这里，而在 box 的 `count` 上（容量可大于长度）。
/// 独立成层是为 `append`：契约要求产出新数组、输入不变，而发射形态 append → destroy(旧) → store(新)
/// 当场丢弃旧句柄 ⇒ 深拷退化成二次方；`refs == 1` 就地增长，否则深拷。对外函数均经 `@_cdecl` 导出 C ABI。
private final class _BkArrayStorage {
    /// 装箱-raw 存储：每槽是一个由本存储拥有的堆 box（`UnsafeMutableRawPointer`），box 内 memcpy 存元素
    /// 原始字节 ⇒ 对元素类型无关，宽度由 codegen 的 `elemBytes` 传入。元素 box 的生命周期由本存储持有，
    /// 最后一个持有者离开时经 `releaseAllElements` 统一释放。
    var elements: [UnsafeMutableRawPointer?]
    /// 每槽内容的类型标签（与 `_BkTag` 对齐）。COW 深拷时据此识别嵌套句柄元素
    /// 并递增其 share count——否则字节复制会让两个数组共享同一内层句柄，
    /// 而内层写因 `shares == 1` 原地生效，污染另一侧（嵌套 COW 的关键）。
    var tags: [Int32]
    /// 每槽字节宽度（深拷需要，且与 `elemBytes` 一致）。
    var widths: [Int]
    /// 聚合元素的成员钩子：`tag == .aggregate` 的槽里是一个内联结构体，逐成员的保留与归还
    /// 需要布局知识，而布局只在发射层 ⇒ 由它合成的两个函数在这里登记。
    ///  注意  其它 tag 的槽不看这两个字段；`nil` 表示「这个数组没有聚合元素」。
    var elementRetain: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    var elementRelease: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    /// 持有本存储的 **box 数**（由 `_BkArrayBox` 的初始化器与反初始化器成对增减）。
    ///  行不通  不借 ARC / `isKnownUniquelyReferenced` 判定 —— 与 box 的 `shares` 同源（见件头那条
    /// 「LLVM 层的复制不经过 ARC」）：要的是一个能被判据数出来的计数，不是运行时的猜测。
    var refs: Int = 0

    init(capacity: Int) {
        // 上限保护：负数容量按 0 处理，避免越界分配。
        let n = max(capacity, 0)
        elements = Array(repeating: nil, count: n)
        tags = Array(repeating: 0, count: n)
        widths = Array(repeating: 0, count: n)
    }

    /// 扩容到至少容纳 `needed` 个槽（容量倍增；增量追加 ⇒ 单次摊销 O(1)）。
    ///  注意  **只搬指针**：已存在的元素 box 继续原地被引用，份额不变
    /// ——  行不通  **不**为它们重新分配 box，那正是改动前那条二次方路径。
    func grow(to needed: Int) {
        var capacity = max(elements.count, 1)
        while capacity < needed { capacity *= 2 }
        guard capacity > elements.count else { return }
        elements.append(contentsOf: Array(repeating: nil, count: capacity - elements.count))
        tags.append(contentsOf: Array(repeating: 0, count: capacity - tags.count))
        widths.append(contentsOf: Array(repeating: 0, count: capacity - widths.count))
    }

    /// 深拷前 `count` 个槽成一块**新存储**（COW 分裂 / 共享路专用）。
    /// 与 `grow` 的分工：这里**必须**为每个元素重新分配 box —— 两块存储将各自拥有它们，
    /// 一侧释放不得动到另一侧的槽；并对 `tag == .handle` 的嵌套元素 retain 一份（配对 `deinit`）。
    func deepCopy(count: Int) -> _BkArrayStorage {
        let n = max(count, 0)
        let copy = _BkArrayStorage(capacity: n)
        copy.elementRetain = elementRetain
        copy.elementRelease = elementRelease
        for i in 0..<n {
            copy.tags[i] = tags[i]
            copy.widths[i] = widths[i]
            guard let src = elements[i], widths[i] > 0 else { continue }
            copy.elements[i] = _bkAllocBox(src, widths[i])
            copy.retainElement(src, tag: tags[i])
        }
        return copy
    }

    /// 归还一格元素的份额：聚合按登记的钩子逐成员归还，其余按 tag 分派。
    ///  注意  与 `retainElement` 成对 —— 两侧都走这一对入口，才不会一边逐成员保留、一边按标量释放。
    func releaseElement(_ box: UnsafeMutableRawPointer, tag: Int32) {
        if _BkTag(rawValue: tag) == .aggregate {
            elementRelease?(box)
        } else {
            _bkReleaseIfHandle(box, tag)
        }
    }

    /// 保留一格元素的份额：聚合逐成员保留，其余按 tag 分派（深拷复制字节时要靠这一步）。
    func retainElement(_ box: UnsafeMutableRawPointer, tag: Int32) {
        if _BkTag(rawValue: tag) == .aggregate {
            elementRetain?(box)
        } else {
            _bkRetainIfHandle(box, tag)
        }
    }

    /// 释放本存储拥有的全部元素 box（**最后一个**持有者离开时调用）。
    ///  注意  遍历**整个容量**（ 行不通  不是某个 box 的 `count`）：被追加过的槽可能超出该持有者的长度，
    /// 却仍由本存储拥有；漏掉即泄漏、多放即双重释放。
    func releaseAllElements() {
        for i in elements.indices {
            guard let b = elements[i] else { continue }
            releaseElement(b, tag: tags[i])
            b.deallocate()
        }
    }
}

/// 数组句柄背后的真实存储：**长度**（`count`）+ 一块（可与兄弟 box 共享的）`_BkArrayStorage`。
private final class _BkArrayBox: _BkBox {
    /// 元素存储。 注意  可与 `append` 产出的兄弟 box **共享**（`refs > 1`）⇒ 写入前须先分裂。
    var storage: _BkArrayStorage
    /// 本数组的**长度**（元素个数）。
    ///  注意  与 `storage.elements.count`（**容量**）不是一回事：容量可因追加而更大，也可被更长的
    /// 兄弟 box 共享 ⇒ 一切越界判定（get / set / ensure_unique_at）**只认本字段**。
    var count: Int

    init(count: Int) {
        let n = max(count, 0)
        storage = _BkArrayStorage(capacity: n)
        self.count = n
        storage.refs += 1
    }

    /// 承接一块已有存储（追加的就地增长路径 · 深拷之后的绑定）。
    ///  注意  与 `init(count:)` 同规：**初始化即计入一份 `refs`**，与 `deinit` 成对。
    init(reusing storage: _BkArrayStorage, count: Int) {
        self.storage = storage
        self.count = count
        storage.refs += 1
    }

    override func cowCopy() -> _BkBox {
        _BkArrayBox(reusing: storage.deepCopy(count: count), count: count)
    }

    deinit {
        storage.refs -= 1
        guard storage.refs <= 0 else { return }
        storage.releaseAllElements()
    }
}

/// 写入前确保 box 的元素存储独占：共享（`refs > 1`）则深拷一块私有存储并就地换装。
/// 与 `_bkEnsureUnique`（变量槽别名）是两件事：那层管「同一句柄被两个槽持有」，这层管「`append` 产出的
/// 新容器与输入共享同一块存储」。缺任一层就会出现「改一个数组、另一个跟着变」；句柄不换，调用方仍有效。
private func _bkArraySplitStorage(_ box: _BkArrayBox) {
    guard box.storage.refs > 1 else { return }
    let old = box.storage
    let fresh = old.deepCopy(count: box.count)
    fresh.refs = 1
    box.storage = fresh
    old.refs -= 1
}

// MARK: - 数组运行时（D0 最小覆盖：I32 元素特化）

/// 运行时致命错误：消息写到 stderr，进程以退出码 1 终止（解释器通道同码）。
/// `exit` 会 flush 标准流 ⇒ 陷阱之前的输出必然落地；`abort` 不 flush；`PINI_PANIC_ABORT` 非空时改走它。
/// stderr 在 Glibc 里是可变全局量，直接引用按共享可变状态判错 ⇒ 走 `write(2, …)`，绕开 stdio 的全局表。
private func _bkWriteStderr(_ text: String) {
    var bytes = Array(text.utf8)
    bytes.withUnsafeMutableBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        var offset = 0
        while offset < buf.count {
            let n = write(2, base + offset, buf.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
}

/// 打印语句的独占门：一次 `print` 的多段 `printf` 必须连成一段，否则并发下两行的字节会互相插进去。
/// 可重入：聚合值打印是递归的，求值期间的用户代码也可能再打印。
private let _bkPrintLock = NSRecursiveLock()

@_cdecl("bk_print_lock")
public func bk_print_lock() {
    _bkPrintLock.lock()
}

@_cdecl("bk_print_unlock")
public func bk_print_unlock() {
    _bkPrintLock.unlock()
}

@_cdecl("bk_panic")
public func bk_panic(_ msg: UnsafePointer<CChar>?) -> Never {
    if let msg { _bkWriteStderr(String(cString: msg)) }
    _bkWriteStderr("\n")
    if let flag = getenv("PINI_PANIC_ABORT"), flag.pointee != 0 {
        abort()
    }
    exit(1)
}

// MARK: 句柄通用原语（类型无关的 share count / COW 分裂）

/// 别名绑定（`var b = a`、容器传参等）：递增 share count，使后续任一侧的写触发分裂。
/// codegen 在容器句柄被复制进新变量槽时发射本调用；不发射则退化为「共享且原地改」（错误语义）。
/// 裸份额操作，不校验在册：传入的必须是仍存活的容器句柄，否则计数改到已回收的对象上。
@_cdecl("bk_handle_retain")
public func bk_handle_retain(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    Unmanaged<_BkBox>.fromOpaque(h).takeUnretainedValue().shares += 1
}

/// 写入前的独占化：共享则深拷分裂并返回**新句柄**，独占则原样返回。
/// 调用方必须把返回值写回持有该句柄的变量槽（值语义要求）。
@_cdecl("bk_handle_ensure_unique")
public func bk_handle_ensure_unique(_ h: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let h else { return nil }
    return _bkEnsureUnique(h)
}

/// 嵌套写路径的中间层独占化：确保 `parent[i]` 处的嵌套句柄独占，并就地更新父槽。
/// 不能拆成 ensure_unique + `bk_array_set`：后者会 `_bkReleaseIfHandle(old)` 再递减一次同一份 share，
/// 导致内层提前回收。故只改写句柄字节、不释放旧句柄；前置条件是 `parent` 已独占，违反即 panic 暴露缺陷。
@_cdecl("bk_array_ensure_unique_at")
public func bk_array_ensure_unique_at(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> UnsafeMutableRawPointer? {
    guard let arr else { return nil }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    guard box.shares <= 1 else {
        bk_panic("Pini runtime error: bk_array_ensure_unique_at requires a unique parent handle (shares=\(box.shares))")
    }
    _bkArraySplitStorage(box)
    let idx = Int(i)
    guard idx >= 0, idx < box.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.count))")
    }
    guard let slot = box.storage.elements[idx] else {
        bk_panic("Pini runtime error: array element \(idx) is uninitialized")
    }
    guard _BkTag(rawValue: box.storage.tags[idx]) == .handle else {
        bk_panic("Pini runtime error: array element \(idx) is not a nested container handle")
    }
    let old = slot.load(as: UnsafeMutableRawPointer.self)
    let new = _bkEnsureUnique(old)
    // `_bkEnsureUnique` 已把本槽的 share 转移给 new，故仅改写字节、不再 release old。
    if new != old { slot.storeBytes(of: new, as: UnsafeMutableRawPointer.self) }
    return new
}

/// 当前 share count（仅供测试/诊断，IR 不发射）。
@_cdecl("bk_handle_shares")
public func bk_handle_shares(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard let h else { return 0 }
    return Int32(Unmanaged<_BkBox>.fromOpaque(h).takeUnretainedValue().shares)
}

/// 释放一份 share（归零则回收）。三个类型化 `bk_*_destroy` 均委托至此。
/// 与 `bk_handle_retain` 成对；多减一次就是双释放，这里不查在册。
@_cdecl("bk_handle_release")
public func bk_handle_release(_ h: UnsafeMutableRawPointer?) {
    _bkReleaseShare(h)
}

/// 创建长度为 `len` 的数组，返回不透明句柄。
@_cdecl("bk_array_create")
public func bk_array_create(_ len: Int32) -> UnsafeMutableRawPointer {
    return _bkRegister(_BkArrayBox(count: Int(len)))
}

/// 给数组登记聚合元素的成员钩子：深拷时逐成员保留、销毁时逐成员归还。
///  注意  必须在第一次写入之前调用（创建后立刻）；存储已被共享时登记只落在当前 box 上，
/// 兄弟 box 各自带自己的那一份 —— 而元素类型相同的数组本就该有同一对函数。
@_cdecl("bk_array_set_element_hooks")
public func bk_array_set_element_hooks(
    _ arr: UnsafeMutableRawPointer?,
    _ retain: (@convention(c) (UnsafeMutableRawPointer) -> Void)?,
    _ release: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
) {
    guard let arr else { return }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    box.storage.elementRetain = retain
    box.storage.elementRelease = release
}

/// 数组长度（元素个数）。
@_cdecl("bk_array_len")
public func bk_array_len(_ arr: UnsafeMutableRawPointer?) -> Int32 {
    guard let arr else { return 0 }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    return Int32(box.count)
}

/// 读取下标 `i` 处的元素 box，返回运行时拥有的稳定 `ptr`，codegen 据此 `load T`；越界或槽未初始化
/// 经 `bk_panic` 终止（与解释器报错一致）。稳定期到该槽被 `bk_array_set` 重写或本数组被释放为止；
/// 与兄弟数组共享存储的写入不会动到它（那条路先分裂成私有存储）。
@_cdecl("bk_array_get")
public func bk_array_get(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> UnsafeMutableRawPointer {
    guard let arr else { bk_panic("Pini runtime error: array handle is null") }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    let idx = Int(i)
    guard idx >= 0, idx < box.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.count))")
    }
    guard let ptr = box.storage.elements[idx] else {
        bk_panic("Pini runtime error: array element \(idx) is uninitialized")
    }
    return ptr
}

/// 写下标 `i`：两层分裂后把 `src` 的 `elemBytes` 字节 memcpy 进新箱、先释放该槽旧箱，返回须写回的句柄。
/// 份额由调用方自带：本入口只搬字节，覆盖或销毁时按 tag 归还旧元素 —— 少带即悬垂，多带即泄漏。
/// Swift 名带 `_unsafe`；C 符号仍是 `bk_array_set`，生成 IR 不受影响。
@_cdecl("bk_array_set")
public func bk_array_set_unsafe(
    _ arr: UnsafeMutableRawPointer?, _ i: Int32, _ src: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let arr else {
        _bkReleaseIfHandle(src, elemTag)
        return nil
    }
    let target = _bkEnsureUnique(arr)
    let box = Unmanaged<_BkArrayBox>.fromOpaque(target).takeUnretainedValue()
    //  重要  两层分裂都必须在写入**之前**：一层管变量槽别名（上一行），一层管容器存储共享（本行）。
    _bkArraySplitStorage(box)
    let idx = Int(i)
    guard idx >= 0, idx < box.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.count))")
    }
    let n = Int(elemBytes)
    guard n > 0 else { return target }
    if let old = box.storage.elements[idx] {
        box.storage.releaseElement(old, tag: box.storage.tags[idx])
        old.deallocate()
    }
    box.storage.elements[idx] = _bkAllocBox(src, n)
    box.storage.tags[idx] = elemTag
    box.storage.widths[idx] = n
    return target
}

/// 追加一个元素，返回新数组（调用方须用返回值替换原句柄）；输入与其内容不受影响，空句柄视作空数组。
/// 与 `bk_array_set` 分工：后者写既有容器（写前必分裂），前者产出新容器，故须补 `_bkArraySplitStorage`。
/// 份额：新数组接管 `src` 那一份，本入口只搬字节、不 retain；别名那份由发射层补。
@_cdecl("bk_array_append")
public func bk_array_append_unsafe(
    _ arr: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer {
    let width = Int(elemBytes)
    guard width > 0 else {
        bk_panic(
            "Pini runtime error: bk_array_append needs a positive element width (from the codegen element ABI)")
    }
    let source = arr.map { Unmanaged<_BkArrayBox>.fromOpaque($0).takeUnretainedValue() }
    let count = source?.count ?? 0
    // 分岔点：存储独占（`refs == 1`）⇒ 就地增长，旧元素一个都不动，只有追加那格新分配（容量不足则倍增）
    // ⇒ 单次摊销 O(1)。判据不是「长度 == 容量」：容量可更大，那些槽仍由本存储拥有，故先释放该格旧内容。
    // 就地增长仍保证输入不受影响：写入槽恒 ≥ 输入长度，长度记在 box 的 `count` 上。
    if let source, source.storage.refs == 1 {
        let storage = source.storage
        storage.grow(to: count + 1)
        if let old = storage.elements[count] {
            storage.releaseElement(old, tag: storage.tags[count])
            old.deallocate()
        }
        storage.elements[count] = _bkAllocBox(src, width)
        storage.tags[count] = elemTag
        storage.widths[count] = width
        return _bkRegister(_BkArrayBox(reusing: storage, count: count + 1))
    }
    // 存储被共享（或输入为空句柄）：走逐元素深拷那条路 —— 新数组拿到一块**自己独占**的存储，
    // 与输入侧互不相干（语义与改动前逐字相同；重复此路也不构成二次方，因为每次只增一格）。
    let grown = _BkArrayBox(count: count + 1)
    if let source {
        grown.storage.elementRetain = source.storage.elementRetain
        grown.storage.elementRelease = source.storage.elementRelease
        for i in 0..<count {
            grown.storage.tags[i] = source.storage.tags[i]
            grown.storage.widths[i] = source.storage.widths[i]
            guard let elem = source.storage.elements[i], source.storage.widths[i] > 0 else { continue }
            grown.storage.elements[i] = _bkAllocBox(elem, source.storage.widths[i])
            grown.storage.retainElement(elem, tag: source.storage.tags[i])
        }
    }
    grown.storage.elements[count] = _bkAllocBox(src, width)
    grown.storage.tags[count] = elemTag
    grown.storage.widths[count] = width
    return _bkRegister(grown)
}

/// 释放数组句柄的一份 share；归零才真正回收，并按元素 tag 逐格归还。
/// 与兄弟数组共享元素存储时，归还推迟到最后一个持有者离开。
@_cdecl("bk_array_destroy")
public func bk_array_destroy(_ arr: UnsafeMutableRawPointer?) {
    _bkReleaseShare(arr)
}

// MARK: - 懒加载引用语义（LazyRef，LLVM 端：once 锁 + 缓存）

/// LazyRef 的引用语义承载：闭包 code/env + 元素类型 + once 锁 + 缓存 box，惰性物化恰一次、地址稳定。
/// 闭包调用走 codegen 的类型特化 wrapper（统一 `ptr` 返回，规避 I32/F64/指针的返回寄存器差异），
/// 运行时取回后 memcpy 到堆缓存。不参与 COW 分裂、复制共享同一 box，生命周期由 `bk_runtime_cleanup` 兜底。
private final class _BkLazyRefBox: _BkBox {
    let wrapper: UnsafeMutableRawPointer?
    let code: UnsafeMutableRawPointer?
    let env: UnsafeMutableRawPointer?
    let elemBytes: Int
    let elemTag: Int32
    let lock = NSLock()
    var initialized = false
    var cached: UnsafeMutableRawPointer? = nil

    init(
        wrapper: UnsafeMutableRawPointer?, code: UnsafeMutableRawPointer?, env: UnsafeMutableRawPointer?,
        elemBytes: Int, elemTag: Int32
    ) {
        self.wrapper = wrapper
        self.code = code
        self.env = env
        self.elemBytes = elemBytes
        self.elemTag = elemTag
        super.init()
    }

    deinit {
        if let c = cached { c.deallocate() }
    }
}

/// 创建 LazyRef：`bk_lazyref_create(wrapper, code, env, elemBytes, elemTag)` → 不透明句柄。
/// `wrapper` = codegen 生成的类型特化装箱函数（`ptr (ptr code, ptr env, ptr out) -> ptr`，统一 ABI）；
/// `code` = 初始化闭包 code（wrapper 内部调用）；`env` = 闭包捕获环境。
@_cdecl("bk_lazyref_create")
public func bk_lazyref_create(
    _ wrapper: UnsafeMutableRawPointer?,
    _ code: UnsafeMutableRawPointer?,
    _ env: UnsafeMutableRawPointer?,
    _ elemBytes: Int32,
    _ elemTag: Int32
) -> UnsafeMutableRawPointer {
    return _bkRegister(
        _BkLazyRefBox(
            wrapper: wrapper, code: code, env: env,
            elemBytes: Int(elemBytes), elemTag: elemTag))
}

/// 同步阻塞获取 `.value`（once）：首访加锁调用 `wrapper(code, env, out)` 求值并缓存，后续返回缓存。
/// 返回元素 box 指针（运行时拥有、稳定），codegen 据此 `load T`。
@_cdecl("bk_lazyref_value")
public func bk_lazyref_value(_ h: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let h else { bk_panic("Pini runtime error: lazyref handle is null") }
    let box = Unmanaged<_BkLazyRefBox>.fromOpaque(h).takeUnretainedValue()
    box.lock.lock()
    defer { box.lock.unlock() }
    if let c = box.cached { return c }
    guard let wrapper = box.wrapper, let code = box.code else {
        bk_panic("Pini runtime error: lazyref initializer is null")
    }
    // wrapper ABI：`ptr (ptr code, ptr env, ptr out) -> ptr`——运行时分配堆输出 box，
    // wrapper 写入 T 并返回 out；规避「wrapper 内 alloca 返回栈地址」逃逸 UB。
    let buf = UnsafeMutableRawPointer.allocate(byteCount: box.elemBytes, alignment: MemoryLayout<Int>.alignment)
    let invoke = unsafeBitCast(wrapper, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer).self)
    _ = invoke(code, box.env, buf)
    box.cached = buf
    box.initialized = true
    return box.cached!
}

/// 释放 LazyRef 的一份 share（归零才回收；进程退出 `bk_runtime_cleanup` 亦兜底）。
///  注意  发射器目前**不产出**本调用点：LazyRef 句柄只在进程退出时由退出钩子统一回收，
/// 循环里反复创建会累积到退出。
@_cdecl("bk_lazyref_destroy")
public func bk_lazyref_destroy(_ h: UnsafeMutableRawPointer?) {
    _bkReleaseShare(h)
}

// MARK: - 默认实例取用（契约 §2.46）

/// 「某类型的默认实例」的存放位盒。
/// 与 `_BkLazyRefBox` 的差别只在持有物：那边持 wrapper/code/env（一个闭包的调用面），这边只需要
/// `initFn` 与字节数——「谁来跑各字段初值」由发射层合成的具名函数承担；锁与缓存同形（语义要求相同）。
private final class _BkGivenSlotBox {
    let initFn: UnsafeMutableRawPointer?
    let bytes: Int
    let lock = NSLock()
    var cached: UnsafeMutableRawPointer? = nil

    init(initFn: UnsafeMutableRawPointer?, bytes: Int) {
        self.initFn = initFn
        self.bytes = bytes
    }
}

/// 保护「判空 + 建盒 + 写 slot」这一段的全局锁。
/// 必须是独立于盒内锁的第二级：两个线程同时看到空 slot 会各建一个盒，同一类型就物化出两个实例、
/// 地址不稳定，而地址稳定是契约语义。建盒之后物化仍归盒内锁管（那才是「恰一次」的地方）。
private let _bkGivenSlotLock = NSLock()

/// 取某类型的默认实例：`slot` 是发射层定义的静态全局（`@__given_<T>`），首调时由 `initFn` 写入初值，
/// 此后永远返回同一地址。`init_fn` 的 ABI 为 `ptr (ptr out) -> ptr`：运行时把分配好的输出缓冲交给它，
/// 它写入 T 并返回该缓冲。 行不通  不得持 `_bkGivenSlotLock` 调 `initFn`（初值可能取用另一类型的默认实例 ⇒ 自死锁）。
@_cdecl("bk_given_get")
public func bk_given_get(
    _ slot: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ initFn: UnsafeMutableRawPointer?,
    _ bytes: Int
) -> UnsafeMutableRawPointer {
    guard let slot else { bk_panic("Pini runtime error: given slot is null") }
    let boxPtr: UnsafeMutableRawPointer
    _bkGivenSlotLock.lock()
    if let existing = slot.pointee {
        boxPtr = existing
    } else {
        let fresh = Unmanaged.passRetained(_BkGivenSlotBox(initFn: initFn, bytes: bytes)).toOpaque()
        slot.pointee = fresh
        boxPtr = fresh
    }
    _bkGivenSlotLock.unlock()

    let box = Unmanaged<_BkGivenSlotBox>.fromOpaque(boxPtr).takeUnretainedValue()
    box.lock.lock()
    defer { box.lock.unlock() }
    if let cached = box.cached { return cached }
    guard let initFn else { bk_panic("Pini runtime error: given initializer is null") }
    let buf = UnsafeMutableRawPointer.allocate(
        byteCount: box.bytes, alignment: MemoryLayout<Int>.alignment)
    let invoke = unsafeBitCast(
        initFn, to: (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer).self)
    _ = invoke(buf)
    box.cached = buf
    return buf
}

/// 进程退出时释放所有活动句柄（数组 / 字典 / 集合），避免句柄泄漏（D0 阶段护栏；
/// D4.2.3 收紧为作用域精确销毁后本函数退化为兜底）。
@_cdecl("bk_runtime_cleanup")
public func bk_runtime_cleanup() {
    // deinit 会递归修改 `_liveHandles`（释放嵌套句柄的 share），故先整体摘出再逐个 release。
    _liveHandlesLock.lock()
    let all = _liveHandles
    _liveHandles.removeAll()
    _liveHandlesLock.unlock()
    for u in all { u.release() }
}

/// 进程退出钩子：先打让出观测汇总，再统一回收活动句柄。
/// 汇总走既有的退出路径、 行不通  不新起退出路径；顺序放在回收之前：回收会碰句柄表，而汇总只读一个计数器，
/// 先打完更不容易被回收路径上的意外打断。
private func _bkAtExitCleanup() {
    _bkReportYields()
    bk_runtime_cleanup()
}

private let _bkAtExitToken = atexit(_bkAtExitCleanup)

/// 保证进程退出钩子真的被登记。
/// Swift 全局 `let` 惰性初始化：`atexit(_bkAtExitCleanup)` 仅在该声明被求值时发生，没有读者就永不生效。
/// 由首个真实并发入口（`bk_task_spawn`）触发 ⇒ 不用任务的程序不受「活动句柄兜底回收」保护。
private func _bkEnsureProcessExitHook() {
    _ = _bkAtExitToken
}

// MARK: - 字典 / 集合 运行时

/// box 内容的类型标签：用于跨后端一致地比较键/元素相等性（与指针身份解耦）。
/// 解决了 `generateStringLiteral` 不为相同文本复用全局（每次新建 `@.strN`）导致的
/// 「字符串键指针在两处不一致」问题——运行时按 tag 解释字节，字符串按 C 串内容比较。
private enum _BkTag: Int32 {
    case i32 = 0
    case double = 1
    case bool = 2
    case str = 3
    case handle = 4
    /// 不透明的 i64 字：8 字节载荷字，其类型身份不在本层（由发射层解释）。
    /// 用途单一：`bk_task_join_all` 的聚合结果是「成员 ok 载荷」的数组，而载荷被擦除为 i64 宽度。
    ///  行不通  不是 `.i32`（比较宽度 4）也不是 `.handle`（COW 会把字里的位型当句柄 retain/release）。
    case i64 = 5
    /// 裸指针（`*T` / 任务句柄）：不参与计数，比较按指针值；与 `str` 分开，销毁时才不会把指针当串释放。
    case rawPtr = 6
    /// `Char`：八字节按值，指针形态指向一条带头串；销毁时按它的计数归还。
    case char = 7
    /// 内联结构体（`Optional` / `Result` / 元组）：元素字节就是聚合本身，宽度由发射层给出。
    ///  注意  成员份额不按 tag 猜 —— 布局在发射层，故深拷与销毁都经该数组登记的两个回调。
    case aggregate = 8
}

/// 两个 box 的内容相等性（按 tag 解释字节）。字符串按 C 串内容比较，与指针身份无关。
private func _bkBoxesEqual(_ a: UnsafeRawPointer, _ aTag: Int32, _ b: UnsafeRawPointer, _ bTag: Int32) -> Bool {
    guard aTag == bTag else { return false }
    switch _BkTag(rawValue: aTag) ?? .i32 {
    case .i32: return a.load(as: Int32.self) == b.load(as: Int32.self)
    case .double: return a.load(as: Double.self) == b.load(as: Double.self)
    case .bool: return a.load(as: UInt8.self) == b.load(as: UInt8.self)
    case .str:
        let pa = a.load(as: UnsafePointer<CChar>.self)
        let pb = b.load(as: UnsafePointer<CChar>.self)
        return strcmp(pa, pb) == 0
    case .handle:
        return a.load(as: UnsafeRawPointer.self) == b.load(as: UnsafeRawPointer.self)
    case .i64:
        // 不透明 i64 字按位型比较。（当前无调用点：聚合数组只被搬运、不被比较；
        // 补这一支是为了让 switch 穷尽，并让将来拿它做键时不至静默落进 .i32 的窄读。）
        return a.load(as: Int64.self) == b.load(as: Int64.self)
    case .rawPtr:
        return a.load(as: UnsafeRawPointer.self) == b.load(as: UnsafeRawPointer.self)
    case .char:
        /// `Char` 按值比较：内联形态整字相等，指针形态要按字节内容判，不能比地址。
        return a.load(as: Int64.self) == b.load(as: Int64.self)
            || bk_char_equal(a.load(as: Int64.self), b.load(as: Int64.self)) == 1
    case .aggregate:
        /// 聚合按字节判等要宽度，而这里只有 tag ⇒ 字典 / 集合的键不收聚合（发射层已拒绝）。
        return false
    }
}

// MARK: 字典

/// 字典真实存储：每条目记「键 box（运行时拥有、稳定指针）+ 键 tag + 值 box + 值宽度」。
/// 键/值查找走 `_bkBoxesEqual`（tag + 字节内容），与 LLVM 端 boxed-raw 模型一致，天然支持任意宽度键/值。
/// 键/值各以「运行时拥有的稳定 `ptr`」承载，使 `bk_dict_key_at`/`bk_dict_val_at`（D3 容器格式化迭代）可安全返回指针。
private final class _BkDictBox: _BkBox {
    struct Entry {
        let key: UnsafeMutableRawPointer
        let keyTag: Int32
        let keyBytes: Int
        var val: UnsafeMutableRawPointer
        var valTag: Int32
        var valBytes: Int
    }
    var entries: [Entry] = []

    override func cowCopy() -> _BkBox {
        let copy = _BkDictBox()
        copy.entries = entries.map { e in
            _bkRetainIfHandle(e.key, e.keyTag)
            _bkRetainIfHandle(e.val, e.valTag)
            return Entry(
                key: _bkAllocBox(e.key, e.keyBytes), keyTag: e.keyTag, keyBytes: e.keyBytes,
                val: _bkAllocBox(e.val, e.valBytes), valTag: e.valTag, valBytes: e.valBytes)
        }
        return copy
    }

    deinit {
        for e in entries {
            _bkReleaseIfHandle(e.key, e.keyTag)
            _bkReleaseIfHandle(e.val, e.valTag)
            e.key.deallocate()
            e.val.deallocate()
        }
    }
}

/// 创建空字典，返回不透明句柄。
@_cdecl("bk_dict_create")
public func bk_dict_create() -> UnsafeMutableRawPointer {
    return _bkRegister(_BkDictBox())
}

/// 字典条目数。
@_cdecl("bk_dict_len")
public func bk_dict_len(_ dict: UnsafeMutableRawPointer?) -> Int32 {
    guard let dict else { return 0 }
    return Int32(Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue().entries.count)
}

/// 写键值：`val` 的 `valBytes` 字节 memcpy 进新箱（替换先释放旧值），按 (keyBytes, keyTag) 经 `_bkBoxesEqual`
/// 定位条目。写前 `_bkEnsureUnique` 分裂，返回须写回的句柄；空句柄或零宽 panic。
/// 份额：值落槽即接管一份、覆盖时先还旧值；键只在首次插入时接管，键已存在则新键就地归还。
@_cdecl("bk_dict_set")
public func bk_dict_set_unsafe(
    _ dict: UnsafeMutableRawPointer?,
    _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32,
    _ val: UnsafeRawPointer, _ valBytes: Int32, _ valTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
    let target = _bkEnsureUnique(dict)
    let box = Unmanaged<_BkDictBox>.fromOpaque(target).takeUnretainedValue()
    let kn = Int(keyBytes)
    guard kn > 0 else {
        _bkReleaseIfHandle(val, valTag)
        return target
    }
    let vn = Int(valBytes)
    guard vn > 0 else {
        _bkReleaseIfHandle(key, keyTag)
        return target
    }
    let newVal = _bkAllocBox(val, vn)
    if let idx = box.entries.firstIndex(where: { stored in
        _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
    }) {
        // 键已存在：新键不落槽，调用方为它带来的那一份在这里归还。
        _bkReleaseIfHandle(key, keyTag)
        _bkReleaseIfHandle(box.entries[idx].val, box.entries[idx].valTag)
        box.entries[idx].val.deallocate()
        box.entries[idx].val = newVal
        box.entries[idx].valTag = valTag
        box.entries[idx].valBytes = vn
    } else {
        box.entries.append(
            .init(
                key: _bkAllocBox(key, kn), keyTag: keyTag, keyBytes: kn,
                val: newVal, valTag: valTag, valBytes: vn))
    }
    return target
}

/// 读取键对应的值 box（命中返回运行时拥有的稳定 `ptr`，调用方据此 `load T`）。
/// 缺失即 panic（G48 三通道：字典缺失键与越界同义，安全断言通道 panic——
/// 与 `bk_array_get` 越界 panic 对齐，也消除与解释器缺键 panic 的分歧）。
@_cdecl("bk_dict_get")
public func bk_dict_get(
    _ dict: UnsafeMutableRawPointer?,
    _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
    let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
    let kn = Int(keyBytes);
    guard kn > 0 else {
        bk_panic("Pini runtime error: dict key not found (empty key)")
    }
    guard
        let entry = box.entries.first(where: { stored in
            _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
        })
    else {
        bk_panic("Pini runtime error: dict key not found (missing key is out-of-bounds-equivalent, safe-assert channel)")
    }
    return entry.val
}

/// 嵌套写路径的中间层独占化（字典版）：确保 `parent[key]` 处的嵌套句柄独占，并就地更新条目值 box。
/// 与 `bk_array_ensure_unique_at` 同契约：`_bkEnsureUnique` 已把本槽的 share 转移给副本，故只改写字节、
/// 不再 release 旧句柄（否则二次递减 → use-after-free）；`parent` 已独占、键存在是前置条件。
@_cdecl("bk_dict_ensure_unique_at")
public func bk_dict_ensure_unique_at(
    _ dict: UnsafeMutableRawPointer?,
    _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let dict else { return nil }
    let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
    guard box.shares <= 1 else {
        bk_panic("Pini runtime error: bk_dict_ensure_unique_at requires a unique parent handle (shares=\(box.shares))")
    }
    guard Int(keyBytes) > 0 else { bk_panic("Pini runtime error: dict key box has zero width") }
    guard
        let idx = box.entries.firstIndex(where: { stored in
            _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
        })
    else {
        bk_panic("Pini runtime error: dict key not found for nested write")
    }
    guard _BkTag(rawValue: box.entries[idx].valTag) == .handle else {
        bk_panic("Pini runtime error: dict value is not a nested container handle")
    }
    let slot = box.entries[idx].val
    let old = slot.load(as: UnsafeMutableRawPointer.self)
    let new = _bkEnsureUnique(old)
    if new != old { slot.storeBytes(of: new, as: UnsafeMutableRawPointer.self) }
    return new
}

/// 释放字典句柄的一份 share；归零才回收，并逐条归还键与值（各按自己的 tag）。
@_cdecl("bk_dict_destroy")
public func bk_dict_destroy(_ dict: UnsafeMutableRawPointer?) {
    _bkReleaseShare(dict)
}

// MARK: 集合（保序去重）

/// 集合真实存储：元素以 (稳定 box 指针, tag) 记录，插入时按 `_bkBoxesEqual` 去重。
/// 稳定指针使 `bk_set_at`（D3 容器格式化迭代）可安全返回元素 box。
private final class _BkSetBox: _BkBox {
    var elems: [(ptr: UnsafeMutableRawPointer, tag: Int32, bytes: Int)] = []

    override func cowCopy() -> _BkBox {
        let copy = _BkSetBox()
        copy.elems = elems.map { e in
            _bkRetainIfHandle(e.ptr, e.tag)
            return (ptr: _bkAllocBox(e.ptr, e.bytes), tag: e.tag, bytes: e.bytes)
        }
        return copy
    }

    deinit {
        for e in elems {
            _bkReleaseIfHandle(e.ptr, e.tag)
            e.ptr.deallocate()
        }
    }
}

/// 创建空集合，返回不透明句柄。
@_cdecl("bk_set_create")
public func bk_set_create() -> UnsafeMutableRawPointer {
    return _bkRegister(_BkSetBox())
}

/// 集合元素数。
@_cdecl("bk_set_len")
public func bk_set_len(_ set: UnsafeMutableRawPointer?) -> Int32 {
    guard let set else { return 0 }
    return Int32(Unmanaged<_BkSetBox>.fromOpaque(set).takeUnretainedValue().elems.count)
}

/// 插入元素（去重）：`elem` 的 `elemBytes` 字节按 (bytes, tag) 经 `_bkBoxesEqual` 判定是否已存在。
/// COW：写前 `_bkEnsureUnique` 分裂，返回实际被写入的句柄（调用方须写回槽）。
/// 份额：元素入集合时接管一份；重复元素不落槽，那一份由本入口就地归还（调用方仍须自带一份）。
@_cdecl("bk_set_add")
public func bk_set_add_unsafe(
    _ set: UnsafeMutableRawPointer?, _ elem: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let set else { bk_panic("Pini runtime error: set handle is null") }
    let target = _bkEnsureUnique(set)
    let box = Unmanaged<_BkSetBox>.fromOpaque(target).takeUnretainedValue()
    let n = Int(elemBytes); guard n > 0 else { return target }
    if box.elems.contains(where: { stored in
        _bkBoxesEqual(elem, elemTag, stored.ptr, stored.tag)
    }) {
        // 重复元素不落槽：调用方为它带来的那一份在这里归还。
        _bkReleaseIfHandle(elem, elemTag)
    } else {
        box.elems.append((ptr: _bkAllocBox(elem, n), tag: elemTag, bytes: n))
    }
    return target
}

/// 释放集合句柄的一份 share；归零才回收，并逐元素归还（各按自己的 tag）。
@_cdecl("bk_set_destroy")
public func bk_set_destroy(_ set: UnsafeMutableRawPointer?) {
    _bkReleaseShare(set)
}

// MARK: 容器格式化迭代（LLVM `print` 对齐解释器 `stringify`）

/// 字典第 `idx` 个条目的「键 box」指针（运行时拥有，稳定）。越界经 `bk_panic` 终止（与解释器一致）。
@_cdecl("bk_dict_key_at")
public func bk_dict_key_at(_ dict: UnsafeMutableRawPointer?, _ idx: Int32) -> UnsafeMutableRawPointer {
    guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
    let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
    let i = Int(idx)
    guard i >= 0, i < box.entries.count else {
        bk_panic("Pini runtime error: dict index \(i) out of bounds (size \(box.entries.count))")
    }
    return box.entries[i].key
}

/// 字典第 `idx` 个条目的「值 box」指针（运行时拥有，稳定）。
@_cdecl("bk_dict_val_at")
public func bk_dict_val_at(_ dict: UnsafeMutableRawPointer?, _ idx: Int32) -> UnsafeMutableRawPointer {
    guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
    let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
    let i = Int(idx)
    guard i >= 0, i < box.entries.count else {
        bk_panic("Pini runtime error: dict index \(i) out of bounds (size \(box.entries.count))")
    }
    return box.entries[i].val
}

/// 集合第 `idx` 个元素的 box 指针（运行时拥有，稳定）。
@_cdecl("bk_set_at")
public func bk_set_at(_ set: UnsafeMutableRawPointer?, _ idx: Int32) -> UnsafeMutableRawPointer {
    guard let set else { bk_panic("Pini runtime error: set handle is null") }
    let box = Unmanaged<_BkSetBox>.fromOpaque(set).takeUnretainedValue()
    let i = Int(idx)
    guard i >= 0, i < box.elems.count else {
        bk_panic("Pini runtime error: set index \(i) out of bounds (size \(box.elems.count))")
    }
    return box.elems[i].ptr
}

/// 字典是否含指定键（与 `bk_dict_get` 同源的 `_bkBoxesEqual` 判定）。
/// 本 shim 目前零调用点：`collection.contains` 已声明为 trait 方法但尚未降载，字典在语言层也没有
/// 构造入口 ⇒ 它是该特性落地时的接线点，不是某个在用实现的重复。
@_cdecl("bk_dict_contains")
public func bk_dict_contains(_ dict: UnsafeMutableRawPointer?, _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32) -> Int32 {
    guard let dict else { return 0 }
    let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
    let kn = Int(keyBytes)
    guard kn > 0 else { return 0 }
    let found = box.entries.contains { stored in
        _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
    }
    return found ? 1 : 0
}

// MARK: - Phase 2a（FFI 子系统）：指针原语（C-ABI 面）

/// `*T` 原始指针的 load/store 原语，供 LLVM 后端接 FFI：在 `p + offsetBytes` 处读写标量，
/// 字节宽度按类型固定（C ABI 纪律，不泄漏 Swift 类型）。语言层的 `load` / `store` 不经过本族
/// （发射器直出指令、解释器直操作 Swift 指针）⇒ 本族零调用点，是 FFI 的接线面（当前显式 unsupported）。
@_cdecl("bk_ptr_load_i8")
public func bk_ptr_load_i8(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64) -> Int8 {
    guard let p else { return 0 }
    return p.advanced(by: Int(offsetBytes)).load(as: Int8.self)
}

@_cdecl("bk_ptr_load_i32")
public func bk_ptr_load_i32(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64) -> Int32 {
    guard let p else { return 0 }
    return p.advanced(by: Int(offsetBytes)).load(as: Int32.self)
}

@_cdecl("bk_ptr_load_i64")
public func bk_ptr_load_i64(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64) -> Int64 {
    guard let p else { return 0 }
    return p.advanced(by: Int(offsetBytes)).load(as: Int64.self)
}

@_cdecl("bk_ptr_load_f32")
public func bk_ptr_load_f32(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64) -> Float {
    guard let p else { return 0 }
    return p.advanced(by: Int(offsetBytes)).load(as: Float.self)
}

@_cdecl("bk_ptr_load_f64")
public func bk_ptr_load_f64(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64) -> Double {
    guard let p else { return 0 }
    return p.advanced(by: Int(offsetBytes)).load(as: Double.self)
}

@_cdecl("bk_ptr_store")
public func bk_ptr_store(_ p: UnsafeMutableRawPointer?, _ offsetBytes: Int64, _ src: UnsafeRawPointer, _ bytes: Int32) {
    guard let p else { return }
    let n = Int(bytes)
    guard n > 0 else { return }
    memcpy(p.advanced(by: Int(offsetBytes)), src, n)
}

// 字符串表示：`i8*` 指向载荷首字节，载荷前 16 字节是冻结头 {rc, len, cap, graphemes}，四个 i32。
// 载荷恒 NUL 结尾且 `cap >= len + 1` ⇒ `const char*` 零拷贝借出、`printf("%s")`、`strcmp` 照旧成立。
// 布局随 profile 而定，不是语言属性：嵌入式通道不装这个头，因为它不需要长度与容量。

/// 计数头长度（字节）。发射器以同一常数写常量的头，改这里必须同步 `IREmitter` 与 `registerStringConstant`。
private let _bkStrHeaderBytes = 16

/// 头长对外的读取口：发射器与测试用它自检「IR 里的常量布局」与运行时段一致，防两处各写一份而漂移。
@_cdecl("bk_str_header_bytes")
public func bk_str_header_bytes() -> Int32 { Int32(_bkStrHeaderBytes) }

/// 带索引表槽的最小容量对外的读取口：发射器据此决定字面量要不要留槽，测试据此钉住两边相等。
@_cdecl("bk_str_table_min_cap")
public func bk_str_table_min_cap() -> Int32 { Int32(_bkStrTableMinCap) }

/// 用户指针 → 头基址。
@inline(__always) private func _bkStrHead(_ p: UnsafeRawPointer) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(mutating: p).advanced(by: -_bkStrHeaderBytes)
}

/// 头字段的取址：偏移 0 = rc、4 = len、8 = cap、12 = graphemes。
@inline(__always) private func _bkStrField(_ p: UnsafeRawPointer, _ offset: Int) -> UnsafeMutablePointer<Int32> {
    _bkStrHead(p).advanced(by: offset).assumingMemoryBound(to: Int32.self)
}

/// 引用计数字段的原子读：`Synchronization.Atomic` 要 macOS 15，而部署目标是 12 ⇒ Darwin 走普通读。
///  行不通  这里不能借 `OSAtomicAdd32Barrier(0, p)` 当读：它是读-改-写，会把零增量写回只读段而崩。
/// 对齐的 4 字节读在 arm64 / x86_64 上本身就是单指令，故普通读即为原子读。
@inline(__always) private func _bkStrAtomicLoad(_ p: UnsafeMutablePointer<Int32>) -> Int32 {
    #if canImport(Darwin)
    return p.pointee
    #else
    let cell = UnsafeMutableRawPointer(p).assumingMemoryBound(to: Atomic<Int32>.self)
    return cell.pointee.load(ordering: .acquiring)
    #endif
}

/// 引用计数字段的原子加减，返回**加完之后**的值。归零判断靠它，故不能是「读-改-写」三步。
///  注意  `OSAtomicAdd32Barrier` 返回的是新值而非旧值（实测；头文件只写 result），别再往上加一次 delta。
///  `Synchronization` 的对应方法叫 `add`，返回 `(oldValue, newValue)`，取后一半才是同一语义。
@inline(__always) private func _bkStrAtomicAdd(_ p: UnsafeMutablePointer<Int32>, _ delta: Int32) -> Int32 {
    #if canImport(Darwin)
    return OSAtomicAdd32Barrier(delta, p)
    #else
    let cell = UnsafeMutableRawPointer(p).assumingMemoryBound(to: Atomic<Int32>.self)
    return cell.pointee.add(delta, ordering: .acquiringAndReleasing).newValue
    #endif
}

/// 引用计数格：`0` = 只读段的不可变常量（字面量），`> 0` = 堆上分配、可增容。
@inline(__always) private func _bkStrRC(_ p: UnsafeRawPointer) -> UnsafeMutablePointer<Int32> {
    _bkStrField(p, 0)
}

/// 当前计数（原子读）。
@inline(__always) private func _bkStrRefCount(_ p: UnsafeRawPointer) -> Int32 {
    _bkStrAtomicLoad(_bkStrRC(p))
}

/// 字节数格（不含 NUL）。
@inline(__always) private func _bkStrLen(_ p: UnsafeRawPointer) -> UnsafeMutablePointer<Int32> {
    _bkStrField(p, 4)
}

/// 载荷容量格（不含 NUL）：就地追加的边界。
@inline(__always) private func _bkStrCap(_ p: UnsafeRawPointer) -> UnsafeMutablePointer<Int32> {
    _bkStrField(p, 8)
}

/// 字素数格：`-1` = 未算；与 `len` 相等当且仅当纯 ASCII（非 ASCII 一字素至少两字节）。
@inline(__always) private func _bkStrGraphemes(_ p: UnsafeRawPointer) -> UnsafeMutablePointer<Int32> {
    _bkStrField(p, 12)
}

/// 分配一条空串：容量 `capacity` 字节（不含 NUL），长度 0，计数 1。载荷不置零，只写首字节 NUL。
/// 容量达到 `_bkStrTableMinCap` 时，块尾多留索引表的槽 —— 表要惰性建，而串一旦交出去就不能搬家。
private func _bkStrAlloc(_ capacity: Int) -> UnsafeMutableRawPointer {
    let cap = max(capacity, 0)
    let extra = cap >= _bkStrTableMinCap ? _bkStrSlotReserve : 0
    let base = UnsafeMutableRawPointer.allocate(
        byteCount: _bkStrHeaderBytes + cap + 1 + extra, alignment: 8)
    base.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
    base.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
    base.storeBytes(of: Int32(cap), toByteOffset: 8, as: Int32.self)
    base.storeBytes(of: Int32(0), toByteOffset: 12, as: Int32.self)
    let user = base.advanced(by: _bkStrHeaderBytes)
    user.storeBytes(of: 0, as: CChar.self)
    _bkStrTableSlot(user)?.pointee = nil
    return user
}

/// 索引表只在「容量足够装下 64 个字素块」的串上才有槽：更短的串连一个块都填不满，
/// 建表比直接走一遍还贵。这条阈值同时决定分配大小与槽的地址，故必须是同一个数。
private let _bkStrTableMinCap = 128

/// 槽区预留：槽地址落在 `p + cap + 1` 到 `p + cap + 8`（向下对齐），占 8 字节 ⇒ 载荷之后最多到 `cap + 15`。
private let _bkStrSlotReserve = 16

/// 索引表的槽：载荷末尾（NUL 之后）的 8 字节，值是 `u32` 偏移表基址或空。
/// 容量不足 `_bkStrTableMinCap` 的串没有槽 ⇒ 返回 nil，调用方按「无表」处理。
///  注意  槽按 8 字节对齐且随 `cap` 定位 —— 扩容是整块重分配，槽跟着换地方；就地追加则让表作废。
@inline(__always) private func _bkStrTableSlot(
    _ p: UnsafeRawPointer
) -> UnsafeMutablePointer<UnsafeMutableRawPointer?>? {
    let cap = Int(_bkStrCap(p).pointee)
    guard cap >= _bkStrTableMinCap else { return nil }
    /// 载荷长度任意，`p + cap + 8` 不保证对齐；未对齐的 8 字节写会崩在 arm64 上。
    let address = (UInt(bitPattern: p) + UInt(cap) + 8) & ~UInt(7)
    return UnsafeMutableRawPointer(bitPattern: address)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
}

/// 纯 ASCII 判定：8 字节块取高位掩码，块外逐字节补扫。纯 ASCII 串的 `graphemes` 直接等于 `len`。
private func _bkStrUtf8IsASCII(_ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
    var index = 0
    while index + 8 <= count {
        if bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
            return false
        }
        index += 8
    }
    while index < count {
        if bytes.load(fromByteOffset: index, as: UInt8.self) >= 0x80 { return false }
        index += 1
    }
    return true
}

/// 保护索引表的建表临界区。建一次、读无数次，故只在首次构建时争锁。
private let _bkStrTableLock = NSLock()

/// 取（必要时建）稀疏字素索引表：每 64 个字素一条 `u32` 字节偏移，尾项是总长。
/// 纯 ASCII 与容量不足一个块的短串不建表，直接走整串物化那条退路。
///  注意  建表前先验「Swift 视角的字节数等于头里的长度」：串里有非法 UTF-8 时 `String(decoding:)` 会折成替换符，偏移就对不上。
private func _bkStrGraphemeTable(_ p: UnsafeMutablePointer<CChar>) -> UnsafePointer<UInt32>? {
    guard let slot = _bkStrTableSlot(p) else { return nil }
    if let existing = slot.pointee {
        return UnsafePointer(existing.assumingMemoryBound(to: UInt32.self))
    }
    let length = Int(_bkStrLen(p).pointee)
    guard _bkStrUtf8IsASCII(p, length) == false else { return nil }
    var count = Int(_bkStrGraphemes(p).pointee)
    if count < 0 {
        let text = _bkStrSwiftString(p)
        guard text.utf8.count == length else { return nil }
        count = text.count
        _bkStrGraphemes(p).pointee = Int32(count)
    }
    guard count >= 128 else { return nil }
    _bkStrTableLock.lock()
    defer { _bkStrTableLock.unlock() }
    if let raced = slot.pointee {
        return UnsafePointer(raced.assumingMemoryBound(to: UInt32.self))
    }
    let text = _bkStrSwiftString(p)
    guard text.utf8.count == length else { return nil }
    let entries = count / 64 + 2
    let table = UnsafeMutablePointer<UInt32>.allocate(capacity: entries)
    table[0] = 0
    var block = 0
    var index = 0
    var offset = 0
    for character in text {
        if index > 0, index % 64 == 0 {
            block += 1
            table[block] = UInt32(offset)
        }
        offset += String(character).utf8.count
        index += 1
    }
    table[block + 1] = UInt32(offset)
    slot.pointee = UnsafeMutableRawPointer(table)
    return UnsafePointer(table)
}

/// 丢掉索引表：内容变了（就地追加），表里的偏移全部作废。
private func _bkStrDropTable(_ p: UnsafeRawPointer) {
    guard let slot = _bkStrTableSlot(p), let table = slot.pointee else { return }
    UnsafeMutablePointer<UInt32>(table.assumingMemoryBound(to: UInt32.self)).deallocate()
    slot.pointee = nil
}

/// 线程本地的块缓存：记住上一次物化的 64 字素块及其块内字节偏移表，块内任意下标都是两次数组读。
///  注意  缓存**不保留**源串：保留会让 `rc` 从 1 变 2，就地追加随即退化成每次重分配。
/// 换来的风险是「串释放后同地址被新串复用」，故命中判据里必须比对块内字节 —— 字节相同则偏移必然成立。
private final class _BkStrCursor {
    var owner: UnsafeMutableRawPointer?
    var length = -1
    var block = -1
    /// 块首的整串字节偏移。
    var lo = 0
    /// 块内字素数：块尾可能不满 64。
    var count = 0
    /// 块内容副本，用于和当前载荷比对。
    var span = ""
    /// 块内字节偏移，`count + 1` 条；第 `k` 个字素占 `offsets[k] ..< offsets[k + 1]`。
    let offsets: UnsafeMutablePointer<UInt32>

    init() {
        offsets = UnsafeMutablePointer<UInt32>.allocate(capacity: 65)
    }

    deinit {
        offsets.deallocate()
    }
}

/// 每线程一份游标的键：`pthread_getspecific` 是一条约两纳秒的取址，不经过任何全局锁。
private let _bkStrCursorKey: pthread_key_t = {
    var key = pthread_key_t()
    #if canImport(Glibc)
    let destructor: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
        guard let raw else { return }
        Unmanaged<_BkStrCursor>.fromOpaque(raw).release()
    }
    #else
    let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { raw in
        Unmanaged<_BkStrCursor>.fromOpaque(raw).release()
    }
    #endif
    pthread_key_create(&key, destructor)
    return key
}()

/// 取当前线程的游标，没有就装一个。
private func _bkStrCursor() -> _BkStrCursor {
    if let raw = pthread_getspecific(_bkStrCursorKey) {
        return Unmanaged<_BkStrCursor>.fromOpaque(raw).takeUnretainedValue()
    }
    let cursor = _BkStrCursor()
    pthread_setspecific(_bkStrCursorKey, Unmanaged.passRetained(cursor).toOpaque())
    return cursor
}

/// 游标换块：记下持有者、长度与块号；不碰引用计数（见 `_BkStrCursor` 的注记）。
private func _bkStrCursorAdopt(
    _ cursor: _BkStrCursor, _ s: UnsafeMutablePointer<CChar>, length: Int, block: Int, lo: Int
) {
    cursor.owner = UnsafeMutableRawPointer(s)
    cursor.length = length
    cursor.block = block
    cursor.lo = lo
    cursor.count = 0
}

/// 缓存内容与当前载荷是否逐字节相同：不同就说明这一块已经换了（或被复用的地址），不能拿旧偏移去切。
private func _bkStrCursorMatches(
    _ cursor: _BkStrCursor, _ s: UnsafeMutablePointer<CChar>, _ count: Int
) -> Bool {
    guard cursor.span.utf8.count == count else { return false }
    return cursor.span.withUTF8 { buffer in
        guard let base = buffer.baseAddress else { return count == 0 }
        return memcmp(base, s + cursor.lo, count) == 0
    }
}

/// 在索引表定位的块里取第 `idx` 个字素：命中缓存时块内任意下标都是两次数组读。
/// 未命中才物化那一块（最多 64 个字素）并把块内偏移一次算好。
///  注意  表的尾项是总长哨兵，故 `block + 1` 恒可读；块内最多 64 个字素。
private func _bkStrCharAtBlocked(
    _ s: UnsafeMutablePointer<CChar>, _ idx: Int, table: UnsafePointer<UInt32>
) -> Int64 {
    let block = idx / 64
    let lo = Int(table[block])
    let length = Int(_bkStrLen(s).pointee)
    let cursor = _bkStrCursor()
    if cursor.owner == UnsafeMutableRawPointer(s), cursor.length == length,
        cursor.block == block, cursor.lo == lo, idx - block * 64 < cursor.count,
        _bkStrCursorMatches(cursor, s, Int(table[block + 1]) - lo)
    {
        let k = idx - block * 64
        let start = Int(cursor.offsets[k])
        let end = Int(cursor.offsets[k + 1])
        return _bkCharPack(s + lo + start, end - start)
    }
    _bkStrCursorAdopt(cursor, s, length: length, block: block, lo: lo)
    let hi = Int(table[block + 1])
    let span = String(
        decoding: UnsafeRawBufferPointer(start: s + lo, count: hi - lo), as: UTF8.self)
    var offset: UInt32 = 0
    var count = 0
    cursor.offsets[0] = 0
    for character in span {
        offset += UInt32(String(character).utf8.count)
        count += 1
        cursor.offsets[count] = offset
    }
    cursor.span = span
    cursor.count = count
    let k = idx - block * 64
    guard k < count else {
        bk_panic("Pini runtime error: string index out of range")
    }
    let start = Int(cursor.offsets[k])
    let end = Int(cursor.offsets[k + 1])
    return _bkCharPack(s + lo + start, end - start)
}

/// 把 Swift `String` 的 UTF-8 字节装成带头串（`strdup` 的替代）：字素数已知，一并写进头。
private func _bkStrDup(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8)
    let user = _bkStrAlloc(bytes.count)
    let out = user.assumingMemoryBound(to: CChar.self)
    bytes.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress, buffer.count > 0 { memcpy(out, base, buffer.count) }
    }
    out[bytes.count] = 0
    _bkStrLen(out).pointee = Int32(bytes.count)
    _bkStrGraphemes(out).pointee = Int32(text.count)
    return out
}

/// 把一条既有 C 串复制成带头串（`strdup` 的替代 · 指针形态）；字素惰性 —— 纯 ASCII 直接等于字节数。
private func _bkStrDup(_ source: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    let length = Int(strlen(source))
    let user = _bkStrAlloc(length)
    let out = user.assumingMemoryBound(to: CChar.self)
    memcpy(out, source, length + 1)
    _bkStrLen(out).pointee = Int32(length)
    _bkStrGraphemes(out).pointee = _bkStrUtf8IsASCII(out, length) ? Int32(length) : -1
    return out
}

/// 从一段**已有字节**造带头串（计数 1）：只复制、不解释内容。`count` 是字节数，不含 NUL。
/// 字素数按 ASCII 快判填 `count` 或 `-1`（惰性），与 `_bkStrDup` 的指针形态同规。
///  注意  切片 / 切分 / 去空白都走这里，省掉「先造 Swift String 再转回来」的那次中间分配。
private func _bkStrFromBytes(
    _ start: UnsafePointer<CChar>, _ count: Int
) -> UnsafeMutablePointer<CChar> {
    let user = _bkStrAlloc(count)
    let out = user.assumingMemoryBound(to: CChar.self)
    if count > 0 { memcpy(out, start, count) }
    out[count] = 0
    _bkStrLen(out).pointee = Int32(count)
    _bkStrGraphemes(out).pointee = _bkStrUtf8IsASCII(out, count) ? Int32(count) : -1
    return out
}

/// 用头里的长度构造 Swift `String`：省掉 `strlen`，非法字节由 `String(decoding:)` 折成替换符。
private func _bkStrSwiftString(_ p: UnsafePointer<CChar>) -> String {
    let length = Int(_bkStrLen(p).pointee)
    return String(decoding: UnsafeRawBufferPointer(start: p, count: length), as: UTF8.self)
}

/// 造一条 `rc == 0` 的带头串：进程期常量，`retain` / `release` 都空转，永不归还。
/// 用途是把「无头的 C 串」换成「带头的只读串」，让值域里每一条串读头都是安全的。
private func _bkStrConstant(_ text: String) -> UnsafeMutablePointer<CChar> {
    let made = _bkStrDup(text)
    _bkStrRC(made).pointee = 0
    return made
}

/// 释放一条**已知带头**的串：计数递减，归零即归还整块。`rc == 0`（只读段常量）空转。
private func _bkStrReleaseRaw(_ p: UnsafeRawPointer) {
    let rc = _bkStrRC(p)
    guard _bkStrAtomicLoad(rc) > 0 else { return }
    guard _bkStrAtomicAdd(rc, -1) == 0 else { return }
    _bkStrDropTable(p)
    _bkStrHead(p).deallocate()
}

/// 拼接后的字素数：两半都已知且右半以 ASCII 起头时直接相加（边界不可能并成新簇），否则置 -1。
private func _bkStrMergedGraphemes(
    _ lhsCount: Int32, _ rhsCount: Int32, rhsLength: Int, rhs: UnsafeRawPointer?
) -> Int32 {
    guard lhsCount >= 0, rhsCount >= 0 else { return -1 }
    guard rhsLength > 0, let rhs else { return lhsCount }
    guard rhs.load(as: UInt8.self) < 0x80 else { return -1 }
    let sum = Int64(lhsCount) + Int64(rhsCount)
    return sum <= Int64(Int32.max) ? Int32(sum) : -1
}

/// 拼接内核：两半的长度与字素数由调用方读出；`ownsLhs` 为真时消耗左操作数那份引用。
/// 唯一持有且有容量就地追加，否则按倍增新分配 —— 前者是累加式建串做到摊还 O(1) 的全部机制。
private func _bkStrJoin(
    _ lhs: UnsafeRawPointer?, _ lhsLength: Int, _ lhsGraphemes: Int32,
    _ rhs: UnsafeRawPointer?, _ rhsLength: Int, _ rhsGraphemes: Int32,
    ownsLhs: Bool
) -> UnsafeMutableRawPointer {
    let need = lhsLength + rhsLength
    guard need < Int(Int32.max) else {
        bk_panic("Pini runtime error: string exceeds 2 GiB")
    }
    if ownsLhs, let lhs {
        let rc = _bkStrRefCount(lhs)
        if rc == 1, Int(_bkStrCap(lhs).pointee) >= need {
            let base = UnsafeMutableRawPointer(mutating: lhs)
            /// 用 `memmove` 而非 `memcpy`：`s = s + s` 时右操作数就是这块载荷本身，两者重叠。
            if rhsLength > 0, let rhs { memmove(base.advanced(by: lhsLength), rhs, rhsLength) }
            base.advanced(by: need).storeBytes(of: 0, as: CChar.self)
            _bkStrLen(lhs).pointee = Int32(need)
            _bkStrGraphemes(lhs).pointee = _bkStrMergedGraphemes(
                lhsGraphemes, rhsGraphemes, rhsLength: rhsLength, rhs: rhs)
            /// 内容变了，索引表里的偏移全部作废 —— 不丢就是拿旧块去切新载荷。
            _bkStrDropTable(lhs)
            return base
        }
    }
    /// 新分配按倍增：容量至少两倍左半，保证「每次重分配后能容纳若干次追加」，累加总代价 O(n)。
    let capacity = max(16, max(need, lhsLength * 2))
    let out = _bkStrAlloc(capacity)
    if lhsLength > 0, let lhs { memcpy(out, lhs, lhsLength) }
    if rhsLength > 0, let rhs { memcpy(out.advanced(by: lhsLength), rhs, rhsLength) }
    out.advanced(by: need).storeBytes(of: 0, as: CChar.self)
    _bkStrLen(out).pointee = Int32(need)
    _bkStrGraphemes(out).pointee = _bkStrMergedGraphemes(
        lhsGraphemes, rhsGraphemes, rhsLength: rhsLength, rhs: rhs)
    if ownsLhs, let lhs { _bkStrReleaseRaw(lhs) }
    return out
}

/// 字符串的**别名点 retain**（与 `bk_handle_retain` 同一条归还规则的不同族）。
/// `rc == 0` 的只读段常量空转 —— 这条替代了旧的全局登记表，锁随之消失。
@_cdecl("bk_str_retain")
public func bk_str_retain(_ p: UnsafeMutablePointer<CChar>?) {
    guard let p else { return }
    let rc = _bkStrRC(p)
    guard _bkStrAtomicLoad(rc) > 0 else { return }
    _ = _bkStrAtomicAdd(rc, 1)
}

/// 字符串的**释放**：计数递减，归零则归还内存。只读段常量与已归零指针 ⇒ 无操作。
@_cdecl("bk_str_release")
public func bk_str_release(_ p: UnsafeMutablePointer<CChar>?) {
    guard let p else { return }
    _bkStrReleaseRaw(p)
}

/// 分配一条空串（容量 `byteCount` 字节，不含 NUL），供发射层累积拼接用。
/// 旧契约「载荷由调用方写、不置零」已退役：长度与容量必须经本文件维护，绕过它的写入会让头不可信。
@_cdecl("bk_str_alloc")
public func bk_str_alloc(_ byteCount: Int64) -> UnsafeMutablePointer<CChar> {
    return _bkStrAlloc(Int(max(byteCount, 0))).assumingMemoryBound(to: CChar.self)
}

/// `lhs + rhs`：两边都是带头串，读头的长度而非 `strlen`。`ownsLhs` 为真时消耗左操作数那份引用。
@_cdecl("bk_str_concat")
public func bk_str_concat(
    _ lhs: UnsafeMutablePointer<CChar>?, _ rhs: UnsafeMutablePointer<CChar>?, _ ownsLhs: Int32
) -> UnsafeMutablePointer<CChar> {
    let left = lhs.map { UnsafeRawPointer($0) }
    let right = rhs.map { UnsafeRawPointer($0) }
    let leftLength = left.map { Int(_bkStrLen($0).pointee) } ?? 0
    let rightLength = right.map { Int(_bkStrLen($0).pointee) } ?? 0
    let joined = _bkStrJoin(
        left, leftLength, left.map { _bkStrGraphemes($0).pointee } ?? 0,
        right, rightLength, right.map { _bkStrGraphemes($0).pointee } ?? 0,
        ownsLhs: ownsLhs != 0)
    return joined.assumingMemoryBound(to: CChar.self)
}

/// 追加一条裸 C 串（无头的栈缓冲 / 格式化产物）：长度现算，其余同 `bk_str_concat`。
@_cdecl("bk_str_append_cstr")
public func bk_str_append_cstr(
    _ lhs: UnsafeMutablePointer<CChar>?, _ rhs: UnsafePointer<CChar>?, _ ownsLhs: Int32
) -> UnsafeMutablePointer<CChar> {
    let left = lhs.map { UnsafeRawPointer($0) }
    let leftLength = left.map { Int(_bkStrLen($0).pointee) } ?? 0
    let right = rhs.map { UnsafeRawPointer($0) }
    let rightLength = right.map { Int(strlen($0)) } ?? 0
    let rightGraphemes: Int32 = right.map {
        _bkStrUtf8IsASCII($0, rightLength) ? Int32(rightLength) : -1
    } ?? 0
    let joined = _bkStrJoin(
        left, leftLength, left.map { _bkStrGraphemes($0).pointee } ?? 0,
        right, rightLength, rightGraphemes,
        ownsLhs: ownsLhs != 0)
    return joined.assumingMemoryBound(to: CChar.self)
}

/// 把一条既有 C 串（无头的栈缓冲或外部输入）复制成带头串，计数 = 1。
/// 发射器的 `heapCopyOfStackString` 与 FFI 取回都走这里：复制语义不变，结果可被 `bk_str_release` 回收。
@_cdecl("bk_str_dup")
public func bk_str_dup(_ source: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let source else { return _bkStrDup("") }
    return _bkStrDup(source)
}

/// 当前引用计数（仅供测试 / 诊断，IR 不发射）：`rc == 0` 读成 0，即不可变常量。
@_cdecl("bk_str_refcount")
public func bk_str_refcount(_ p: UnsafeMutablePointer<CChar>?) -> Int32 {
    guard let p else { return 0 }
    return max(_bkStrRefCount(p), 0)
}

// MARK: - F64 最短往返展示（spec「值展示语义」节）

/// `print(F64)` 的文本展示：委托 `String(Double)`，即最短往返表示（往返恒等、定点/指数切换阈值、
/// 定点恒带小数点、`e±NN` 两位指数由标准库保证）。解释器 stringify 同样走它 ⇒ 两后端同一语义。
/// 返回带头串（计数 1），由持有位置按 `bk_str_release` 归还。
@_cdecl("bk_double_to_string")
public func bk_double_to_string(_ v: Double) -> UnsafeMutablePointer<CChar>? {
    return _bkStrDup(String(v))
}

// MARK: - G15: whole-file read for the LLVM leg

/// `readFile(path)`: the whole file as a NUL-terminated, malloc-allocated UTF-8 C string, or NULL if it
/// cannot be read (missing, unreadable, not valid UTF-8). Runs in the runtime because the size is unknowable
/// before the read under LLI's JIT; `strdup` contract, caller frees; same Foundation decode as interpreter.
@_cdecl("bk_read_file")
public func bk_read_file(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    // 失败仍返 nil（发射侧把它折成陷阱），而陷阱文案是**不带路径**的通用句：
    // 非字面量实参不能折进常量，一条只覆盖部分调用形态的消息比不覆盖更糟。
    // 带路径的详细诊断留给可接住的那条路 —— 它把诊断当值交给调用者。
    guard case .content(let text) = _bkReadFileCore(path) else { return nil }
    return _bkStrDup(text)
}

// MARK: - G14 FFI: Pini String -> C string (interpreter "cstr" shim parity)

/// Materializes a Swift String as a NUL-terminated, malloc-allocated UTF-8 C string: the caller
/// frees it, same as the interpreter's `cstr` shim. A counted `_bkStrAlloc` block would return an
/// interior pointer, which libc `free` rejects.
@_cdecl("bk_cstr")
public func bk_cstr(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return nil }
    let length = Int(_bkStrLen(s).pointee)
    guard let raw = malloc(length + 1) else { return nil }
    memcpy(raw, s, length + 1)
    return raw.assumingMemoryBound(to: CChar.self)
}

/// 取回：外部 C 串复制成计数串（调用方持有 +1，返回后按 `bk_str_release` 归还）。
/// 空指针与 `bk_str_dup` 同一约定 —— 读成空串，不让 NUL 读取落到空地址上。
@_cdecl("bk_str_from_cstr")
public func bk_str_from_cstr(_ source: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    return bk_str_dup(source)
}

// MARK: - 字符串句柄（C 侧可持有的串）
// 句柄 = 一份自有拷贝 + 一个计数。C 侧只拿不透明指针：字节与长度各一个入口，计数靠 retain / release
// 成对加减，归零时释放拷贝。Pini 侧不参与计数 —— IR 的 `stringHandle` 归 inert，谁创建谁交给 C。

/// 句柄箱。`storage` 是 NUL 结尾的字节缓冲，`length` 不含 NUL：字节视图按长度读，不以 NUL 定界。
private final class _BkStringHandle {
    let storage: UnsafeMutablePointer<CChar>
    let length: Int

    init(_ source: UnsafePointer<CChar>?) {
        guard let source else {
            let empty = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
            empty[0] = 0
            storage = empty
            length = 0
            return
        }
        let count = Int(strlen(source))
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: count + 1)
        memcpy(buffer, source, count + 1)
        storage = buffer
        length = count
    }

    deinit { storage.deallocate() }
}

/// 创建：复制一条 C 串，计数 = 1。空指针按空串处理（与 `bk_str_dup` 同一约定）。
@_cdecl("bk_str_handle_new")
public func bk_str_handle_new(_ source: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    return Unmanaged.passRetained(_BkStringHandle(source)).toOpaque()
}

/// 字节视图（UTF-8，不以 NUL 为界读；字节数见 `bk_str_handle_len`）。句柄释放后即失效。
@_cdecl("bk_str_handle_bytes")
public func bk_str_handle_bytes(_ handle: UnsafeRawPointer?) -> UnsafePointer<UInt8>? {
    guard let handle else { return nil }
    let box = Unmanaged<_BkStringHandle>.fromOpaque(handle).takeUnretainedValue()
    return UnsafeRawPointer(box.storage).assumingMemoryBound(to: UInt8.self)
}

/// 字节数（不是字素数）。空句柄读成 0。
@_cdecl("bk_str_handle_len")
public func bk_str_handle_len(_ handle: UnsafeRawPointer?) -> Int64 {
    guard let handle else { return 0 }
    return Int64(Unmanaged<_BkStringHandle>.fromOpaque(handle).takeUnretainedValue().length)
}

/// 保留一份：计数 +1，返回同一个指针，便于链式写法。空句柄原样返回。
@_cdecl("bk_str_handle_retain")
public func bk_str_handle_retain(_ handle: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let handle else { return nil }
    return Unmanaged<_BkStringHandle>.fromOpaque(handle).retain().toOpaque()
}

/// 释放一份：计数归零时释放拷贝。空句柄是无操作。
@_cdecl("bk_str_handle_release")
public func bk_str_handle_release(_ handle: UnsafeRawPointer?) {
    guard let handle else { return }
    Unmanaged<_BkStringHandle>.fromOpaque(handle).release()
}

// MARK: - 字符内建与宿主环境查询内建的 LLVM 侧运行时段
// 这组名字在解释器侧已有实现、降载侧也已降成 `call` 节点，缺的只有 LLVM 侧符号：缺则 emit 照常产出
// `call`，直到 clang 才以 `use of undefined value` 拒绝。语义一律镜像解释器， 行不通  不另造第二套解释。

/// 把一组 Swift 字符串装成语言层 `Array<String>`：每槽是一个 8 字节的 C 串指针 box。
///  注意  不能把字节直接塞进槽：发射层读元素是先 `bk_array_get` 拿 box 指针、再 `load i8*`
/// ⇒ box 内容必须是指针、宽度必须是 8。
private func _bkStringArray(_ items: [String]) -> UnsafeMutableRawPointer {
    let box = _BkArrayBox(count: items.count)
    for (index, item) in items.enumerated() {
        var pointer: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(_bkStrDup(item))
        withUnsafeBytes(of: &pointer) { raw in
            box.storage.elements[index] = _bkAllocBox(raw.baseAddress!, MemoryLayout<UnsafeMutableRawPointer?>.size)
        }
        box.storage.tags[index] = _BkTag.str.rawValue
        box.storage.widths[index] = MemoryLayout<UnsafeMutableRawPointer?>.size
    }
    return _bkRegister(box)
}

// MARK: - Char：八字节按值

/// `Char` 的机器表示。最高位为 1 ⇒ 低 55 位是指向**带头串载荷**的指针、bit 56..62 是字节数；
/// 为 0 ⇒ 长度在 bit 56..58、字节在 bit 0..55。七字节以内内联：ASCII 一、CJK 三、emoji 四都在内。
///  注意  更长的在打包时就复制到堆上，长度格写 127 表示真长在头里 —— 字节数因此没有上限。
@inline(__always) private func _bkCharIsPointer(_ value: Int64) -> Bool {
    UInt64(bitPattern: value) & 0x8000_0000_0000_0000 != 0
}

@inline(__always) private func _bkCharLength(_ value: Int64) -> Int {
    let field = Int((UInt64(bitPattern: value) >> 56) & 0x7F)
    guard field == 127, _bkCharIsPointer(value) else { return field }
    return Int(_bkStrLen(UnsafeRawPointer(_bkCharPointer(value))).pointee)
}

@inline(__always) private func _bkCharPointer(_ value: Int64) -> UnsafePointer<CChar> {
    UnsafePointer<CChar>(bitPattern: Int(UInt64(bitPattern: value) & 0x00FF_FFFF_FFFF_FFFF))!
}

/// 造一块承载一个长字素的带头串：计数 1、长度按字节写、字素数恒为 1。
///  注意  块与普通串同构（`bk_char_to_heap_string` 的产物也是这一形），故它的份额由串的计数规则管。
private func _bkCharBlock(
    _ bytes: UnsafePointer<CChar>, _ count: Int
) -> UnsafeMutablePointer<CChar> {
    let user = _bkStrAlloc(count)
    let out = user.assumingMemoryBound(to: CChar.self)
    if count > 0 { memcpy(out, bytes, count) }
    out[count] = 0
    _bkStrLen(out).pointee = Int32(count)
    _bkStrGraphemes(out).pointee = 1
    return out
}

/// 打包一个字节序列成 `Char`。七字节以内内联；更长的复制成一块计数为 1 的带头串。
///  注意  复制这一步实现「值即自持」：`Char` 离开产生它的表达式后，源串随时可以归还；
/// 长度格写 `127` 表示真长在头里 —— 与内联形态的七字节上限分开，任意长的字素簇都装得下。
private func _bkCharPack(_ bytes: UnsafePointer<CChar>, _ count: Int) -> Int64 {
    if count >= 1, count <= 7 {
        var packed: UInt64 = 0
        for index in 0..<count {
            packed |= UInt64(UInt8(bitPattern: bytes[index])) << (8 * index)
        }
        return Int64(bitPattern: packed | (UInt64(count) << 56))
    }
    let made = _bkCharBlock(bytes, Swift.max(count, 0))
    let address = UInt64(UInt(bitPattern: UnsafeRawPointer(made)))
    let field = UInt64(Swift.min(count, 127))
    return Int64(bitPattern: address | (field << 56) | 0x8000_0000_0000_0000)
}

/// 把 `Char` 的字节复制到调用方缓冲，返回字节数（不含 NUL）。
///  注意  缓冲须容得下真长（`_bkCharLength`）：内联形态最多七字节，指针形态可到任意长。
@discardableResult
private func _bkCharCopyTo(_ value: Int64, _ buffer: UnsafeMutablePointer<CChar>) -> Int {
    let count = _bkCharLength(value)
    if _bkCharIsPointer(value) {
        if count > 0 { memcpy(buffer, _bkCharPointer(value), count) }
        return count
    }
    let packed = UInt64(bitPattern: value)
    for index in 0..<count {
        buffer[index] = CChar(bitPattern: UInt8((packed >> (8 * index)) & 0xFF))
    }
    return count
}

/// `Char` 落成**带头串**（计数 1）：消费点按串的规矩归还。
///  注意  不能返回到栈缓冲 —— `bk_str_concat` 与 `bk_str_release` 都要读载荷前的头，
/// 栈上那块没有头，读到的会是相邻变量。
@_cdecl("bk_char_to_heap_string")
public func bk_char_to_heap_string(_ value: Int64) -> UnsafeMutablePointer<CChar> {
    if _bkCharIsPointer(value) {
        return _bkStrFromBytes(_bkCharPointer(value), _bkCharLength(value))
    }
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 8) { buffer in
        let count = _bkCharCopyTo(value, buffer.baseAddress!)
        return _bkStrFromBytes(buffer.baseAddress!, count)
    }
}

/// `Char` 的保留：只有指针形态进堆，内联形态是纯值 ⇒ 原样返回。
///  注意  指针形态指向一条带头串（与 `bk_char_to_heap_string` 的产物同构），故计数就是那条串的计数。
@_cdecl("bk_char_retain")
public func bk_char_retain(_ value: Int64) -> Int64 {
    guard _bkCharIsPointer(value) else { return value }
    bk_str_retain(UnsafeMutablePointer(mutating: _bkCharPointer(value)))
    return value
}

/// `Char` 的归还：内联形态零动作；指针形态减那份串的计数，归零即归还整块。
@_cdecl("bk_char_release")
public func bk_char_release(_ value: Int64) {
    guard _bkCharIsPointer(value) else { return }
    bk_str_release(UnsafeMutablePointer(mutating: _bkCharPointer(value)))
}

/// 两个 `Char` 判等：内联值先比整字，只有一侧是指针形态时才落回字节比较。
@_cdecl("bk_char_equal")
public func bk_char_equal(_ lhs: Int64, _ rhs: Int64) -> Int32 {
    if lhs == rhs { return 1 }
    let count = _bkCharLength(lhs)
    guard count == _bkCharLength(rhs), count > 0 else { return 0 }
    let leftIsPointer = _bkCharIsPointer(lhs)
    let rightIsPointer = _bkCharIsPointer(rhs)
    if !leftIsPointer, !rightIsPointer { return 0 }
    if leftIsPointer, rightIsPointer {
        return memcmp(_bkCharPointer(lhs), _bkCharPointer(rhs), count) == 0 ? 1 : 0
    }
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Swift.max(count, 8)) { buffer in
        let base = buffer.baseAddress!
        if rightIsPointer {
            _bkCharCopyTo(lhs, base)
            return memcmp(base, _bkCharPointer(rhs), count) == 0 ? 1 : 0
        }
        _bkCharCopyTo(rhs, base)
        return memcmp(_bkCharPointer(lhs), base, count) == 0 ? 1 : 0
    }
}

/// `Char` 与 `String` 判等：长度先比，再比字节。判据与 `bk_string_contains` 同一条。
@_cdecl("bk_char_equal_string")
public func bk_char_equal_string(_ value: Int64, _ text: UnsafePointer<CChar>?) -> Int32 {
    guard let text else { return 0 }
    let count = _bkCharLength(value)
    guard count == Int(_bkStrLen(text).pointee), count > 0 else { return 0 }
    if _bkCharIsPointer(value) {
        return memcmp(_bkCharPointer(value), text, count) == 0 ? 1 : 0
    }
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Swift.max(count, 8)) { buffer in
        _bkCharCopyTo(value, buffer.baseAddress!)
        return memcmp(buffer.baseAddress!, text, count) == 0 ? 1 : 0
    }
}

/// `chars(String) -> Array<Char>` —— 按**字素簇**切分。元素是八字节按值槽（不计数、不释放）。
///  注意  元素在取出时已复制到堆上，故结果不依赖源串的寿命；七字节以内直接内联，零分配。
@_cdecl("bk_chars")
public func bk_chars(_ s: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    guard let s else { return bk_array_create(0) }
    let text = _bkStrSwiftString(s)
    var handle = bk_array_create(Int32(text.count))
    var index: Int32 = 0
    var cursor = text.startIndex
    while cursor < text.endIndex {
        let next = text.index(after: cursor)
        let lo = text.utf8.distance(from: text.utf8.startIndex, to: cursor)
        let hi = text.utf8.distance(from: text.utf8.startIndex, to: next)
        let start = UnsafeRawPointer(s).advanced(by: lo).assumingMemoryBound(to: CChar.self)
        var word = _bkCharPack(start, hi - lo)
        handle = bk_array_set_unsafe(handle, index, &word, 8, 0) ?? handle
        index += 1
        cursor = next
    }
    return handle
}

/// `chr(I32) -> Char` —— 码点到单字符。越界（负数 / 超标量上界 / 代理区）**panic**，
/// 与解释器 `builtinChr` 同口径（G67：不再回空串哨兵）。单标量最多四字节，故必定内联。
@_cdecl("bk_chr")
public func bk_chr(_ code: Int32) -> Int64 {
    guard code >= 0, let scalar = Unicode.Scalar(UInt32(code)) else {
        bk_panic("Pini runtime error: chr 的参数超出 Unicode 标量范围（\(code)）")
    }
    var piece = String(Character(scalar))
    var word: Int64 = 0
    piece.withUTF8 { buffer in
        guard let base = buffer.baseAddress else { return }
        base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
            word = _bkCharPack($0, buffer.count)
        }
    }
    return word
}

/// `ord(Char) -> I32` —— **首个 Unicode 标量**的值；空字素回 -1（同解释器）。
@_cdecl("bk_ord")
public func bk_ord(_ c: Int64) -> Int32 {
    return withUnsafeTemporaryAllocation(
        of: CChar.self, capacity: Swift.max(_bkCharLength(c), 8)
    ) { buffer in
        let count = _bkCharCopyTo(c, buffer.baseAddress!)
        guard count > 0 else { return -1 }
        let text = String(
            decoding: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count), as: UTF8.self)
        guard let first = text.unicodeScalars.first else { return -1 }
        return Int32(first.value)
    }
}

/// `is_letter(Char) -> Bool` —— 首字符的 Unicode 字母属性（同解释器 `first.isLetter`）。
///  行不通  返回值是 `i32` 而非 C 的 `_Bool`：后者在 C ABI 里是零扩展的 i8，而语言的 Bool 是 i1。
@_cdecl("bk_is_letter")
public func bk_is_letter(_ c: Int64) -> Int32 {
    return withUnsafeTemporaryAllocation(
        of: CChar.self, capacity: Swift.max(_bkCharLength(c), 8)
    ) { buffer in
        let count = _bkCharCopyTo(c, buffer.baseAddress!)
        guard count > 0 else { return 0 }
        let text = String(
            decoding: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count), as: UTF8.self)
        return text.first?.isLetter == true ? 1 : 0
    }
}

/// `is_number(Char) -> Bool` —— 同解释器 `first.isNumber`。
@_cdecl("bk_is_number")
public func bk_is_number(_ c: Int64) -> Int32 {
    return withUnsafeTemporaryAllocation(
        of: CChar.self, capacity: Swift.max(_bkCharLength(c), 8)
    ) { buffer in
        let count = _bkCharCopyTo(c, buffer.baseAddress!)
        guard count > 0 else { return 0 }
        let text = String(
            decoding: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count), as: UTF8.self)
        return text.first?.isNumber == true ? 1 : 0
    }
}

/// `argv() -> Array<String>` —— 进程参数里去掉可执行文件自己之后的裸参数数组。
/// 两边对称的判据是「第一个元素是层名」：解释器的 `argv` 是脚本路径之后的裸参数，而原生二进制
/// 没有脚本路径 ⇒ 同样去掉第一个；自举 `main.pini` 的分派依赖这一条。
@_cdecl("bk_argv")
public func bk_argv() -> UnsafeMutableRawPointer {
    return _bkStringArray(Array(CommandLine.arguments.dropFirst()))
}

/// `listDir(String) -> Array<String>` —— 目录条目名（不含目录部分）+ UTF-8 字节序升序，与解释器
/// `IRExecutor` 的 `listDir` 同义（排序要紧：文件系统返回顺序不稳定，不排序则顺序相关判据会假绿）。
/// 路径按 `bk_read_file` 的口径解析；列不全时 panic， 行不通  不返回半个目录。
@_cdecl("bk_list_dir")
public func bk_list_dir(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    guard let path else { bk_panic("Pini runtime error: listDir: 路径为空") }
    let dirPath = _bkResolveIOPath(String(cString: path))
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        bk_panic("Pini runtime error: listDir: 不是目录或不存在 \(dirPath)")
    }
    let entries: [String]
    do {
        entries = try FileManager.default.contentsOfDirectory(atPath: dirPath)
    } catch {
        bk_panic("Pini runtime error: listDir: 无法列出目录 \(dirPath): \(error.localizedDescription)")
    }
    let ordered = entries.sorted {
        Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
    return _bkStringArray(ordered)
}

/// `exists(String) -> Bool` —— 路径存在（文件或目录皆可）； 行不通  不 panic。
/// 与 `listDir` / `readFile` 的操作类语义相反：路径不存在是**正常答案**。
///  注意  父目录不可读时底层查询同样答「不存在」，本符号不区分这两者。
@_cdecl("bk_exists")
public func bk_exists(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    return FileManager.default.fileExists(atPath: _bkResolveIOPath(String(cString: path))) ? 1 : 0
}

/// `isDir(String) -> Bool` —— 存在**且**是目录；「不存在」与「是文件」同答 false。
/// 返 `i32` 而非 C 的 `_Bool`：后者在 C ABI 里是零扩展 i8，与本层 Bool 的 i1 对不上。
@_cdecl("bk_is_dir")
public func bk_is_dir(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    var isDirectory: ObjCBool = false
    let present = FileManager.default.fileExists(
        atPath: _bkResolveIOPath(String(cString: path)), isDirectory: &isDirectory)
    return present && isDirectory.boolValue ? 1 : 0
}

// MARK: - IO 内核（陷阱版与可接住版共用）

/// 写 / 追加的共用内核：结局只有「成了」与「没成」，没成的那条带诊断文案。
/// 陷阱版与 `try*` 版是同一操作的两种失败形态（一个当终止理由、一个当值），各写一套就会在写入方式、
/// 路径解析与文案上分叉，而分叉的两侧在成功路径上都看起来对，只有失败时才露馅。
private enum _BkIOWriteOutcome {
    case done
    case failure(String)
}

/// 读的共用内核。与写内核分开是因为**成功带载荷** —— 把两者塞进一个枚举会让写侧
/// 多出一个永不出现的 `content` case，而那种 case 迟早会被人当成「写也能返回内容」。
private enum _BkIOReadOutcome {
    case content(String)
    case failure(String)
}

private func _bkWriteFileCore(
    _ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?
) -> _BkIOWriteOutcome {
    guard let path else { return .failure("writeFile: 路径为空") }
    let target = _bkResolveIOPath(String(cString: path))
    let text = content.map { String(cString: $0) } ?? ""
    do {
        try text.write(toFile: target, atomically: false, encoding: .utf8)
        return .done
    } catch {
        return .failure(
            "IO 错误: 无法写入文件 \(target): \(error.localizedDescription)")
    }
}

private func _bkAppendFileCore(
    _ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?
) -> _BkIOWriteOutcome {
    guard let path else { return .failure("appendFile: 路径为空") }
    let target = _bkResolveIOPath(String(cString: path))
    let text = content.map { String(cString: $0) } ?? ""
    guard let handle = fopen(target, "a") else {
        return .failure(
            "IO 错误: 无法打开文件以追加 \(target): \(String(cString: strerror(errno)))"
        )
    }
    defer { fclose(handle) }
    let bytes = Array(text.utf8)
    if !bytes.isEmpty {
        let written = bytes.withUnsafeBufferPointer {
            fwrite($0.baseAddress, 1, bytes.count, handle)
        }
        if written != bytes.count {
            return .failure(
                "IO 错误: 无法追加到文件 \(target): \(String(cString: strerror(errno)))"
            )
        }
    }
    return .done
}

private func _bkReadFileCore(_ path: UnsafePointer<CChar>?) -> _BkIOReadOutcome {
    guard let path else { return .failure("readFile: 路径为空") }
    let target = _bkResolveIOPath(String(cString: path))
    do {
        return .content(try String(contentsOfFile: target, encoding: .utf8))
    } catch {
        return .failure("IO 错误: 无法读取文件 \(target): \(error.localizedDescription)")
    }
}

/// `writeFile(path, content)` —— 整份内容写入 `path`，就地截断（ 行不通  非原子替换）、跟随符号链接。
/// 写入用与解释器写分支**同一个** Foundation 调用 ⇒ 两侧是同一份实现，失败原因串也相同。
/// 不返回值：写失败即 `bk_panic`，成功没有可回传的结果。
@_cdecl("bk_write_file")
public func bk_write_file(_ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?) {
    if case .failure(let message) = _bkWriteFileCore(path, content) {
        bk_panic("Pini runtime error: " + message)
    }
}

/// `appendFile(path, content)` —— 追加到目标末尾；目标不存在则创建（POSIX `"a"`）。
/// 与 `bk_write_file` 共用同一段打开/写入形状（解释器侧的 `.fileAppend` 臂逐句同构），否则第一次改动
/// 就会分叉。 行不通  本函数不截断，`bk_write_file` 也永不追加。
@_cdecl("bk_append_file")
public func bk_append_file(_ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?) {
    if case .failure(let message) = _bkAppendFileCore(path, content) {
        bk_panic("Pini runtime error: " + message)
    }
}

// MARK: - 可接住的 IO（`try*` 三兄弟）

/// 与上面三个陷阱版并存：同一个操作、两种失败形态，选哪个是源码写的名字。载荷：读是内容，写与追加是
/// 空元组。 注意  ABI 不对称是刻意的：读的成功值占住返回值，错误只能走 out 参数；写与追加没有成功值，
/// 错误就是返回值（`0` = 成功）。两边都不引线程局部「上次错误」——嵌套调用下会互相覆盖。

/// `tryReadFile(path)` —— 读全文；失败写错误对象字到 `outErr` 并返回 null。
@_cdecl("bk_try_read_file")
public func bk_try_read_file(
    _ path: UnsafePointer<CChar>?, _ outErr: UnsafeMutablePointer<Int64>?
) -> UnsafeMutablePointer<CChar>? {
    switch _bkReadFileCore(path) {
    case .content(let text):
        outErr?.pointee = 0
        return _bkStrDup(text)
    case .failure(let message):
        outErr?.pointee = _bkMakeError(message, isCancel: false, code: 1)
        return nil
    }
}

/// `tryWriteFile(path, content)` —— 就地截断写；返回 `0` 或错误对象字。
@_cdecl("bk_try_write_file")
public func bk_try_write_file(
    _ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?
) -> Int64 {
    switch _bkWriteFileCore(path, content) {
    case .done: return 0
    case .failure(let message): return _bkMakeError(message, isCancel: false, code: 1)
    }
}

/// `tryAppendFile(path, content)` —— 追加写；返回 `0` 或错误对象字。
@_cdecl("bk_try_append_file")
public func bk_try_append_file(
    _ path: UnsafePointer<CChar>?, _ content: UnsafePointer<CChar>?
) -> Int64 {
    switch _bkAppendFileCore(path, content) {
    case .done: return 0
    case .failure(let message): return _bkMakeError(message, isCancel: false, code: 1)
    }
}

/// 程序基准（`moduleRoot` 的答案来源）；`nil` = 未注入，取值回落到进程 CWD。
/// 写入点只有进程入口的第一句，读取可能来自任务族线程 ⇒ 读写两侧都由 `_bkProgramBaseLock` 配对。
nonisolated(unsafe) private var _bkProgramBase: UnsafeMutablePointer<CChar>? = nil
private let _bkProgramBaseLock = NSLock()

/// 程序基准的当前值；`nil` = 未注入。
private func _bkProgramBaseSnapshot() -> String? {
    _bkProgramBaseLock.lock()
    defer { _bkProgramBaseLock.unlock() }
    return _bkProgramBase.map { String(cString: $0) }
}

/// IO 路径的统一解析：`/`、`./`、`../` 开头的路径原样返回，其余拼接程序基准；未注入基准时原样返回
/// ⇒ 相对路径落到进程 CWD。与解释器的 `RuntimeOps.resolveIOPath` 必须同解，故各存一份。
///  注意  `./` / `../` 这一支是豁免：自举仓的相对路径全带 `./`，靠本支在两种基准语义下都落到 CWD。
private func _bkResolveIOPath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("./") || path.hasPrefix("../") { return path }
    guard let base = _bkProgramBaseSnapshot() else { return path }
    return base + "/" + path
}

/// 注入程序基准（绝对路径），入口函数体最前调用一次。
/// 入参可以是常量串：本函数 `strdup` 一份自持，调用方不必保留。`nil` 清除注入态。
@_cdecl("bk_set_program_base")
public func bk_set_program_base(_ base: UnsafePointer<CChar>?) {
    var copy: UnsafeMutablePointer<CChar>? = nil
    if let base { copy = strdup(base) }
    _bkProgramBaseLock.lock()
    _bkProgramBase = copy
    _bkProgramBaseLock.unlock()
}

/// `moduleRoot() -> String` —— 程序基准的绝对路径；未注入时答**进程 CWD**。
/// 取值式与解释器同一条（`programBase ?? 当前工作目录`）⇒ 两通道同一串。
/// 分配契约同 `bk_cstr`：`strdup`、**调用方释放**。
@_cdecl("bk_module_root")
public func bk_module_root() -> UnsafeMutablePointer<CChar>? {
    _bkProgramBaseLock.lock()
    let base = _bkProgramBase.map { String(cString: $0) }
    _bkProgramBaseLock.unlock()
    return _bkStrDup(base ?? FileManager.default.currentDirectoryPath)
}

/// `substring(start, end) -> String`：第 2 参数是 end（绝对下标）而非长度，按字素簇切、负值尾计数、
/// 双端夹取到 `[0, len]`、`hi <= lo` 得空串——逐字节 memcpy 表达不了字素语义。分配也必须在此发生：
/// 调用点 `alloca` 在循环里不到函数返回不回收。语义镜像 `IRExecutor.stringSubstring`；结果 strdup、调用方释放。
@_cdecl("bk_substring")
public func bk_substring(
    _ s: UnsafePointer<CChar>?, _ start: Int32, _ end: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    let text = String(cString: s)
    let n = text.count
    var lo = Int(start)
    var hi = Int(end)
    if lo < 0 { lo = n + lo }
    if hi < 0 { hi = n + hi }
    if lo < 0 { lo = 0 }
    if lo > n { lo = n }
    if hi < 0 { hi = 0 }
    if hi > n { hi = n }
    guard hi > lo else { return _bkStrDup("") }
    var a = text.startIndex
    var k = 0
    while k < lo {
        a = text.index(after: a)
        k += 1
    }
    var b = a
    while k < hi {
        b = text.index(after: b)
        k += 1
    }
    return _bkStrDup(String(text[a..<b]))
}

// MARK: - 名义箱（结构体 / 对象 / 枚举）的堆分配

// 名义值（`%struct` / `%object` / `%enum`）一律上堆：栈形状下返回值与闭包捕获会外逃成垃圾值。
// 头四格固定为 {强计数, 弱计数, 类型标识, 弱引用旁表}，且留在聚合体内部 ⇒ 字段可被 GEP 直接寻址、
// 无常驻注册表、无动态转型；分配在此，retain/release 与逐类型释放胶水在发射层，计数归零后 `free`。

/// 名义箱的分配：`malloc(size)`，写头四格。布局与发射层的聚合体定义逐字节对应：
/// 强计数 @0、弱计数 @4、类型标识 @8、旁表指针 @16（12–15 是指针 8 字节对齐的填充）。
/// `size` 由发射层用「过尾指针的整数形式」算好；字段不在这里初始化 —— 构造点逐格覆盖。
@_cdecl("bk_nominal_alloc")
public func bk_nominal_alloc(_ size: Int64, _ typeID: Int32) -> UnsafeMutableRawPointer? {
    guard size > 0 else { bk_panic("Pini runtime error: nominal box size must be positive") }
    guard let raw = malloc(Int(size)) else {
        bk_panic("Pini runtime error: nominal box allocation failed")
    }
    raw.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
    raw.storeBytes(of: typeID, toByteOffset: 8, as: Int32.self)
    raw.storeBytes(of: UInt(0), toByteOffset: 16, as: UInt.self)
    return raw
}

/// 被闭包捕获的变量槽：闭包与帧共享同一个盒。
/// 与 `bk_nominal_alloc` 刻意不同：没有引用计数头，槽是裸的零初始化数据块，读写由发射层直接
/// `load`/`store`（盒子本体不参与计数）。分配为 `malloc`，不释放：寿命归闭包，与闭包 env 同阶。
@_cdecl("bk_slot_alloc")
public func bk_slot_alloc(_ size: Int64) -> UnsafeMutableRawPointer? {
    guard size > 0 else { bk_panic("Pini runtime error: captured slot size must be positive") }
    guard let raw = malloc(Int(size)) else {
        bk_panic("Pini runtime error: captured slot allocation failed")
    }
    // 零初始化：栈 `alloca` 是未初始化的，而捕获槽可能在被写之前就被闭包读到
    // （`capture` 声明只要求变量存在，不要求已赋值）⇒ 零比垃圾更能暴露问题（0 比随机数好认）。
    memset(raw, 0, Int(size))
    return raw
}

/// 名义箱的别名点 retain：头格 +1。
/// 只需要箱指针——三族名义箱的头都在同一偏移（第 0 格），故不需要类型分派；按类型递归的是释放胶水
/// （发射层合成的 `__release_*`）。
@_cdecl("bk_nominal_retain")
public func bk_nominal_retain(_ box: UnsafeMutableRawPointer?) {
    guard let box else { return }
    box.assumingMemoryBound(to: Int32.self).pointee += 1
}

/// 名义箱的引用计数递减：返回 1 表示归零（调用方负责释放字段并 `free`），0 表示还有其他持有者。
/// 归零后的动作不在这里：字段要按静态类型递归释放，那是发射层逐类型合成 `__release_*` 的事，
/// 运行时只碰头格、保持类型无关。 注意  `null` 入参返回 0，故胶水可对「可能为空的字段」直接递归。
@_cdecl("bk_nominal_release")
public func bk_nominal_release(_ box: UnsafeMutableRawPointer?) -> Int32 {
    guard let box else { return 0 }
    let rc = box.assumingMemoryBound(to: Int32.self)
    rc.pointee -= 1
    return rc.pointee == 0 ? 1 : 0
}

// MARK: - 字符串的**字素簇**通道（IR 契约 §2.9 第 22/23/36/37 条的 LLVM 侧落地）

/// 契约 `字符模型 = Grapheme Cluster`，而 C 字符串只能按字节碰；字素簇边界是 Unicode 分段算法
/// （组合序列、ZWJ 表情、区域旗标…），字节循环复现不了——切点会落进多字节序列内部。
/// ⇒ 这一族一律下沉到运行时段，用 `String` / `Character`，与解释器同一模型。分配同 `bk_substring`。

/// `len(s)`：数的是字素簇。读头的 `graphemes`；为 `-1` 时算一次并回填。
/// 权威 = `RuntimeOps.containerLength` 的 `.string` 分支（`text.count`）。纯 ASCII 串 `graphemes == len`。
///  注意  值域里的每条串都带头且存储可写（字面量放可写全局），故回填不设条件。
@_cdecl("bk_string_count")
public func bk_string_count(_ s: UnsafePointer<CChar>?) -> Int32 {
    guard let s else { return 0 }
    let cached = _bkStrGraphemes(s).pointee
    if cached >= 0 { return cached }
    let count = Int32(_bkStrSwiftString(s).count)
    _bkStrGraphemes(s).pointee = count
    return count
}

/// `s[i]` 读一个字符：负值尾计数，越界走安全断言通道 ⇒ `bk_panic`（与数组下标同规）。
/// 纯 ASCII 串按字节直取 O(1)；非 ASCII 走稀疏索引表，只物化目标所在的那一块（≤64 字素）。
///  注意  七字节以内的字素装在整字里、不进分配器；更长的复制成自持块，故返回值不欠源串任何东西。
@_cdecl("bk_string_char_at")
public func bk_string_char_at(
    _ s: UnsafePointer<CChar>?, _ index: Int32
) -> Int64 {
    guard let s else { return 0 }
    let count = Int(bk_string_count(s))
    var idx = Int(index)
    if idx < 0 { idx += count }
    guard idx >= 0, idx < count else {
        bk_panic("Pini runtime error: string index out of range")
    }
    if Int(_bkStrLen(s).pointee) == count {
        return _bkCharPack(s + idx, 1)
    }
    /// 有索引表时只在目标所在的那一块里走：顺序访问命中游标，每步前进一个字素。
    if let table = _bkStrGraphemeTable(UnsafeMutablePointer(mutating: s)) {
        return _bkStrCharAtBlocked(UnsafeMutablePointer(mutating: s), idx, table: table)
    }
    let text = _bkStrSwiftString(s)
    var p = text.startIndex
    var k = 0
    while k < idx {
        p = text.index(after: p)
        k += 1
    }
    let next = text.index(after: p)
    let lo = text.utf8.distance(from: text.utf8.startIndex, to: p)
    let hi = text.utf8.distance(from: text.utf8.startIndex, to: next)
    return _bkCharPack(s + lo, hi - lo)
}

/// 字符串切片：开界取默认（`hasStart == 0` ⇒ 0，`hasEnd == 0` ⇒ 字数）、负值尾计数、两端夹到
/// `[0, count]`、`hi <= lo` 得空串——逐条镜像 `IRExecutor.sliceValue` 的 `.string` 分支（权威）。
///  注意  两个 `has*` 是开界标志而非 `Int32` 哨兵（哨兵会与真实下标撞车）；实现走到边界即停，阶不变。
@_cdecl("bk_string_slice")
public func bk_string_slice(
    _ s: UnsafePointer<CChar>?, _ hasStart: Int32, _ start: Int32,
    _ hasEnd: Int32, _ end: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    let text = _bkStrSwiftString(s)
    let count = text.count
    var lo = hasStart != 0 ? Int(start) : 0
    var hi = hasEnd != 0 ? Int(end) : count
    if lo < 0 { lo = count + lo }
    if hi < 0 { hi = count + hi }
    lo = Swift.max(0, Swift.min(lo, count))
    hi = Swift.max(0, Swift.min(hi, count))
    guard hi > lo else { return _bkStrDup("") }
    var a = text.startIndex
    var k = 0
    while k < lo {
        a = text.index(after: a)
        k += 1
    }
    var b = a
    while k < hi {
        b = text.index(after: b)
        k += 1
    }
    return _bkStrDup(String(text[a..<b]))
}

/// `s.upper()` / `s.lower()`：Unicode 感知，接收者不变。权威 = `IRExecutor` 的 `.stringCase` 分支
/// （`String.uppercased()` / `.lowercased()`）。
///  注意  逐字节 `toupper`/`tolower` 是 ASCII-only：`"café".upper()` 得 `CAFé`，带变音符的整词错。
@_cdecl("bk_string_upper")
public func bk_string_upper(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    return _bkStrDup(String(cString: s).uppercased())
}

@_cdecl("bk_string_lower")
public func bk_string_lower(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    return _bkStrDup(String(cString: s).lowercased())
}

/// `s.contains(needle)`：按**字节**子串查找。判据是「比较一律按码点序列，不做规范等价」，
/// 故 NFD 的 `é`（`65 CC 81`）不含预组合的 `é`（`C3 A9`）。空 needle 为真，返回 `i32`。
///  注意  两侧只读头取长度，命中交给 `memmem` —— 不再逐字素建数组，也没有 O(n·m) 的双层循环。
@_cdecl("bk_string_contains")
public func bk_string_contains(
    _ haystack: UnsafePointer<CChar>?, _ needle: UnsafePointer<CChar>?
) -> Int32 {
    guard let haystack, let needle else { return 0 }
    let hayLength = Int(_bkStrLen(haystack).pointee)
    let needleLength = Int(_bkStrLen(needle).pointee)
    if needleLength == 0 { return 1 }
    if needleLength > hayLength { return 0 }
    return memmem(haystack, hayLength, needle, needleLength) == nil ? 0 : 1
}

/// `s.trimLeft()`：剥离前导空格。权威 = `IRExecutor` 的 `.stringTrimLeft` 分支：只剥 ASCII 空格 U+0020
/// （ 行不通  不含 tab 及其他空白，与树渲染约定一致）；空串 / 全空格 ⇒ 空串。
/// 被剥的是单字节空格 ⇒ 字节走查即字素走查。分配契约 = 调用方持有 +1。
@_cdecl("bk_string_trim_left")
public func bk_string_trim_left(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    let length = Int(_bkStrLen(s).pointee)
    var start = 0
    while start < length, s[start] == 0x20 { start += 1 }
    return _bkStrFromBytes(s + start, length - start)
}

/// `s.trimRight()` —— 剥离**尾随**空格。口径同 `bk_string_trim_left`（只剥 U+0020）；
/// 从尾部回走连续空格，前缀原样拷一份。
@_cdecl("bk_string_trim_right")
public func bk_string_trim_right(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return _bkStrDup("") }
    let length = Int(_bkStrLen(s).pointee)
    var end = length
    while end > 0, s[end - 1] == 0x20 { end -= 1 }
    return _bkStrFromBytes(s, end)
}

/// `s.indexOf(needle)`：`needle` 首现的**字素位置**；空 needle ⇒ 0；未找到 ⇒ −1。
/// 单位必须与 `s[i]` 一致（字素），否则结果不能直接喂给下标。
///  注意  查找按字节做，命中后只数**一次**前缀字素 —— 整体仍是 O(n)，不随长度平方增长。
@_cdecl("bk_string_index_of")
public func bk_string_index_of(
    _ haystack: UnsafePointer<CChar>?, _ needle: UnsafePointer<CChar>?
) -> Int32 {
    guard let haystack, let needle else { return -1 }
    let hayLength = Int(_bkStrLen(haystack).pointee)
    let needleLength = Int(_bkStrLen(needle).pointee)
    if needleLength == 0 { return 0 }
    if needleLength > hayLength { return -1 }
    guard let hit = memmem(haystack, hayLength, needle, needleLength) else { return -1 }
    let byteOffset = UnsafeRawPointer(hit) - UnsafeRawPointer(haystack)
    // 纯 ASCII 串的字节偏移即字素位置（graphemes == len），不必物化整串。
    if _bkStrGraphemes(haystack).pointee == _bkStrLen(haystack).pointee {
        return Int32(byteOffset)
    }
    let prefix = String(
        decoding: UnsafeRawBufferPointer(start: haystack, count: byteOffset), as: UTF8.self)
    return Int32(prefix.count)
}

/// `s.split(sep)`：空定界符 ⇒ 逐字素（自举 `textAtoms` 靠它建原子数组）；非空按**字节序列**匹配
/// （ 行不通  不是字符集）；省略空子序列（`"".split(",")` ⇒ 0 个元素）。元素形态 = 8 字节 `.str` 槽。
///  注意  非空分支只切字节，每个元素一次分配，中间不造 Swift `String` 也不再逐字符累加。
@_cdecl("bk_string_split")
public func bk_string_split(
    _ s: UnsafePointer<CChar>?, _ delim: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer {
    guard let s else { return _bkStringArray([]) }
    let length = Int(_bkStrLen(s).pointee)
    let delimLength = delim.map { Int(_bkStrLen($0).pointee) } ?? 0
    var parts: [UnsafeMutablePointer<CChar>] = []
    if delimLength == 0 {
        for character in _bkStrSwiftString(s) {
            parts.append(_bkStrDup(String(character)))
        }
    } else if let delim {
        var start = 0
        var i = 0
        while i + delimLength <= length {
            if memcmp(s + i, delim, delimLength) == 0 {
                if i > start { parts.append(_bkStrFromBytes(s + start, i - start)) }
                i += delimLength
                start = i
            } else {
                i += 1
            }
        }
        if start < length { parts.append(_bkStrFromBytes(s + start, length - start)) }
    }
    var handle = bk_array_create(Int32(parts.count))
    for (index, part) in parts.enumerated() {
        // 每个元素是刚造的新串（计数 1），`bk_array_set` 消费那一份，故这里不再 retain。
        var box: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(part)
        handle = bk_array_set_unsafe(handle, Int32(index), &box, 8, 3) ?? handle
    }
    return handle
}

// MARK: - 并发原语的 C ABI 面
// 语义对齐解释器后端（`joinFuture` 三态归一化、`makeJoinAllFuture` fail-fast、`closeScope` 有界
// override、`checkCancellation`）。`status`：0 = `out` 已写；1 = 未取得 `Result`（取消/超时）；空句柄/越界一律 panic。

/// 任务盒 —— 解释器后端 `FutureValue` 在 C ABI 面的对应物。
/// 继承 `_BkBox` 是刻意复用：`_bkRegister` / `_bkReleaseShare` / `bk_runtime_cleanup` 那套「活动句柄登记 +
/// 退出兜底回收」对任务句柄同样成立，故不新造第二套生命周期。 注意  不参与 COW，谁也不该对它发 ensure_unique。
private final class _BkTaskBox: _BkBox {
    /// 阻塞 join 的等待 / 唤醒。
    /// 与 `FutureValue.wait()` 同构，但用 `NSCondition` 而非 `DispatchGroup`：后者为每个等待者引入一次队列
    /// 跳转，而等待者往往就是同后端上的发射代码。 行不通  所有状态改动都在本锁下 —— 否则丢唤醒。
    let cond = NSCondition()

    /// 是否已决（`ok` / `err` 之一已写入）。三槽在**未决**时无意义。
    var resolved = false
    /// 结果三槽：槽 0 = tag（`ok=0` / `err=1`）· 槽 1 = ok 载荷 · 槽 2 = err 载荷，
    /// 载荷一律**擦除为 i64 宽度**。
    ///  行不通  本层**不解释**它们的语义，只搬运 —— 解释权在发射层。
    var resultTag: Int64 = 0
    var okPayload: Int64 = 0
    var errPayload: Int64 = 0

    /// 协作式取消标志。 行不通  取消**不强杀** —— 与解释器后端一致：worker 在下一个检查点
    /// （`bk_task_is_cancelled`）自行提前结束，故取消是**最终一致**的。
    var cancelled = false

    /// 取消树的边（照 `FutureValue`：**父强持有子、子弱引用父**，避免保留环）。
    weak var parent: _BkTaskBox?
    var children: [_BkTaskBox] = []

    // MARK: 任务体（`B-3` 的 `bk_task_spawn` 记入）

    /// 体的 wrapper / code / env（任务体实参，原样存下）。
    var wrapper: UnsafeMutableRawPointer?
    var code: UnsafeMutableRawPointer?
    var env: UnsafeMutableRawPointer?

    /// 载荷类型描述（`elemBytes` / `elemTag`）—— 本层**不解释**它们，
    /// 与三槽同理：只搬运，解释权在发射层。
    var elemBytes: Int32 = 0
    var elemTag: Int32 = 0

    /// 体是否已让出（wrapper 返回非 `0`）。
    ///  行不通  它不是结束状态：让出后 `future` 仍未决，由续跑方决出。记它只为让「体让出过」可被外部观测，
    /// 否则本层的让出是静默的。
    var suspended = false

    /// 体已经跑过（无论跑完还是让出）。防同一句柄被跑第二次。
    var bodyStarted = false

    // MARK: 可恢复帧

    /// 指向自己的句柄。 重要  只为**续跑**存在：决出方手里是「等待者盒子」，而起一条线程重入体需要
    /// 的是**句柄**（`_bkTaskRunBody` 的实参）⇒ 没有它就得反查登记表。
    var selfHandle: UnsafeMutableRawPointer?

    /// 帧里局部槽的块表 —— `bk_task_slot` 每次取槽追加一块，体真跑完（或让出态被取消）时一次性交还。
    ///  行不通  不一次性算好整块：发射层没有「类型 → 字节数」的通用能力，在 Swift 侧另算一套布局就会两处各算
    /// 一次，一旦不一致就是静默错位的帧。⇒ 尺寸由 IR 侧常量表达式算，本层只管搬运。
    var frameChunks: [UnsafeMutableRawPointer] = []

    /// `bk_task_slot` 的重放游标：每次进入体都归零（见 `_bkTaskRunBody`）。
    /// 这不是优化，是续跑正确性的前提：让出时体从栈返回、槽指针全部丢失，续跑靠重新执行同一段取槽代码
    /// 拿回来 ⇒ 只有「第 n 次进入的第 k 次取槽必得同一地址」，续跑才拿得到上次那些槽。
    var frameCursor = 0

    /// 我已经把控制流交还出去、正等 `awaiting` 决出。 行不通  它**不是**结束状态 —— `future` 仍**未决**。
    ///
    /// 弱引用：`awaiters` 反向持强引用，两者不成环（与 `parent` / `children` 同一套记账）。
    weak var awaiting: _BkTaskBox?

    /// 正在等我决出的那些任务 —— 我决出或被取消时逐个**续跑**它们。
    var awaiters: [_BkTaskBox] = []

    /// 体**正在跑**。防同一句柄被并发进入两次：续跑是**另一条线程**，与首次进入可能交错。
    var running = false

    /// 「决出方已经来叫过，但那时我还没让出」的**记号**（见 `_bkTaskResume`）。
    ///  行不通  它关的是一扇**丢唤醒**的窗，不是缓存：没有它，「等我的任务」会在窄缝里永远不再被调度。
    var resumePending = false

    /// 我此刻在就绪队列里等着被挑。
    ///  行不通  与 `suspended` 不是同一件事：后者说「体交出了控制流」，本位置说「已交给策略层、尚未被挑」
    /// —— 一个待挑的任务两者同时成立。它正是 `bk_task_state` 里「可跑」的落点；由入队写、出队清。
    var queued = false

    /// 帧是否已交还。幂等守卫 —— 「跑完」与「让出态被取消」两条路径都会来收，而**只能收一次**。
    var frameReleased = false
}

/// 句柄 → 任务盒。
/// 与 `bk_array_get` / `bk_dict_get` 同一条路：句柄是 `Unmanaged` 的裸指针，这里按具体子类取回
/// （`bk_dict_ensure_unique_at` 等处已是同一先例）。
private func _bkTaskBox(_ h: UnsafeMutableRawPointer?) -> _BkTaskBox? {
    guard let h else { return nil }
    return Unmanaged<_BkTaskBox>.fromOpaque(h).takeUnretainedValue()
}

/// 写 `Result` 三槽（**唯一**写入点，避免三处各写各的）。
/// `out` 由调用方提供、至少 24 字节。
private func _bkWriteResult(_ out: UnsafeMutableRawPointer?, tag: Int64, ok: Int64, err: Int64) {
    guard let out else { return }
    out.storeBytes(of: tag, toByteOffset: 0, as: Int64.self)
    out.storeBytes(of: ok, toByteOffset: 8, as: Int64.self)
    out.storeBytes(of: err, toByteOffset: 16, as: Int64.self)
}

/// 指针 → 不透明 i64 字（三槽的载荷宽度是 i64，句柄要按位型搬进去）。
private func _bkWord(_ p: UnsafeMutableRawPointer) -> Int64 {
    Int64(bitPattern: UInt64(UInt(bitPattern: p)))
}

// MARK: - Result 的 err 载荷

/// err 槽里那个字的所指：一个错误对象 = 消息 + 是不是取消。槽本身是 64 位字（载荷类型擦除为一个
/// 机器字），字里放的是本对象的句柄位型。 行不通  不要把它当指针解引用、也不要当计数：读它只有
/// `bk_error_is_cancel` 与 `bk_error_message` 两个入口。生命周期 = 进程；消息创建时复制自持，读侧零分配。
private final class _BkErrorBox {
    let message: UnsafeMutablePointer<CChar>
    let isCancel: Bool
    /// C 边界的码：`Error`/`CancelError` 固定 `1`/`2`，枚举错误由基址与用例 tag 组合。
    let code: Int32

    /// 消息存成**只读带头串**（`rc == 0`）：它会离开本对象进到 Pini 值域，被归还时必须是空转。
    ///  行不通  裸 `strdup`：值域里每一条串都带头，归还时读 `p - 16` 就会减掉 malloc 块头，间歇写坏堆。
    init(_ text: String, isCancel: Bool, code: Int32) {
        self.message = _bkStrConstant(text)
        self.isCancel = isCancel
        self.code = code
    }
}

/// 造一个错误对象并按字返回（`isCancel` 区分 `CancelError` 与业务 `Error`）。
private func _bkMakeError(_ text: String, isCancel: Bool, code: Int32) -> Int64 {
    let box = _BkErrorBox(text, isCancel: isCancel, code: code)
    return _bkWord(Unmanaged.passRetained(box).toOpaque())
}

/// 超时归约的消息文案；`nil` 的时限（`bk_task_join` 不设限）不会走到这里。
private func _bkTimeoutText(_ timeoutMs: Int32?) -> String {
    "任务超时: \(timeoutMs ?? 0)ms"
}

/// 字 → 对象。**0 表示无载荷**（`ok` 结果的占位、以及任何未携带错误的槽）⇒ 读侧答
/// 空消息、非取消， 行不通  不 fail-loud：读一个 ok 结果的 err 槽是调用方的事，不该炸掉进程。
private func _bkErrorBox(_ word: Int64) -> _BkErrorBox? {
    guard word != 0,
        let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(truncatingIfNeeded: word)))
    else { return nil }
    return Unmanaged<_BkErrorBox>.fromOpaque(pointer).takeUnretainedValue()
}

/// `Error("msg")` —— 业务错误。入参可以是常量串：本函数复制一份自持。
@_cdecl("bk_error_create")
public func bk_error_create(_ message: UnsafePointer<CChar>?) -> Int64 {
    _bkMakeError(message.map { String(cString: $0) } ?? "", isCancel: false, code: 1)
}

/// `CancelError("msg")` —— 取消错误。与 `bk_error_create` 只差那个标志位；
///  行不通  两者的消息面完全同形，区分只经 `bk_error_is_cancel`，不靠消息约定。
@_cdecl("bk_cancel_error_create")
public func bk_cancel_error_create(_ message: UnsafePointer<CChar>?) -> Int64 {
    _bkMakeError(message.map { String(cString: $0) } ?? "", isCancel: true, code: 2)
}

/// `err(枚举值)` —— 载荷是枚举：码 = 类型基址或上用例 tag，消息用类型名。枚举布局
/// `{ i32, i32, i32, ptr, i32 }`：tag 在偏移 24，布局调整时这里与 `IREmitter` 一起改。
/// `codes` 非 nil 时按 tag 查它（稳定码类型）：表由编译器按用例声明序生成，长度即用例数。
@_cdecl("bk_error_from_enum")
public func bk_error_from_enum(
    _ payload: Int64, _ base: Int32, _ name: UnsafePointer<CChar>?,
    _ codes: UnsafePointer<Int32>?
) -> Int64 {
    let text = name.map { String(cString: $0) } ?? ""
    guard payload != 0,
        let pointer = UnsafeMutableRawPointer(
            bitPattern: UInt(bitPattern: Int(truncatingIfNeeded: payload)))
    else { return _bkMakeError(text, isCancel: false, code: base) }
    let tag = pointer.load(fromByteOffset: 24, as: Int32.self)
    let code = codes.map { $0[Int(tag)] } ?? (base | tag)
    return _bkMakeError(text, isCancel: false, code: code)
}

/// `err(非枚举错误值)` —— 载体没有 tag 槽，码就是编译器给的基址。消息留空：类型名不进 ABI。
@_cdecl("bk_error_with_code")
public func bk_error_with_code(_ code: Int32) -> Int64 {
    _bkMakeError("", isCancel: false, code: code)
}

/// 错误对象上的码：导出桩据它回填状态码。无载荷答 `0`。
@_cdecl("bk_error_code")
public func bk_error_code(_ word: Int64) -> Int32 {
    guard let box = _bkErrorBox(word) else { return 0 }
    return box.code
}

/// `calc_strerror` 的三个固定答案。进程期常驻：C 侧拿到的是静态地址， 行不通  不归调用方释放。
nonisolated(unsafe) private let _bkFixedErrorNames: (success: UnsafePointer<CChar>, unclassified: UnsafePointer<CChar>, cancelled: UnsafePointer<CChar>) = {
    func permanent(_ text: String) -> UnsafePointer<CChar> {
        let bytes = Array(text.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        return UnsafePointer(buffer)
    }
    return (permanent("success"), permanent("unclassified error"), permanent("cancelled"))
}()

/// 导出面的 `calc_strerror`：码 → 名字。固定码 `0`/`1`/`2` 先答，其余按表线性查（错误集通常几十条，
/// 线性扫比维护「表必须有序」这条隐式不变量便宜）。查不到答 NULL，是否兜底由 C 侧决定。
@_cdecl("bk_error_lookup")
public func bk_error_lookup(
    _ code: Int32, _ codes: UnsafePointer<Int32>?, _ names: UnsafePointer<UnsafePointer<CChar>?>?,
    _ count: Int32
) -> UnsafePointer<CChar>? {
    switch code {
    case 0: return _bkFixedErrorNames.success
    case 1: return _bkFixedErrorNames.unclassified
    case 2: return _bkFixedErrorNames.cancelled
    default: break
    }
    guard let codes, let names else { return nil }
    var index = 0
    while index < Int(count) {
        if codes[index] == code { return names[index] }
        index += 1
    }
    return nil
}

/// `isCancel(e)` —— err 字是不是取消类。无载荷（字为 0）答 `0`。
@_cdecl("bk_error_is_cancel")
public func bk_error_is_cancel(_ word: Int64) -> Int32 {
    guard let box = _bkErrorBox(word) else { return 0 }
    return box.isCancel ? 1 : 0
}

/// `e.message` / `print(e)` —— err 字的消息。
/// 返回的是错误对象内部的 C 串， 行不通  调用方不得释放；指针在对象存活期（= 进程期）内稳定。
/// 无载荷（字为 0）答空串。
@_cdecl("bk_error_message")
public func bk_error_message(_ word: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let box = _bkErrorBox(word) else { return _bkEmptyCString }
    return box.message
}

/// 无载荷 err 槽的空消息（进程期只读带头串，同样不归调用方释放）。
nonisolated(unsafe) private let _bkEmptyCString: UnsafeMutablePointer<CChar> = _bkStrConstant("")

/// 阻塞等待任务决出（或被取消）。
///
/// - Returns: `true` = 已决或被取消 · `false` = **超时**（`join_within` 用）。
private func _bkTaskWait(_ box: _BkTaskBox, timeoutMs: Int32?) -> Bool {
    box.cond.lock()
    defer { box.cond.unlock() }
    if box.resolved || box.cancelled { return true }
    guard let ms = timeoutMs else {
        while !box.resolved && !box.cancelled { box.cond.wait() }
        return true
    }
    let deadline = Date(timeIntervalSinceNow: Double(max(0, ms)) / 1000.0)
    while !box.resolved && !box.cancelled {
        if !box.cond.wait(until: deadline) { return false }
    }
    return true
}

/// 递归取消（照 `FutureValue.cancel()`）。
///  行不通  先取快照、解锁、再向下传播 —— 持锁递归会与剪枝的反向加锁（子 → 父）形成锁序死锁。
/// 解释器后端的 `cancel()` 也是这个形状。
private func _bkTaskCancelBox(_ box: _BkTaskBox) {
    box.cond.lock()
    if box.cancelled { box.cond.unlock(); return }
    box.cancelled = true
    let kids = box.children
    let wasSuspended = box.suspended
    box.cond.broadcast()   // 唤醒阻塞中的 join —— 它读到标志后归一为 err(CancelError)
    box.cond.unlock()
    /// **让出态被取消 ⇒ 体不会再被进入** ⇒ 帧必须由运行时交还。
    ///  行不通  落地顺序有讲究：先把取消位置起（上面的锁内），再交还帧 —— 反过来的话，一条已经在
    /// 「续跑」路上的线程会带着已释放的帧进入体，而那是**静默内存错**，不是崩溃。
    if wasSuspended { _bkTaskReleaseFrame(box) }
    // 等我的那些任务：我已经被取消 ⇒ 它们的等待应当**现在**归约为 `err(CancelError)`，
    // 而不是等我（永不）决出。它们醒来后走的是 `bk_task_await` 的「已决 ⇒ 直线取值」那条路。
    _bkTaskResumeAwaiters(box)
    for k in kids { _bkTaskCancelBox(k) }
}

/// 取消是协作式的：调用点返回时，任务体可能还在自己的一步里。等它停下再走，
/// 免得进程退出时线程仍在运行时代码里；上限 200ms，等不到也不把 join 卡死。
private func _bkTaskWaitQuiescent(_ box: _BkTaskBox) {
    let deadline = Date().addingTimeInterval(0.2)
    while Date() < deadline {
        box.cond.lock()
        let running = box.running
        box.cond.unlock()
        if !running { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

/// 从父 scope 剪枝（照 `FutureValue.detachFromParent`）。
///  行不通  加锁顺序是**子 → 父**，且**不同时持两把锁** —— 与取消传播（父 → 子）方向相反，
/// 同时持锁就会死锁。
private func _bkTaskDetachFromParent(_ box: _BkTaskBox) {
    box.cond.lock()
    let p = box.parent
    box.parent = nil
    box.cond.unlock()
    guard let p else { return }
    p.cond.lock()
    p.children.removeAll { $0 === box }
    p.cond.unlock()
}

/// 单任务 join（`bk_task_join` 与 `bk_task_join_within` 的唯一实现体），归一化照 `RuntimeOps.joinFuture`：
/// 已决 → 直通三槽；超时 → 取消该任务并归约为 `err(CancelError)`；被取消 → 同样归约为 `err(CancelError)`
/// （取消优先于结果）。 注意  无论成败都剪枝：生命周期已被显式消费，父返回时不该再取消它。
private func _bkTaskJoinOne(
    _ box: _BkTaskBox, timeoutMs: Int32?, out: UnsafeMutableRawPointer?
) -> Int32 {
    let completed = _bkTaskWait(box, timeoutMs: timeoutMs)
    defer { _bkTaskDetachFromParent(box) }
    if !completed {
        _bkTaskCancelBox(box)
        _bkTaskWaitQuiescent(box)
        _bkWriteResult(out, tag: 1, ok: 0, err: _bkMakeError(_bkTimeoutText(timeoutMs), isCancel: true, code: 2))
        return 1
    }
    box.cond.lock()
    let cancelled = box.cancelled
    let resolved = box.resolved
    let tag = box.resultTag
    let ok = box.okPayload
    let err = box.errPayload
    box.cond.unlock()
    if cancelled {
        _bkTaskWaitQuiescent(box)
        _bkWriteResult(out, tag: 1, ok: 0, err: _bkMakeError("任务已取消", isCancel: true, code: 2))
        return 1
    }
    guard resolved else {
        bk_panic("Pini runtime error: task join returned with neither an outcome nor a cancelling")
    }
    _bkWriteResult(out, tag: tag, ok: ok, err: err)
    return 0
}

// MARK: 进程级能力自述

/// 后端能力位图：启动时解析一次、此后固化（文件级 `let` 天然满足「不逐调用点判」与「进程内不变」）。
/// 位 0 = L0 调度 `1` · 位 1 = L1 让出 `2` · 位 2 = L2 抢占 `4`； 行不通  L2 一律不许宣称（登记不实现）。
/// 本后端宣称 L0 + L1（`bk_task_yield` 能真让出）；本 target 不依赖 `PiniCore`，故位值在此重述并由判据钉住一致。
private enum ConcurrencyTierBits {
    static let dispatch: UInt32 = 1  // L0 调度
    static let yield: UInt32 = 2     // L1 让出
}

private let _bkCapabilities: UInt32 =
    ConcurrencyTierBits.dispatch | ConcurrencyTierBits.yield  // L0 + L1（L2 永不给）

/// 后端能力位图。
@_cdecl("bk_capabilities")
public func bk_capabilities() -> UInt32 { _bkCapabilities }

// MARK: 协作式取消

/// 取消任务：**协作式**，不强杀，于下一检查点生效。
/// 取消沿取消树向下传播，并唤醒正阻塞在该任务上的 join。
@_cdecl("bk_task_cancel")
public func bk_task_cancel(_ h: UnsafeMutableRawPointer?) {
    guard let box = _bkTaskBox(h) else { return }
    _bkTaskCancelBox(box)
}

/// 取消检查点：回答当前任务是否已被取消。
/// 无参形态对应 `RuntimeOps.checkCancellation`；在岗的检查点是异步体入口与 `joinAll` 聚合，`sleep` 的
/// 检查点按片真查取消位。 行不通  无当前任务时回 `0` —— 与 `checkCancellation(nil)`「不做事」同义。
@_cdecl("bk_task_is_cancelled")
public func bk_task_is_cancelled() -> Int32 {
    guard let box = _bkTaskCurrent else { return 0 }
    box.cond.lock()
    let c = box.cancelled
    box.cond.unlock()
    return c ? 1 : 0
}

/// 从父 scope 剪枝、不再由父任务收回 —— fire-and-forget 的唯一合法出口。
@_cdecl("bk_task_detach")
public func bk_task_detach(_ h: UnsafeMutableRawPointer?) {
    guard let box = _bkTaskBox(h) else { return }
    _bkTaskDetachFromParent(box)
}

// MARK: spawn 与让出（任务族里仅有的两个**受形状影响**的符号）

/// 任务体的 wrapper 调用形态：两态（跑完 / 已让出）。
///  行不通  与 LazyRef / 给定块的 wrapper ABI 不同形是刻意的：那条统一 ABI 只返回单个 `ptr`，表达不了两态，
/// 而两态正是让出的全部内容。返回值 `0` = 体跑到底（三槽已写），非 `0` = 已让出（`out` 未写）。
private typealias _BkTaskBody = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32

/// `Result` 三槽的字节数（tag + ok + err，载荷一律擦除为 i64 宽度）。
private let _bkResultSlotsBytes = 24

/// 派发任务体：调用即派发，实参就是该次异步调用的实参，故它自己没有待定的形状。
/// 三件事按序做完再返回，调用方立刻拿到句柄（急切派发）：建盒 · 认父（父已取消 ⇒ 新子立即取消）· 起线程跑体。
///  注意  线程归原语层；策略层（队列/优先级/归约阈值/选下一个）不住在这里，本函数只回答「体在哪条线程上开始跑」。
@_cdecl("bk_task_spawn")
public func bk_task_spawn(
    _ wrapper: UnsafeMutableRawPointer?, _ code: UnsafeMutableRawPointer?,
    _ env: UnsafeMutableRawPointer?, _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer {
    guard let wrapper else {
        bk_panic("Pini runtime error: task spawn got a null body wrapper")
    }
    // 并发的首个真实入口 —— 进程退出钩子在此登记（见 `_bkEnsureProcessExitHook`：惰性全局，
    // 没有读者就等于没登记）。
    _bkEnsureProcessExitHook()
    let box = _BkTaskBox()
    box.wrapper = wrapper
    box.code = code
    box.env = env
    box.elemBytes = elemBytes
    box.elemTag = elemTag
    let h = _bkRegister(box)
    box.selfHandle = h
    if let parent = _bkTaskCurrent {
        _bkTaskAdopt(Unmanaged.passUnretained(parent).toOpaque(), h)
    }
    _bkSpawnTaskThread(h)
    return h
}

/// 起一条线程跑任务体。`Thread` 的闭包按 `@Sendable` 检查，裸指针不 Sendable ⇒ 以位模式过界。
/// 进程内地址不变，出界即重建指针；这样「指针归这条新线程独有」不必写成对类型系统的断言。
private func _bkSpawnTaskThread(_ h: UnsafeMutableRawPointer) {
    let bits = UInt(bitPattern: h)
    let thread = Thread {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        _bkTaskRunBody(raw)
    }
    thread.start()
}

/// 体的一次运行：登记当前任务 → 调 wrapper → 按返回的两态收尾。
/// 首跑与续跑走同一条路径（续跑不需要第二个入口函数）。
///  注意  让出时不决出 `future` —— 那是续跑方的责任；本层只让这件事可观测（`box.suspended`）并计数。
private func _bkTaskRunBody(_ h: UnsafeMutableRawPointer) {
    guard let box = _bkTaskBox(h), let wrapper = box.wrapper else { return }
    let restore = _bkTaskEnter(h)
    defer { restore() }
    box.cond.lock()
    //  行不通  这道闸从 L0 的「体已跑过就返回」放开为「**让出态允许续跑**」。
    // 不放开，续跑会被这里**静默吞掉**，而症状是「等待方永久阻塞」——不是崩溃，所以更需要闸本身
    // 开门见山。今天（L0）体从不中途返回，故放开的只是那条到不了的路径。
    let admitted = (!box.bodyStarted || box.suspended) && !box.frameReleased
    let concurrent = box.running
    box.bodyStarted = true
    box.suspended = false
    if admitted && !concurrent { box.running = true }
    //  重要  取槽游标归零 ⇒ 帧槽地址可重放（见 `frameCursor` 的注释）。
    box.frameCursor = 0
    box.awaiting = nil
    box.cond.unlock()
    guard admitted, !concurrent else { return }

    let out = UnsafeMutableRawPointer.allocate(byteCount: _bkResultSlotsBytes, alignment: 8)
    defer { out.deallocate() }
    let body = unsafeBitCast(wrapper, to: _BkTaskBody.self)
    let status = body(box.code, box.env, out)

    box.cond.lock()
    box.running = false
    box.cond.unlock()

    if status == 0 {
        let tag = out.load(fromByteOffset: 0, as: Int64.self)
        let ok = out.load(fromByteOffset: 8, as: Int64.self)
        let err = out.load(fromByteOffset: 16, as: Int64.self)
        /// 真跑完才交还帧；先读三槽再交还，免得交还后又去读它。
        _bkTaskReleaseFrame(box)
        if tag == 0 {
            _bkTaskResolveOk(h, ok)
        } else {
            _bkTaskResolveErr(h, err)
        }
        return
    }
    _bkTaskNoteYield()
    box.cond.lock()
    box.suspended = true
    //  重要  关上那扇丢唤醒的窗：若「决出方」在我交还控制流**之前**就已经来叫过（`resumePending`），
    // 它当时看到的还是一个没让出的任务、因而没起线程 ⇒ 记号的兑现责任落在这里。
    let resumeNow = box.resumePending
    box.resumePending = false
    box.cond.broadcast()
    box.cond.unlock()
    if resumeNow {
        /// 兑现方式是**入队**：「谁跑下一个」归策略层，
        ///  行不通  不在这里抢跑。 注意  这一处与 `_bkTaskResume` 的那一处是**同一个入队路径的两侧**：
        /// 漏掉任何一侧，被漏的那条路上挑选顺序就退回决出顺序。
        if _bkTaskOffer(box) { _bkTaskScheduleDrain() }
    }
}

/// 问后端能否让出（查询语义）：它不执行让出 —— 让出是异步体的 `return`，由驱动器接住。
/// 返回 `1` = 能真让出；`0` = 合规降级，本次等待按占用处理（ 行不通  不是错误）。
/// 答案取自 L1 位，与解释器后端同源（`capabilities.supports(.yield)`），各后端由同一条规则决定。
@_cdecl("bk_task_yield")
public func bk_task_yield() -> Int32 {
    (_bkCapabilities & ConcurrencyTierBits.yield) != 0 ? 1 : 0
}

/// 帧的取用：一个概念、两种用途，区别只在 `bytes`。
/// `bytes > 0` 派发点用：新建一块属于运行时的帧（已清零，首字是续跑点、`0` = 首次进入，故不必再 store）；
/// `bytes == 0` 体内用：取当前任务的帧，无论第几次进入都是同一块。份额在运行时，否则取消路径上无人释放。
@_cdecl("bk_task_frame")
public func bk_task_frame(_ bytes: Int64) -> UnsafeMutableRawPointer? {
    guard bytes > 0 else {
        return _bkTaskCurrent?.env
    }
    let p = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: 8)
    _ = p.initializeMemory(as: UInt8.self, repeating: 0, count: Int(bytes))
    _bkAdoptFrame(p)
    return p
}

/// 帧内取一个局部槽：可重放是全部要点。
/// 让出时槽指针全丢，续跑靠重执行同一段取槽代码 ⇒ 必须保证「同一体第 n 次进入的第 k 次调用得到同一
/// 地址」（游标每次进入体时归零，命中已发的块原样返回）。尺寸由发射层给；对齐按 8 字节，超 8 无通道。
@_cdecl("bk_task_slot")
public func bk_task_slot(_ bytes: Int64) -> UnsafeMutableRawPointer {
    let size = max(1, Int(bytes))
    guard let box = _bkTaskCurrent else {
        bk_panic("Pini runtime error: bk_task_slot called outside a task body")
    }
    box.cond.lock()
    let index = box.frameCursor
    if index < box.frameChunks.count {
        box.frameCursor = index + 1
        let reused = box.frameChunks[index]
        box.cond.unlock()
        return reused
    }
    let fresh = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    box.frameChunks.append(fresh)
    box.frameCursor = index + 1
    box.cond.unlock()
    return fresh
}

/// 可让出的等待：与 `bk_task_join` 的区别是它可以拒绝阻塞。`0` / `1` 的归一化与 join 同一套；
/// `2` = 本次会让出：`out` 一个字节都不许写，控制流交还驱动器，调用方据此返回非 `0` 且不得交还帧。
///  行不通  「这次会让出」是编译期事实（运行时刻判不出调用方是不是异步体）；登记在 `target.awaiters`，与已决判定同锁。
@_cdecl("bk_task_await")
public func bk_task_await(
    _ handle: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let target = _bkTaskBox(handle) else {
        bk_panic("Pini runtime error: task await got a null handle")
    }
    ///  行不通  两处**合规降级**（都不是错误）：不在任何任务里 ⇒ 没有「当前任务」可让出；
    /// L1 位缺席 ⇒ 后端不能真让出（降级，不失败）。
    guard let current = _bkTaskCurrent,
        (_bkCapabilities & ConcurrencyTierBits.yield) != 0
    else {
        return _bkTaskJoinOne(target, timeoutMs: nil, out: out)
    }
    target.cond.lock()
    let settled = target.resolved || target.cancelled
    if !settled {
        current.awaiting = target
        target.awaiters.append(current)
    }
    target.cond.unlock()
    // 已决的对象不值得交出控制流：直接取值（解释器后端同一条规则 —— 「已决的 future 不是
    // 放弃任务的理由」，那里也走直线）。
    if settled { return _bkTaskJoinOne(target, timeoutMs: nil, out: out) }
    return 2
}

/// `sleep(ms)` 的原语层落点：按片睡，每片醒来查一次取消位。
///  行不通  不做成直通的 libc 睡眠：解释器后端把长睡拆片，取消在「一片之内」生效；直通会让各后端在取消时机
/// 上分岔。 注意  C ABI 面没有异常通道 ⇒ 发现取消只能提前结束睡眠，体仍会跑完；等待侧归约是同一套。
@_cdecl("bk_sleep")
public func bk_sleep(_ ms: Int32) {
    guard ms > 0 else { return }
    var remaining = Double(ms) / 1000.0
    let slice = 0.02
    while remaining > 0 {
        if _bkTaskCurrent?.cancelled == true { return }
        let step = min(slice, remaining)
        Thread.sleep(forTimeInterval: step)
        remaining -= step
    }
}

// MARK: join

/// 阻塞 join（现行唯一形态）。`out` 收 `Result`（三槽，见 `_bkWriteResult`）。
/// - Returns: 见段首 `status` 取值表。
@_cdecl("bk_task_join")
public func bk_task_join(
    _ h: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = _bkTaskBox(h) else {
        bk_panic("Pini runtime error: task join got a null task handle")
    }
    return _bkTaskJoinOne(box, timeoutMs: nil, out: out)
}

/// 带超时的阻塞 join。超时**归约为取消**（与解释器后端 `joinFuture(timeoutMs:)`
/// 同构：取消该任务 + `err(CancelError)`）⇒ 超时时返回 `status = 1`。
@_cdecl("bk_task_join_within")
public func bk_task_join_within(
    _ h: UnsafeMutableRawPointer?, _ ms: Int32, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = _bkTaskBox(h) else {
        bk_panic("Pini runtime error: task joinWithin got a null task handle")
    }
    return _bkTaskJoinOne(box, timeoutMs: ms, out: out)
}

/// 聚合 join，fail-fast：任一成员的 `err` 即决定聚合，其余成员被取消（没人在等它们，就不该继续占线程）。
///  注意  成员的父链不动：只对成员调取消，不 `adopt` —— 改写父链会让调用方的返回取消掉它从未拥有过的任务。
///  注意  全 `ok` 时聚合载荷是数组句柄，元素是各成员 ok 载荷（8 字节不透明字、tag = `.i64`），类型身份不在本层。
private func _bkJoinAll(
    _ handles: [UnsafeMutableRawPointer?], _ out: UnsafeMutableRawPointer?
) -> Int32 {
    let n = handles.count
    guard n > 0 else {
        // 空集合的聚合是**空数组**，不是错误：`joinAll([])` 在解释器后端返回 ok([])。
        let arr = bk_array_create(0)
        _bkWriteResult(out, tag: 0, ok: _bkWord(arr), err: 0)
        return 0
    }
    // 先把**全部**句柄解出来再动手：fail-fast 会在中途返回，若那时才发现某个成员句柄是空的，
    // 报错点就落在「已经取消了一半」之后，调用方拿到的是半成品世界的解释。
    var boxes: [_BkTaskBox] = []
    boxes.reserveCapacity(n)
    for i in 0..<n {
        guard let b = _bkTaskBox(handles[i]) else {
            bk_panic("Pini runtime error: task joinAll got a null member handle at \(i)")
        }
        boxes.append(b)
    }

    var okWords: [Int64] = []
    for (i, box) in boxes.enumerated() {
        // 复用单任务 join：它已含「取消 → err(CancelError)」的归一化，这里不重写一遍。
        if _bkTaskJoinOne(box, timeoutMs: nil, out: out) != 0 {
            for rest in boxes.dropFirst(i + 1) { _bkTaskCancelBox(rest) }
            _bkWriteResult(out, tag: 1, ok: 0, err: _bkMakeError("任务已取消", isCancel: true, code: 2))
            return 1
        }
        let tag = out?.load(fromByteOffset: 0, as: Int64.self) ?? 0
        if tag == 1 {
            // fail-fast：首个 err 决定聚合，其余取消。`out` 已是该成员的 err 三槽。
            for rest in boxes.dropFirst(i + 1) { _bkTaskCancelBox(rest) }
            return 0
        }
        okWords.append(out?.load(fromByteOffset: 8, as: Int64.self) ?? 0)
    }

    let arr = bk_array_create(Int32(okWords.count))
    for (i, w) in okWords.enumerated() {
        var word = w
        _ = withUnsafePointer(to: &word) { bk_array_set_unsafe(arr, Int32(i), $0, 8, _BkTag.i64.rawValue) }
    }
    _bkWriteResult(out, tag: 0, ok: _bkWord(arr), err: 0)
    return 0
}

/// 字面量形态的入口：codegen 已把各成员的句柄排进一块连续区，这里只管解地址。
@_cdecl("bk_task_join_all")
public func bk_task_join_all(
    _ handles: UnsafeMutableRawPointer?, _ count: Int32, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    let n = Int(count)
    guard n > 0 else { return _bkJoinAll([], out) }
    guard let handles else {
        bk_panic("Pini runtime error: task joinAll got null handles")
    }
    let base = handles.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return _bkJoinAll(Array(UnsafeBufferPointer(start: base, count: n)), out)
}

/// 变量数组的入口：句柄还在数组盒里，逐槽取出再走同一段聚合。
///  注意  元素槽存的是「装着句柄字的 box」，故先解一层 box 再读那一个字。
@_cdecl("bk_task_join_all_box")
public func bk_task_join_all_box(
    _ array: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let array else { return _bkJoinAll([], out) }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(array).takeUnretainedValue()
    var handles: [UnsafeMutableRawPointer?] = []
    handles.reserveCapacity(box.count)
    for index in 0..<box.count {
        guard let cell = box.storage.elements[index] else {
            bk_panic("Pini runtime error: task joinAll got an uninitialized member at \(index)")
        }
        handles.append(cell.load(as: UnsafeMutableRawPointer?.self))
    }
    return _bkJoinAll(handles, out)
}

// MARK: scope 收口

/// 关闭范围：收集 leaked 失败并上浮 —— `ok(v)` 翻 `err(aggregate)`，契约里的唯一有界 override。
///  注意  `out` 是 in-out（调用方先写自己的 `Result`）；「有界」两处：未完成的子任务被取消、不计 leaked；
/// 已有 `err` 的 `out` 不被覆盖（否则丢掉哪次失败）。聚合载荷是一条带失败条数的人读消息。
@_cdecl("bk_scope_close")
public func bk_scope_close(
    _ scope: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = _bkTaskBox(scope) else {
        bk_panic("Pini runtime error: scope close got a null scope handle")
    }
    box.cond.lock()
    let kids = box.children
    box.children = []
    box.cond.unlock()

    var leaked = 0
    for kid in kids {
        kid.cond.lock()
        let finished = kid.resolved
        let tag = kid.resultTag
        kid.cond.unlock()
        // 未完成 ⇒ 取消，不计失败（①）。已 detach / 已 join 的子不在 `children` 里，
        // 天然不计入 —— 这正是「剪枝」与 scope 收口的衔接点。
        guard finished else { _bkTaskCancelBox(kid); continue }
        if tag == 1 { leaked += 1 }
    }

    guard let out, leaked > 0 else { return 0 }
    // ② 有界：只在 `out` 当前是 `ok` 时翻。已有 err ⇒ 原样保留。
    let currentTag = out.load(fromByteOffset: 0, as: Int64.self)
    guard currentTag == 0 else { return 0 }
    _bkWriteResult(out, tag: 1, ok: 0, err: _bkMakeError("\(leaked) 个子任务失败", isCancel: false, code: 1))
    return 0
}

// MARK: - 并发面的非导出入口
// 这些函数没有 `@_cdecl` ⇒ 不是 `bk_*` 导出符号，不计入 IR 契约清单。它们存在是为让「造盒 / 决出 /
// 认父 / 登记当前任务」各只有一个实现点，故判据与 `bk_task_spawn` 不会各造一套语义。

/// 当前线程正在跑的任务的线程本地存放位（`bk_task_is_cancelled` 的无参形态读它）。
///  注意  只存弱引用、不 retain：当前任务一定同时被别处持有，本存放位只是「谁在跑」的读数面、不参与计数；
/// 若在此 retain 就多出一条与注册表并行的持有边，还要再定义释放时机。线程退出由 POSIX 销毁器清位。
private let _bkCurrentTaskKey: pthread_key_t = {
    var k = pthread_key_t()
    // Glibc 的销毁器形参可空、Darwin 不可空；语义相同，两处签名只能各写一遍。
    #if canImport(Glibc)
        let destructor: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in }
    #else
        let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { _ in }
    #endif
    pthread_key_create(&k, destructor)
    return k
}()

private var _bkTaskCurrent: _BkTaskBox? {
    get {
        guard let raw = pthread_getspecific(_bkCurrentTaskKey) else { return nil }
        return Unmanaged<_BkTaskBox>.fromOpaque(raw).takeUnretainedValue()
    }
    set {
        pthread_setspecific(
            _bkCurrentTaskKey,
            newValue.map { Unmanaged.passUnretained($0).toOpaque() })
    }
}

/// 造一个**未决**任务盒并返回句柄。归还责任 = 调用方（用完经 `bk_handle_release` 归还）。
func _bkTaskMake() -> UnsafeMutableRawPointer {
    let box = _BkTaskBox()
    let h = _bkRegister(box)
    box.selfHandle = h
    return h
}

/// 把任务标记为已决（`ok`）。写入方是任务体。
func _bkTaskResolveOk(_ h: UnsafeMutableRawPointer?, _ payload: Int64) {
    guard let box = _bkTaskBox(h) else { return }
    box.cond.lock()
    if !box.resolved {
        box.resolved = true
        box.resultTag = 0
        box.okPayload = payload
        box.errPayload = 0
        box.cond.broadcast()
    }
    box.cond.unlock()
    /// 决出方**续跑**在等我的那些任务 —— 这是 L1 的驱动侧（「决出方触发」）。
    /// 放在锁外：续跑会起线程，不该持锁做。
    _bkTaskResumeAwaiters(box)
}

/// 把任务标记为已决（`err`）。写入方是任务体。
func _bkTaskResolveErr(_ h: UnsafeMutableRawPointer?, _ payload: Int64) {
    guard let box = _bkTaskBox(h) else { return }
    box.cond.lock()
    if !box.resolved {
        box.resolved = true
        box.resultTag = 1
        box.okPayload = 0
        box.errPayload = payload
        box.cond.broadcast()
    }
    box.cond.unlock()
    _bkTaskResumeAwaiters(box)
}

// MARK: 可恢复帧与续跑

/// 运行时自有帧的地址集 —— 由 `bk_task_frame(bytes > 0)` 登记，交还时摘除。
/// 这张表的理由是归属：帧必须由运行时释放，而 `env` 也可能是调用方直接给的（单测把 Swift 对象指针当
/// 观测箱传进来）。 行不通  无条件释放后者会立即崩溃 ⇒ 只有本表登记过的才释放。
nonisolated(unsafe) private var _bkAllocatedFrames: Set<UInt> = []
private let _bkAllocatedFramesLock = NSLock()

private func _bkAdoptFrame(_ p: UnsafeMutableRawPointer) {
    _bkAllocatedFramesLock.lock()
    _bkAllocatedFrames.insert(UInt(bitPattern: p))
    _bkAllocatedFramesLock.unlock()
}

/// 交还一个任务的全部帧内存（`env` 那一块 + `bk_task_slot` 发出的各块），幂等。
///  重要  两条路径都来这里：真跑完（`status == 0` 分支）与让出态被取消（`_bkTaskCancelBox`）。
private func _bkTaskReleaseFrame(_ box: _BkTaskBox) {
    box.cond.lock()
    guard !box.frameReleased else {
        box.cond.unlock()
        return
    }
    box.frameReleased = true
    let chunks = box.frameChunks
    box.frameChunks.removeAll()
    box.frameCursor = 0
    let env = box.env
    box.env = nil
    box.cond.unlock()
    for chunk in chunks { chunk.deallocate() }
    guard let env else { return }
    _bkAllocatedFramesLock.lock()
    let allocated = _bkAllocatedFrames.remove(UInt(bitPattern: env)) != nil
    _bkAllocatedFramesLock.unlock()
    if allocated { env.deallocate() }
}

/// 取走等待者快照并逐个交给队列（先快照、解锁、再动作 —— 与取消传播同一条定式，持锁递归会死锁）。
/// 这个函数是一次决出的全部后果，它做的是「把这一批交给策略层」， 行不通  不是「把这一批跑掉」。
///  重要  顺序是「先全部入队、再请挑选」，两步分开：否则第一个醒来的被挑走，顺序即退回决出顺序，策略无选择。
private func _bkTaskResumeAwaiters(_ box: _BkTaskBox) {
    box.cond.lock()
    let waiters = box.awaiters
    box.awaiters.removeAll()
    box.cond.unlock()
    var enqueuedAny = false
    for w in waiters {
        if _bkTaskResume(w) { enqueuedAny = true }
    }
    guard enqueuedAny else { return }
    _bkTaskScheduleDrain()
}

/// 让一个已让出的任务接着跑：改道之后「接着跑」= 交给策略层的队列， 行不通  不再起线程（起线程会让顺序
/// 完全由决出顺序决定，策略层没有可挑的余地）。`resolved` / `cancelled` 守卫挡「已收口，别再排队」。
///  重要  `resumePending` 不是优化：登记「在等谁」与标「已让出」隔着体的返回，缝里决出就没人叫醒 ⇒ 先挂记号。
private func _bkTaskResume(_ box: _BkTaskBox) -> Bool {
    box.cond.lock()
    let alive = !box.resolved && !box.cancelled
    let wasSuspended = box.suspended
    if alive && !wasSuspended { box.resumePending = true }
    box.cond.unlock()
    guard alive, wasSuspended else { return false }
    return _bkTaskOffer(box)
}

// MARK: 就绪队列的驱动面（决出 ⇒ 入队，由策略层决定谁跑）
//  行不通  与解释器后端同形：决出不再直接续跑体，而是把任务交给策略层的队列，再由挑选循环按策略顺序推进。
//  注意  句柄承载不同是架构使然：解释器用整数句柄 + 映射表，LLVM 的任务句柄本就是裸指针 ⇒ 零映射表。

/// 策略层的绑定记录：布局即 ABI——三个机器字（策略实例 · 「收下」入口 · 「选择下一个任务」入口）。
/// 发射层在派发点就地构造这三个字并把地址交进来。 行不通  本层不解释第一个字（它是默认实例的盒指针，只原样回传）。
/// 写成一个记录指针而非三个实参：形状只此一处，将来加一格只动那一处。
private struct _BkSchedBinding {
    /// 调策略层的「收下」：`(策略实例, 任务句柄) -> ()`。
    typealias Accept = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    /// 调策略层的「选择下一个任务」：`(策略实例) -> 任务句柄`，**`nil` = 队列空**。
    typealias Pick = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    let sched: UnsafeMutableRawPointer?
    let accept: Accept?
    let pick: Pick?
}

/// 一次「问策略层要一个」的结果。
///  注意  「空」与「缺陷」必须分开（与解释器后端同一条纪律）：前者是正常状态（刚建好的队列就是空的），
/// 后者是策略给了从没发出过的句柄。混成一个读数就会把缺陷读成「暂时没活」⇒ 静默地什么都不做。
private enum _BkReadyTake {
    case task(UnsafeMutableRawPointer)
    case empty
    case unknown(UnsafeMutableRawPointer)
    /// 策略层答不出来（没绑、或答了个不是句柄的东西）。
    case defect(String)
}

/// 就绪队列 —— 元素是任务盒句柄（造盒时登记所得的那个裸指针）。
///  注意  写入方是决出方那条线程（决出 ⇒ 入队），读取方是挑选循环 ⇒ 由 `_bkReadyLock` 守护。
///  行不通  不能以「反正单线」或「同族状态已有隔离」为由省掉这层。
nonisolated(unsafe) private var _bkReadyQueue: [UnsafeMutableRawPointer] = []
private let _bkReadyLock = NSLock()

/// 「趟」的两笔账（照解释器后端）：有人要挑 · 已经有一趟在挑。
/// 一批任务全部入队之后才请挑选，而请挑选可能落在另一条线程上（同一时刻可能有多批）⇒ 用「已有循环
/// 在跑就只记一笔」收成同一时刻只跑一趟，那一笔由收工的那趟兑现（见 `_bkTaskDrain` 尾部的对账）。
nonisolated(unsafe) private var _bkReadyRequested = false
nonisolated(unsafe) private var _bkReadyScheduled = false
nonisolated(unsafe) private var _bkReadyDraining = false

/// 进程内最近一次的绑定 —— 挑选循环用它问策略。
///  注意  今天只有一个调度实例（预置那份或用户替换的那份）⇒「用哪份绑定」不构成问题； 行不通  本层不做按调度器
/// 分组的多队列（那是设计里另立的一段，今天无对象）。
nonisolated(unsafe) private var _bkSchedBinding: _BkSchedBinding?

/// 从绑定记录的三个字里读出它的三个字段（布局见 `_BkSchedBinding`）。
private func _bkReadBinding(_ p: UnsafeMutableRawPointer?) -> _BkSchedBinding? {
    guard let p else { return nil }
    let sched = p.load(fromByteOffset: 0, as: UnsafeMutableRawPointer?.self)
    let acceptRaw = p.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self)
    let pickRaw = p.load(fromByteOffset: 16, as: UnsafeMutableRawPointer?.self)
    guard let acceptRaw, let pickRaw else { return nil }
    return _BkSchedBinding(
        sched: sched,
        accept: unsafeBitCast(acceptRaw, to: _BkSchedBinding.Accept.self),
        pick: unsafeBitCast(pickRaw, to: _BkSchedBinding.Pick.self))
}

/// 把调度器绑定交给运行时：`handle` 只作校验用（绑定存在运行时那一份上，不逐任务存——今天只有一个
/// 调度实例，逐任务存会得到没有读者的字段）；`binding` 传空即解绑（替身策略释放后绑定还在，后续入队
/// 会调到悬垂的函数指针）。返回 `0` = 已接受或已解绑，今天不定义别的取值。
@_cdecl("bk_task_bind_sched")
public func bk_task_bind_sched(
    _ handle: UnsafeMutableRawPointer?, _ binding: UnsafeMutableRawPointer?
) -> Int32 {
    guard _bkTaskBox(handle) != nil else { return 1 }
    _bkReadyLock.lock()
    defer { _bkReadyLock.unlock() }
    guard let binding else {
        _bkSchedBinding = nil
        return 0
    }
    guard let read = _bkReadBinding(binding) else { return 1 }
    _bkSchedBinding = read
    return 0
}

/// 任务的可观测态：四态、互斥（与「能力位查询」那种可叠加的位图不同族）。
/// `3` 已决 = 有结果或其取消已归约 · `1` 可跑 = 在就绪队列里 · `2` 等待中 = 体已交出控制流、等某个未来
/// 决出 · `0` 未起 = 体从未进入。 注意  一经采纳即成可观测承诺 ⇒ 改它须走破坏性流程。
@_cdecl("bk_task_state")
public func bk_task_state(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard let box = _bkTaskBox(h) else { return 0 }
    box.cond.lock()
    let resolved = box.resolved
    let cancelled = box.cancelled
    let queued = box.queued
    let suspended = box.suspended
    let started = box.bodyStarted
    box.cond.unlock()
    // ① 取消按既有的归一读作**已决**（`join` 那一侧就是把它归约成 `err(CancelError)`）。
    //  注意  四态表里没有「已取消」这一格 —— 如实登记， 行不通  不自行扩表。
    if resolved || cancelled { return 3 }
    if queued { return 1 }
    if suspended { return 2 }
    // ② 体正在跑 ⇒ 读作**可跑**：四态表里没有「正在被推进」这一格，而它的定义
    // （「该被执行器推进」）在这一刻仍然成立。 注意  由此本条**不能**用来区分「在队列里」与「正在跑」
    // —— 判据要区分的是「等待中」与「可跑」，那两格分得开。
    if started { return 1 }
    return 0
}

/// 把一个任务交给策略层的队列。
///  注意  调「收下」在锁外：那跑的是用户代码（策略是 Pini 值）， 行不通  不该持本层的锁调它。
/// 返回真的入了队 ⇒ `true`（入不了队时已就地处置）。
@discardableResult
private func _bkTaskOffer(_ box: _BkTaskBox) -> Bool {
    guard let h = box.selfHandle else { return false }
    _bkReadyLock.lock()
    let binding = _bkSchedBinding
    guard let binding else {
        _bkReadyLock.unlock()
        ///  注意  没有策略层 ⇒ 降级为直接续跑， 行不通  不是把任务归约掉（纪律：无合格版本则降级，不失败）。
        /// 具体用处：进程内直接调这一族符号的用法（判据就是这么做的）从不绑策略，归约会让他们从能跑变成不能跑。
        ///  注意  ① 这条路上不置 `queued` ⇒ 可观测面读作「等待中」；② 解释器后端没有这条路径，两后端在此不对称。
        _bkSpawnTaskThread(h)
        return false
    }
    box.cond.lock()
    let already = box.queued
    box.queued = true
    box.cond.unlock()
    if !already { _bkReadyQueue.append(h) }
    _bkReadyLock.unlock()
    binding.accept?(binding.sched, h)
    return true
}

/// 请一趟挑选循环来把这批活挑完。**同一时刻只排一趟**。
private func _bkTaskScheduleDrain() {
    _bkReadyLock.lock()
    if _bkReadyDraining || _bkReadyScheduled {
        _bkReadyRequested = true
        _bkReadyLock.unlock()
        return
    }
    _bkReadyScheduled = true
    _bkReadyLock.unlock()
    DispatchQueue.global().async { _bkTaskDrain() }
}

/// 问策略层「下一个是谁」。
private func _bkTaskPick() -> _BkReadyTake {
    _bkReadyLock.lock()
    let binding = _bkSchedBinding
    _bkReadyLock.unlock()
    guard let binding, let pick = binding.pick else {
        return .defect("没有绑定可用的策略层")
    }
    guard let answered = pick(binding.sched) else { return .empty }
    _bkReadyLock.lock()
    let known = _bkReadyQueue.contains(answered)
    _bkReadyLock.unlock()
    //  行不通  给了一个**从没发出去过**的句柄 ⇒ 缺陷， 行不通  不得读成「暂时没活」。
    guard known else { return .unknown(answered) }
    return .task(answered)
}

/// 驱动循环：**问策略要一个 ⇒ 推进它一次**，直到策略说没有下一个。
private func _bkTaskDrain() {
    _bkReadyLock.lock()
    _bkReadyScheduled = false
    _bkReadyDraining = true
    _bkReadyLock.unlock()

    //  注意  策略给的答案**可不可信**要分开记：不可信时**不得**再排下一趟，
    // 否则「策略每次都答同一个我们不认识的句柄」会转成一个不停循环。
    var trustworthy = true
    drain: while true {
        switch _bkTaskPick() {
        case .task(let h):
            _bkReadyLock.lock()
            if let idx = _bkReadyQueue.firstIndex(where: { $0 == h }) {
                _bkReadyQueue.remove(at: idx)
            }
            _bkReadyLock.unlock()
            if let box = _bkTaskBox(h) {
                box.cond.lock()
                //  注意  在队列里等着的这段时间里它可能被取消 ⇒ **出队即丢弃**：
                // 一个从未被进入的体没有检查点，取消只能在**这里**被看见。
                box.queued = false
                let gone = box.cancelled
                box.cond.unlock()
                if !gone { _bkTaskRunBody(h) }
            }
        case .empty:
            break drain
        case .unknown(let h):
            trustworthy = false
            _bkReportSchedulerDefect("它点名了一个从未发出去过的句柄 \(h)")
            break drain
        case .defect(let why):
            trustworthy = false
            _bkReportSchedulerDefect(why)
            break drain
        }
    }

    _bkReadyLock.lock()
    _bkReadyDraining = false
    // 关掉那道窗：本循环据「策略说没有」收工时，另一边可能刚入了队、
    // 又因为「已经有一趟在跑」而只记了一笔 ⇒ 那一笔在这里兑现。
    let again = trustworthy && _bkReadyRequested && !_bkReadyScheduled
    _bkReadyRequested = false
    if again { _bkReadyScheduled = true }
    _bkReadyLock.unlock()
    if again {
        DispatchQueue.global().async { _bkTaskDrain() }
    }
}

/// 策略层坏了 —— 响亮说， 行不通  不静默降级成「没有下一个」。
///  注意  走 stderr 而非 stdout：这一层程序的 stdout 是被断言的东西（判据逐字节比它），混在一起会毁掉读数。
///  注意  与解释器后端的对应物一处不对称：那个后端打 stdout（本后端 stdout 承载 `printf` 的程序输出）。
private func _bkReportSchedulerDefect(_ detail: String) {
    FileHandle.standardError.write(
        Data("[scheduler]  行不通  策略层给出的答案不可用，就绪队列停止驱动：\(detail)\n".utf8))
}

// MARK: 让出的可观测通道

/// 闸门：仅在环境变量置位时输出，未置位 ⇒ 零输出。
///  行不通  它是测试器械专用的观测面——不是 ABI、不是诊断通道、不是给用户的功能；本仓另有已登记的
/// 「诊断通道」缺口，二者不是一件事，这条声明正是防止有人把它当成那个缺口的补丁。
private let _bkYieldReportEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["PINI_YIELD_REPORT"] else { return false }
    return !(raw.isEmpty || raw == "0")
}()

nonisolated(unsafe) private var _bkYieldCount = 0
private let _bkYieldCountLock = NSLock()

/// 体**真让出**一次（wrapper 返回非 `0`，且运行时已接受）。计数在闸门之外也累加 ——
/// 闸门只决定**打不打印**，不影响运行时行为。
private func _bkTaskNoteYield() {
    guard _bkYieldReportEnabled else { return }
    _bkYieldCountLock.lock()
    _bkYieldCount += 1
    _bkYieldCountLock.unlock()
}

/// 进程退出时打一行汇总（经既有的退出钩子那条路径， 行不通  不新起退出路径）。
///  注意  汇总而非逐次：逐次打点会与程序自身输出交错 ⇒ 读数非确定；汇总一行逐字节可断言。
/// 代价如实说：只有置位的运行可见 ⇒「不置位时也让出」这一半测不到（跳过必须可见）。
private func _bkReportYields() {
    guard _bkYieldReportEnabled else { return }
    _bkYieldCountLock.lock()
    let n = _bkYieldCount
    _bkYieldCountLock.unlock()
    FileHandle.standardError.write(Data("pini-yield-report: bodies-suspended=\(n)\n".utf8))
}

/// 认父（照 `FutureValue.addChild`）：父已取消 ⇒ 新子**立即**被取消（不漏网）。
/// `B-3` 的 `bk_task_spawn` 在此登记新任务。
func _bkTaskAdopt(_ parent: UnsafeMutableRawPointer?, _ child: UnsafeMutableRawPointer?) {
    guard let p = _bkTaskBox(parent), let c = _bkTaskBox(child) else { return }
    p.cond.lock()
    let parentAlreadyCancelled = p.cancelled
    if !parentAlreadyCancelled {
        c.parent = p
        p.children.append(c)
    }
    p.cond.unlock()
    if parentAlreadyCancelled { _bkTaskCancelBox(c) }
}

/// 登记「当前任务」（`bk_task_is_cancelled` 读它；`B-3` 的 `bk_task_spawn` 亦在此登记）。
/// - Returns: **恢复闭包** —— 调用方在体跑完后调它还原上一层（照 `RuntimeOps.enterTask`）。
func _bkTaskEnter(_ h: UnsafeMutableRawPointer?) -> () -> Void {
    let previous = _bkTaskCurrent
    _bkTaskCurrent = _bkTaskBox(h)
    return { _bkTaskCurrent = previous }
}
