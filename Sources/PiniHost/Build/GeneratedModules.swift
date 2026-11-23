import Foundation
import PiniSemantics
import PiniSyntax

public enum GeneratedModulesError: Error, LocalizedError, Equatable {
    case missingPlan(package: String, planPath: String)
    case staleScript(package: String, planPath: String)
    case missingOutput(package: String, step: String, path: String, planPath: String)
    case unreadableOutput(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingPlan(let package, let planPath):
            return "包 '\(package)' 有 build.pini 但没有构建计划（\(planPath)）；请先运行 `pini build`"
        case .staleScript(let package, let planPath):
            return "包 '\(package)' 的 build.pini 与构建计划不一致（\(planPath)）；请先运行 `pini build`"
        case .missingOutput(let package, let step, let path, let planPath):
            return
                "包 '\(package)' 的翻译步 '\(step)' 没有产物（\(path)）；请先运行 `pini build`"
                + "（计划：\(planPath)）"
        case .unreadableOutput(let path, let reason):
            return "生成的模块 `\(path)` 读不出来：\(reason)"
        }
    }
}

/// 生成模块的装载入口：给定包与计划，返回源码集加生成模块。各命令都经这里取，
/// 谁也不自行拼 `.build` 路径。缺计划、计划过期、产物缺失都报定向诊断，不静默跳过 ——
/// 静默跳过会让「外部符号全不见了」表现为一串未定义调用，与真正的原因隔了好几层。
public enum GeneratedModules {

    public static func attach(to package: Package, packageRoot: String?) throws -> Package {
        guard let root = packageRoot else { return package }
        let layout = try BuildLayout.locate(packageRoot: root)
        guard let plan = try BuildPlan.read(at: layout.planPath, layout: layout) else {
            if BuildScript.exists(packageRoot: root) {
                throw GeneratedModulesError.missingPlan(
                    package: package.name, planPath: layout.planPath)
            }
            return package
        }
        guard !plan.packages.isEmpty else { return package }
        // 计划在、但里面没有这个包：包名改过或计划属于别处。静默跳过会让生成模块凭空消失。
        guard let entry = plan.package(named: package.name) else {
            throw GeneratedModulesError.staleScript(
                package: package.name, planPath: layout.planPath)
        }
        let script = BuildScript.path(packageRoot: entry.root)
        guard scriptHash(at: script) == entry.scriptHash else {
            throw GeneratedModulesError.staleScript(
                package: package.name, planPath: layout.planPath)
        }
        var units = package.fileUnits
        for step in plan.steps(for: package.name) {
            guard FileManager.default.fileExists(atPath: step.output) else {
                throw GeneratedModulesError.missingOutput(
                    package: package.name, step: step.name, path: step.output,
                    planPath: layout.planPath)
            }
            do {
                units.append(try FileLoader.loadUnit(path: step.output))
            } catch {
                throw GeneratedModulesError.unreadableOutput(
                    path: step.output, reason: error.localizedDescription)
            }
        }
        // 跳过名只收宏：它们没有声明可查，但用户写下去时该得到「翻译没产出」而不是「没定义」。
        var unavailable: [String: String] = [:]
        for skip in plan.skips(for: package.name) { unavailable[skip.name] = skip.reason }
        return Package(
            name: package.name, fileUnits: units, rootPath: package.rootPath,
            unavailableNames: unavailable)
    }

    /// 脚本哈希：文件不存在为空串。与计划里的空值同义，都是「没有构建脚本」。
    public static func scriptHash(at path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
        return SHA256.hexDigest(data)
    }
}
