import Foundation
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

// 环检测的判据：只读边表，不依赖编译器状态。路径首尾同名、同一环只报一次、无环不报、
// 不含给定块的环（普通递归）不报。名字排序按 Unicode 标量，故纯算法用例用 A/B/C 取名。
struct GivenCycleDetectorTests: Sendable, PiniSourceLowering {

    @Test("自环：A 取用自己，报 A → A")
    func selfCycleIsFound() {
        let cycles = GivenCycleDetector.cycles(in: ["A": ["A"]], givenBlocks: ["A"])
        #expect(cycles == [["A", "A"]], "实际：\(cycles)")
    }

    @Test("互环：A 与 B 互相取用，只报一条且起点取最小名字")
    func mutualCycleIsReportedOnce() {
        let cycles = GivenCycleDetector.cycles(
            in: ["B": ["A"], "A": ["B"]], givenBlocks: ["A", "B"])
        #expect(cycles == [["A", "B", "A"]], "实际：\(cycles)")
    }

    @Test("三块成环：路径按取用顺序完整给出")
    func threeNodeCycleKeepsThePath() {
        let cycles = GivenCycleDetector.cycles(
            in: ["A": ["B"], "B": ["C"], "C": ["A"]], givenBlocks: ["A", "B", "C"])
        #expect(cycles == [["A", "B", "C", "A"]], "实际：\(cycles)")
    }

    @Test("无环不报：DAG 与空图都返回空表")
    func acyclicGraphIsSilent() {
        let dag = ["A": ["B", "C"], "B": ["C"], "C": []]
        let cycles = GivenCycleDetector.cycles(in: dag, givenBlocks: ["A", "B", "C"])
        #expect(cycles.isEmpty, "实际：\(cycles)")
        #expect(GivenCycleDetector.cycles(in: [:], givenBlocks: []).isEmpty)
    }

    @Test("函数键不干扰：main 取用甲块、甲块自环，只报甲块那条")
    func functionEdgesDoNotJoinTheCycle() {
        /// 意图：边表混着「函数 → 给定块」的边，函数没有入边，不该被卷进环路径。
        let edges = ["main": ["甲块"], "甲块": ["甲块"]]
        let cycles = GivenCycleDetector.cycles(in: edges, givenBlocks: ["甲块"])
        #expect(cycles == [["甲块", "甲块"]], "实际：\(cycles)")
    }

    @Test("纯函数递归不报：环里没有给定块就不是物化环")
    func plainRecursionIsSilent() {
        /// 驳回性：加了调用边之后，每个递归函数都会成环。不按「环里必须有给定块」过滤，
        /// 告警会淹没所有递归代码。
        let edges = ["递归": ["递归"], "甲块": ["递归"]]
        let cycles = GivenCycleDetector.cycles(in: edges, givenBlocks: ["甲块"])
        #expect(cycles.isEmpty, "实际：\(cycles)")
    }

    @Test("间接环：路径穿过两个普通函数，起点仍是给定块")
    func cycleThroughFunctionsIsFound() {
        /// 意图：字段初值 → 函数 → 函数 → 取用自己，这条链上的边一半是调用、一半是取用。
        /// 起点旋转到给定块而不是最小名字（`取` 小于 `甲`），否则告警取不到声明位置。
        let edges = ["甲块": ["取数"], "取数": ["读甲"], "读甲": ["甲块"]]
        let cycles = GivenCycleDetector.cycles(in: edges, givenBlocks: ["甲块"])
        #expect(cycles == [["甲块", "取数", "读甲", "甲块"]], "实际：\(cycles)")
    }

