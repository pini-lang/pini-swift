import Foundation

/// 一条待执行的析构：对象归零时把字段整块交割出来，析构体由引擎在安全点跑。
/// 交割字段而不是对象本身，是因为归零点就在对象销毁途中 —— 那一刻再取强引用复活它是未定义行为。
/// 替身带着同样的类型名与字段，析构体读写的仍是它认得的那份状态。
struct PendingDestruction {
    let typeName: String
    var fields: [String: Value]
}

/// 释放队列：生产者在任意线程、任意时刻投递（对象死在哪就在哪），消费只在引擎的语句边界发生。
/// 它就是参考件 7.1 那条「延迟释放队列」：归零不递归释放字段，逐条入队迭代，析构风暴由此摊成一条链。
/// 跨线程投递要有锁；取出即出队，故同一条不会被两个线程各跑一次。
final class DeinitQueue {
    private let lock = NSLock()
    private var pending: [PendingDestruction] = []

    /// 投递一条。加锁是因为工作线程与主线程都可能在这一刻归零。
    func enqueue(_ record: PendingDestruction) {
        lock.lock()
        pending.append(record)
        lock.unlock()
    }

    /// 取走一条；空队列返回 nil。后进先出：同批归零的次序本就不作保证（绑定表是字典），
    /// 取尾部让出队是 O(1)，链式析构的顺序由字段交接本身决定，不受它影响。
    func takeOne() -> PendingDestruction? {
        lock.lock()
        defer { lock.unlock() }
        return pending.popLast()
    }

    /// 换模块前清空：上一个模块的遗留记录在新类型表里查不到析构，留着只会白跑一趟。
    /// 只在装载期调用，那时还没有工作线程。
    func removeAll() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }
}
