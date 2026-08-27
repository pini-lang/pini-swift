import XCTest
import PiniCore
import Foundation

/// 值/引用语义收口（G7：值/引用相等性、拷贝语义、`let` 不可变边界）。
/// 兼固化 P3-2 ②：enum 判别联合子类型（variant → union 可赋值性）与 match 绑定类型窄化。
/// 类型层驱动：Lexer → Parser → TypeChecker.checkCollecting(module:)，与 CLI `pini check` 同构。
/// 运行时驱动：Lexer → Parser → Interpreter.run(module:)，与 CLI `pini run` 同构。
final class ValueSemanticsTests: XCTestCase {

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "value_test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "value_test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "value_test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "value_test.pini")
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

    // MARK: - 类型层：`let` 不可变边界

    /// 意图：`let` 声明后重新赋值，类型层必须静态报 reassignmentToImmutable（提前于运行时 immutableVariable）。
    func testLetReassignmentReported() throws {
        let source = """
        main|func() -> ()
            let x = 1
            x = 2
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .reassignmentToImmutable(variableName: "x", _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "let 重赋值应报 reassignmentToImmutable，实际: \(diagnostics)")
    }

    /// 意图：`var` 声明后重新赋值不应报错（回归保护，确认仅 `let` 被限制）。
    func testVarReassignmentNoError() throws {
        let source = """
        main|func() -> ()
            var x = 1
            x = 2
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "var 重赋值应无类型错误，实际: \(diagnostics)")
    }

    /// 意图：`let` 重赋值在类型层报错，同时不波及同作用域其他合法语句。
    func testLetReassignmentIsOnlyDiagnostic() throws {
        let source = """
        main|func() -> ()
            let a = 1
            var b = 2
            b = 3
            a = 4
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertEqual(diagnostics.count, 1, "应仅有 1 条 let 重赋值诊断，实际: \(diagnostics)")
        if case .reassignmentToImmutable(variableName: "a", _) = diagnostics[0] {
            // 期望
        } else {
            XCTFail("应为 reassignmentToImmutable(a)，实际: \(diagnostics[0])")
        }
    }

    // MARK: - 类型层：enum 判别联合子类型 + match 绑定窄化（固化 P3-2 ②）

    /// 意图：enum 值构造 + match 进入某 case 后，关联值绑定变量获得其类型（窄化），
    /// 在 case 体内访问绑定变量的字段不应报 undefinedVariable / field 错误。
    func testEnumMatchBindingNarrowing() throws {
        let source = """
        [形状]
        圆(点, F64,)

        (点)
            x: I32 = 0

        main|func() -> ()
            var c = 圆(点(), 1.0)
            match c:
                case 圆(p, r):
                    print(p.x + 1)
                    return
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "enum match 绑定窄化应无类型错误，实际: \(diagnostics)")
    }

    /// 意图：enum 变体（圆）传给期望其联合类型（形状）的函数参数，variant → union 子类型应放行。
    func testEnumVariantToUnionAssignable() throws {
        let source = """
        [形状]
        圆(点, F64,)

        (点)
            x: I32 = 0

        取面积|func(s: 形状) -> ()
            return

        main|func() -> ()
            var c = 圆(点(), 1.0)
            取面积(c)
            return
        """
        let diagnostics = checkCollecting(source)
        XCTAssertTrue(diagnostics.isEmpty, "enum variant → union 可赋值性应放行，实际: \(diagnostics)")
    }

    // MARK: - 运行时：值/引用语义 + let 边界

    /// 意图：`let` 重赋值在运行时必须抛错（immutableVariable 兜底；类型层已提前静态捕获）。
    func testLetReassignmentRuntimeError() throws {
        let source = """
        main|func() -> ()
            let x = 1
            x = 2
            return
        """
        XCTAssertThrowsError(try runProgram(source), "let 重赋值运行时必须抛错")
    }

    /// 意图：struct 为值语义——赋值产生独立拷贝，修改副本不影响原值。
    func testStructCopySemantics() throws {
        let source = """
        (点)
            x: I32 = 0
            y: I32 = 0

        main|func() -> ()
            var p = 点()
            var q = p
            q.x = 9
            print(p.x)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "0",
                       "struct 值拷贝：修改副本 q 不应影响原值 p.x（期望 0）")
    }

    /// 意图：object 为引用语义——赋值共享同一实例，通过别名修改影响原值。
    func testObjectReferenceSharing() throws {
        let source = """
        {盒子}
            值: I32 = 0

        main|func() -> ()
            var a = 盒子()
            var b = a
            b.值 = 9
            print(a.值)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "9",
                       "object 引用共享：通过别名 b 修改应影响原值 a.值（期望 9）")
    }

    // MARK: - 类型层：`let` 聚合成员赋值（P3-3 加固）

    /// 意图：P3-3 加固——`let` 聚合的成员赋值（`p.x = 9`）须在类型层报 reassignmentToImmutable，
    /// 闭合此前「成员赋值完全不查可变性」的缺口（直接 `x = 9` 已报，成员路径此前漏检）。
    func testLetMemberReassignmentReported() throws {
        let source = """
        (点)
            x: I32 = 0

        main|func() -> ()
            let p = 点()
            p.x = 9
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .reassignmentToImmutable(variableName: "p", _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "let 聚合成员赋值 p.x=9 应报 reassignmentToImmutable(p)，实际: \(diagnostics)")
    }

    /// 意图：运行时同样拒绝 `let` 聚合成员赋值（p 不可变 → immutableVariable）。
    func testLetMemberReassignmentRuntimeError() throws {
        let source = """
        (点)
            x: I32 = 0

        main|func() -> ()
            let p = 点()
            p.x = 9
            return
        """
        XCTAssertThrowsError(try runProgram(source), "let 聚合成员赋值 p.x=9 运行时必须抛错")
    }

    /// 意图：成员赋值须与字段声明类型一致（P3-3 加固——此前成员赋值完全不做类型检查）。
    func testMemberAssignTypeMismatchReported() throws {
        let source = """
        (点)
            x: I32 = 0

        main|func() -> ()
            var p = 点()
            p.x = "hello"
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .mismatch = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "struct 字段类型不符（p.x = 字符串）应报 mismatch，实际: \(diagnostics)")
    }

    // MARK: - 类型层：Array<T> 静态 unknownMember（P3-2 ③ 修复）

    /// 意图：P3-2 ③ 修复——`Array<T>` 泛型接收者上的未知成员也须静态报 unknownMember
    /// （原实现仅匹配 .simple，导致 Array<T> 静态检测失效，只能运行时兜底）。
    /// 同接收者的已知成员 join 不应被误报。
    func testArrayUnknownMemberReported() throws {
        let source = """
        main|func() -> ()
            var lst = Array<String>()
            lst.join("-")
            lst.foo()
            return
        """
        let diagnostics = checkCollecting(source)
        let hit = diagnostics.contains {
            if case .unknownMember(typeName: "Array", memberName: "foo", _) = $0 { return true }
            return false
        }
        XCTAssertTrue(hit, "Array<String> 上调用未知成员 foo 应静态报 unknownMember(Array, foo)，实际: \(diagnostics)")
        let hasUnknownForJoin = diagnostics.contains {
            if case .unknownMember(typeName: "Array", memberName: "join", _) = $0 { return true }
            return false
        }
        XCTAssertFalse(hasUnknownForJoin, "Array.join 为已知成员，不应报 unknownMember，实际: \(diagnostics)")
    }

    // MARK: - 集合值语义 / COW（#46-D D4.1.5，解释器侧，不依赖 LLVM 工具链）

    /// 意图：集合是值类型——`var b = a` 后写任一方，另一方不受影响（数组 / 字典 / 集合）。
    /// 推进性测量：双向写（写别名、写源）各断言两侧快照。
    /// 驳回性测量：若底层存储被共享且原地改写，两次 print 会输出同一内容 → 红灯。
    /// 与 `RuntimeBackendTests` 的双后端锁步用例互补：本用例不需要 LLVM 工具链，永远参与门禁。
    func testCollectionAliasIsValueSemantics() throws {
        let out = try runProgram("""
        main|func() -> ()
            var a = [1, 2, 3]
            var b = a
            b[0] = 99
            print(a)
            print(b)
            var c = [1, 2]
            var d = c
            c[1] = 7
            print(c)
            print(d)
            var m = ["k": 1]
            var n = m
            n["k"] = 9
            print(m)
            print(n)
            return
        """)
        XCTAssertEqual(out, "[1, 2, 3]\n[99, 2, 3]\n[1, 7]\n[1, 2]\n{k: 1}\n{k: 9}\n",
                       "集合别名写入必须分裂，源与别名互不污染（双向 + 字典）")
    }

    /// 意图：容器被放进另一个容器时，外层持有的是**当时的快照**——之后写源变量不应改动外层内容。
    /// 驳回性测量：若外层只存了引用且未分裂，`print(outer)` 会跟着变成 `[[42, 2]]` → 红灯。
    func testContainerElementSnapshotIsIndependent() throws {
        let out = try runProgram("""
        main|func() -> ()
            var inner = [1, 2]
            var outer = [inner]
            inner[0] = 42
            print(inner)
            print(outer)
            var arr = [1, 2]
            var box = ["k": arr]
            arr[0] = 8
            print(arr)
            print(box)
            return
        """)
        XCTAssertEqual(out, "[42, 2]\n[[1, 2]]\n[8, 2]\n{k: [1, 2]}\n",
                       "被容器持有的容器是快照，源变量后续写入不应影响它")
    }

    /// 意图：嵌套下标写 `m[0][0] = v` 必须**只**改内层目标槽，且不污染别名的内层快照。
    /// 驳回性测量：#46-D D4.2.2 修复前，`writeSubscript` 把内层值写进外层槽 →
    /// `[[99, [3, 4]], [3, 4]]` 这类结构错乱；共享内层存储时 `h` 也会被一起改动。
    /// 覆盖混合容器（数组套字典 / 字典套数组）与三层嵌套。
    func testNestedSubscriptWriteAndCOW() throws {
        let out = try runProgram("""
        main|func() -> ()
            var g = [[1, 2], [3, 4]]
            var h = g
            g[0][0] = 99
            print(g)
            print(h)
            var d = ["a": [1, 2]]
            var e = d
            d["a"][0] = 7
            print(d)
            print(e)
            var p = [["k": 1], ["k": 2]]
            var q = p
            p[0]["k"] = 9
            print(p)
            print(q)
            var t = [[[1, 2], [3, 4]]]
            t[0][1][0] = 77
            print(t)
            return
        """)
        XCTAssertEqual(out, "[[99, 2], [3, 4]]\n[[1, 2], [3, 4]]\n"
            + "{a: [7, 2]}\n{a: [1, 2]}\n"
            + "[{k: 9}, {k: 2}]\n[{k: 1}, {k: 2}]\n"
            + "[[[1, 2], [77, 4]]]\n",
            "嵌套写只改内层目标槽，且别名内层快照不受污染（含混合容器与三层嵌套）")
    }
}
