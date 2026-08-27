import XCTest
@testable import PiniRuntime

/// #46-D D4.2.1a：运行时 COW（写时复制）机制单测——**直接打 C ABI**，与 codegen 解耦。
///
/// 为何这层要独立测：LLVM 后端里 `var b = a` 只复制不透明句柄（裸 `ptr`），Swift ARC 看不到
/// 这次别名（box 引用计数恒为 1），`isKnownUniquelyReferenced` 恒真、分裂永不触发。故 D4 采用
/// **运行时显式 share count**：别名点 `bk_handle_retain`，写入前 `_bkEnsureUnique` 分裂。
/// 本文件在不经过 IR 生成的前提下锁死该机制的核心不变量，使 codegen 侧回归（D4.2.1b/D4.2.2）
/// 能明确区分「运行时算错」与「IR 没发射 retain / 没写回句柄」。
///
/// tag 约定与 `_BkTag` / `bkTagForLLVMType` 一致：i32=0, double=1, bool=2, str=3, handle=4。
final class RuntimeCOWTests: XCTestCase {

    // MARK: - 装箱辅助（模拟 codegen 的 alloca T + store）

    private var scratch: [UnsafeMutableRawPointer] = []

    override func tearDown() {
        for p in scratch { p.deallocate() }
        scratch.removeAll()
        super.tearDown()
    }

