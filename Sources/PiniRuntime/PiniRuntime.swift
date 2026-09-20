import Foundation

// POSIX 线程本地存储（`pthread_key_t`）的取用口。与 `Sources/PiniCore/Common/ThreadLocal.swift`
// 用同一套系统头，理由相同：`Thread.current.threadDictionary` 只在 Apple 平台存在，
// 而运行时组件是**跨平台**目标（见 `Package.swift`）。
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - 并发后端抽象 阶段1：集合/COW 运行时 shim（Swift 实现，C ABI 边界）

// MARK: - #46-D D4：显式 share count 与写时复制（COW）基础设施
//
// 为何不用 `isKnownUniquelyReferenced`：LLVM 后端里 `var b = a` 只是把**不透明句柄**
// （裸 `ptr`）从一个 alloca 槽复制到另一个槽——Swift ARC 完全看不到这次别名，box 的
// 引用计数恒为 1（仅 `_liveHandles` 持有），`isKnownUniquelyReferenced` 恒为 true，
// 分裂永不触发。故 D4 改为**运行时显式 share count**：codegen 在别名绑定处发射
// `bk_handle_retain`，写入前发射 `bk_handle_ensure_unique`（或经 set 的返回句柄），
// 由运行时按 `shares` 判定是否分裂。解释器侧则由 Swift 集合原生 COW 保证（见 值分裂与 COW 判定）。

// 所有权契约（codegen 与运行时的分工，务必遵守）：
// 1. `bk_*_create` 产出 shares == 1 的 box，所有权归**接收该句柄的那个所有者**
// （变量槽，或作为元素被写入的父容器）。
// 2. `bk_*_set` / `bk_set_add` 对句柄型内容只做**字节复制（移动语义）**，不 retain。
// 故 `[[1,2],[3,4]]` 这种「内层字面量是临时值」的构造是所有权转移，零额外计数。
// 3. 若被写入的句柄**同时仍被别处持有**（如 `var outer = [inner]` 中的 `inner` 变量），
// 则由 **codegen 在读取该标识符句柄时发射 `bk_handle_retain`**——「别名点 retain」
// 是 codegen 的责任，运行时不猜测。
// 4. box `deinit` 对句柄型元素递减一份 share（与 2 的移动语义配对闭环）。

/// 所有容器 box 的公共基类：携带 share count 与深拷协议。
///
/// 以基类承载使 `bk_handle_*` 系列可**类型无关**地操作任意容器句柄
/// （`Unmanaged<_BkBox>.fromOpaque` 后动态转型），无需 IR 侧按类型分派 retain/split，
/// 也避免查三张 live 表的 O(n) 判型。
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
private var _liveHandles: [Unmanaged<_BkBox>] = []

/// 登记新建 box，返回其不透明句柄。
private func _bkRegister(_ box: _BkBox) -> UnsafeMutableRawPointer {
    let u = Unmanaged.passRetained(box)
    _liveHandles.append(u)
    return u.toOpaque()
}

/// 递减句柄的 share count；归零则从登记表摘出并释放。
///
/// 「先从数组摘出、再 release」的顺序是必要的：release 可能触发 `deinit`，其中会对
/// 嵌套 handle 元素递归调用本函数、再次修改 `_liveHandles`。摘出动作先于 release 完成，
/// 故递归修改发生在数组访问之外，不触发独占性冲突。
private func _bkReleaseShare(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    let box = Unmanaged<_BkBox>.fromOpaque(h).takeUnretainedValue()
    box.shares -= 1
    guard box.shares <= 0 else { return }
    if let idx = _liveHandles.firstIndex(where: { $0.toOpaque() == h }) {
        let u = _liveHandles.remove(at: idx)
        u.release()
    }
}

/// 元素 box 内容若为嵌套句柄（`tag == .handle`），递增其 share count。
/// 供 `cowCopy` 使用：字节复制会让两个容器持有同一内层句柄，必须计入共享。
private func _bkRetainIfHandle(_ elemBox: UnsafeRawPointer, _ tag: Int32) {
    guard _BkTag(rawValue: tag) == .handle else { return }
    let inner = elemBox.load(as: UnsafeMutableRawPointer?.self)
    guard let inner else { return }
    Unmanaged<_BkBox>.fromOpaque(inner).takeUnretainedValue().shares += 1
}

