import Foundation
import PiniSemantics

/// 计划里的一个包：目录、以及 `build.pini` 的内容哈希。哈希为空表示该包没有构建脚本。
/// 检查器拿它判「计划是否过期」，因此哈希必须覆盖脚本全文，不能只覆盖步骤列表。
public struct PlannedPackage: Equatable, Sendable {
    public let name: String
    public let root: String
    public let scriptHash: String

    public init(name: String, root: String, scriptHash: String) {
        self.name = name
        self.root = root
        self.scriptHash = scriptHash
    }
}

/// 计划里的一条翻译步。`inputHash` 由执行期算：头文件、被包含文件与宏定义合起来才决定产物，
/// 少算任一项，升级工具链或改宏定义后都会静默沿用旧产物。
public struct PlannedTranslateStep: Equatable, Sendable {
    public let package: String
    public let name: String
    public let header: String
    public let includePaths: [String]
    public let defines: [String]
    public let output: String
    public let inputHash: String

    public init(
        package: String, name: String, header: String, includePaths: [String],
        defines: [String], output: String, inputHash: String
    ) {
        self.package = package
        self.name = name
        self.header = header
        self.includePaths = includePaths
        self.defines = defines
        self.output = output
        self.inputHash = inputHash
    }

    /// 换算出替换本步 `inputHash` 与 `output` 的新步骤；执行期与配置期共用同一形状。
    public func with(inputHash: String) -> PlannedTranslateStep {
        PlannedTranslateStep(
            package: package, name: name, header: header, includePaths: includePaths,
            defines: defines, output: output, inputHash: inputHash)
    }
}

/// 计划里的一条宏常量结局：有值记 `value`，没值记理由码与细节。
/// 两个状态同形，自举侧据此区分「有值可降」与「缺计划/求值失败」。
public struct PlannedMacro: Equatable, Sendable {
    public let package: String
    public let name: String
    public let type: String
    public let value: String?
    public let reason: String?
    public let detail: String

    public var isResolved: Bool { value != nil }

    public init(
        package: String, name: String, type: String,
        value: String? = nil, reason: String? = nil, detail: String = ""
    ) {
        self.package = package
        self.name = name
        self.type = type
        self.value = value
        self.reason = reason
        self.detail = detail
    }
}

/// 计划里的一条生成面跳过项：`pini bind` 看见了这个宏名，但没有为它产生声明。
/// 只收宏：其余跳过项各有自己的原因，混进「已知但未翻译」会让未定义名报错指错方向。
public struct PlannedSkip: Equatable, Sendable {
    public let package: String
    public let step: String
    public let name: String
    public let reason: String

    public init(package: String, step: String, name: String, reason: String) {
        self.package = package
        self.step = step
        self.name = name
        self.reason = reason
    }
}

public enum BuildPlanError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case invalid(path: String, reason: String)
    case unrepresentable(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "构建计划 `\(path)` 读不出来：\(reason)"
        case .invalid(let path, let reason):
            return "构建计划 `\(path)` 不成立：\(reason)"
        case .unrepresentable(let path):
            return "路径 `\(path)` 含有引号或换行，写不进计划文件"
        }
    }
}

/// 构建器与其余命令之间唯一的数据接口。计划是纯数据：可打印、可比较、可逐字节复现。
/// 其余命令只读它，绝不执行 `build.pini` —— 脚本写坏只该让 `pini build` 红，不该拖垮整仓检查。
public struct BuildPlan: Equatable, Sendable {
    public static let version = 1
    /// 翻译器版本进缓存键：升级映射规则后产物会变，不换键就会静默沿用旧块。
    public static let translator = "pini-bind/1"

    public let packages: [PlannedPackage]
    public let steps: [PlannedTranslateStep]
    /// 宏常量的求值结局，按包与名索引；旧计划没有这一段，读出来是空表。
    public let macros: [PlannedMacro]
    /// 生成面跳过项：`pini bind` 见到但没翻译的宏名与理由。
    public let skips: [PlannedSkip]

    public init(
        packages: [PlannedPackage], steps: [PlannedTranslateStep],
        macros: [PlannedMacro] = [], skips: [PlannedSkip] = []
    ) {
        self.packages = packages.sorted { $0.name < $1.name }
        self.steps = steps.sorted {
            $0.package == $1.package ? $0.name < $1.name : $0.package < $1.package
        }
        self.macros = macros.sorted {
            $0.package == $1.package ? $0.name < $1.name : $0.package < $1.package
        }
        self.skips = skips.sorted {
            if $0.package != $1.package { return $0.package < $1.package }
            if $0.step != $1.step { return $0.step < $1.step }
            return $0.name < $1.name
        }
    }

    public func package(named name: String) -> PlannedPackage? {
        packages.first { $0.name == name }
    }

