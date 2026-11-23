import Foundation
import PiniIR
import PiniSemantics
import PiniSyntax

/// 配置期的一条翻译步：计划里的形状，加上它来自哪个包根。包根是配置期唯一需要记住的上下文，
/// 执行期据此把头文件与包含路径换成绝对路径。
public struct ConfiguredStep: Equatable, Sendable {
    public let planned: PlannedTranslateStep
    public let spec: TranslateStepSpec
    public let packageRoot: String
}

/// 配置期的产出：一张可打印、可比较的计划。它不碰 clang、不读环境、不写文件 ——
/// 这三条让计划在任何机器上都能复现，也让 `--print-plan` 在没装 clang 时照样可用。
public struct ConfiguredBuild: Equatable, Sendable {
    public let layout: BuildLayout
    public let packages: [PlannedPackage]
    public let steps: [ConfiguredStep]

    public var plan: BuildPlan {
        BuildPlan(packages: packages, steps: steps.map(\.planned))
    }
}

public struct BuildStepOutcome: Sendable {
    public let step: ConfiguredStep
    public let translated: Bool
    public let skipped: [CHeaderSkip]
    public let fromIncludedHeaders: Int
}

public struct BuildRunReport: Sendable {
    public let outcomes: [BuildStepOutcome]
    public let plan: BuildPlan
    public let planPath: String
}

/// 构建器：配置期只登记，执行期才翻译。两段分开不是风格选择 ——
/// 合成一段就得在配置期调 clang，计划随之与机器绑定，`--print-plan` 也就失去意义。
public enum BuildRunner {

    /// 配置期。路径不是包（单文件、无清单目录）时返回 nil，由调用方走单文件检查路径。
    public static func configure(rootDirectory: String) throws -> ConfiguredBuild? {
        let root = ModuleDependencyLoader.shared.canonicalPath(
            packagePath: rootDirectory, relativeTo: FileManager.default.currentDirectoryPath)
        let members: [(name: String, root: String)]
        let layout: BuildLayout
        if let workspace = try WorkspaceBuilder.plan(rootDirectory: root) {
            members = workspace.packages.map { ($0.name, $0.rootPath) }
            layout = BuildLayout(root: workspace.rootPath, profile: workspace.profile)
        } else if let manifest = try FileLoader.loadManifest(directory: root) {
            members = [(manifest.name, root)]
            /// 成员单独构建时计划仍落工作区根：布局只有一处定义，装载器按同一处去找。
            layout = try BuildLayout.locate(packageRoot: root)
        } else {
            return nil
        }

        var packages: [PlannedPackage] = []
        var steps: [ConfiguredStep] = []
        for member in members {
            let scriptPath = BuildScript.path(packageRoot: member.root)
            let specs = try BuildScript.steps(packageRoot: member.root) ?? []
            packages.append(
                PlannedPackage(
                    name: member.name, root: member.root,
                    scriptHash: GeneratedModules.scriptHash(at: scriptPath)))
            for spec in specs {
                let planned = PlannedTranslateStep(
                    package: member.name, name: spec.name,
                    header: absolute(spec.header, relativeTo: member.root),
                    includePaths: spec.includePaths.map { absolute($0, relativeTo: member.root) },
                    defines: spec.defines,
                    output: layout.generatedPath(package: member.name, step: spec.name),
                    inputHash: "")
                steps.append(
                    ConfiguredStep(planned: planned, spec: spec, packageRoot: member.root))
            }
        }
        return ConfiguredBuild(layout: layout, packages: packages, steps: steps)
    }