/// 元素 box 内容若为嵌套句柄，递减其 share count（供 `deinit` 释放嵌套引用）。
private func _bkReleaseIfHandle(_ elemBox: UnsafeRawPointer, _ tag: Int32) {
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

/// 不透明句柄背后的真实存储。
///
/// 所有对外函数经 `@_cdecl` 导出为 C ABI：句柄为 `void*`（LLVM IR 中 `ptr`），
/// 在模块内以 `%bk_array*`（= `type { ptr }`）承载，仅作类型区分；IR 中从不解引用，
/// 所有访问经下方 `@bk_array_*` 调用完成。C ABI 为 MUST 硬约束（见 并发后端抽象），
/// 否则阶段3 纯 libc 重写时被锁死。
private final class _BkArrayBox: _BkBox {
    /// #46-D D1：装箱-raw 存储——每槽是一个由运行时拥有的堆 box（`UnsafeMutableRawPointer`），
    /// box 内 memcpy 存元素原始字节。无论元素类型是 Int/F64/Bool/String 还是嵌套数组，
    /// 均以 `ptr` 承载，与 并发后端抽象「一切经 C ABI 的 `ptr`」哲学一致，且天然支持任意宽度元素
    /// （由 codegen 在 `@bk_array_set` 时传入 `elemBytes`）。box 的生命周期由本 box 持有，
    /// `deinit` 时统一释放，配合 `bk_array_destroy` / `bk_runtime_cleanup` 实现精确/进程级回收。
    var elements: [UnsafeMutableRawPointer?]
    /// #46-D D4：每槽内容的类型标签（与 `_BkTag` 对齐）。COW 深拷时据此识别嵌套句柄元素
    /// 并递增其 share count——否则字节复制会让两个数组共享同一内层句柄，
    /// 而内层写因 `shares == 1` 原地生效，污染另一侧（嵌套 COW 的关键）。
    var tags: [Int32]
    /// 每槽字节宽度（深拷需要，且与 `elemBytes` 一致）。
    var widths: [Int]

    init(count: Int) {
        // 上限保护：负数长度按 0 处理，避免越界分配。
        let n = max(count, 0)
        elements = Array(repeating: nil, count: n)
        tags = Array(repeating: 0, count: n)
        widths = Array(repeating: 0, count: n)
    }

    override func cowCopy() -> _BkBox {
        let copy = _BkArrayBox(count: elements.count)
        for i in elements.indices {
            copy.tags[i] = tags[i]
            copy.widths[i] = widths[i]
            guard let src = elements[i], widths[i] > 0 else { continue }
            copy.elements[i] = _bkAllocBox(src, widths[i])
            _bkRetainIfHandle(src, tags[i])
        }
        return copy
    }

    deinit {
        for i in elements.indices {
            guard let b = elements[i] else { continue }
            _bkReleaseIfHandle(b, tags[i])
            b.deallocate()
        }
    }
}

// MARK: - 数组运行时（D0 最小覆盖：I32 元素特化）

/// 运行时致命错误：打印到 stderr 并终止进程。
/// 与解释器抛 `RuntimeError` 语义对齐——双后端均以「错误」终止（见 并发后端抽象）。
@_cdecl("bk_panic")
public func bk_panic(_ msg: UnsafePointer<CChar>?) -> Never {
    if let msg { fputs(String(cString: msg), stderr) }
    fputs("\n", stderr)
    abort()
}

// MARK: 句柄通用原语（#46-D D4：类型无关的 share count / COW 分裂）

/// 别名绑定（`var b = a`、容器传参等）：递增 share count，使后续任一侧的写触发分裂。
/// codegen 在容器句柄被复制进新变量槽时发射本调用；不发射则退化为「共享且原地改」（错误语义）。
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

/// 嵌套写路径的**中间层**独占化：确保 `parent[i]` 处的嵌套句柄独占，并就地更新父槽。
///
/// 为何需要独立入口而非「ensure_unique + bk_array_set 写回」：`_bkEnsureUnique` 的语义是
/// 「把调用方持有的那一份 share 从原句柄转移给副本」（已 decrement）；若随后再经
/// `bk_array_set` 写回父槽，其 `_bkReleaseIfHandle(old)` 会**第二次**递减同一份 share，
/// 导致内层被提前回收（use-after-free）。故此处就地改写句柄字节、**不**释放旧句柄。
///
/// 前置条件：`parent` 必须已独占（由自顶向下的调用链保证）。违反则 `bk_panic` 立即暴露
/// codegen 缺陷，而非静默破坏别名语义。
@_cdecl("bk_array_ensure_unique_at")
public func bk_array_ensure_unique_at(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> UnsafeMutableRawPointer? {
    guard let arr else { return nil }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    guard box.shares <= 1 else {
        bk_panic("Pini runtime error: bk_array_ensure_unique_at requires a unique parent handle (shares=\(box.shares))")
    }
    let idx = Int(i)
    guard idx >= 0, idx < box.elements.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.elements.count))")
    }
    guard let slot = box.elements[idx] else {
        bk_panic("Pini runtime error: array element \(idx) is uninitialized")
    }
    guard _BkTag(rawValue: box.tags[idx]) == .handle else {
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
@_cdecl("bk_handle_release")
public func bk_handle_release(_ h: UnsafeMutableRawPointer?) {
    _bkReleaseShare(h)
}

/// 创建长度为 `len` 的数组，返回不透明句柄。
@_cdecl("bk_array_create")
public func bk_array_create(_ len: Int32) -> UnsafeMutableRawPointer {
    return _bkRegister(_BkArrayBox(count: Int(len)))
}

/// 数组长度（元素个数）。
@_cdecl("bk_array_len")
public func bk_array_len(_ arr: UnsafeMutableRawPointer?) -> Int32 {
    guard let arr else { return 0 }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    return Int32(box.elements.count)
}

/// 读取下标 `i` 处的元素 box（返回运行时拥有的稳定 `ptr`，codegen 据此 `load T`）。
/// 越界或槽未初始化经 `bk_panic` 终止（与解释器越界抛错一致）。
@_cdecl("bk_array_get")
public func bk_array_get(_ arr: UnsafeMutableRawPointer?, _ i: Int32) -> UnsafeMutableRawPointer {
    guard let arr else { bk_panic("Pini runtime error: array handle is null") }
    let box = Unmanaged<_BkArrayBox>.fromOpaque(arr).takeUnretainedValue()
    let idx = Int(i)
    guard idx >= 0, idx < box.elements.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.elements.count))")
    }
    guard let ptr = box.elements[idx] else {
        bk_panic("Pini runtime error: array element \(idx) is uninitialized")
    }
    return ptr
}

