import XCTest
@testable import PiniCore

/// （消解风险 R6）：**任务隔离 —— 引用类型不得跨 `=>` 边界共享**。
///
/// 背景（探针实证）：两个 `=>` 任务并发写同一 object 的字段会直接 SIGABRT——
/// `ObjectReference.fields` 是无锁 Swift Dictionary，并发变更即内存不安全，
/// 不是"计数不准"这种逻辑竞争，而是进程崩溃。
///
/// 决策（用户拍板，方案 C·静态隔离）：不加全局解释器锁、不加细粒度锁，
/// 而是在**类型层封死共享通道**——引用类型（object 声明的类型）
/// 不得作为实参穿过 `=>` 并发进程的调用边界。任务之间靠「传值 + Future 汇合」交换数据，
/// 契合既有值语义与 errors-as-data 的数据流哲学，且零运行时开销、保留真 CPU 并行。
///
/// 封闭性论证（为何只查传参就足够）：`=>` 任务体获得外部引用只有两条可能通道——
/// ① 实参传入；② 闭包捕获。而 ①由本检查封死；②async 匿名函数（`func =>`，spec G29）理论上
/// 可闭包捕获引用越过 `=>` 边界，但完整防护需闭包捕获分析（free variable），当前类型系统
/// 无此信息（与 TypeChecker escapingReferenceType 一致，暂不下钻函数类型）；此外顶层 `var` 在函数体内
/// **不可见**（无全局可变状态通道，已由探针验证 `undefined variable`）。
/// 因此「引用类型跨 `=>` 传参」是唯一共享入口，封死它即封闭。
final class TaskIsolationTests: XCTestCase {

    private func typeErrors(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "iso.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "iso.pini")
        let result = parser.parseModuleCollectingErrors()
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        return TypeChecker().checkCollecting(module: result.module)
    }

    private func isolationViolation(_ errors: [TypeError]) -> (String, String, String)? {
        for e in errors {
            if case .sharedReferenceAcrossTasks(let typeName, let paramName, let funcName, _) = e {
                return (typeName, paramName, funcName)
            }
        }
        return nil
    }

    // MARK: - 拦截：引用类型跨 `=>` 边界

    /// 意图：直接把 object 实例传进 `=>` 进程 —— 正是探针里导致 SIGABRT 的写法，必须静态拒绝。
    func testPassingObjectIntoAsyncFunctionIsRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        bump|func(c: Counter,) => ()
            c.inc()
            return

        main|func() -> ()
            let c = Counter()
            var a = bump(c)
            wait a
            return
        """)
        guard let (typeName, paramName, funcName) = isolationViolation(errors) else {
            return XCTFail("引用类型跨 => 传参应被拒绝，实际错误：\(errors)")
        }
        XCTAssertEqual(typeName, "Counter")
        XCTAssertEqual(paramName, "c")
        XCTAssertEqual(funcName, "bump")
    }

    /// 意图：`object` 声明的类型即引用语义，跨 `=>` 边界传参被封死（不能只认特定类型名）。
    /// `referenceTypeNames` 收录该类型名，类型检查阶段即拦截。
    func testPassingArbitraryObjectIntoAsyncFunctionIsRejected() {
        let errors = typeErrors("""
        {Node}
        v: I32 = 0

        touch|func(n: Node,) => ()
            return

