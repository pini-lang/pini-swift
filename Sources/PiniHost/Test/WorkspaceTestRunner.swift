import Foundation
import PiniSemantics
import PiniSyntax

/// 工作区里一个待执行的测试 target。顺序即执行顺序：包按依赖拓扑序，target 按 `[[test]]` 出现序。
public struct WorkspaceTestSuite: Equatable {
    public let packageName: String
    public let targetName: String
    public let packageRoot: String

    public init(packageName: String, targetName: String, packageRoot: String) {
        self.packageName = packageName
        self.targetName = targetName
        self.packageRoot = packageRoot
    }
}

/// 一个测试 target 的执行结果。语义警告随结果带回，怎么呈现由调用方决定。
public struct WorkspaceTestSuiteResult {
    public let suite: WorkspaceTestSuite
    public let warnings: [SemanticWarning]
    public let results: [ProgramRunner.TestRunResult]
    /// 该 target 收集到测试、但全数被跳过名单排除：结果为空不是「没有测试」，报告须说出来。
    public let fullySkipped: Bool

    public init(
        suite: WorkspaceTestSuite, warnings: [SemanticWarning],
        results: [ProgramRunner.TestRunResult], fullySkipped: Bool = false
    ) {
        self.suite = suite
        self.warnings = warnings
        self.results = results
        self.fullySkipped = fullySkipped
    }
}

/// 工作区测试的统一结果：汇总只从逐条结果派生，不另存计数器。
public struct WorkspaceTestReport {
    public let suites: [WorkspaceTestSuiteResult]
    /// 发现到执行结束的墙钟秒数，只进报告末尾，不参与任何判据。
    public let elapsed: TimeInterval

    public var passed: Int { suites.reduce(0) { $0 + $1.results.filter(\.passed).count } }
    public var failed: Int { suites.reduce(0) { $0 + $1.results.filter { !$0.passed }.count } }
    public var total: Int { passed + failed }

    public init(suites: [WorkspaceTestSuiteResult], elapsed: TimeInterval = 0) {
        self.suites = suites
        self.elapsed = elapsed
    }
}

extension WorkspaceTestReport {
    /// 报告全文一次拼好：首行、逐 target 汇总与失败清单不得由不同调用点各拼一次。
    /// 通过的用例只计数不逐条打印，失败的一条不落——降噪不能盖住该看的东西。
    public func rendered(rootLabel: String) -> String {
        var lines = ["测试目标: 工作区 \(rootLabel)（\(suites.count) 个测试 target）"]
        for suite in suites {
            let name = "\(suite.suite.packageName) / \(suite.suite.targetName)"
            let passedHere = suite.results.filter(\.passed).count
            let detail = suite.fullySkipped ? "--skip 全数排除" : "\(passedHere) 通过"
            lines.append("包 \(name)（\(suite.results.count) 个测试，\(detail)）")
            for result in suite.results where !result.passed {
                lines.append(" ✗ \(result.name)\(result.positionLabel): \(result.message)")
            }
        }
        lines.append(String(format: "结果: %d 通过, %d 失败（%.2f 秒）", passed, failed, elapsed))
        return lines.joined(separator: "\n")
    }
}

public enum WorkspaceTestError: Error, LocalizedError, Equatable {
    case noTestTargets(root: String)
    case emptyTarget(package: String, target: String)
    case registrationLost(package: String, target: String, declared: Int, collected: Int)
    case noMatchingTests(filter: String)
    case noMatchingSkip(skip: String)
    case allSkipped(filter: String, skip: [String])
    case cannotEnterRoot(path: String)

    public var errorDescription: String? {
        switch self {
        case .noTestTargets(let root):
            return "工作区 \(root) 未声明任何 [[test]] target；测试门禁不能空跑"
        case .emptyTarget(let package, let target):
            return "包 '\(package)' 的测试 target '\(target)' 未收集到任何 |test 测试函数"
        case .registrationLost(let package, let target, let declared, let collected):
            return
                "包 '\(package)' 的测试 target '\(target)' 声明了 \(declared) 个 |test，"
                + "只收集到 \(collected) 个；测试注册不完整不得读成通过"
        case .noMatchingTests(let filter):
            return "没有测试名匹配筛选条件 '\(filter)'"
        case .noMatchingSkip(let skip):
            return "没有测试名匹配 --skip '\(skip)'；跳过规则写了就必须命中至少一条"
        case .allSkipped(let filter, let skip):
            let listed = skip.map { "'\($0)'" }.joined(separator: " ")
            return "筛选与跳过之后没有测试可跑（--filter '\(filter)'，--skip \(listed)）"
        case .cannotEnterRoot(let path):
            return "无法进入工作区根目录：\(path)"
        }
    }
}

/// 工作区测试的发现与执行。包可见性、依赖图和源码集全部复用 `WorkspaceBuilder`，
/// 不为测试另排一套装载顺序。
public enum WorkspaceTestRunner {

    /// 计划里的测试 target，按包拓扑序与 target 声明序展开；只描述，不装载。
    public static func suites(in plan: WorkspaceBuildPlan) -> [WorkspaceTestSuite] {
        plan.packages.flatMap { package in
            package.targets.filter { $0.kind == .test }.map {
                WorkspaceTestSuite(
                    packageName: package.name, targetName: $0.name,
                    packageRoot: package.rootPath)
            }
        }
    }