/// 写入下标 `i` 处的元素：将 `src` 处 `elemBytes` 字节 memcpy 进运行时新分配的堆 box
/// （先释放该槽旧 box），与 并发后端抽象「一切经 `ptr` C ABI」一致，支持任意宽度/类型元素。
/// 越界经 `bk_panic` 终止（与解释器越界抛错一致）。
///
/// #46-D D4（COW）：写前先 `_bkEnsureUnique` —— 句柄被共享（`shares > 1`）时深拷分裂，
/// 写入落在**副本**上，原 box 不受影响；返回实际被写入的句柄，**调用方必须写回变量槽**。
/// `elemTag` 供深拷时识别嵌套句柄元素（见 `_BkArrayBox.tags`）。
@_cdecl("bk_array_set")
public func bk_array_set(
    _ arr: UnsafeMutableRawPointer?, _ i: Int32, _ src: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let arr else { return nil }
    let target = _bkEnsureUnique(arr)
    let box = Unmanaged<_BkArrayBox>.fromOpaque(target).takeUnretainedValue()
    let idx = Int(i)
    guard idx >= 0, idx < box.elements.count else {
        bk_panic("Pini runtime error: array index \(idx) out of bounds (size \(box.elements.count))")
    }
    let n = Int(elemBytes)
    guard n > 0 else { return target }
    if let old = box.elements[idx] {
        _bkReleaseIfHandle(old, box.tags[idx])
        old.deallocate()
    }
    box.elements[idx] = _bkAllocBox(src, n)
    box.tags[idx] = elemTag
    box.widths[idx] = n
    return target
}

/// 释放数组句柄的一份 share（归零才真正回收）。
/// D4.2.3 将经 IR 在作用域末尾注入此调用以实现精确释放。
@_cdecl("bk_array_destroy")
public func bk_array_destroy(_ arr: UnsafeMutableRawPointer?) {
    _bkReleaseShare(arr)
}

// MARK: - #46-E G40（LazyRef，S3 LLVM 端）：懒加载引用语义（once 锁 + 缓存）

/// LazyRef 的引用语义承载：闭包 code/env + 元素类型 + once 锁 + 缓存 box。
///
/// 闭包调用 ABI（codegen 生成类型特化 wrapper 统一装箱）：
/// `define ptr @__lazyref_wrapper_<T>(ptr %code, ptr %env)`——内部 `call T %code(ptr %env)`
/// 后把 T 存进栈 box 并返回 box 指针；运行时 `bk_lazyref_value` 以统一 `(ptr, ptr) -> ptr`
/// C ABI 调用 wrapper 并立即 memcpy 到堆缓存。规避「不同 T 返回寄存器不一致」的 ABI 差异
/// （I32/F64/指针在 arm64 上分别走 x0/d0，统一为 ptr 后恒走 x0）。
/// 引用语义：不参与 COW 分裂（cowCopy 默认 fatalError，codegen 不对其发 ensure_unique）；
/// 复制共享同一 box（Swift ARC 强引用）；生命周期由 `bk_runtime_cleanup` 兜底回收。
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

/// 释放 LazyRef 的一份 share（归零才回收；进程退出 cleanup 亦兜底）。
@_cdecl("bk_lazyref_destroy")
public func bk_lazyref_destroy(_ h: UnsafeMutableRawPointer?) {
    _bkReleaseShare(h)
}

// MARK: - 默认实例取用（ADR-001，契约 §2.46）

/// 「某类型的默认实例」的**存放位盒**。
///
/// 与 `_BkLazyRefBox` 的差别只在持有物：那边持 wrapper/code/env（一个闭包的调用面），
/// 这边只需要 `initFn` 与字节数 —— 「谁来跑各字段初值」由发射层合成的具名函数承担。
/// 锁与缓存的形态照抄，因为**语义要求相同**：惰性物化、恰一次、地址稳定。
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
///
/// 必须是**独立于盒内锁**的第二级：两个线程同时看到一个空 slot 会各建一个盒，
/// 于是同一个类型物化出**两个实例**、地址不稳定 —— 而地址稳定是契约写明的语义。
/// 建盒之后物化仍归盒内锁管（那才是「恰一次」发生的地方）。
private let _bkGivenSlotLock = NSLock()

