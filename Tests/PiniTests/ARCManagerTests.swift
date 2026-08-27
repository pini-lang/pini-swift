import XCTest
import PiniCore

/// ARCManager 引用计数管理测试
final class ARCManagerTests: XCTestCase {

    /// 意图：retain 应增加对象引用计数
    /// 推进性测量：连续 retain 多次应累计计数
    /// 驳回性测量：release 后计数应下降，而非保持不变
    func testRetainIncreasesReferenceCount() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "计数对象", fields: [:])

        manager.register(obj)
        XCTAssertEqual(obj.refCount, 1, "注册后初始引用计数应为 1")

        manager.retain(obj)
        XCTAssertEqual(obj.refCount, 2, "retain 后引用计数应为 2")

        manager.retain(obj)
        XCTAssertEqual(obj.refCount, 3, "再次 retain 后引用计数应为 3")

        // 驳回性测量：release 应使计数下降
        manager.release(obj)
        XCTAssertEqual(obj.refCount, 2, "release 后引用计数应降回 2")
    }

    /// 意图：release 使引用计数降为 0 后，collect 应回收该对象
    /// 推进性测量：多个对象中只回收计数为 0 的
    /// 驳回性测量：计数大于 0 的对象不应被回收
    func testCollectRemovesZeroCountObjects() {
        let manager = ARCManager()
        let obj1 = ObjectReference(typeName: "对象1", fields: [:])
        let obj2 = ObjectReference(typeName: "对象2", fields: [:])

        manager.register(obj1)
        manager.register(obj2)

        XCTAssertEqual(manager.liveCount, 2, "注册 2 个对象后 liveCount 应为 2")

        // obj1 引用计数降为 0
        manager.release(obj1)
        XCTAssertEqual(obj1.refCount, 0, "obj1 release 后引用计数应为 0")

        // collect 应回收 obj1，保留 obj2
        let collected = manager.collect()
        XCTAssertEqual(collected, 1, "应回收 1 个对象")
        XCTAssertEqual(manager.liveCount, 1, "回收后 liveCount 应为 1")
    }

    /// 意图：ARCManager 应正确追踪多个对象的独立引用计数
    /// 推进性测量：不同对象的 retain/release 互不影响
    func testIndependentObjectTracking() {
        let manager = ARCManager()
        let objA = ObjectReference(typeName: "A", fields: [:])
        let objB = ObjectReference(typeName: "B", fields: [:])

        manager.register(objA)
        manager.register(objB)

        manager.retain(objA)
        manager.retain(objA)
        manager.retain(objB)

        XCTAssertEqual(objA.refCount, 3, "objA 应为 3")
        XCTAssertEqual(objB.refCount, 2, "objB 应为 2")
        XCTAssertEqual(manager.liveCount, 2, "两个对象都存活")

        manager.release(objB)
        XCTAssertEqual(objB.refCount, 1, "objB release 后应为 1")
        XCTAssertEqual(objA.refCount, 3, "objA 不受影响")
    }

    // MARK: - 弱引用测试

    /// 意图：验证 weakRetain 不增加对象的强引用计数
    /// 推进性测量：weakRetain 后 refCount 仍为 1、liveCount 保持 1
    func testWeakRetainDoesNotIncreaseStrongCount() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "Test", fields: [:])

        manager.register(obj)
        XCTAssertEqual(manager.liveCount, 1)

        manager.weakRetain(obj)
        XCTAssertEqual(obj.refCount, 1, "弱引用不应增加强引用计数")
        XCTAssertEqual(manager.liveCount, 1, "弱引用不应影响 liveCount")
    }

    /// 意图：验证对象存活判定随强引用状态变化
    /// 推进性测量：强引用存在时 isAlive 为 true
    /// 驳回性测量：强引用归零后 isAlive 应为 false
    func testWeakReferenceLivenessCheck() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "Test", fields: [:])

        manager.register(obj)
        manager.weakRetain(obj)

        XCTAssertTrue(manager.isAlive(obj), "强引用存在时对象应存活")

        manager.release(obj)
        XCTAssertFalse(manager.isAlive(obj), "强引用归零后对象应不再存活")
    }

    /// 意图：验证弱引用计数也归零后 collect 能完全回收对象
    /// 推进性测量：weakRetain 两次后全部 weakRelease，collect 后 liveCount 为 0
    func testWeakRelease() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "Test", fields: [:])

        manager.register(obj)
        manager.weakRetain(obj)
        manager.weakRetain(obj)

        manager.release(obj)
        XCTAssertFalse(manager.isAlive(obj))

        manager.weakRelease(obj)
        manager.weakRelease(obj)

        manager.collect()
        XCTAssertEqual(manager.liveCount, 0, "弱引用也归零后应能完全回收")
    }
}
