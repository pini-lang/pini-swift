import Foundation

/// 对象块的引用计数管理器：追踪 `register` / `retain` / `release` / `weakRetain` 并给出回收接口。
/// 它是解释器共享单例，并发任务在 worker 线程上调用，故所有状态访问（含 `ObjectReference.refCount` 的读写）
/// 一律由 `NSLock` 串行化——绕过锁即数据竞争，弱引用表与计数会互不一致。
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