/// 取某类型的**默认实例**（ADR-001；契约 §2.46）。`slot` 是发射层定义的静态全局
/// （`@__given_<T>`），首调时由 `initFn` 写入初值，此后永远返回同一地址。
///
/// `init_fn` 的 ABI 与 LazyRef 的 wrapper 同形：`ptr (ptr out) -> ptr` —— 运行时把
/// 分配好的输出缓冲交给它，它写入 T 并返回该缓冲（规避「wrapper 内 alloca 返回栈
/// 地址」的逃逸 UB）。
///
/// ⚠️ **不得持 `_bkGivenSlotLock` 调 `initFn`**：`initFn` 会跑各字段初值，而那些初值
/// 自己可能取用**另一个**类型的默认实例 ⇒ 持锁调用就是一次可复现的自死锁。
/// 故建盒与物化分成两段，中间放锁。
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
    let all = _liveHandles
    _liveHandles.removeAll()
    for u in all { u.release() }
}

/// 进程退出统一回收活动句柄（D0 阶段；D4 改为作用域精确销毁）。
private func _bkAtExitCleanup() { bk_runtime_cleanup() }
private let _bkAtExitToken = atexit(_bkAtExitCleanup)

// MARK: - 字典 / 集合 运行时（#46-D D2）

/// box 内容的类型标签：用于跨后端一致地比较键/元素相等性（与指针身份解耦）。
/// 解决了 `generateStringLiteral` 不为相同文本复用全局（每次新建 `@.strN`）导致的
/// 「字符串键指针在两处不一致」问题——运行时按 tag 解释字节，字符串按 C 串内容比较。
private enum _BkTag: Int32 {
    case i32 = 0
    case double = 1
    case bool = 2
    case str = 3
    case handle = 4
    /// **不透明的 i64 字**（`DE-3b` · `B-2` 新增）。
    ///
    /// 用途单一：`bk_task_join_all` 的聚合结果是一个「成员 ok 载荷」的数组，而
    /// `DE-1` §3.1 把载荷**擦除为 i64 宽度** ⇒ 那些元素是 8 字节的不透明字，
    /// 它们的类型身份**不在本层**（由发射层解释，见 `DE-3c`）。
    /// ⛔ 因此它**不是** `.i32` 也不是 `.handle`：前者的比较宽度是 4 字节，
    /// 后者会让 COW 把字里的位型当成句柄去 retain/release（灾难）。
    case i64 = 5
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

/// 写入键值：将 `val` 处 `valBytes` 字节 memcpy 进新 box（替换则先释放旧值），按
/// (keyBytes, keyTag) 经 `_bkBoxesEqual` 定位既有条目（命中则替换，否则追加）。
/// 越界/空句柄经 `bk_panic` 终止（与解释器一致）。
/// #46-D D4（COW）：写前 `_bkEnsureUnique` 分裂，返回实际被写入的句柄（调用方须写回槽）。
@_cdecl("bk_dict_set")
public func bk_dict_set(
    _ dict: UnsafeMutableRawPointer?,
    _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32,
    _ val: UnsafeRawPointer, _ valBytes: Int32, _ valTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
    let target = _bkEnsureUnique(dict)
    let box = Unmanaged<_BkDictBox>.fromOpaque(target).takeUnretainedValue()
    let kn = Int(keyBytes); guard kn > 0 else { return target }
    let vn = Int(valBytes); guard vn > 0 else { return target }
    let newVal = _bkAllocBox(val, vn)
    if let idx = box.entries.firstIndex(where: { stored in
        _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
    }) {
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

/// 嵌套写路径的**中间层**独占化（字典版，#46-D D4.2.2）：确保 `parent[key]` 处的嵌套句柄
/// 独占，并就地更新该条目的值 box 字节。
///
/// 与 `bk_array_ensure_unique_at` 完全同契约（含「**不**释放旧句柄」的理由：`_bkEnsureUnique`
/// 已把本槽持有的那一份 share 转移给副本，再 release 旧句柄会二次递减 → use-after-free）。
///
/// 前置条件：`parent` 已独占（由自顶向下调用链保证）；键必须存在且值为嵌套句柄。
/// 违反一律 `bk_panic`，让 codegen 缺陷立即暴露而非静默破坏别名语义。
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

/// 释放字典句柄的一份 share（归零才回收；D4.2.3 将按作用域注入）。
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

/// 插入元素（去重）：`elem` 处 `elemBytes` 字节按 (bytes, tag) 经 `_bkBoxesEqual` 判定是否已存在。
/// #46-D D4（COW）：写前 `_bkEnsureUnique` 分裂，返回实际被写入的句柄（调用方须写回槽）。
@_cdecl("bk_set_add")
public func bk_set_add(
    _ set: UnsafeMutableRawPointer?, _ elem: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer? {
    guard let set else { bk_panic("Pini runtime error: set handle is null") }
    let target = _bkEnsureUnique(set)
    let box = Unmanaged<_BkSetBox>.fromOpaque(target).takeUnretainedValue()
    let n = Int(elemBytes); guard n > 0 else { return target }
    if !box.elems.contains(where: { stored in
        _bkBoxesEqual(elem, elemTag, stored.ptr, stored.tag)
    }) {
        box.elems.append((ptr: _bkAllocBox(elem, n), tag: elemTag, bytes: n))
    }
    return target
}

/// 释放集合句柄的一份 share（归零才回收；D4.2.3 将按作用域注入）。
@_cdecl("bk_set_destroy")
public func bk_set_destroy(_ set: UnsafeMutableRawPointer?) {
    _bkReleaseShare(set)
}

// MARK: 容器格式化迭代（#46-D D3：LLVM `print` 对齐解释器 `stringify`）

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
/// （2026-09-07：LLVM `print(d[k])` 缺失键 null 特例已随 G48 三通道对齐移除，
/// 本 shim 无 IR 调用点，保留供运行时内部/测试复用。）
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

/// `*T` 原始指针的 load/store 原语（ `load/store/addressof` 经 runtime `bk_*`）。
/// 语义：`p + offsetBytes` 处读/写标量，字节宽度按类型固定——C ABI 纪律，
/// 不泄漏 Swift 类型。LLVM 端 FFI 当前显式 unsupported（用户决策 D1），
/// 这些入口是 C-ABI 面的完整性预留；解释器端直接用 Swift 指针原语实现同语义。
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

// MARK: - LR-8：F64 最短往返展示（spec「值展示语义」节）

/// `print(F64)` 的文本展示（spec「值展示语义」注的四条形态规则）。
///
/// 单源方式 = 委托宿主标准库：`String(Double)` 即最短往返表示（往返恒等、
/// 定点/指数切换阈值、定点恒带小数点、`e±NN` 两位指数均由标准库保证），
/// 解释器通道 stringify 同样走 `String(Double)`——两后端委托同一语义，
/// 规范权威是 spec 的四条规则，实现零漂移空间。
///
/// 返回 malloc 分配的 NUL 结尾 C 串，**调用方负责 free**（发射的 IR 在
/// printf 消费后调 `@free` 释放；单值即用即弃，无别名）。
@_cdecl("bk_double_to_string")
public func bk_double_to_string(_ v: Double) -> UnsafeMutablePointer<CChar>? {
    return strdup(String(v))
}

// MARK: - G14 FFI: Pini String -> C string (interpreter "cstr" shim parity)

/// Materializes a Swift String as a NUL-terminated, malloc-allocated C
/// string (UTF-8 bytes). Mirrors the interpreter's `cstr` shim exactly:
/// same allocation contract (caller frees), same UTF-8 encoding, same
/// null terminator. The emitted IR calls this for foreign-declared
/// `cstr` symbols — libc has no such function, so it must come from the
/// runtime dylib.
@_cdecl("bk_cstr")
public func bk_cstr(_ s: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return nil }
    return strdup(s)
}

// MARK: - 并发原语的 C ABI 面（`DE-3b` · `B-2` 段：8 个无悔符号）
//
// 「无悔」= 形状与**让出机制**无关。`DE-1` §3 的 10 个符号里，`bk_task_spawn` 与
// `bk_task_yield` 受机制选择影响（2026-09-20 定案**走乙**：让出是**体的 `return`**，
// 不是一次调用）⇒ 已由 `B-1` 标为**待重议**，**不在本段**；其余 8 个
// （`join` · `join_within` · `join_all` · `cancel` · `is_cancelled` · `detach` ·
// `scope_close` · `capabilities`）的形状与机制无关，故本段交付。
//
// 语义**一律对齐解释器腿**，不做第二套解释（出处逐个写明）：
//   `RuntimeOps.joinFuture`        —— 阻塞 join 的三态归一化（`RuntimeOps.swift`）
//   `RuntimeOps.makeJoinAllFuture` —— fail-fast 聚合
//   `FutureValue.closeScope` + `RuntimeOps.flipIfLeaked` —— 唯一有界 override
//   `RuntimeOps.checkCancellation` —— 协作式检查点
//   `FutureValue` 的 `parent` / `children` —— 取消树的形状与传播
//
// ⛔ **两处 `DE-1` 留白，由本段定案并登记**（`HIR 契约` §5.2 注 + 提案 §11 执行记录）：
//   ① `status` 的**取值**（`DE-1` 只写了 `-> status`，没写值）；
//   ② 「**运行时自己产生的 err**」（取消 / 超时 / leaked 聚合）其**载荷**在 C ABI 面
//      **构造不出来** —— 这一层没有值构造器、也没有 stringify。本段的处置：取消身份由
//      `status` 承载、聚合只写 `leaked` 计数，并**明标为待 `DE-3c` 换真实值**。
//   两处都是**补全**（`DE-1` 留了空），**不是**改形状 ⇒ `DE-1` 的符号签名一个都没动。
//
// `status` 取值（本段定案）：
//   `0` = `out` 已写（任务的 `Result`，或聚合结果）
//   `1` = **未取得 `Result`**：任务被取消 / 超时归约 ⇒ 调用方按 `err(CancelError)` 处置
// 非法用法（空句柄 / 越界）**不走 `status`**，一律 `bk_panic` —— 与既有 `bk_array_get` /
// `bk_dict_get` 同一条通道（本仓错误分三通道：panic / status / 值，此处沿用 panic）。

/// 任务盒 —— `FutureValue`（解释器腿）在 C ABI 面的对应物。
///
/// 继承 `_BkBox` 是**刻意的复用**，不是顺手：`_bkRegister` / `_bkReleaseShare` /
/// `bk_runtime_cleanup` 那套「活动句柄登记 + 进程退出兜底回收」对任务句柄**同样成立**
/// ⇒ 任务句柄不必新造第二套生命周期（`DE-1` §2：并发面照抄既有形态，不新造第二套）。
/// ⚠️ 它**不参与 COW**：`cowCopy` 落基类的 `fatalError`，谁也不该对任务句柄发 `ensure_unique`。
private final class _BkTaskBox: _BkBox {
    /// 阻塞 join 的等待 / 唤醒。
    ///
    /// 与 `FutureValue.wait()` 同构，但用 `NSCondition` 而非 `DispatchGroup`：后者为每个
    /// 等待者引入一次队列跳转，而这里的等待者往往就是同一台腿上的发射代码，不需要那层调度。
    /// ⛔ **所有状态改动都在本锁下进行** —— 否则「置位 + broadcast」与「判位 + wait」之间
    /// 会出现丢唤醒的窗口，而那正是阻塞 join 最经典的竞态。
    let cond = NSCondition()

    /// 是否已决（`ok` / `err` 之一已写入）。三槽在**未决**时无意义。
    var resolved = false
    /// 结果三槽（`DE-1` §3.1）：槽 0 = tag（`ok=0` / `err=1`）· 槽 1 = ok 载荷 · 槽 2 = err 载荷，
    /// 载荷一律**擦除为 i64 宽度**。
    /// ⛔ 本层**不解释**它们的语义，只搬运 —— 解释权在发射层（`DE-3c`）。
    var resultTag: Int64 = 0
    var okPayload: Int64 = 0
    var errPayload: Int64 = 0

    /// 协作式取消标志。⛔ 取消**不强杀** —— 与解释器腿一致：worker 在下一个检查点
    /// （`bk_task_is_cancelled`）自行提前结束，故取消是**最终一致**的。
    var cancelled = false

    /// 取消树的边（照 `FutureValue`：**父强持有子、子弱引用父**，避免保留环）。
    weak var parent: _BkTaskBox?
    var children: [_BkTaskBox] = []
}

/// 句柄 → 任务盒。
///
/// 与既有 `bk_array_get` / `bk_dict_get` 同一条路：句柄是 `Unmanaged` 的裸指针，
/// 这里按**具体子类**取回（该先例在 `bk_dict_ensure_unique_at` 等处已经在用）。
private func _bkTaskBox(_ h: UnsafeMutableRawPointer?) -> _BkTaskBox? {
    guard let h else { return nil }
    return Unmanaged<_BkTaskBox>.fromOpaque(h).takeUnretainedValue()
}

/// 写 `Result` 三槽（`DE-1` §3.1 的**唯一**写入点，避免三处各写各的）。
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
///
/// ⛔ **先取快照、解锁、再向下传播** —— 持锁递归会与剪枝的反向加锁（子 → 父）
/// 形成锁序死锁。解释器腿的 `cancel()` 也是这个形状（取快照 → 解锁 → 传播）。
private func _bkTaskCancelBox(_ box: _BkTaskBox) {
    box.cond.lock()
    if box.cancelled { box.cond.unlock(); return }
    box.cancelled = true
    let kids = box.children
    box.cond.broadcast()   // 唤醒阻塞中的 join —— 它读到标志后归一为 err(CancelError)
    box.cond.unlock()
    for k in kids { _bkTaskCancelBox(k) }
}

/// 从父 scope 剪枝（照 `FutureValue.detachFromParent`）。
/// ⛔ 加锁顺序是**子 → 父**，且**不同时持两把锁** —— 与取消传播（父 → 子）方向相反，
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

/// 单任务 join（`bk_task_join` 与 `bk_task_join_within` 的唯一实现体）。
///
/// 归一化照 `RuntimeOps.joinFuture`：
/// - 已决 → 直通它的三槽（`ok` 与任务自己产生的 `err` 都原样搬运）；
/// - 超时 → **取消该任务**并归约为 `err(CancelError)`；
/// - 被取消 → 归约为 `err(CancelError)`（取消优先于结果，与 `FutureValue.wait()` 同序）。
///
/// ⚠️ 无论成败都**剪枝**（`joinFuture` 的 `defer { detachFromParent() }`）：
/// 生命周期已被显式消费 ⇒ 父返回时不该再取消它，长任务的 `children` 也不该无界增长。
private func _bkTaskJoinOne(
    _ box: _BkTaskBox, timeoutMs: Int32?, out: UnsafeMutableRawPointer?
) -> Int32 {
    let completed = _bkTaskWait(box, timeoutMs: timeoutMs)
    defer { _bkTaskDetachFromParent(box) }
    if !completed {
        _bkTaskCancelBox(box)
        _bkWriteResult(out, tag: 1, ok: 0, err: 0)
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
        _bkWriteResult(out, tag: 1, ok: 0, err: 0)
        return 1
    }
    guard resolved else {
        bk_panic("Pini runtime error: task join returned with neither an outcome nor a cancelling")
    }
    _bkWriteResult(out, tag: tag, ok: ok, err: err)
    return 0
}

// MARK: 进程级能力自述

/// 后端能力位图（`DE-1` §3.4 / §6）。**启动时解析一次、此后固化** —— 文件级 `let` 天然满足
/// 纪律 1（不逐调用点判）与纪律 2（进程生命周期内不变）。
///
/// 位值照 `DE-1` §3.4 的定案表（`DE-2b-3` 补遗）：位 0 = **L0 调度** `1` ·
/// 位 1 = **L1 让出** `2` · 位 2 = **L2 抢占** `4`。
///
/// ⛔ **L2 一律不许宣称**（裁定 29：登记不实现）⇒ 这里没有它的位。
///
/// ⭐ **本腿今天只宣称 L0**，这是 `DE-1` §6.2 **纪律 3** 的合规降级，不是遗漏：
/// L1 的定义是「`bk_task_yield` 能**真让出**」，而走乙之下「让出」是**异步体的 `return`**、
/// 由驱动器（发射层）接住 —— 那件**尚未落地**（`DE-3c`）。在它落地之前宣称 L1 就是发假绿。
///
/// ⚠️ 本 target **不依赖 `PiniCore`**（`Package.swift`），故位值在此**重述**；权威定义在解释器腿
/// （`Sources/PiniCore/Interpreter/ConcurrencyCapabilities.swift`）。**重述不漂开**由判据钉住：
/// `ConcurrencyRuntimeABITests` 断言本腿的置位是解释器腿的**子集**（即位定义一致）。
private let _bkCapabilities: UInt32 = 1  // L0（L1 待 `DE-3c`；L2 永不给）

/// 后端能力位图（`DE-1` §3.4）。
@_cdecl("bk_capabilities")
public func bk_capabilities() -> UInt32 { _bkCapabilities }

// MARK: 协作式取消

/// 取消任务（`DE-1` §3.3）：**协作式**，不强杀，于下一检查点生效。
/// 取消沿取消树向下传播，并唤醒正阻塞在该任务上的 join。
@_cdecl("bk_task_cancel")
public func bk_task_cancel(_ h: UnsafeMutableRawPointer?) {
    guard let box = _bkTaskBox(h) else { return }
    _bkTaskCancelBox(box)
}

/// 取消检查点（`DE-1` §3.3）：回答**当前任务**是否已被取消。
///
/// 无参形态对应解释器腿的循环头 / 函数入口 / 睡眠分片检查点
/// （`RuntimeOps.checkCancellation`）。⛔ **无当前任务时回 `0`** —— 与
/// `checkCancellation(nil)`「不做事」同义，也即「没有任务在跑 ⇒ 没有被取消」。
@_cdecl("bk_task_is_cancelled")
public func bk_task_is_cancelled() -> Int32 {
    guard let box = _bkTaskCurrent else { return 0 }
    box.cond.lock()
    let c = box.cancelled
    box.cond.unlock()
    return c ? 1 : 0
}

/// 从父 scope 剪枝、主动退出所有权（`DE-1` §3.3）—— fire-and-forget 的唯一合法出口。
@_cdecl("bk_task_detach")
public func bk_task_detach(_ h: UnsafeMutableRawPointer?) {
    guard let box = _bkTaskBox(h) else { return }
    _bkTaskDetachFromParent(box)
}

// MARK: join

/// 阻塞 join（`DE-1` §3.1，现行唯一形态）。`out` 收 `Result`（三槽，见 `_bkWriteResult`）。
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

/// 带超时的阻塞 join（`DE-1` §3.1）。超时**归约为取消**（与解释器腿 `joinFuture(timeoutMs:)`
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

/// 聚合 join（`DE-1` §3.1），**fail-fast**：任一成员的 `err` 即决定聚合，其余成员被取消
/// （照 `RuntimeOps.makeJoinAllFuture` —— 没人在等它们，就不该继续占线程）。
///
/// ⚠️ **成员的父链不动**：解释器腿用 `onCancel` 做取消联动，而非改写父链 —— 改写会让某个
/// 调用方的返回取消掉**它从未拥有过**的任务。本段同此：只对成员调取消，不 `adopt`。
///
/// ⚠️ 全 `ok` 时聚合载荷是一个**数组句柄**，元素是各成员的 ok 载荷（8 字节不透明字，
/// tag = `.i64`）。⛔ 那些字的类型身份**不在本层** —— 见 `.i64` 的注释。
@_cdecl("bk_task_join_all")
public func bk_task_join_all(
    _ handles: UnsafeMutableRawPointer?, _ count: Int32, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    let n = Int(count)
    guard n > 0 else {
        // 空集合的聚合是**空数组**，不是错误：`joinAll([])` 在解释器腿返回 ok([])。
        let arr = bk_array_create(0)
        _bkWriteResult(out, tag: 0, ok: _bkWord(arr), err: 0)
        return 0
    }
    guard let handles else {
        bk_panic("Pini runtime error: task joinAll got null handles")
    }
    let base = handles.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    // 先把**全部**句柄解出来再动手：fail-fast 会在中途返回，若那时才发现某个成员句柄是空的，
    // 报错点就落在「已经取消了一半」之后，调用方拿到的是半成品世界的解释。
    var boxes: [_BkTaskBox] = []
    boxes.reserveCapacity(n)
    for i in 0..<n {
        guard let b = _bkTaskBox(base[i]) else {
            bk_panic("Pini runtime error: task joinAll got a null member handle at \(i)")
        }
        boxes.append(b)
    }

    var okWords: [Int64] = []
    for (i, box) in boxes.enumerated() {
        // 复用单任务 join：它已含「取消 → err(CancelError)」的归一化，这里不重写一遍。
        if _bkTaskJoinOne(box, timeoutMs: nil, out: out) != 0 {
            for rest in boxes.dropFirst(i + 1) { _bkTaskCancelBox(rest) }
            _bkWriteResult(out, tag: 1, ok: 0, err: 0)
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
        _ = withUnsafePointer(to: &word) { bk_array_set(arr, Int32(i), $0, 8, _BkTag.i64.rawValue) }
    }
    _bkWriteResult(out, tag: 0, ok: _bkWord(arr), err: 0)
    return 0
}

// MARK: scope 收口

/// 关闭范围（`DE-1` §3.3）：收集 **leaked 失败**并上浮 —— `ok(v)` 翻 `err(aggregate)`，
/// 契约里的**唯一有界 override**（照 `FutureValue.closeScope` + `RuntimeOps.flipIfLeaked`）。
///
/// ⚠️ **`out` 是 in-out**：调用方**先**把自己的 `Result` 写进 `out`，本函数在有 leaked 时
/// 把它翻成 `err`。签名只有 `(scope, out)`，而「翻」必须知道被翻的那个值 ⇒ 这是唯一与签名
/// 相容的读法（`DE-1` 未写明，本段定案并登记）。
///
/// 「有界」体现在两处，缺一不可（两条都各有可执行判据）：
/// ① **未完成**的子任务 → 取消，**不计** leaked（它是预期行为，不是失败）；
/// ② **已有 `err` 的 `out` 不被覆盖** —— errors-as-data 已经载着一次失败，
///    覆盖它等于丢掉「到底哪一次失败了」。
///
/// ⛔ 聚合载荷：解释器腿拼的是一句人读的错误消息（要 stringify 各 leaked 值），
/// 而 C ABI 面**构造不出值、也没有 stringify** ⇒ 本段只写 **leaked 计数**，
/// 并明标为待 `DE-3c` 换真实聚合值（见段首 ②）。
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
    _bkWriteResult(out, tag: 1, ok: 0, err: Int64(leaked))
    return 0
}

// MARK: - 并发面的**非导出**入口（`B-2` 判据与 `B-3` 的 `bk_task_spawn` 共用）
//
// ⛔ 这些函数**没有 `@_cdecl`** ⇒ **不是** `bk_*` 导出符号，**不计入** `HIR 契约` §5.2 的清单。
// 它们的存在是为了让「造盒 / 决出 / 认父 / 登记当前任务」这四件事各只有**一个**实现点：
// `B-2` 的判据经它们造出被 join 的对象，而 `B-3` 的 `bk_task_spawn` 落地后将经**同一批**
// 入口做同样的事 —— 于是两条使用方不会各造一套语义。

/// 「当前线程正在跑的任务」的线程本地存放位（`bk_task_is_cancelled` 的无参形态读它）。
///
/// ⚠️ **只存弱引用、不 retain**：当前任务一定同时被别处持有（造它的那一帧、或父的
/// `children`），本存放位只是「谁在跑」的读数面，不参与所有权 —— 若在此 retain，就多出
/// 一条与注册表并行的所有权边，反而要再定义它的释放时机。线程退出由 POSIX 销毁器清位。
private let _bkCurrentTaskKey: pthread_key_t = {
    var k = pthread_key_t()
    let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { _ in }
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

/// 造一个**未决**任务盒并返回句柄。所有权 = 调用方（用完经 `bk_handle_release` 归还）。
func _bkTaskMake() -> UnsafeMutableRawPointer {
    _bkRegister(_BkTaskBox())
}

/// 把任务标记为已决（`ok`）。写入方是任务体（`DE-3c` 接线）。
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
}

/// 把任务标记为已决（`err`）。写入方是任务体（`DE-3c` 接线）。
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
