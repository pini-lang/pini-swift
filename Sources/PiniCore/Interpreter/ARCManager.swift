import Foundation

/// ARC 引用计数管理器
/// 负责对象块的引用计数管理
/// 当前三步走计划中 Swift ARC 自动管理内存，此管理器提供引用计数追踪与回收接口
///
/// D1 修复：原实现 `table` / `refCount` 无同步，而 `arcManager` 是解释器共享单例，
/// 并发任务在 worker 线程上 `register` / `retain` / `release` / `weakRetain` 时会产生数据竞争。
/// 现以 NSLock 串行化所有状态访问（含 `ObjectReference.refCount` 的读写），消除竞态。
public final class ARCManager {
 private class ARCEntry {
 let object: ObjectReference
 var weakRefCount: Int
 var isDeallocated: Bool

 init(object: ObjectReference) {
 self.object = object
 self.weakRefCount = 0
 self.isDeallocated = false
 }
 }

 private var table: [ObjectIdentifier: ARCEntry] = [:]
 private let lock = NSLock()

 public init() {}

 public var liveCount: Int {
 lock.lock()
 defer { lock.unlock() }
 return table.values.filter { $0.object.refCount > 0 && !$0.isDeallocated }.count
 }

 public func register(_ ref: ObjectReference) {
 lock.lock()
 defer { lock.unlock() }
 let id = ObjectIdentifier(ref)
 table[id] = ARCEntry(object: ref)
 }

 public func retain(_ ref: ObjectReference) {
 lock.lock()
 defer { lock.unlock() }
 ref.refCount += 1
 let id = ObjectIdentifier(ref)
 if table[id] == nil {
 table[id] = ARCEntry(object: ref)
 }
 }

 public func release(_ ref: ObjectReference) {
 lock.lock()
 defer { lock.unlock() }
 ref.refCount = max(0, ref.refCount - 1)
 }

 public func weakRetain(_ ref: ObjectReference) {
 lock.lock()
 defer { lock.unlock() }
 let id = ObjectIdentifier(ref)
 if let entry = table[id] {
 entry.weakRefCount += 1
 }
 }

 public func weakRelease(_ ref: ObjectReference) {
 lock.lock()
 defer { lock.unlock() }
 let id = ObjectIdentifier(ref)
 if let entry = table[id] {
 entry.weakRefCount = max(0, entry.weakRefCount - 1)
 if entry.object.refCount <= 0 && entry.weakRefCount == 0 {
 table.removeValue(forKey: id)
 }
 }
 }

 public func isAlive(_ ref: ObjectReference) -> Bool {
 lock.lock()
 defer { lock.unlock() }
 let id = ObjectIdentifier(ref)
 guard let entry = table[id] else { return false }
 return entry.object.refCount > 0 && !entry.isDeallocated
 }

 @discardableResult
 public func collect() -> Int {
 lock.lock()
 defer { lock.unlock() }
 let toRemove = table.filter { $0.value.object.refCount <= 0 && $0.value.weakRefCount == 0 }
 for id in toRemove.keys {
 table.removeValue(forKey: id)
 }
 return toRemove.count
 }
}
