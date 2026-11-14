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

    public init(packages: [PlannedPackage], steps: [PlannedTranslateStep]) {
        self.packages = packages.sorted { $0.name < $1.name }
        self.steps = steps.sorted {
            $0.package == $1.package ? $0.name < $1.name : $0.package < $1.package
        }
    }

    public func package(named name: String) -> PlannedPackage? {
        packages.first { $0.name == name }
    }

    public func steps(for package: String) -> [PlannedTranslateStep] {
        steps.filter { $0.package == package }
    }

    public func replacing(steps: [PlannedTranslateStep]) -> BuildPlan {
        BuildPlan(packages: packages, steps: steps)
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
        return lines.joined(separator: "\n") + "\n"
    }

    private func pair(_ key: String, _ value: String, layout: BuildLayout) throws -> String {
        "\(key) = \"\(try literal(value, layout: layout))\""
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
        return BuildPlan(packages: packages, steps: steps)
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
        return lines.joined(separator: "\n")
    }
}