    /// 逐 target 做与 `check` 同规的语义/类型门禁，再收集并执行 `|test`。
    /// 运行期工作目录切到工作区根：测试体里的 `./` 相对路径以工作区为基准，
    /// 而不带前缀的相对路径仍按 `moduleRoot()`（包根）解析。
    public static func run(
        plan: WorkspaceBuildPlan, filter: String? = nil, skip: [String] = []
    ) throws -> WorkspaceTestReport {
        let started = Date()
        let declaredSuites = suites(in: plan)
        guard !declaredSuites.isEmpty else {
            throw WorkspaceTestError.noTestTargets(root: plan.rootPath)
        }
        let previous = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(plan.rootPath) else {
            throw WorkspaceTestError.cannotEnterRoot(path: plan.rootPath)
        }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }

        var executed: [WorkspaceTestSuiteResult] = []
        var collectedNames: [String] = []
        // 让位主张按整个工作区收集：邻居包的同名声明也摘掉标准库那份，与自举同口径。
        let claims = try WorkspaceBuilder.claims(for: plan)
        for package in plan.packages {
            for target in package.targets where target.kind == .test {
                let suite = WorkspaceTestSuite(
                    packageName: package.name, targetName: target.name,
                    packageRoot: package.rootPath)
                let progress = ProcessInfo.processInfo.environment["PINI_TEST_PROGRESS"] == "1"
                let startedAt = Date()
                if progress {
                    FileHandle.standardError.write(Data("· \(package.name)/\(target.name)\n".utf8))
                }
                let loaded = try WorkspaceBuilder.load(package: package, target: target, claims: claims)
                let analyzer = SemanticAnalyzer()
                try analyzer.analyze(package: loaded.package)
                let checker = TypeChecker()
                try checker.check(package: loaded.package, foreignConstantFailures: [:])

                let runner = ProgramRunner(
                    ffiConfig: package.manifest.ffi ?? .default,
                    programBase: package.rootPath)
                let lowered = try runner.lowerTests(package: loaded.package)                // 声明数与收集数必须相等：注册在解析或降载里被静默丢掉时，少跑不得当成少写。
                let declaredTests = declaredTestCount(in: loaded.package)
                let collected = lowered.functions.filter(\.isTest).count
                if declaredTests != collected {
                    throw WorkspaceTestError.registrationLost(
                        package: package.name, target: target.name,
                        declared: declaredTests, collected: collected)
                }
                let names = lowered.functions.filter(\.isTest).map(\.name)
                collectedNames.append(contentsOf: names)
                // 选中面与执行面用同一判定：这里算「该不该跑」，执行器按同一条规则跳过。
                let selected = names.filter {
                    ProgramRunner.selectsTest(
                        name: $0, nameFilter: filter, nameSkip: skip)
                }
                let fullySkipped = !names.isEmpty && selected.isEmpty
                let outcomes = try runner.runLoweredTests(
                    lowered, nameFilter: filter, nameSkip: skip)
                if progress {
                    let cost = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
                    FileHandle.standardError.write(
                        Data("  \(package.name)/\(target.name) \(outcomes.count) 条 \(cost)\n".utf8))
                }
                if outcomes.isEmpty {
                    // 筛选未命中的 target 不进报告（与筛选单独生效时的呈现一致）；
                    // 只有跳过名单把它排空时才留下一条说明，空结果不得冒充「没有测试」。
                    guard filter == nil else { continue }
                    guard skip.isEmpty else {
                        executed.append(
                            WorkspaceTestSuiteResult(
                                suite: suite, warnings: analyzer.warnings, results: [],
                                fullySkipped: fullySkipped))
                        continue
                    }
                    throw WorkspaceTestError.emptyTarget(
                        package: package.name, target: target.name)
                }
                executed.append(
                    WorkspaceTestSuiteResult(
                        suite: suite, warnings: analyzer.warnings, results: outcomes,
                        fullySkipped: fullySkipped))
            }
        }
        // 跳过规则写了就必须真的命中：拼错的名字会让「以为跳过了」与「实际没跳」长得一样。
        for text in skip where !collectedNames.contains(where: { $0.contains(text) }) {
            throw WorkspaceTestError.noMatchingSkip(skip: text)
        }
        if let filter, !skip.isEmpty, executed.allSatisfy({ $0.results.isEmpty }) {
            throw WorkspaceTestError.allSkipped(filter: filter, skip: skip)
        }
        if let filter, executed.isEmpty {
            throw WorkspaceTestError.noMatchingTests(filter: filter)
        }
        return WorkspaceTestReport(suites: executed, elapsed: Date().timeIntervalSince(started))
    }

    /// AST 面声明的测试函数数：收集数少于它即说明注册链路丢过节点。
    static func declaredTestCount(in package: Package) -> Int {
        package.fileUnits.reduce(0) { total, unit in
            total
                + unit.module.declarations.filter { decl in
                    guard case .funcDecl(let function) = decl else { return false }
                    return function.modifiers.contains("test")
                }.count
        }
    }
}
