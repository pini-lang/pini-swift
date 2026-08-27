import Foundation

// MARK: - ADR-008 阶段1：集合/COW 运行时 shim（Swift 实现，C ABI 边界）

// MARK: - #46-D D4：显式 share count 与写时复制（COW）基础设施
//
// 为何不用 `isKnownUniquelyReferenced`：LLVM 后端里 `var b = a` 只是把**不透明句柄**
// （裸 `ptr`）从一个 alloca 槽复制到另一个槽——Swift ARC 完全看不到这次别名，box 的
// 引用计数恒为 1（仅 `_liveHandles` 持有），`isKnownUniquelyReferenced` 恒为 true，
// 分裂永不触发。故 D4 改为**运行时显式 share count**：codegen 在别名绑定处发射
// `bk_handle_retain`，写入前发射 `bk_handle_ensure_unique`（或经 set 的返回句柄），
// 由运行时按 `shares` 判定是否分裂。解释器侧则由 Swift 集合原生 COW 保证（见 ADR-001）。

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
/// 所有访问经下方 `@bk_array_*` 调用完成。C ABI 为 MUST 硬约束（见 ADR-008），
/// 否则阶段3 纯 libc 重写时被锁死。
private final class _BkArrayBox: _BkBox {
 /// #46-D D1：装箱-raw 存储——每槽是一个由运行时拥有的堆 box（`UnsafeMutableRawPointer`），
 /// box 内 memcpy 存元素原始字节。无论元素类型是 Int/F64/Bool/String 还是嵌套数组，
 /// 均以 `ptr` 承载，与 ADR-008「一切经 C ABI 的 `ptr`」哲学一致，且天然支持任意宽度元素
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
/// 与解释器抛 `RuntimeError` 语义对齐——双后端均以「错误」终止（见 ADR-008）。
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
/// （先释放该槽旧 box），与 ADR-008「一切经 `ptr` C ABI」一致，支持任意宽度/类型元素。
/// 越界经 `bk_panic` 终止（与解释器越界抛错一致）。
///
/// #46-D D4（COW）：写前先 `_bkEnsureUnique` —— 句柄被共享（`shares > 1`）时深拷分裂，
/// 写入落在**副本**上，原 box 不受影响；返回实际被写入的句柄，**调用方必须写回变量槽**。
/// `elemTag` 供深拷时识别嵌套句柄元素（见 `_BkArrayBox.tags`）。
@_cdecl("bk_array_set")
public func bk_array_set(_ arr: UnsafeMutableRawPointer?, _ i: Int32, _ src: UnsafeRawPointer,
 _ elemBytes: Int32, _ elemTag: Int32) -> UnsafeMutableRawPointer? {
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

 init(wrapper: UnsafeMutableRawPointer?, code: UnsafeMutableRawPointer?, env: UnsafeMutableRawPointer?,
 elemBytes: Int, elemTag: Int32) {
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
public func bk_lazyref_create(_ wrapper: UnsafeMutableRawPointer?,
 _ code: UnsafeMutableRawPointer?,
 _ env: UnsafeMutableRawPointer?,
 _ elemBytes: Int32,
 _ elemTag: Int32) -> UnsafeMutableRawPointer {
 return _bkRegister(_BkLazyRefBox(wrapper: wrapper, code: code, env: env,
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
 return Entry(key: _bkAllocBox(e.key, e.keyBytes), keyTag: e.keyTag, keyBytes: e.keyBytes,
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
public func bk_dict_set(_ dict: UnsafeMutableRawPointer?,
 _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32,
 _ val: UnsafeRawPointer, _ valBytes: Int32, _ valTag: Int32) -> UnsafeMutableRawPointer? {
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
 box.entries.append(.init(key: _bkAllocBox(key, kn), keyTag: keyTag, keyBytes: kn,
 val: newVal, valTag: valTag, valBytes: vn))
 }
 return target
}

/// 读取键对应的值 box（命中返回运行时拥有的稳定 `ptr`，调用方据此 `load T`）。
/// 缺失返回 `nil`——`@_cdecl` 将 `UnsafeMutableRawPointer?` 降级为 C 可空 `void*`，
/// 故 IR 侧收到 `null`，与 codegen 的 `icmp eq ptr %boxPtr, null` 契约一致；
/// codegen 据值类型补零值（与解释器「缺失返回 `.null`」在既有键读取场景对齐；打印 `.null` 属 D3 范畴）。
@_cdecl("bk_dict_get")
public func bk_dict_get(_ dict: UnsafeMutableRawPointer?,
 _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32) -> UnsafeMutableRawPointer? {
 guard let dict else { bk_panic("Pini runtime error: dict handle is null") }
 let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
 let kn = Int(keyBytes); guard kn > 0 else { return nil }
 guard let entry = box.entries.first(where: { stored in
 _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
 }) else {
 return nil
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
public func bk_dict_ensure_unique_at(_ dict: UnsafeMutableRawPointer?,
 _ key: UnsafeRawPointer, _ keyBytes: Int32, _ keyTag: Int32) -> UnsafeMutableRawPointer? {
 guard let dict else { return nil }
 let box = Unmanaged<_BkDictBox>.fromOpaque(dict).takeUnretainedValue()
 guard box.shares <= 1 else {
 bk_panic("Pini runtime error: bk_dict_ensure_unique_at requires a unique parent handle (shares=\(box.shares))")
 }
 guard Int(keyBytes) > 0 else { bk_panic("Pini runtime error: dict key box has zero width") }
 guard let idx = box.entries.firstIndex(where: { stored in
 _bkBoxesEqual(key, keyTag, stored.key, stored.keyTag)
 }) else {
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
public func bk_set_add(_ set: UnsafeMutableRawPointer?, _ elem: UnsafeRawPointer,
 _ elemBytes: Int32, _ elemTag: Int32) -> UnsafeMutableRawPointer? {
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

/// 字典是否含指定键（与 `bk_dict_get` 同源的 `_bkBoxesEqual` 判定）。供 LLVM `print(d[k])` 在缺失键时
/// 输出 `null`（对齐解释器 `stringify(.null)` → "null"），闭合 D2 遗留的「缺失键 LLVM 补零值」分歧。
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

// MARK: - Phase 2a（ADR-015 FFI）：指针原语（C-ABI 面）

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