    public func steps(for package: String) -> [PlannedTranslateStep] {
        steps.filter { $0.package == package }
    }

    public func macros(for package: String) -> [PlannedMacro] {
        macros.filter { $0.package == package }
    }

    public func skips(for package: String) -> [PlannedSkip] {
        skips.filter { $0.package == package }
    }

    public func replacing(steps: [PlannedTranslateStep]) -> BuildPlan {
        BuildPlan(packages: packages, steps: steps, macros: macros, skips: skips)
    }

    /// 只换宏段：跳过段与步骤原样留住，写宏不该顺手丢别的结果段。
    public func replacing(macros: [PlannedMacro]) -> BuildPlan {
        BuildPlan(packages: packages, steps: steps, macros: macros, skips: skips)
    }

    /// 宏求值要沿翻译步的头文件走一遍：生成的 `|macro` 条目值只能来自声明它的那个头文件。
    /// 头文件写绝对路径并加引号，包含路径与宏定义一并带上，配置与构建才看同一份输入。
    public func ffiConfig(for package: String, base: FFIConfig) -> FFIConfig {
        let steps = steps(for: package)
        guard !steps.isEmpty else { return base }
        return FFIConfig(
            abi: base.abi, searchPaths: base.searchPaths, libs: base.libs,
            headers: base.headers + steps.map { "\"\($0.header)\"" },
            includePaths: base.includePaths + steps.flatMap(\.includePaths),
            defines: base.defines + steps.flatMap(\.defines))
    }

    // MARK: - 渲染