    /// 执行期。指纹一致的步直接复用产物；其余重翻。计划最后落盘，翻译中途失败不留半张计划。
    public static func execute(_ configured: ConfiguredBuild) throws -> BuildRunReport {
        let previous = try BuildPlan.read(at: configured.layout.planPath, layout: configured.layout)
        var outcomes: [BuildStepOutcome] = []
        var steps: [PlannedTranslateStep] = []
        var skips: [PlannedSkip] = []
        for step in configured.steps {
            let options = CHeaderTranslator.Options(
                header: step.planned.header,
                includePaths: step.planned.includePaths,
                defines: step.planned.defines,
                blockName: step.spec.name)
            let digest = try CHeaderTranslator.inputDigest(options)
            let reusable =
                previous?.steps.contains {
                    $0.package == step.planned.package && $0.name == step.planned.name
                        && $0.inputHash == digest
                        && FileManager.default.fileExists(atPath: step.planned.output)
                } ?? false
            if reusable {
                outcomes.append(
                    BuildStepOutcome(
                        step: step, translated: false, skipped: [], fromIncludedHeaders: 0))
                /// 复用步不重翻，跳过表沿用旧计划里这一步的行：丢了它们，E4-046 会随增量构建消失。
                skips += (previous?.skips ?? []).filter {
                    $0.package == step.planned.package && $0.step == step.planned.name
                }
            } else {
                let translation = try CHeaderTranslator.translate(options)
                try write(translation.text, to: step.planned.output)
                outcomes.append(
                    BuildStepOutcome(
                        step: step, translated: true, skipped: translation.skipped,
                        fromIncludedHeaders: translation.fromIncludedHeaders))
                skips += translation.skipped.filter(\.isMacro).map {
                    PlannedSkip(
                        package: step.planned.package, step: step.planned.name,
                        name: $0.name, reason: $0.reason)
                }
            }
            steps.append(step.planned.with(inputHash: digest))
        }
        /// 只构建一个成员时，计划里别的包必须原样留住：覆盖写会让它们的检查凭空要求重跑。
        let owned = Set(configured.packages.map(\.name))
        let keptPackages = previous?.packages.filter { !owned.contains($0.name) } ?? []
        let keptSteps = previous?.steps.filter { !owned.contains($0.package) } ?? []
        let keptMacros = previous?.macros.filter { !owned.contains($0.package) } ?? []
        let keptSkips = previous?.skips.filter { !owned.contains($0.package) } ?? []
        let plan = BuildPlan(
            packages: keptPackages + configured.packages, steps: keptSteps + steps,
            macros: keptMacros, skips: keptSkips + skips)
        /// 没有翻译步也不曾有计划时不落盘：没构建面的包不该多个空文件。
        if !steps.isEmpty || previous != nil {
            try write(try plan.render(layout: configured.layout), to: configured.layout.planPath)
        }
        return BuildRunReport(
            outcomes: outcomes, plan: plan, planPath: configured.layout.planPath)
    }

    /// 宏段：翻译完成后按包重算全部 `|macro`，把值与未求值理由写进计划。
    /// 自举侧不启动 C 编译器，值只能从这里来；这一步因此放在计划已含新版翻译步之后。
    /// 求值不依赖类型检查，源码只需解析得出声明；声明之外的一切留给 `check`。
    public static func recordMacros(_ plan: BuildPlan, layout: BuildLayout) throws -> BuildPlan {
        var rows: [PlannedMacro] = []
        for entry in plan.packages {
            let manifest = try FileLoader.loadManifest(directory: entry.root)
            let package = try FileLoader.loadDirectory(
                path: entry.root, manifest: manifest, withStdlib: false)
            let attached = try GeneratedModules.attach(to: package, packageRoot: entry.root)
            let symbols = attached.fileUnits.flatMap { unit -> [ForeignSymbol] in
                unit.module.declarations.flatMap { decl -> [ForeignSymbol] in
                    guard case .foreignDecl(let block) = decl else { return [] }
                    return block.symbols
                }
            }
            guard symbols.contains(where: { $0.flags.contains("macro") }) else { continue }
            let config = plan.ffiConfig(
                for: entry.name, base: manifest?.ffi ?? .default)
            let evaluation = try ForeignMacroEvaluator.evaluate(symbols: symbols, config: config)
            var values: [String: IRForeignConstant] = [:]
            for constant in evaluation.values { values[constant.name] = constant }
            for symbol in symbols where symbol.flags.contains("macro") {
                let type = symbol.annotation.describe()
                if let constant = values[symbol.name] {
                    rows.append(
                        PlannedMacro(
                            package: entry.name, name: symbol.name, type: type,
                            value: planValue(constant.value)))
                } else if let failure = evaluation.failures[symbol.name] {
                    rows.append(
                        PlannedMacro(
                            package: entry.name, name: symbol.name, type: type,
                            reason: failure.planReason, detail: failure.planDetail))
                }
                /// 两边都没有的是非标量声明：它归 E4-045，不在这里编一条「缺计划」。
            }
        }
        let updated = plan.replacing(macros: rows)
        /// 没有翻译步、没有任何宏条目、盘上也没有旧计划时不落盘：没构建面的包不该多个空计划。
        let existed = FileManager.default.fileExists(atPath: layout.planPath)
        if !updated.steps.isEmpty || !updated.macros.isEmpty || !updated.skips.isEmpty || existed {
            try write(try updated.render(layout: layout), to: layout.planPath)
        }
        return updated
    }

    /// 计划里的值一律字符串：整数不经浮点中转，浮点取最短往返十进制。
    private static func planValue(_ value: IRForeignConstantValue) -> String {
        switch value {
        case .integer(let number): return String(number)
        case .float(let number): return String(number)
        }
    }

    private static func write(_ text: String, to path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func absolute(_ path: String, relativeTo root: String) -> String {
        path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
    }
}