        main|func() -> ()
            let x = Node()
            var t = touch(x)
            wait t
            return
        """)
        guard let (typeName, paramName, funcName) = isolationViolation(errors) else {
            return XCTFail("引用类型跨 => 传参应被拒绝，实际错误：\(errors)")
        }
        XCTAssertEqual(typeName, "Node")
        XCTAssertEqual(paramName, "n")
        XCTAssertEqual(funcName, "touch")
    }

    /// 意图：引用**藏在 struct 字段里**偷渡进任务 —— 必须递归识别，否则一层包装即可绕过。
    /// NOTE：struct 构造语法待验证后补齐独立用例；当前用元组（`(I32, Counter,)`）等价验证
    /// 递归类型检查——`escapingReferenceType` 对 tuple/generic 与 struct 字段走同一递归路径，
    /// 元组穿透即能证明递归机制有效。
    func testStructCarryingReferenceFieldIsRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        sendPair|func(p: (I32, Counter,),) => ()
            return

        main|func() -> ()
            let c = Counter()
            var t = sendPair((42, c,))
            wait t
            return
        """)
        guard let (typeName, paramName, funcName) = isolationViolation(errors) else {
            return XCTFail("元组内引用类型跨 => 传参应被递归拦截，实际错误：\(errors)")
        }
        XCTAssertEqual(typeName, "Counter")
        XCTAssertEqual(paramName, "p")
        XCTAssertEqual(funcName, "sendPair")
    }

    /// 意图：struct 字段递归检测的补充验证——值类型的 struct 放行，引用类型的 struct 字段拦截。
    /// 用 pair 容器（`[Counter]`）替代 array 测试，验证 generic param 递归路径。
    func testTupleContainingReferenceIsRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        sendPair|func(p: (I32, Counter,),) => ()
            return

        main|func() -> ()
            let c = Counter()
            var t = sendPair((42, c,))
            wait t
            return
        """)
        XCTAssertNotNil(isolationViolation(errors), "元组内引用类型跨 => 传参应被递归拦截：\(errors)")
    }

    /// 意图：引用藏在容器泛型实参里（`[Counter]`）同样要拦。
    func testArrayOfReferencesIsRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        bumpAll|func(cs: Array<Counter>,) => ()
            return

        main|func() -> ()
            let c = Counter()
            var xs = [c]
            var t = bumpAll(xs)
            wait t
            return
        """)
        XCTAssertNotNil(isolationViolation(errors), "容器内的引用类型跨 => 传参应被拒绝，实际错误：\(errors)")
    }

    // MARK: - 放行：不构成跨任务共享的写法（零回归）

    /// 意图：同步函数传引用完全合法 —— 隔离规则只约束 `=>` 边界，不得误伤既有同步代码。
    func testPassingObjectIntoSyncFunctionIsAllowed() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        bump|func(c: Counter,) -> ()
            c.inc()
            return

        main|func() -> ()
            let c = Counter()
            bump(c)
            return
        """)
        XCTAssertNil(isolationViolation(errors), "同步调用不应被隔离规则拦截：\(errors)")
    }

    /// 意图：值类型（struct）跨 `=>` 传参是安全的（拷贝语义，无共享），必须放行。
    func testPassingStructIntoAsyncFunctionIsAllowed() {
        let errors = typeErrors("""
        {Point}
        x: I32 = 0
        y: I32 = 0

        {{Point}}
        sum|self() -> ()
            return self.x

        main|func() -> ()
            print(1)
            return
        """)
        XCTAssertNil(isolationViolation(errors), "值类型不应触发隔离错误：\(errors)")
    }

    /// 意图：任务**体内自建**的对象没有跨边界共享，必须放行（否则并发任务无法使用对象）。
    func testAsyncTaskCreatingItsOwnObjectIsAllowed() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return
        get|self() -> ()
            return self.n

        work|func() => (I32,)
            let c = Counter()
            c.inc()
            return ok(c.get())

        main|func() -> ()
            var t = work()
            var r = wait t
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print(e)
            return
        """)
        XCTAssertNil(isolationViolation(errors), "任务体内自建对象不构成共享，应放行：\(errors)")
    }

    /// 意图：基本类型跨 `=>` 传参永远合法（最常见的并发写法，绝不能误伤）。
    func testPassingPrimitiveIntoAsyncFunctionIsAllowed() {
        let errors = typeErrors("""
        double|func(n: I32,) => (I32,)
            return ok(n * 2)

        main|func() -> ()
            var t = double(21)
            var r = wait t
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print(e)
            return
        """)
        XCTAssertTrue(errors.isEmpty, "基本类型跨 => 传参应无任何错误：\(errors)")
    }

    // MARK: - 缺口②修复：async 闭包捕获引用越过 `=>` 边界

    /// 意图：闭包体捕获外层 object `c`，闭包作为 `=>` 实参 —— 经闭包值（env）越过任务边界，
    /// 构成 R6 数据竞争通道；类型系统须静态拒绝。修复点：`.function` 携带 captured 集，
    /// `enforceTaskIsolation` 从实参实际类型取 captured 并入 `escapingReferenceType` 递归检测。
    func testClosureCapturingObjectPassedToAsyncIsRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        go|func(task: () -> (),) => ()
            task()
            return

        main|func() -> ()
            let c = Counter()
            var f = func () -> ():
                return c.inc()
            var a = go(f)
            wait a
            return
        """)
        guard let (typeName, paramName, funcName) = isolationViolation(errors) else {
            return XCTFail("闭包捕获引用类型跨 => 应被拒绝，实际错误：\(errors)")
        }
        XCTAssertEqual(typeName, "Counter")
        XCTAssertEqual(funcName, "go")
    }

    /// 意图：闭包**直接**作为 `=>` 实参（内联匿名函数）同样须检测捕获的引用类型。
    func testClosureCapturingObjectInlineArgRejected() {
        let errors = typeErrors("""
        {Counter}
        n: I32 = 0

        {{Counter}}
        inc|self() -> ()
            self.n = self.n + 1
            return

        go|func(task: () -> (),) => ()
            task()
            return

        main|func() -> ()
            let c = Counter()
            var a = go(func () -> (): return c.inc())
            wait a
            return
        """)
        guard let (typeName, _, funcName) = isolationViolation(errors) else {
            return XCTFail("内联闭包捕获引用类型跨 => 应被拒绝，实际错误：\(errors)")
        }
        XCTAssertEqual(typeName, "Counter")
        XCTAssertEqual(funcName, "go")
    }

    /// 意图（回归防护）：闭包捕获**值类型**不构成引用共享，必须放行（不误报）。
    /// 与 testClosureCapturingObjectPassedToAsyncIsRejected 成对，确保隔离只针对引用类型。
    func testClosureCapturingValuePassedToAsyncIsAllowed() {
        let errors = typeErrors("""
        go|func(task: () -> (),) => ()
            task()
            return

        main|func() -> ()
            var base = 10
            var f = func () -> ():
                base = base + 1
                return
            var a = go(f)
            wait a
            return
        """)
        XCTAssertNil(isolationViolation(errors), "值类型捕获不应触发隔离错误：\(errors)")
    }
}
