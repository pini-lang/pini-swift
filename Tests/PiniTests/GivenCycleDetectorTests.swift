import Foundation
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

// 环检测的判据：只读边表，不依赖编译器状态。路径首尾同名、同一环只报一次、无环不报。
// 名字排序按 Unicode 标量，故纯算法用例用 A/B/C 取名，端到端那条才用中文语料。
struct GivenCycleDetectorTests: Sendable, PiniSourceLowering {

    @Test("自环：A 取用自己，报 A → A")
    func selfCycleIsFound() {
        let cycles = GivenCycleDetector.cycles(in: ["A": ["A"]])
        #expect(cycles == [["A", "A"]], "实际：\(cycles)")
    }

    @Test("互环：A 与 B 互相取用，只报一条且起点取最小名字")
    func mutualCycleIsReportedOnce() {
        let cycles = GivenCycleDetector.cycles(in: ["B": ["A"], "A": ["B"]])
        #expect(cycles == [["A", "B", "A"]], "实际：\(cycles)")
    }

    @Test("三块成环：路径按取用顺序完整给出")
    func threeNodeCycleKeepsThePath() {
        let cycles = GivenCycleDetector.cycles(in: ["A": ["B"], "B": ["C"], "C": ["A"]])
        #expect(cycles == [["A", "B", "C", "A"]], "实际：\(cycles)")
    }

    @Test("无环不报：DAG 与空图都返回空表")
    func acyclicGraphIsSilent() {
        let dag = ["A": ["B", "C"], "B": ["C"], "C": []]
        #expect(GivenCycleDetector.cycles(in: dag).isEmpty, "实际：\(GivenCycleDetector.cycles(in: dag))")
        #expect(GivenCycleDetector.cycles(in: [:]).isEmpty)
    }

    @Test("函数键不干扰：main 取用甲块、甲块自环，只报甲块那条")
    func functionEdgesDoNotJoinTheCycle() {
        /// 意图：边表混着「函数 → 给定块」的边，函数没有入边，不该被卷进环路径。
        let edges = ["main": ["甲块"], "甲块": ["甲块"]]
        let cycles = GivenCycleDetector.cycles(in: edges)
        #expect(cycles == [["甲块", "甲块"]], "实际：\(cycles)")
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
        let cycles = GivenCycleDetector.cycles(in: module.givenReferences)
        #expect(cycles == [["甲块", "甲块"]], "实际：\(module.givenReferences)")
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
}