    @Test("端到端：最短环语料降载后，图里能检出那条自环")
    func loweredSourceYieldsTheCycle() throws {
        /// 意图：补图与检测接得上 —— 降载出的边表直接喂纯函数就能报出环，不必执行程序。
        /// 这条语料 check 通过、run 会被信号 10 杀掉，检测的价值就是它在不执行时也看得见。
        let source = #"""
        [甲块|given]
            值: I32 = 读甲()

        读甲|func(using 甲: 甲块,) -> (I32,):
            return 甲.值

        main|func() -> ():
            print(1)
            return
        """#
        let module = try lowered(source)
        let cycles = GivenCycleDetector.cycles(in: merged(module), givenBlocks: ["甲块"])
        #expect(cycles == [["甲块", "甲块"]], "实际：\(module.givenReferences) + \(module.callReferences)")
    }

    @Test("端到端：间接环降载后走通了调用边")
    func loweredSourceYieldsTheIndirectCycle() throws {
        /// 意图：这正是窄射程漏掉的那一类 —— 字段初值调 `取数()`，`取数` 体内才取用 `甲块`。
        /// 取用边落在**调用方**（`取数`）而不是被调用的 `读甲` 上：实参在调用点插入，这条是既有的结构事实。
        /// 所以只补一条「甲块 → 取数」的调用边，环就闭合成两块。
        let source = #"""
        [甲块|given]
            值: I32 = 取数()

        取数|func() -> (I32,):
            return 读甲()

        读甲|func(using 甲: 甲块,) -> (I32,):
            return 甲.值

        main|func() -> ():
            print(1)
            return
        """#
        let module = try lowered(source)
        let cycles = GivenCycleDetector.cycles(in: merged(module), givenBlocks: ["甲块"])
        #expect(
            cycles == [["甲块", "取数", "甲块"]],
            "实际：\(module.givenReferences) + \(module.callReferences)")
    }

    @Test("端到端：环穿过方法体，路径翻成源码写法")
    func loweredSourceYieldsCycleThroughMethod() throws {
        /// 意图：方法体不在 `functions` 里，得单独并进图 —— 漏了它，这条环在方法那里断成两截。
        /// 而方法名在 IR 里是 `方法名__类型名` 的 mangle 形态，告警必须翻回 `类型.方法` 才读得懂。
        let source = #"""
        [甲块|given]
            值: I32 = 取数()

        (工具)
        数: I32 = 0

        ((工具))
        读数|self() -> (I32,):
            return 读甲()

        读甲|func(using 甲: 甲块,) -> (I32,):
            return 甲.值

        取数|func() -> (I32,):
            return 工具().读数()

        main|func() -> ():
            print(1)
            return
        """#
        let module = try lowered(source)
        let cycles = GivenCycleDetector.cycles(in: merged(module), givenBlocks: ["甲块"])
        let shown = cycles.map { path in path.map { module.displayNames[$0] ?? $0 } }
        #expect(shown == [["甲块", "取数", "工具.读数", "甲块"]], "实际：\(shown)")
        #expect(
            module.displayNames.values.contains("工具.读数"),
            "方法没有记下源码写法：\(module.displayNames)")
    }

    @Test("警告元数据：E7-003、warning 级、位置透传、{path} 取展示形")
    func warningMetadataIsRouted() {
        let loc = SourceLocation(line: 2, column: 5, fileName: "a.pini")
        let warning = SemanticWarning.givenCycle(path: ["甲块", "乙块", "甲块"], location: loc)
        #expect(warning.diagnosticCode == "E7-003")
        #expect(warning.diagnosticSeverity == .warning)
        #expect(warning.diagnosticLocation == loc)
        // 驳回性：槽里不能是 `["甲块", "乙块", "甲块"]` 这种 Swift 描述，那是给人看的句子。
        #expect(ErrorFormatter.diagnosticArgs(of: warning)["path"] == "甲块 → 乙块 → 甲块")
    }

    @Test("文案带环路径，且不把占位符印给用户")
    func warningRendersThePath() {
        let warning = SemanticWarning.givenCycle(
            path: ["甲块", "乙块", "甲块"],
            location: SourceLocation(line: 1, column: 1, fileName: "a.pini"))
        let text = ErrorFormatter.formatDiagnostic(warning, source: "x")
        #expect(text.contains("甲块 → 乙块 → 甲块"), "实际：\(text)")
        #expect(!text.contains("{path}"), "实际：\(text)")
        #expect(text.contains("E7-003"), "实际：\(text)")
    }

    /// 检测器吃一张图，IR 里存两张表。合并放在用例这侧，与 CLI 的 `givenCycleWarnings` 同规。
    private func merged(_ module: IRModule) -> [String: [String]] {
        var edges = module.givenReferences
        for (name, targets) in module.callReferences { edges[name, default: []] += targets }
        return edges
    }
}