    /// 路径一律写根相对：计划因此与检出位置无关，两台机器上的同一输入产出逐字节相同的计划。
    public func render(layout: BuildLayout) throws -> String {
        var lines: [String] = []
        lines.append("[plan]")
        lines.append("version = \(Self.version)")
        lines.append("translator = \"\(Self.translator)\"")
        for package in packages {
            lines.append("")
            lines.append("[[package]]")
            lines.append(try pair("name", package.name, layout: layout))
            lines.append(try pair("root", package.root, layout: layout))
            lines.append(try pair("script_hash", package.scriptHash, layout: layout))
        }
        for step in steps {
            lines.append("")
            lines.append("[[step]]")
            lines.append(try pair("package", step.package, layout: layout))
            lines.append(try pair("name", step.name, layout: layout))
            lines.append(try pair("header", step.header, layout: layout))
            lines.append(try array("include_paths", step.includePaths, layout: layout))
            lines.append(try array("defines", step.defines, layout: layout))
            lines.append(try pair("output", step.output, layout: layout))
            lines.append(try pair("input_hash", step.inputHash, layout: layout))
        }
        // 宏段与跳过段排在步骤之后：旧读取器只认前两段，多余的表原样忽略。
        for macro in macros {
            lines.append("")
            lines.append("[[macro]]")
            lines.append(try rawPair("package", macro.package))
            lines.append(try rawPair("name", macro.name))
            lines.append(try rawPair("state", macro.isResolved ? "value" : "unresolved"))
            lines.append(try rawPair("type", macro.type))
            if let value = macro.value {
                lines.append(try rawPair("value", value))
            } else if let reason = macro.reason {
                lines.append(try rawPair("reason", reason))
                if !macro.detail.isEmpty {
                    lines.append(try rawPair("detail", macro.detail))
                }
            }
        }
        for skip in skips {
            lines.append("")
            lines.append("[[skip]]")
            lines.append(try rawPair("package", skip.package))
            lines.append(try rawPair("step", skip.step))
            lines.append(try rawPair("name", skip.name))
            lines.append(try rawPair("reason", skip.reason))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func pair(_ key: String, _ value: String, layout: BuildLayout) throws -> String {
        "\(key) = \"\(try literal(value, layout: layout))\""
    }

    /// 非路径值（宏名、理由码、数值）不参与根相对换算，但同样不许带引号与换行。
    private func rawPair(_ key: String, _ value: String) throws -> String {
        guard !value.contains("\""), !value.contains("\n") else {
            throw BuildPlanError.unrepresentable(path: value)
        }
        return "\(key) = \"\(value)\""
    }

    private func array(_ key: String, _ values: [String], layout: BuildLayout) throws -> String {
        let items = try values.map { "\"\(try literal($0, layout: layout))\"" }
        return "\(key) = [\(items.joined(separator: ", "))]"
    }

    private func literal(_ value: String, layout: BuildLayout) throws -> String {
        let text = layout.relativeToRoot(value)
        guard !text.contains("\""), !text.contains("\n") else {
            throw BuildPlanError.unrepresentable(path: text)
        }
        return text
    }

    // MARK: - 读取

    public static func read(at path: String, layout: BuildLayout) throws -> BuildPlan? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw BuildPlanError.unreadable(path: path, reason: error.localizedDescription)
        }
        let document = MiniTOML.parse(text)
        let header = document.plain("plan")
        guard let rawVersion = header["version"], let version = Int(rawVersion) else {
            throw BuildPlanError.invalid(path: path, reason: "缺 version 或不是整数")
        }
        guard version == Self.version else {
            throw BuildPlanError.invalid(
                path: path, reason: "版本 \(version) 与当前 \(Self.version) 不符，请重跑 `pini build`")
        }
        var packages: [PlannedPackage] = []
        for table in document.arrayTables["package"] ?? [] {
            guard let name = table["name"], let root = table["root"] else {
                throw BuildPlanError.invalid(path: path, reason: "[[package]] 缺 name 或 root")
            }
            packages.append(
                PlannedPackage(
                    name: name, root: layout.absolute(root), scriptHash: table["script_hash"] ?? ""))
        }
        var steps: [PlannedTranslateStep] = []
        for table in document.arrayTables["step"] ?? [] {
            guard let package = table["package"], let name = table["name"],
                let header = table["header"], let output = table["output"]
            else {
                throw BuildPlanError.invalid(
                    path: path, reason: "[[step]] 缺 package / name / header / output")
            }
            steps.append(
                PlannedTranslateStep(
                    package: package, name: name, header: layout.absolute(header),
                    includePaths: MiniTOML.parseArray(table["include_paths"] ?? "[]")
                        .map { layout.absolute($0) },
                    defines: MiniTOML.parseArray(table["defines"] ?? "[]"),
                    output: layout.absolute(output),
                    inputHash: table["input_hash"] ?? ""))
        }
        var macros: [PlannedMacro] = []
        for table in document.arrayTables["macro"] ?? [] {
            guard let package = table["package"], let name = table["name"],
                let state = table["state"], let type = table["type"]
            else {
                throw BuildPlanError.invalid(
                    path: path, reason: "[[macro]] 缺 package / name / state / type")
            }
            switch state {
            case "value":
                guard let value = table["value"] else {
                    throw BuildPlanError.invalid(
                        path: path, reason: "[[macro]] \(name) 标为 value 但缺 value")
                }
                macros.append(
                    PlannedMacro(package: package, name: name, type: type, value: value))
            case "unresolved":
                guard let reason = table["reason"] else {
                    throw BuildPlanError.invalid(
                        path: path, reason: "[[macro]] \(name) 标为 unresolved 但缺 reason")
                }
                macros.append(
                    PlannedMacro(
                        package: package, name: name, type: type,
                        reason: reason, detail: table["detail"] ?? ""))
            default:
                throw BuildPlanError.invalid(
                    path: path, reason: "[[macro]] \(name) 的 state 是 `\(state)`，只认 value / unresolved")
            }
        }
        var skips: [PlannedSkip] = []
        for table in document.arrayTables["skip"] ?? [] {
            guard let package = table["package"], let step = table["step"],
                let name = table["name"], let reason = table["reason"]
            else {
                throw BuildPlanError.invalid(
                    path: path, reason: "[[skip]] 缺 package / step / name / reason")
            }
            skips.append(
                PlannedSkip(package: package, step: step, name: name, reason: reason))
        }
        return BuildPlan(packages: packages, steps: steps, macros: macros, skips: skips)
    }

    /// 给人读的计划文本。`--print-plan` 打它：工具接口的第一形态是文本，协议等有消费方再谈。
    public func describe(layout: BuildLayout) -> String {
        var lines: [String] = []
        lines.append("构建计划：\(steps.count) 条翻译步，\(packages.count) 个包（profile=\(layout.profile)）")
        for package in packages {
            let scripts = package.scriptHash.isEmpty ? "无 build.pini" : "脚本 \(package.scriptHash.prefix(8))"
            lines.append("  包 \(package.name)（\(layout.relativeToRoot(package.root))，\(scripts)）")
        }
        for step in steps {
            lines.append("  \(step.package)/\(step.name) ← \(layout.relativeToRoot(step.header))")
            if !step.includePaths.isEmpty {
                lines.append("    包含路径: \(step.includePaths.map { layout.relativeToRoot($0) }.joined(separator: ", "))")
            }
            if !step.defines.isEmpty {
                lines.append("    定义: \(step.defines.joined(separator: ", "))")
            }
            lines.append("    输出: \(layout.relativeToRoot(step.output))")
        }
        let unresolved = macros.filter { !$0.isResolved }.count
        if !macros.isEmpty {
            lines.append("  宏常量: \(macros.count) 条（未求值 \(unresolved)）")
        }
        if !skips.isEmpty {
            lines.append("  生成面跳过: \(skips.count) 条")
        }
        return lines.joined(separator: "\n")
    }
}
