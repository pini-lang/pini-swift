import Foundation
@testable import PiniCore
import Testing

/// 递归守卫按宿主栈余量判定，不按调用层数。
/// 条数上限两头出错且同因：轻的形态误杀（栈还剩大半，合法递归被读成疑似无限递归），重的形态漏判
/// （栈在守卫够得着之前就崩，且毫无诊断）。判据必须成对，两侧都钉住才堵死调高与调低两条捷径。
struct RecursionGuardTests {

    /// 一段程序跑出来的结果。
    private enum Outcome: Equatable {
        /// 跑完了，附打印出来的行。
        case ran([String])
        /// 被拒了 —— 文本是那条例外的说明。
        case refused(String)
    }

    /// 让结果能从新线程递出来：`Thread` 的闭包不返回、也不能抛。
    private final class OutcomeBox: @unchecked Sendable {
        var value: Outcome = .refused("线程没有产出结果")
    }

    /// 在指定栈大小的新线程上跑一段单文件程序。新线程不是洁癖：`stackSize` 只在启动之前设得上，
    /// 而用例自己落在哪个线程上，决定权不在本件；不指定则「跑到第几层」这个读数随调度漂移。
    private func run(stackSize: Int, _ source: String) -> Outcome {
        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = Self.attempt(source)
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return box.value
    }

    /// 在**当前**线程上报告一次栈边界，用来核对线程栈真的被设成了请求的大小。
    private static func reportedStackSize(on stackSize: Int, name: String) -> Int {
        let box = StackSizeBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = RuntimeOps.hostStack()?.size ?? 0
            done.signal()
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return box.value
    }

    private final class StackSizeBox: @unchecked Sendable {
        var value = 0
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "守卫探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期就被拒了：\(parsed.errors[0])")
            }
            let unit = FileUnit(
                fileName: name,
                module: ConstantFolder.foldConstants(in: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "递归守卫", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    /// 找不到出口的递归，且是重的调用形态：返回用户声明的枚举、带一个 struct 参数、结果再过一遍 `match`
    /// ⇒ 帧重到在守卫之前吃光栈，进程收到 SIGSEGV，一个字的诊断都没有。形态不是随手挑的：
    /// 纯标量递归的帧轻得多，守卫来得及，撞不出这个缺陷。
    private static let heavyRunaway = """
        (位置)
        行号: I32 = 0

        [节点]
        叶(名: String, 位置: 位置,)
        包(内: 节点, 位置: 位置,)

        绕|func(层: I32, 位置: 位置,) -> (节点,):
            return 包(绕(层 + 1, 位置,), 位置,)

        数|func(n: 节点,) -> (I32,):
            match n:
                case 叶(名, 位置):
                    return 1
                case 包(内, 位置):
                    return 1 + 数(内,)

        main|func() -> (I32,):
            var 址 = 位置()
            址.行号 = 1
            print(数(绕(0, 址,),),)
            return 0
        """

    /// **轻**的调用形态：只传标量。它在层数上跑得远得多，正是这一点让
    /// 「层数上限」看起来够用 —— 也让 `G89` 里那份自举解析器被它误杀。
    private static func lightRecursion(depth: Int) -> String {
        """
        loopA|func(n: I32, limit: I32,) -> (I32,):
            if n >= limit:
                return n
            return loopA(n + 1, limit,)

        main|func() -> (I32,):
            print(loopA(0, \(depth),),)
            return 0
        """
    }

    @Test("重形态的无出口递归：拒绝，且有诊断 —— 不是一声不响地把栈打穿")
    func aHeavyRunawayIsRefusedWithADiagnostic() {
        /// 意图：这条钉的是漏判侧。守卫够得着之前宿主的栈就已打穿，进程连既有输出都留不下。用 1 MB 线程跑
        /// 是为了让触界来得快，不是让它更容易过：判据读的是「有没有诊断」，与栈多大无关。
        let outcome = run(stackSize: 1 << 20, Self.heavyRunaway)
        guard case .refused(let reason) = outcome else {
            Issue.record("重形态无出口递归应当被拒，实测：\(outcome)")
            return
        }
        #expect(
            reason.contains("宿主栈余量不足"),
            "拒绝的理由不是栈余量：\(reason)")
    }

    @Test("轻形态的深度递归：跑得通 —— 旧上限不再是墙")
    func aLightDeepRecursionRunsToItsEnd() {
        /// 意图：这条钉的是误杀侧。层数取 200（深到足以压出误杀），而 32 MB 的线程让这个深度离触界还远 ——
        /// 判据因此不靠「刚好踩线」，也就不随每帧开销漂移。两侧都钉住，调高与调低上限才都无路可走。
        let outcome = run(stackSize: 32 << 20, Self.lightRecursion(depth: 200))
        #expect(outcome == .ran(["200"]), "200 层的标量递归应当跑完，实测：\(outcome)")
    }

    @Test("栈探测读到的是本线程自己的栈，且随新线程的设置走")
    func theStackIsReadFromTheRunningThread() {
        /// 意图：两条判据都建立在「量的是当前线程的栈」之上，所以先把这一层
        /// 钉住。它同时说明为什么判据必须自己指定栈大小 —— 同一台机器上，
        /// 两个线程的栈可以差十六倍。
        let small = Self.reportedStackSize(on: 512 << 10, name: "小栈")
        let large = Self.reportedStackSize(on: 32 << 20, name: "大栈")
        #expect(small > 0, "小栈线程读不到栈边界")
        #expect(large > small, "栈大小没有随线程的设置走：小=\(small) 大=\(large)")
    }

    @Test("留出的余量随栈伸缩，不是固定字节数")
    func theFloorScalesWithTheStack() {
        /// 意图：余量若写成固定值，512 KB 的线程上它会大于整条栈 ——
        /// 守卫就会拒绝**每一次**调用，把「不许崩」变成「什么都不许跑」。
        #expect(RuntimeOps.freeStackFloor(stackSize: 8 << 20) == 1 << 20)
        #expect(RuntimeOps.freeStackFloor(stackSize: 512 << 10) == 256 << 10)
        #expect(RuntimeOps.freeStackFloor(stackSize: 16 << 10) == 256 << 10)
    }
}
