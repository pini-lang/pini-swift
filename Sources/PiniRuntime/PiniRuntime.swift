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

/// 追加一个元素，返回**新数组**（函数式：输入句柄与其内容都不受影响）。
///
/// 与语言层内建数组方法的 `append` 同契约：追加**不就地**发生，调用方必须用返回值替换原句柄
/// （`元素 = 元素.append(任务)`）。与 `bk_array_set` 的分工是刻意的 ——
/// 后者是**写既有容器**（故写前必须 `_bkEnsureUnique`），前者是**产出新容器**
/// （故天然不与输入共享存储，无需分裂）。
///
/// 元素宽度与 tag 由 codegen 的元素 ABI 传入（与 `bk_array_set` 同一对参数），
/// 故本函数对元素类型无关：新元素按 `elemBytes` 字节装箱，`elemTag` 供嵌套句柄识别。
/// ⚠️ 与 `bk_array_set` 同规：对句柄型内容只做**字节复制（移动语义）**、不 retain ——
/// 别名点 retain 是 codegen 的责任（它按同一个判定发射）。
///
/// ⛔ 空句柄（`nil`）上追加视作**从空数组开始**：与「长度为 0 的容器」行为一致，
/// 而不是报错 —— 调用方拿到的仍是长度为 1 的新数组。
@_cdecl("bk_array_append")
public func bk_array_append(
    _ arr: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer,
    _ elemBytes: Int32, _ elemTag: Int32
) -> UnsafeMutableRawPointer {
    let width = Int(elemBytes)
    guard width > 0 else {
        bk_panic(
            "Pini runtime error: bk_array_append needs a positive element width (from the codegen element ABI)")
    }
    let source = arr.map { Unmanaged<_BkArrayBox>.fromOpaque($0).takeUnretainedValue() }
    let count = source?.elements.count ?? 0
    let grown = _BkArrayBox(count: count + 1)
    if let source {
        for i in 0..<count {
            grown.tags[i] = source.tags[i]
            grown.widths[i] = source.widths[i]
            guard let elem = source.elements[i], source.widths[i] > 0 else { continue }
            grown.elements[i] = _bkAllocBox(elem, source.widths[i])
            _bkRetainIfHandle(elem, source.tags[i])
        }
    }
    grown.elements[count] = _bkAllocBox(src, width)
    grown.tags[count] = elemTag
    grown.widths[count] = width
    return _bkRegister(grown)
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
///
/// ⭐ 让出的观测汇总行（`DE-6a` §3.6）挂在这里 —— 经**既有**的退出钩子那条路径，⛔ 不新起
/// 退出路径。顺序放在回收之前：回收会碰句柄表，而汇总只读一个计数器，先打完更不容易被
/// 回收路径上的意外打断。
private func _bkAtExitCleanup() {
    _bkReportYields()
    bk_runtime_cleanup()
}

private let _bkAtExitToken = atexit(_bkAtExitCleanup)

/// 保证进程退出钩子**真的被登记**。
///
/// ⛔ 这一句不是仪式。Swift 的全局 `let` 是**惰性**初始化：`atexit(_bkAtExitCleanup)` 只有在那句
/// 声明被**求值**时才发生，而它此前**没有任何读者** ⇒ 那个退出钩子**一次也没有生效过** ——
/// 文件看着对，行为上不存在（本仓最防的一类形态）。★ 它是 `DE-6b` 落地观测通道时逐处实测发现的：
/// 让出计数打了 0 行，顺着读下去才发现登记本身没发生。
///
/// ⚠️ 由运行时的**首个真实并发入口**触发（`bk_task_spawn`）。⇒ 如实登记一条边界：**不用任务的
/// 程序**不会走到这里，故那条「活动句柄兜底回收」对它们仍然不生效（本批不改，只登记）。
private func _bkEnsureProcessExitHook() {
    _ = _bkAtExitToken
}

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

// MARK: - G15: whole-file read for the LLVM leg

/// `readFile(path)`: the whole file as a NUL-terminated, malloc-allocated C
/// string (UTF-8), or NULL when it cannot be read (missing, unreadable, or not
/// valid UTF-8). The emitted IR calls this instead of `fread`-ing into a fixed
/// buffer; see `IOLimits` for why the cap went away.
///
/// Why the runtime and not emitted IR: reading a whole file needs a buffer
/// sized from the file, and under LLI's JIT the size is not knowable before the
/// read (`fseek` / `ftell` / `fstat` are unreliable there). A chunked
/// grow-and-retry loop would be expressible in IR, but this is the same shape
/// the other `bk_` shims already use, so there is one place that knows the
/// allocation contract instead of two.
///
/// Allocation contract: `strdup`, **caller frees** -- identical to `bk_cstr`
/// and `bk_double_to_string`. ⚠️ The emitted IR does not free string values
/// anywhere today (it has exactly one `free` call, for a print temporary), so
/// this adds no new *class* of leak; it does mean a large read stays resident
/// for the process lifetime on the LLVM leg. The interpreter leg is unaffected
/// (it returns a Swift `String`).
///
/// Decoding uses the **same** Foundation call as the interpreter's arm, so the
/// two channels agree byte for byte rather than merely both being "UTF-8-ish".
@_cdecl("bk_read_file")
public func bk_read_file(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let path else { return nil }
    guard let text = try? String(contentsOfFile: String(cString: path), encoding: .utf8) else {
        return nil
    }
    return strdup(text)
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
// 语义**一律对齐解释器后端**，不做第二套解释（出处逐个写明）：
//   `RuntimeOps.joinFuture`        —— 阻塞 join 的三态归一化（`RuntimeOps.swift`）
//   `RuntimeOps.makeJoinAllFuture` —— fail-fast 聚合
//   `FutureValue.closeScope` + `RuntimeOps.flipIfLeaked` —— 唯一有界 override
//   `RuntimeOps.checkCancellation` —— 协作式检查点
//   `FutureValue` 的 `parent` / `children` —— 取消树的形状与传播
//
// ⛔ **两处 `DE-1` 留白，由本段定案并登记**（`IR 契约` §5.2 注 + 提案 §11 执行记录）：
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

/// 任务盒 —— `FutureValue`（解释器后端）在 C ABI 面的对应物。
///
/// 继承 `_BkBox` 是**刻意的复用**，不是顺手：`_bkRegister` / `_bkReleaseShare` /
/// `bk_runtime_cleanup` 那套「活动句柄登记 + 进程退出兜底回收」对任务句柄**同样成立**
/// ⇒ 任务句柄不必新造第二套生命周期（`DE-1` §2：并发面照抄既有形态，不新造第二套）。
/// ⚠️ 它**不参与 COW**：`cowCopy` 落基类的 `fatalError`，谁也不该对任务句柄发 `ensure_unique`。
private final class _BkTaskBox: _BkBox {
    /// 阻塞 join 的等待 / 唤醒。
    ///
    /// 与 `FutureValue.wait()` 同构，但用 `NSCondition` 而非 `DispatchGroup`：后者为每个
    /// 等待者引入一次队列跳转，而这里的等待者往往就是同一台后端上的发射代码，不需要那层调度。
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

    /// 协作式取消标志。⛔ 取消**不强杀** —— 与解释器后端一致：worker 在下一个检查点
    /// （`bk_task_is_cancelled`）自行提前结束，故取消是**最终一致**的。
    var cancelled = false

    /// 取消树的边（照 `FutureValue`：**父强持有子、子弱引用父**，避免保留环）。
    weak var parent: _BkTaskBox?
    var children: [_BkTaskBox] = []

    // MARK: 任务体（`B-3` 的 `bk_task_spawn` 记入）

    /// 体的 wrapper / code / env（`DE-1` §3.1 的实参，原样存下）。
    var wrapper: UnsafeMutableRawPointer?
    var code: UnsafeMutableRawPointer?
    var env: UnsafeMutableRawPointer?

    /// 载荷类型描述（`DE-1` §3.1 的 `elemBytes` / `elemTag`）—— 本层**不解释**它们，
    /// 与三槽同理：只搬运，解释权在发射层（`DE-3c`）。
    var elemBytes: Int32 = 0
    var elemTag: Int32 = 0

    /// ⭐ **体是否已让出**（wrapper 返回非 `0`）。
    ///
    /// ⛔ 它**不是**结束状态 —— 让出之后 `future` 仍**未决**，由**续跑方**决出（`DE-3c`）。
    /// 记它的用途只有一个：让「体让出过」这件事可被**外部观测**（判据与诊断），
    /// 否则本层的让出是**静默**的，而静默正是本仓反复消灭的东西。
    var suspended = false

    /// 体已经跑过（无论跑完还是让出）。防同一句柄被跑第二次。
    var bodyStarted = false

    // MARK: 可恢复帧（`DE-6b`）

    /// 指向自己的句柄。⭐ 只为**续跑**存在：决出方手里是「等待者盒子」，而起一条线程重入体需要
    /// 的是**句柄**（`_bkTaskRunBody` 的实参）⇒ 没有它就得反查登记表。
    var selfHandle: UnsafeMutableRawPointer?

    /// 帧里**局部槽**的块表 —— `bk_task_slot` 每次取槽追加一块，体真跑完（或让出态被取消）时
    /// 一次性交还。
    ///
    /// ⛔ **为什么不一次性算好整块**：发射层**没有**「类型 → 字节数」的通用能力（容器元素那两张
    /// 表都只枚举有限类型、聚合一律拒绝），若在 Swift 侧另算一套布局，就成了「同一件事两处各算
    /// 一次」—— 一旦不一致就是**静默错位的帧**，比崩溃难查得多。⇒ 尺寸由 IR 侧的常量表达式自己
    /// 算，本层只管搬运。
    var frameChunks: [UnsafeMutableRawPointer] = []

    /// `bk_task_slot` 的**重放游标**：每次进入体都归零（见 `_bkTaskRunBody`）。
    ///
    /// ⭐ 这不是优化，是**续跑正确性的前提**：让出时体从栈返回、槽指针全部丢失，续跑靠重新执行
    /// 同一段取槽代码把它拿回来 ⇒ 只有「第 n 次进入的第 k 次取槽必得同一地址」，续跑才拿得到
    /// 上次那些槽。
    var frameCursor = 0

    /// 我已经把控制流交还出去、正等 `awaiting` 决出。⛔ 它**不是**结束状态 —— `future` 仍**未决**。
    ///
    /// 弱引用：`awaiters` 反向持强引用，两者不成环（与 `parent` / `children` 同一套记账）。
    weak var awaiting: _BkTaskBox?

    /// 正在等我决出的那些任务 —— 我决出或被取消时逐个**续跑**它们。
    var awaiters: [_BkTaskBox] = []

    /// 体**正在跑**。防同一句柄被并发进入两次：续跑是**另一条线程**，与首次进入可能交错。
    var running = false

    /// 「决出方已经来叫过，但那时我还没让出」的**记号**（见 `_bkTaskResume`）。
    /// ⛔ 它关的是一扇**丢唤醒**的窗，不是缓存：没有它，「等我的任务」会在窄缝里永远不再被调度。
    var resumePending = false

    /// ⭐ **我此刻在就绪队列里等着被挑**（`Q-4`）。
    ///
    /// ⛔ 它与 `suspended` **不是同一件事的两面**：`suspended` 说「体交出了控制流」，
    /// 而本位置说「它已经交给策略层、策略层还没挑它」—— 一个已决出**待挑**的任务两者**同时**成立。
    /// ⚠️ 它正是 `bk_task_state` 那一格里「**可跑**」的落点（裁定 50 的四态之一），
    /// 而这个身份**是本路新引入的**：此前的驱动形态里没有「排队等挑」这一段
    /// ⇒ 四态表上那个成员在此之前**没有承载**。
    /// 由**入队**写、由**出队**（挑走）清。
    var queued = false

    /// 帧是否已交还。幂等守卫 —— 「跑完」与「让出态被取消」两条路径都会来收，而**只能收一次**。
    var frameReleased = false
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
/// 形成锁序死锁。解释器后端的 `cancel()` 也是这个形状（取快照 → 解锁 → 传播）。
private func _bkTaskCancelBox(_ box: _BkTaskBox) {
    box.cond.lock()
    if box.cancelled { box.cond.unlock(); return }
    box.cancelled = true
    let kids = box.children
    let wasSuspended = box.suspended
    box.cond.broadcast()   // 唤醒阻塞中的 join —— 它读到标志后归一为 err(CancelError)
    box.cond.unlock()
    // `DE-1` §3.2.2 的第二条连带：**让出态被取消 ⇒ 体不会再被进入** ⇒ 帧必须由运行时交还。
    // ⛔ 落地顺序有讲究：先把取消位置起（上面的锁内），再交还帧 —— 反过来的话，一条已经在
    // 「续跑」路上的线程会带着已释放的帧进入体，而那是**静默内存错**，不是崩溃。
    if wasSuspended { _bkTaskReleaseFrame(box) }
    // 等我的那些任务：我已经被取消 ⇒ 它们的等待应当**现在**归约为 `err(CancelError)`，
    // 而不是等我（永不）决出。它们醒来后走的是 `bk_task_await` 的「已决 ⇒ 直线取值」那条路。
    _bkTaskResumeAwaiters(box)
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
/// ⭐ **本后端自 `DE-6b` 起宣称 L0 + L1**。为什么此刻才敢宣称：L1 的定义是「`bk_task_yield`
/// 能**真让出**」，而走乙之下「让出」是**异步体的 `return`**、由驱动器接住 —— 那件事与申报位
/// **同批落地**：发射层在异步体的语句根 `await` 处交出控制流（帧 + 续跑点），运行时由**决出方**
/// 续跑。⛔ 此前「只宣称 L0」是合规降级、不是遗漏；如今反过来 —— 若再宣 L0 就是**低报**，
/// 而低报同样会让判据失真（能力位的用处正是让各后端可被对照）。
///
/// ⚠️ 本 target **不依赖 `PiniCore`**（`Package.swift`），故位值在此**重述**；权威定义在解释器后端
/// （`Sources/PiniCore/Interpreter/ConcurrencyCapabilities.swift`）。**重述不漂开**由判据钉住：
/// `ConcurrencyRuntimeABITests` 断言本后端的置位是解释器后端的**子集**（即位定义一致）。
/// 能力位的**位值**（`DE-1` §3.4 定案表，`DE-2b-3` 补遗）。命名而非散落字面量：
/// `bk_task_yield` 的答案就取自 L1 位（见该函数），两处必须是**同一个**位。
private enum ConcurrencyTierBits {
    static let dispatch: UInt32 = 1  // L0 调度
    static let yield: UInt32 = 2     // L1 让出
}

private let _bkCapabilities: UInt32 =
    ConcurrencyTierBits.dispatch | ConcurrencyTierBits.yield  // L0 + L1（L2 永不给）

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
/// 无参形态对应解释器后端的检查点 `RuntimeOps.checkCancellation` —— 该后端在岗的是
/// **异步体入口**与 **`joinAll` 聚合**；该后端 `sleep` 的检查点**有意留空**（单线程、
/// 不持任务句柄），按片真查取消位的是发射层的 `bk_sleep`。⛔ 各后端都**没有**
/// 「循环头」检查点（2026-09-21 逐处实测）。⛔ **无当前任务时回 `0`** —— 与
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

// MARK: spawn 与让出（`B-3` —— `DE-1` §3 里仅有的两个**受形状影响**的符号）

/// 任务体的 wrapper 调用形态（`B-1` 订正后的**两态**形状）。
///
/// ⛔ **与 LazyRef / 给定块的 wrapper ABI 不同形，这是刻意的**：那条统一 ABI 的返回是
/// **单个 `ptr`**，**表达不了「跑完 / 已让出」两态**，而两态正是让出在走乙之下的全部内容
/// （`B-1` 的订正结论，见 `DE-1` §3.1 的订正注）。⇒ 本族必须自带**一个状态位**。
///
/// - Returns: `0` = 体跑到底（三槽已写）· 非 `0` = **体已让出**（`out` **未**写，
///   控制流已交还驱动器）。⇒ 续跑入口是 `DE-3c` 的事，本段**不**替它定。
private typealias _BkTaskBody = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32

/// `Result` 三槽的字节数（`DE-1` §3.1：tag + ok + err，载荷一律擦除为 i64 宽度）。
private let _bkResultSlotsBytes = 24

/// 派发任务体（`DE-1` §3.1）。
///
/// ⭐ **「调用即派发」**（裁定 37 糖读法）：本符号是**一次异步调用的落点** ——
/// 它的实参就是该次调用的实参 ⇒ **它自己另无「形状」待定**。
///
/// 三件事按序做完再返回，故调用方**立刻**拿到句柄（急切派发）：
/// ① 建盒 · ② **认父**（父已取消 ⇒ 新子立即取消，见 `_bkTaskAdopt`）· ③ 起线程跑体。
///
/// ⚠️ **线程归本后端的「原语层」**（`DE-1` §4：让出 / 恢复 · 续体保存 · 任务树 · 取消树 = 原语）。
/// **策略层**（队列 / 优先级 / 归约阈值 / **选择下一个任务**）**不住在这里** —— 那是 Pini 值、
/// 经 IR 执行（裁定 28）。本函数只回答「体在哪条 OS 线程上开始跑」，不回答「下一个跑谁」。
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
    let thread = Thread { _bkTaskRunBody(h) }
    thread.start()
    return h
}

/// 体的一次运行：登记当前任务 → 调 wrapper → 按返回的**两态**收尾。
///
/// ⭐ `DE-6b` 起它同时是**续跑**的入口（首跑与续跑走同一条路径，这是「不需要第二个入口函数」
/// 的落地处，`DE-1` §3.2.2）。
///
/// ⚠️ 归出（让出）时**不**决出 `future` —— 那是续跑方的责任；本层在这里做的是**让这件事
/// 可观测**（`box.suspended`）并为观测面计数。
private func _bkTaskRunBody(_ h: UnsafeMutableRawPointer) {
    guard let box = _bkTaskBox(h), let wrapper = box.wrapper else { return }
    let restore = _bkTaskEnter(h)
    defer { restore() }
    box.cond.lock()
    // ⛔ 这道闸从 L0 的「体已跑过就返回」放开为「**让出态允许续跑**」。
    // 不放开，续跑会被这里**静默吞掉**，而症状是「等待方永久阻塞」——不是崩溃，所以更需要闸本身
    // 开门见山。今天（L0）体从不中途返回，故放开的只是那条到不了的路径。
    let admitted = (!box.bodyStarted || box.suspended) && !box.frameReleased
    let concurrent = box.running
    box.bodyStarted = true
    box.suspended = false
    if admitted && !concurrent { box.running = true }
    // ⭐ 取槽游标归零 ⇒ 帧槽地址可重放（见 `frameCursor` 的注释）。
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
        // 真跑完才交还帧（`DE-1` §3.2.2）；先读三槽再交还，免得交还后又去读它。
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
    // ⭐ 关上那扇丢唤醒的窗：若「决出方」在我交还控制流**之前**就已经来叫过（`resumePending`），
    // 它当时看到的还是一个没让出的任务、因而没起线程 ⇒ 记号的兑现责任落在这里。
    let resumeNow = box.resumePending
    box.resumePending = false
    box.cond.broadcast()
    box.cond.unlock()
    if resumeNow {
        // `Q-4`：兑现方式由「起一条新线程重入体」改为「**入队**」——「谁跑下一个」归策略层，
        // ⛔ 不在这里抢跑。⚠️ 这一处与 `_bkTaskResume` 的那一处是**同一个改道的两侧**：
        // 漏掉任何一侧，被漏的那条路上挑选顺序就退回决出顺序。
        if _bkTaskOffer(box) { _bkTaskScheduleDrain() }
    }
}

/// 问后端**能否让出**（`DE-1` §3.2.1 订正后的**查询**语义）。
///
/// ⛔ 它**不执行**让出 —— 走乙之下让出是**异步体的 `return`**（`DE-1` §3.2.1），
/// 由驱动器接住。调用它只回答一个问题：**这次让出能不能真的发生**。
///
/// - Returns: `1` = 能真让出 · `0` = **合规降级** ⇒ 本次等待按**占用**处理。
///   ⛔ `0` **不是错误**（`DE-1` §6.2 纪律 3：无合格版本则降级，不失败）。
///
/// ⭐ **答案取自 L1 位，与解释器后端同源**：解释器后端的对应物就是
/// `GCDScheduler.capabilities.supports(.yield) ? 1 : 0`（`Scheduler.swift`）。
/// ⇒ 各后端在这一位上由**同一条规则**决定，不会各说各话 —— 这正是 `DE-1` §3.2 要求的
/// 「各后端必须在这一位上一致」。
///
/// ⭐ **`DE-6b` 起本后端宣称 L1**（`_bkCapabilities` 含 `yield` 位）⇒ 本函数回 `1`。
/// 它之所以能宣称，是因为让出的**执行路径**真的接上了：发射层在异步体的语句根 `await` 处
/// 交出控制权（帧+续跑点），运行时由决出方续跑 —— 即「申报」与「可用」同批成立。
@_cdecl("bk_task_yield")
public func bk_task_yield() -> Int32 {
    (_bkCapabilities & ConcurrencyTierBits.yield) != 0 ? 1 : 0
}

/// 帧的取用（`DE-6b`）：**一个概念、两种用途**，两者的区别只在 `bytes`。
///
/// - `bytes > 0` —— **派发点用**：新建一块属于运行时的帧（`bytes` 字节、**已清零**），并登记
///   所有权。⛔ 清零不是顺手：帧的第一个字是**续跑点**（`0` = 首次进入），清零即把「首次进入」
///   写进去，发射层因而不必额外发一条 `store`。
/// - `bytes == 0` —— **体内用**：取当前任务的帧。⛔ 无论第几次进入都是**同一块**，
///   这也正是「续跑能拿回上次的上下文」的地方。
///
/// ⭐ 为什么由运行时分配、而不是让派发点 `malloc`（`DE-1` §3.2.2：`env` 升格为**体的持久帧**）：
/// 帧的生命周期跨让出，而「让出态被取消 ⇒ 体不会再被进入 ⇒ 帧必须由**运行时**释放」
/// 是同一节的明文连带 ⇒ 所有权必须在运行时这一侧，否则那条路径上没有人能安全地收这块内存。
/// ⚠️ 由此**取消了一处旧分工**：`env` 原先由体 wrapper 在跑完后 `free`，自 `DE-6b` 起改由
/// 运行时在真跑完时交还 —— 两处都释放会 double free，故 wrapper 侧那一条已删。
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

/// 帧内取一个**局部槽**（`DE-6b`）。
///
/// ⭐ **可重放**是它的全部要点：让出时体从栈返回、槽指针全部丢失，续跑靠重新执行同一段取槽
/// 代码把它们拿回来 ⇒ 本函数必须保证「同一体第 n 次进入的第 k 次调用得到同一地址」，故游标在
/// **每次进入体时归零**（`_bkTaskRunBody`），命中已发的块就原样返回。
///
/// ⚠️ 尺寸由**调用方**（发射层）给：本层没有类型知识，也不该有（见 `frameChunks` 的注释）。
/// ⚠️ 如实边界：对齐按 **8 字节** —— 帧与各块都以 8 对齐，故凡对齐要求 ≤ 8 的类型都对；
/// 超 8 对齐的类型**今天没有通道**（不静默降级：发射层侧由类型表把关）。
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

/// **可让出的等待**（`DE-6a` 定案 · `DE-6b` 落地）。
///
/// 与 `bk_task_join` 的唯一区别是它**可以拒绝阻塞**：
/// - `0` / `1` —— 归一化与 `bk_task_join` **同一套**（`0` = 三槽已写 · `1` = 未取得 `Result`，
///   取消 / 超时归约）；
/// - ⭐ `2` —— **本次会让出**：`out` **一个字节都不许写**，控制流交还驱动器，调用方据此返回非 `0`
///   且**不得交还帧**。
///
/// ⛔ **谁决定「这次会让出」**：编译期事实。发射层**只在**「异步体 · 语句根 · `form = awaits`」
/// 处发射本符号，其余位置（含同步体的 `wait`）一律沿用 `bk_task_join` —— 因为「调用方是不是
/// 异步体」运行时刻判不出来（`DE-1` §3.1 末尾那处补注）。本函数因而**不校验**这个前置。
///
/// ⭐ **登记在等待对象上**（`target.awaiters`）而不是只记在自己身上：决出方是**被等的那个**，
/// 只有它知道「现在该把谁叫醒」。登记与「对象是否已决」的判定**在同一把锁下**完成 ——
/// 否则「登记」与「决出」之间会有一个丢唤醒的窗口，而症状是**永久阻塞**。
@_cdecl("bk_task_await")
public func bk_task_await(
    _ handle: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let target = _bkTaskBox(handle) else {
        bk_panic("Pini runtime error: task await got a null handle")
    }
    // ⛔ 两处**合规降级**（都不是错误）：不在任何任务里 ⇒ 没有「当前任务」可让出；
    // L1 位缺席 ⇒ 后端不能真让出（`DE-1` §6.2 纪律 3：降级，不失败）。
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

/// `sleep(ms)` 的原语层落点 —— **按片睡**，每片醒来查一次取消位。
///
/// ⛔ 为什么不做成 libc 的睡眠：解释器后端的对应物（`RuntimeOps.builtinSleep`）是把长睡
/// 拆成小片、每片回来查一次取消 / 超时，因此「取消一个正在睡的任务」在**一片之内**生效，
/// 而不是等它睡完。一条直通的 libc 睡眠会让各后端在**取消时机**上分岔，而那个分岔在
/// 只跑成功的样板里看不出来。睡眠本就属原语层（`DE-1` §4：让出 / 恢复 / 续体保存归宿主），
/// 故它住在这里、而不是被降载成一条 libc 调用。
///
/// ⚠️ **一处如实的边界**：解释器后端在检查点发现取消时是**抛**（abort 体），而 C ABI 面
/// 没有异常通道 ⇒ 本函数只能**提前结束睡眠**，体随后仍会跑完。差别只在「取消后体还能跑几步」，
/// 而**等待侧的归约是同一套**：盒子已被置取消，`bk_task_join` 照旧返回 `status = 1`
/// （⇒ `err(CancelError)`）。体被真正中断要等发射层的检查点接线，属后置批次。
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

/// 带超时的阻塞 join（`DE-1` §3.1）。超时**归约为取消**（与解释器后端 `joinFuture(timeoutMs:)`
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
/// ⚠️ **成员的父链不动**：解释器后端用 `onCancel` 做取消联动，而非改写父链 —— 改写会让某个
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
        // 空集合的聚合是**空数组**，不是错误：`joinAll([])` 在解释器后端返回 ok([])。
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
/// ⛔ 聚合载荷：解释器后端拼的是一句人读的错误消息（要 stringify 各 leaked 值），
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
// ⛔ 这些函数**没有 `@_cdecl`** ⇒ **不是** `bk_*` 导出符号，**不计入** `IR 契约` §5.2 的清单。
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
    let box = _BkTaskBox()
    let h = _bkRegister(box)
    box.selfHandle = h
    return h
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
    // `DE-6b`：决出方**续跑**在等我的那些任务 —— 这是 L1 的驱动侧（`DE-6a` §3.2.2 用户选定
    // 的「决出方触发」）。放在锁外：续跑会起线程，不该持锁做。
    _bkTaskResumeAwaiters(box)
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
    _bkTaskResumeAwaiters(box)
}

// MARK: 可恢复帧与续跑（`DE-6b`）

/// 运行时**自有**帧的地址集 —— 由 `bk_task_frame(bytes > 0)` 登记，交还时摘除。
///
/// ⚠️ 这张表存在的理由是**归属**：帧必须由运行时释放（让出态被取消那条路径上没有别人能安全
/// 地收它），而 `env` 也可能是**调用方直接给的**（进程内单测就这么做：把 Swift 对象的指针当作
/// 体的观测箱传进来）。⛔ 无条件释放后者会立即崩溃 ⇒ 只有本表里登记过的才释放。
private var _bkOwnedFrames: Set<UInt> = []
private let _bkOwnedFramesLock = NSLock()

private func _bkAdoptFrame(_ p: UnsafeMutableRawPointer) {
    _bkOwnedFramesLock.lock()
    _bkOwnedFrames.insert(UInt(bitPattern: p))
    _bkOwnedFramesLock.unlock()
}

/// 交还一个任务的全部帧内存（`env` 那一块 + `bk_task_slot` 发出的各块）。幂等。
///
/// ⭐ 两条路径都会来这里：**真跑完**（`_bkTaskRunBody` 的 `status == 0` 分支）与
/// **让出态被取消**（`_bkTaskCancelBox`）—— `DE-1` §3.2.2 的两条明文连带。
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
    _bkOwnedFramesLock.lock()
    let owned = _bkOwnedFrames.remove(UInt(bitPattern: env)) != nil
    _bkOwnedFramesLock.unlock()
    if owned { env.deallocate() }
}

/// 取走等待者快照并逐个交给队列（先快照、解锁、再动作 —— 与取消传播同一条定式：
/// 持锁递归会与反向加锁形成死锁）。
///
/// ⭐ **改道落在这里**（本段的「决策点不再直接重入体」）：这个函数是**一次决出的全部后果**，
/// 而它现在做的是「把这一批交给策略层」，⛔ 不是「把这一批跑掉」。
///
/// ⭐⭐ 顺序是「**先全部入队、再请挑选**」，两步分开 —— 这不是优化，是「顺序由策略决定」
/// 成立的**前提**：一次决出会**同步地、依次**唤醒所有等它的任务，若让**每个**唤醒各自去请挑选，
/// 第一趟挑选就可能发生在这批里**还有任务没入队**的时刻 ⇒ 第一个醒来的被挑走
/// ⇒ 挑选顺序退回**决出顺序**，策略层**无选择可言**。
/// ⚠️ 这条与解释器后端同源（那个后端为此把登记改成「按被等的未来并批」）；本后端的快照**本来就是整批**，
/// 故只需把「两步分开」写对。
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

/// 让一个**已让出**的任务接着跑 —— 在改道之后，「接着跑」= **交给策略层的队列**（`Q-4`）。
///
/// ⛔ **本函数不再起线程**：那正是本段改掉的东西。此前它 `Thread { _bkTaskRunBody(h) }`
/// 直接重入体 ⇒ 顺序完全由**决出顺序**决定，策略层没有任何可挑的余地
/// （与解释器后端在 `Q-3` 之前同构）。⇒ 「调度器可替换」这句话在各后端上从此有**对象**。
///
/// ⛔ 两道守卫各挡一件事：`resolved` / `cancelled` 挡「已经收口了，别再排队」。
///
/// ⭐⭐ **`resumePending` 仍然是这里最要紧的一行，它不是优化**：等待方登记「我在等谁」与它把
/// 自己标成「已让出」**不是同一个原子步** —— 中间隔着体的返回。若被等方恰好在这条缝里决出，
/// 「谁来叫醒它」这一问就会落空：决出方看到的还是一个**没让出**的任务，于是既不入队、
/// 也不留记号 ⇒ **等待方永远不再被调度**。⚠️ 症状是**永久阻塞**而不是崩溃，所以这个窗口
/// 必须由记号关掉，不能靠「缝很窄」侥幸：让出态未到就先**挂记号**，等体交还控制流时自取自跑。
///
/// - Returns: 它这次**真的入了队** ⇒ `true`（没让出而只挂了记号 ⇒ `false`，那不是「没接上」）。
private func _bkTaskResume(_ box: _BkTaskBox) -> Bool {
    box.cond.lock()
    let alive = !box.resolved && !box.cancelled
    let wasSuspended = box.suspended
    if alive && !wasSuspended { box.resumePending = true }
    box.cond.unlock()
    guard alive, wasSuspended else { return false }
    return _bkTaskOffer(box)
}

// MARK: 就绪队列的驱动面（`Q-4`：决出 ⇒ 入队，由策略层决定谁跑）
//
// ⛔ 本段与解释器后端**同形**（对应物在 `IRExecutor` 的同名一节）—— 决出不再直接续跑体，
// 而是把任务**交给策略层的队列**，再由挑选循环按策略给的顺序推进。
// ⚠️ 各后端在**句柄承载**上不同，这是架构使然、⛔ 不是偏差：
//   · 解释器后端的任务是宿主对象，塞不进语言层的 `*U8` ⇒ 用**整数句柄 + 一张映射表**；
//   · LLVM 后端的任务句柄**本来就是一个不透明指针**（造盒时登记所得），与语言层的 `*U8` 同形
//     ⇒ **零映射表**：直接把那个指针交给策略层，拿回来即任务。
//   ⇒ 「推进一次」的跨后端契约定的是**语义**，明文不固定各后端的入口形状。

/// 策略层的绑定记录（裁定 **57** 取甲：**运行时持挑选循环**，发射层交出**可调用的入口**）。
///
/// ⭐ **布局即 ABI** —— 三个机器字：策略实例 · 「收下」入口 · 「选择下一个任务」入口。
/// 发射层在派发点就地构造这三个字、把地址交进来。⛔ 本层**不解释**第一个字是什么
/// （它是默认实例的盒指针，本层只把它原样回传给那两个入口）。
/// ⚠️ 为什么不写成三个独立实参：一个记录指针是**一处**形状，将来加一格只动那一处；
/// 且它与「绑定记录」这个已裁的形态**同名同实**。
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
///
/// ⚠️ **「空」与「缺陷」必须分开**（与解释器后端同一条纪律）：前者是正常状态（刚建好的队列
/// 就是空的），后者是策略给了一个**从没发出去过**的句柄。混成一个读数就会把缺陷读成
/// 「暂时没活」⇒ 于是**静默地什么都不做** —— 那是本引擎最不能出的结果。
private enum _BkReadyTake {
    case task(UnsafeMutableRawPointer)
    case empty
    case unknown(UnsafeMutableRawPointer)
    /// 策略层答不出来（没绑、或答了个不是句柄的东西）。
    case defect(String)
}

/// 就绪队列 —— 元素是**任务盒句柄**（造盒时登记所得的那个裸指针）。
///
/// ⚠️ 写入方是**决出方所在的那条线程**（决出 ⇒ 入队），读取方是挑选循环 ⇒ 由 `_bkReadyLock`
/// 守护。⛔ **不是「反正单线」**：「同族的既有状态已有隔离」这条**推不到**新状态上。
private var _bkReadyQueue: [UnsafeMutableRawPointer] = []
private let _bkReadyLock = NSLock()

/// 「趟」的两笔账（照解释器后端）：**有人要挑** · **已经有一趟在挑**。
///
/// ⚠️ 为什么需要它们：一批任务**全部入队之后**才请挑选循环，但请挑选这件事本身可能落在
/// **另一条线程**上（同一时刻可能有多批）⇒ 用「已有循环在跑就只记一笔」把它收成
/// **同一时刻只跑一趟**，那一笔由收工的那趟兑现（见 `_bkTaskDrain` 尾部的对账）。
private var _bkReadyRequested = false
private var _bkReadyScheduled = false
private var _bkReadyDraining = false

/// 进程内最近一次的绑定 —— 挑选循环用它问策略。
///
/// ⚠️ **今天只有一个调度实例**（预置那份，或用户替换的那一份）⇒ 「用哪份绑定」不构成问题。
/// ⛔ 本层**不做**「按调度器分组的多队列」—— 那是设计里另立的一段，今天**无对象**
/// （登记在案，⛔ 不在本段顺手做）。
private var _bkSchedBinding: _BkSchedBinding?

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

/// 把调度器绑定交给运行时（乙段）。
///
/// - Parameters:
///   - handle: 该次派发得到的任务句柄 —— ⚠️ **今天只作校验用**：绑定存在**运行时**那一份上
///     （见 `_bkSchedBinding` 的注释），⛔ 不逐任务存。理由是今天只有一个调度实例，
///     逐任务存会得到一个**没有读者**的字段，而那正是本仓反复消灭的东西。
///   - binding: 指向绑定记录的指针（布局见 `_BkSchedBinding`）。⭐ **传空即解绑** ——
///     这条路径不是为生产代码留的，而是为判据留的：替身策略住在一个测试对象里，
///     它一旦释放而绑定还在，后续任何入队都会调到一个**悬垂的函数指针**。
/// - Returns: `0` = 已接受（或已解绑）。⛔ 今天**不定义**别的取值 —— 语义未裁 ⇒ 不作承诺。
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

/// 任务的可观测态（裁定 **50** 的**四态**；丙段）。
///
/// ⚠️ 一经采纳即成**可观测承诺**（受「使用者会依赖一切可见行为」约束）⇒ 改它须走**破坏性**流程。
/// ⛔ 与「能力位查询」**不同族**：那是**可叠加的位图**，这是**互斥的状态**。
///
/// ⭐ 四态与盒子上那几个位的关系（三处**如实登记**的空洞，都在下表的脚注里）：
/// `3` 已决 = 有结果或其取消已归约 · `1` 可跑 = **在就绪队列里**（这个成员身份是本路新引入的，
/// 此前无承载）· `2` 等待中 = 体已交出控制流、等某个未来决出 · `0` 未起 = 体从未进入。
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
    // ⚠️ 四态表里没有「已取消」这一格 —— 如实登记，⛔ 不自行扩表。
    if resolved || cancelled { return 3 }
    if queued { return 1 }
    if suspended { return 2 }
    // ② 体正在跑 ⇒ 读作**可跑**：四态表里没有「正在被推进」这一格，而它的定义
    // （「该被执行器推进」）在这一刻仍然成立。⚠️ 由此本条**不能**用来区分「在队列里」与「正在跑」
    // —— 判据要区分的是「等待中」与「可跑」，那两格分得开。
    if started { return 1 }
    return 0
}

/// 把一个任务**交给策略层的队列**（甲段）。
///
/// ⚠️ 调「收下」在锁**外**：那跑的是用户代码（策略是 Pini 值），⛔ 不该持本层的锁调它。
///
/// - Returns: 真的入了队 ⇒ `true`（入不了队时已就地处置，见下）。
@discardableResult
private func _bkTaskOffer(_ box: _BkTaskBox) -> Bool {
    guard let h = box.selfHandle else { return false }
    _bkReadyLock.lock()
    let binding = _bkSchedBinding
    guard let binding else {
        _bkReadyLock.unlock()
        // ⚠️ **没有策略层 ⇒ 降级为直接续跑**，⛔ 不是把任务归约掉。
        //
        // 依据是本仓的既有纪律：**无合格版本则降级，不失败**（与 `bk_task_await` 在
        // 「不在任何任务里」时走直线等待同族）。⭐ 这条降级另有一个**具体用处**：
        // 进程内直接调这一族符号的用法（判据就是这么做的）从不绑策略，而那些用法在改道
        // 之前是能跑的 —— 「没有绑定就归约」会让它们**从能跑变成不能跑**，是退化不是改进。
        //
        // ⚠️ 两处**如实登记**：① 这条路上不置 `queued` ⇒ 可观测面读作「等待中」而非「可跑」
        // （没有队列就无所谓「在队列里」，那个成员身份在这条路上**不成立**）；
        // ② 解释器后端**没有**这条降级路径（那个后端总有策略 —— 预置默认实例），
        // 故各后端在这一格上不对称，收敛它须另行点名。
        let thread = Thread { _bkTaskRunBody(h) }
        thread.start()
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
    // ⛔ 给了一个**从没发出去过**的句柄 ⇒ 缺陷，⛔ 不得读成「暂时没活」。
    guard known else { return .unknown(answered) }
    return .task(answered)
}

/// 驱动循环：**问策略要一个 ⇒ 推进它一次**，直到策略说没有下一个。
private func _bkTaskDrain() {
    _bkReadyLock.lock()
    _bkReadyScheduled = false
    _bkReadyDraining = true
    _bkReadyLock.unlock()

    // ⚠️ 策略给的答案**可不可信**要分开记：不可信时**不得**再排下一趟，
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
                // ⚠️ 在队列里等着的这段时间里它可能被取消 ⇒ **出队即丢弃**：
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

/// 策略层坏了 —— 响亮说，⛔ 不静默降级成「没有下一个」。
///
/// ⚠️ **走 stderr 而不是 stdout**：这一层程序的 stdout 是**被断言的东西**（判据逐字节比它），
/// 在它上面打诊断会把「程序输出」与「引擎抱怨」混成一个读数。
/// ⚠️ 与解释器后端的对应物**一处不对称**如实登记：那个后端打的是 stdout
/// （本后端的 stdout 承载着 `printf` 的程序输出，故不能照搬）。
private func _bkReportSchedulerDefect(_ detail: String) {
    FileHandle.standardError.write(
        Data("[scheduler] ⛔ 策略层给出的答案不可用，就绪队列停止驱动：\(detail)\n".utf8))
}

// MARK: 让出的可观测通道（`DE-6a` §3.6）

/// 闸门：**仅在环境变量置位时**输出，未置位 ⇒ **零输出**。
///
/// ⛔ 性质：它是**测试器械专用**的观测面 —— **不是** ABI、**不是**诊断通道、**不是**给用户的
/// 功能（`DE-6a` §3.6 的明文声明）。本仓另有一笔**已登记的**「诊断通道」缺口，**二者不是一件
/// 事** —— 这条声明的作用正是防止有人把它当成那个缺口的补丁。
private let _bkYieldReportEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["PINI_YIELD_REPORT"] else { return false }
    return !(raw.isEmpty || raw == "0")
}()

private var _bkYieldCount = 0
private let _bkYieldCountLock = NSLock()

/// 体**真让出**一次（wrapper 返回非 `0`，且运行时已接受）。计数在闸门之外也累加 ——
/// 闸门只决定**打不打印**，不影响运行时行为。
private func _bkTaskNoteYield() {
    guard _bkYieldReportEnabled else { return }
    _bkYieldCountLock.lock()
    _bkYieldCount += 1
    _bkYieldCountLock.unlock()
}

/// 进程退出时打**一行**汇总（经**既有**的退出钩子那条路径，⛔ 不新起退出路径）。
///
/// ⚠️ 为什么是汇总一行而不是逐次一行：逐次打点会与程序自身输出交错 ⇒ 读起来**非确定**；
/// 汇总一行**逐字节可断言**。代价如实说：**只有置位的运行可见** ⇒ 「不置位时也让出」这一半
/// 测不到 —— 这与本仓「**跳过必须可见**」同向（必须显式开闸，否则读数不可信）。
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