    /// 分配一个装着 Int32 的临时 box（生命周期由 tearDown 统一回收）。
    private func boxI32(_ v: Int32) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 8)
        p.storeBytes(of: v, as: Int32.self)
        scratch.append(p)
        return p
    }

    /// 分配一个装着句柄（8 字节指针）的临时 box。
    private func boxHandle(_ h: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        p.storeBytes(of: h, as: UnsafeMutableRawPointer.self)
        scratch.append(p)
        return p
    }

    private func i32At(_ arr: UnsafeMutableRawPointer, _ i: Int32) -> Int32 {
        bk_array_get(arr, i).load(as: Int32.self)
    }

    private func handleAt(_ arr: UnsafeMutableRawPointer, _ i: Int32) -> UnsafeMutableRawPointer {
        bk_array_get(arr, i).load(as: UnsafeMutableRawPointer.self)
    }

    /// 构造 [1, 2, 3]（I32 元素）。
    private func makeArray123() -> UnsafeMutableRawPointer {
        let a = bk_array_create(3)
        for (i, v) in [Int32(1), 2, 3].enumerated() {
            _ = bk_array_set(a, Int32(i), boxI32(v), 4, 0)
        }
        return a
    }

    // MARK: - 独占句柄：原地写，不分裂

    /// 意图：验证独占句柄（share==1）写入原地生效——bk_array_set 返回同一句柄（零拷贝）、内容更新、share 不变。
    func testUniqueHandleWritesInPlace() {
        let a = makeArray123()
        XCTAssertEqual(bk_handle_shares(a), 1, "新建句柄 share 应为 1")

        let after = bk_array_set(a, 0, boxI32(99), 4, 0)
        XCTAssertEqual(after, a, "独占句柄写入应原地生效，返回同一句柄（零拷贝）")
        XCTAssertEqual(i32At(a, 0), 99)
        XCTAssertEqual(bk_handle_shares(a), 1, "原地写不应改变 share count")
    }

    // MARK: - 共享句柄：写触发分裂，原句柄不受污染（COW 核心不变量）

    /// 意图：验证共享句柄（share==2）写入触发 COW 分裂——返回新句柄、原句柄不被污染、未写槽被深拷、两侧 share 各减为 1。
    func testSharedArraySplitsOnWrite() {
        let a = makeArray123()
        bk_handle_retain(a)                     // 模拟 `var b = a`
        XCTAssertEqual(bk_handle_shares(a), 2, "别名后 share 应为 2")

        // 经 b 写入 → 必须分裂出新句柄
        guard let b = bk_array_set(a, 0, boxI32(99), 4, 0) else {
            return XCTFail("bk_array_set 应返回句柄")
        }
        XCTAssertNotEqual(b, a, "共享句柄写入应分裂出新句柄")
        XCTAssertEqual(i32At(a, 0), 1, "原句柄内容不应被别名写污染（COW 核心）")
        XCTAssertEqual(i32At(b, 0), 99, "新句柄应持有写入后的值")
        XCTAssertEqual(i32At(b, 1), 2, "分裂应深拷未被写的槽")
        XCTAssertEqual(i32At(b, 2), 3)
        XCTAssertEqual(bk_handle_shares(a), 1, "分裂后原句柄 share 应减 1")
        XCTAssertEqual(bk_handle_shares(b), 1, "分裂出的副本应独占")
    }

    /// 意图：验证 COW「写时只付一次代价」——已独占副本的后续写入原地生效、不重复拷贝，原句柄仍不受影响。
    func testSplitOnceThenWritesInPlace() {
        let a = makeArray123()
        bk_handle_retain(a)
        guard let b = bk_array_set(a, 0, boxI32(10), 4, 0) else { return XCTFail("set 应返回句柄") }
        // 第二次写同一副本：已独占 → 不再拷贝（COW 的「写时」只付一次代价）
        let b2 = bk_array_set(b, 1, boxI32(20), 4, 0)
        XCTAssertEqual(b2, b, "已独占副本的后续写入应原地生效，不重复拷贝")
        XCTAssertEqual(i32At(b, 0), 10)
        XCTAssertEqual(i32At(b, 1), 20)
        XCTAssertEqual(i32At(a, 1), 2, "原句柄仍不受影响")
    }

    // MARK: - 字典 / 集合 同款语义

    /// 意图：验证共享字典写入触发分裂——原字典不被污染、新增键只落在副本、已独占副本再写原地生效且 len 不串。
    func testSharedDictSplitsOnWrite() {
        let d = bk_dict_create()
        _ = bk_dict_set(d, boxI32(1), 4, 0, boxI32(100), 4, 0)
        _ = bk_dict_set(d, boxI32(2), 4, 0, boxI32(200), 4, 0)
        XCTAssertEqual(bk_dict_len(d), 2)

        bk_handle_retain(d)                     // `var d2 = d1`
        guard let d2 = bk_dict_set(d, boxI32(1), 4, 0, boxI32(999), 4, 0) else {
            return XCTFail("bk_dict_set 应返回句柄")
        }
        XCTAssertNotEqual(d2, d, "共享字典写入应分裂")
        XCTAssertEqual(bk_dict_get(d, boxI32(1), 4, 0)?.load(as: Int32.self), 100, "原字典不应被污染")
        XCTAssertEqual(bk_dict_get(d2, boxI32(1), 4, 0)?.load(as: Int32.self), 999)
        XCTAssertEqual(bk_dict_len(d), 2)
        XCTAssertEqual(bk_dict_len(d2), 2)

        // 新增键只落在副本上
        let d3 = bk_dict_set(d2, boxI32(3), 4, 0, boxI32(300), 4, 0)
        XCTAssertEqual(d3, d2, "已独占副本新增键应原地生效")
        XCTAssertEqual(bk_dict_len(d), 2, "原字典条目数不变")
        XCTAssertEqual(bk_dict_len(d2), 3)
    }

    /// 意图：验证共享集合插入触发分裂——原集合 len 不变、新集合 len 为 3（含去重后插入）。
    func testSharedSetSplitsOnAdd() {
        let s = bk_set_create()
        _ = bk_set_add(s, boxI32(1), 4, 0)
        _ = bk_set_add(s, boxI32(2), 4, 0)
        _ = bk_set_add(s, boxI32(2), 4, 0)      // 去重
        XCTAssertEqual(bk_set_len(s), 2)

        bk_handle_retain(s)
        guard let s2 = bk_set_add(s, boxI32(3), 4, 0) else { return XCTFail("bk_set_add 应返回句柄") }
        XCTAssertNotEqual(s2, s, "共享集合插入应分裂")
        XCTAssertEqual(bk_set_len(s), 2, "原集合不应被污染")
        XCTAssertEqual(bk_set_len(s2), 3)
    }

    // MARK: - 嵌套容器：递归分裂（用户拍板的语义）

    /// 嵌套写 `m[0][1] = v` 的完整协议（自顶向下独占化，**无后序回写**）：
    ///   1. 根槽：`h' = ensure_unique(h)` → store 回变量槽；
    ///   2. 中间层：`hi = ensure_unique_at(h', 0)`（父槽就地更新，不重复释放）；
    ///   3. 末层：`bk_array_set(hi, 1, v)`（此时 hi 已独占 → 原地写）。
    ///
    /// 关键陷阱（本测试锁死）：若第 2 步用「ensure_unique + bk_array_set 写回父槽」代替，
    /// 同一份 share 会被递减两次（ensure_unique 转移 + set 释放旧值），内层提前回收 → UAF。
    /// 意图：验证嵌套写「根 ensure_unique → 中间层 ensure_unique_at（父槽就地更新）→ 末层原地写」完整协议，锁死内层 share 无双重递减（不提前回收 UAF）。
    func testNestedWriteProtocolNoDoubleRelease() {
        let inner = bk_array_create(2)
        _ = bk_array_set(inner, 0, boxI32(1), 4, 0)
        _ = bk_array_set(inner, 1, boxI32(2), 4, 0)
        let outer = bk_array_create(1)
        _ = bk_array_set(outer, 0, boxHandle(inner), 8, 4)

        bk_handle_retain(outer)                              // `var b = m`
        // 1) 根独占化
        guard let outer2 = bk_handle_ensure_unique(outer) else { return XCTFail("ensure_unique 应返回句柄") }
        XCTAssertNotEqual(outer2, outer)
        XCTAssertEqual(bk_handle_shares(inner), 2, "外层深拷应 retain 句柄元素")

        // 2) 中间层独占化（父槽就地更新）
        guard let hi = bk_array_ensure_unique_at(outer2, 0) else { return XCTFail("ensure_unique_at 应返回句柄") }
        XCTAssertNotEqual(hi, inner, "内层共享 → 应分裂")
        XCTAssertEqual(handleAt(outer2, 0), hi, "父槽应已指向分裂后的内层")
        XCTAssertEqual(handleAt(outer, 0), inner, "原容器父槽仍指向原内层")

        // 3) 末层写（已独占 → 原地）
        let written = bk_array_set(hi, 1, boxI32(99), 4, 0)
        XCTAssertEqual(written, hi, "末层已独占，写应原地生效")

        XCTAssertEqual(i32At(handleAt(outer2, 0), 1), 99, "别名侧读到新值")
        XCTAssertEqual(i32At(handleAt(outer, 0), 1), 2, "原容器侧不受污染（递归分裂正确）")
        XCTAssertEqual(bk_handle_shares(inner), 1, "share 无双重递减（未提前回收）")
    }

    /// 外层分裂时对句柄型元素 retain，使内层写再次分裂——`m[0][1] = v` 不污染别名的机制基础。
    /// 意图：验证外层分裂时对句柄型元素 retain（内层 share 由 1 → 2），使内层写可再次分裂而非原地改写污染另一侧。
    func testNestedSplitRetainsInnerHandle() {
        // inner = [1, 2]；所有权随后移交给 outer 的槽 0（移动语义，不 retain）
        let inner = bk_array_create(2)
        _ = bk_array_set(inner, 0, boxI32(1), 4, 0)
        _ = bk_array_set(inner, 1, boxI32(2), 4, 0)
        let outer = bk_array_create(1)
        _ = bk_array_set(outer, 0, boxHandle(inner), 8, 4)   // tag=4：句柄元素
        XCTAssertEqual(bk_handle_shares(inner), 1, "字面量内层是所有权移动，不额外计数")

        bk_handle_retain(outer)                              // `var b = m`
        // 写路径第一步：外层独占化 → 分裂，且内层被 retain
        guard let outer2 = bk_handle_ensure_unique(outer) else { return XCTFail("ensure_unique 应返回句柄") }
        XCTAssertNotEqual(outer2, outer, "共享外层应分裂")
        XCTAssertEqual(bk_handle_shares(inner), 2,
                       "外层深拷必须 retain 句柄型元素，否则内层写会原地改、污染另一侧")

        // 分裂后两侧父槽仍浅共享同一内层（COW：内层未被立即复制）
        XCTAssertEqual(handleAt(outer2, 0), inner, "深拷是浅共享内层，不应立即复制内层")
        XCTAssertEqual(handleAt(outer, 0), inner)
        // 内层的实际分裂与父槽更新由 `bk_array_ensure_unique_at` 负责，
        // 见 `testNestedWriteProtocolNoDoubleRelease`（此处若手工 set 回写会双重递减 share）。
    }

    // MARK: - share 生命周期

    /// 意图：验证 bk_array_destroy 在仍被持有（share==2）时只递减到 1、不回收且内容可读；最后持有者离开时归零释放（不崩溃、无泄漏）。
    func testDestroyDecrementsShareNotFreeWhileShared() {
        let a = makeArray123()
        bk_handle_retain(a)
        XCTAssertEqual(bk_handle_shares(a), 2)

        bk_array_destroy(a)                      // 一个持有者离开作用域
        XCTAssertEqual(bk_handle_shares(a), 1, "仍被持有 → 只递减，不回收")
        XCTAssertEqual(i32At(a, 0), 1, "未回收，内容仍可读")

        // 最后一个持有者离开 → 归零并回收。
        // 归零后**不得**再读 `bk_handle_shares(a)`（那是 use-after-free）；
        // 「确实回收了」由 destroy 不崩溃 + 无泄漏（atexit cleanup 不重复 release）间接保证。
        bk_array_destroy(a)
    }
}
