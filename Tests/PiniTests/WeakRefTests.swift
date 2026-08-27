import XCTest
@testable import PiniCore

final class WeakRefTests: XCTestCase {

    /// 意图：构造 WeakRef(obj) 后访问 isAlive 应输出 true，验证 WeakRef 初始引用有效。
    func testWeakRefConstruction() throws {
        let source = """
{测试对象}
值: I32 = 42
main|func() -> ()
    var obj = 测试对象()
    var weak = WeakRef(obj)
    print(weak.isAlive)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "true", "WeakRef 初始时 isAlive 应为 true")
    }

    /// 意图：通过 weak.target 访问目标对象并打印其字段值，验证 target 可取得原对象（输出 42）。
    func testWeakRefTargetAccess() throws {
        let source = """
{测试对象}
值: I32 = 42
main|func() -> ()
    var obj = 测试对象()
    var weak = WeakRef(obj)
    var target = weak.target
    print(target.值)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42", "WeakRef.target 应能访问目标对象")
    }

    /// 意图：通过 weak.target.字段 链式访问目标字段，验证可读取字段值（输出 hello）。
    func testWeakRefTargetFieldAccess() throws {
        let source = """
{节点}
数据: String = "hello"
main|func() -> ()
    var obj = 节点()
    var weak = WeakRef(obj)
    print(weak.target.数据)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello", "通过 WeakRef.target.字段应能访问字段")
    }

    /// 意图：WeakRef 引用非对象字面量（42）应抛出 RuntimeError，验证非法参数被拒绝。
    func testWeakRefWithNonObjectFails() throws {
        let source = """
main|func() -> ()
    var weak = WeakRef(42)
    return
"""
        XCTAssertThrowsError(try runProgram(source), "WeakRef 引用非对象应报错") { error in
            XCTAssertTrue(error is RuntimeError, "应为 RuntimeError")
        }
    }

    /// 意图：多个 WeakRef 指向同一对象时 isAlive 均应为 true，验证各自独立持有引用（输出 true、true）。
    func testWeakRefMultipleWeaksSameTarget() throws {
        let source = """
{节点}
值: I32 = 99
main|func() -> ()
    var obj = 节点()
    var w1 = WeakRef(obj)
    var w2 = WeakRef(obj)
    print(w1.isAlive)
    print(w2.isAlive)
    return
"""
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["true", "true"], "多个 WeakRef 指向同一目标应都存活")
    }

    /// 意图：访问 WeakRef 目标上不存在的成员（weak.不存在）应抛出 RuntimeError，验证成员解析失败被拒绝。
    func testWeakRefInvalidMemberFails() throws {
        let source = """
{节点}
值: I32 = 10
main|func() -> ()
    var obj = 节点()
    var weak = WeakRef(obj)
    var x = weak.不存在
    return
"""
        XCTAssertThrowsError(try runProgram(source), "访问 WeakRef 不存在的成员应报错") { error in
            XCTAssertTrue(error is RuntimeError, "应为 RuntimeError")
        }
    }

    // MARK: - G42 Ref 系引用语义（2026-08-24 修复：独立 class box 承载）

    /// 意图：语言级 `var w2 = w1`（WeakRef 复制）后 target 访问仍正常——引用语义下复制共享同一目标。
    func testWeakRefAliasSharesTarget() throws {
        let source = """
{节点}
值: I32 = 7
main|func() -> ()
    var obj = 节点()
    var w1 = WeakRef(obj)
    var w2 = w1
    print(w2.target.值)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "7", "别名复制后 target 访问应正常（共享目标）")
    }

    /// 意图：WeakRef 复制共享同一 box（引用语义）——`var b = a` 不再复制包装实例（G42 修复前为值拷贝分裂）。
    func testWeakRefCopySharesSameBox() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "测试对象", fields: [:])
        manager.register(obj)
        let w1 = WeakRefBox(target: obj, manager: manager)
        let w2 = w1
        XCTAssertTrue(w1 === w2, "复制应共享同一 WeakRefBox（引用语义）")
    }

    /// 意图：WeakRefBox 生命周期对称——最后引用释放时 deinit 恰触发一次（weakRetain/weakRelease 配对；
    /// 修复前 weakRelease 无调用点、弱引用表泄漏）。
    func testWeakRefBoxSymmetricReleaseOnDeinit() {
        let manager = ARCManager()
        let obj = ObjectReference(typeName: "测试对象", fields: [:])
        manager.register(obj)
        weak var weakBox: WeakRefBox?
        do {
            var box: WeakRefBox? = WeakRefBox(target: obj, manager: manager)
            weakBox = box
            let shared = box!   // 复制共享 +1 引用（同一 box）
            box = nil
            XCTAssertNotNil(weakBox, "shared 仍持有 → 不应释放")
            _ = shared          // do 作用域结束：shared 释放
        }
        XCTAssertNil(weakBox, "最后引用释放后 box 应 deinit（weakRelease 对称触发，弱引用计数归零）")
    }

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
