import Foundation
import PiniSemantics
import PiniSyntax

public struct WorkspaceTargetPlan: Equatable {
    public let name: String
    public let kind: ModuleTargetKind
    public let entry: String
    public let irPath: String
    public let executablePath: String?
    public let interfacePath: String

    /// 测试 target 只描述源码与依赖，普通 build 不为它生成生产产物。
    public var isBuiltByDefault: Bool { kind != .test }
}

public struct WorkspacePackagePlan: Equatable {
    public let name: String
    public let rootPath: String
    public let manifest: ModuleManifest
    public let targets: [WorkspaceTargetPlan]
}

public struct WorkspaceBuildPlan: Equatable {
    public let rootPath: String
    public let profile: String
    public let packages: [WorkspacePackagePlan]
}

public struct WorkspaceLoadedTarget {
    public let package: Package
    public let publicInterface: String
}

public enum WorkspaceError: Error, Equatable {
    case invalidMember(path: String, reason: String)
    case missingManifest(path: String)
    case duplicatePackage(name: String)
    case duplicateTarget(package: String, target: String)
    case invalidTarget(package: String, target: String, reason: String)
    case dependencyCycle(chain: [String])
    case sourceMissing(package: String, target: String)
    case dependencyDrift(package: String, missing: [String], extra: [String])
}

extension WorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMember(let path, let reason):
            return "工作区成员 '\(path)' 非法：\(reason)"
        case .missingManifest(let path):
            return "工作区成员缺少合法 pini.toml：\(path)"
        case .duplicatePackage(let name):
            return "工作区出现重复包名 '\(name)'；包名是依赖图身份，必须唯一"
        case .duplicateTarget(let package, let target):
            return "包 '\(package)' 出现重复 target '\(target)'"
        case .invalidTarget(let package, let target, let reason):
            return "包 '\(package)' 的 target '\(target)' 非法：\(reason)"
        case .dependencyCycle(let chain):
            return "工作区依赖成环：\(chain.joined(separator: " -> "))"
        case .sourceMissing(let package, let target):
            return "包 '\(package)' 的 target '\(target)' 没有入口或源码"
        case .dependencyDrift(let package, let missing, let extra):
            var parts: [String] = []
            if !missing.isEmpty { parts.append("import 未声明：\(missing.joined(separator: ", "))") }
            if !extra.isEmpty { parts.append("require 未使用：\(extra.joined(separator: ", "))") }
            return "包 '\(package)' 的 require 与 import 不一致（\(parts.joined(separator: "；"))）"
        }
    }
}

/// 从根清单生成确定性的包与 target 计划；外部依赖不混入本地工作区节点。
public enum WorkspaceBuilder {

    public static func plan(rootDirectory: String) throws -> WorkspaceBuildPlan? {
        let root = ModuleDependencyLoader.shared.canonicalPath(
            packagePath: rootDirectory, relativeTo: FileManager.default.currentDirectoryPath)
        guard let workspace = try WorkspaceManifest.load(directory: root) else { return nil }
        var packagesByName: [String: WorkspacePackagePlan] = [:]
        var seenRoots: Set<String> = []
        var executableOwners: [String: String] = [:]
        for member in workspace.members {
            guard !member.hasPrefix("/") else {
                throw WorkspaceError.invalidMember(path: member, reason: "成员必须使用工作区相对路径")
            }
            let packageRoot = ModuleDependencyLoader.shared.canonicalPath(
                packagePath: member, relativeTo: root)
            guard packageRoot.hasPrefix(root + "/") else {
                throw WorkspaceError.invalidMember(path: member, reason: "成员不得越出工作区根")
            }
            guard seenRoots.insert(packageRoot).inserted else {
                throw WorkspaceError.invalidMember(path: member, reason: "同一目录被重复登记")
            }
            guard let manifest = try FileLoader.loadManifest(directory: packageRoot) else {
                throw WorkspaceError.missingManifest(path: packageRoot)
            }
            guard packagesByName[manifest.name] == nil else {
                throw WorkspaceError.duplicatePackage(name: manifest.name)
            }
            let targets = try targetPlans(
                for: manifest, packageRoot: packageRoot,
                workspaceRoot: root, profile: workspace.profile)
            for target in targets where target.kind == .executable {
                if let previous = executableOwners[target.name] {
                    throw WorkspaceError.invalidTarget(
                        package: manifest.name, target: target.name,
                        reason: "与包 '\(previous)' 的可执行产物重名")
                }
                executableOwners[target.name] = manifest.name
            }
            packagesByName[manifest.name] = WorkspacePackagePlan(
                name: manifest.name, rootPath: packageRoot,
                manifest: manifest, targets: targets)
        }

        let ordered = try topologicalOrder(packagesByName)
        return WorkspaceBuildPlan(
            rootPath: root, profile: workspace.profile,
            packages: ordered.compactMap { packagesByName[$0] })
    }

    /// 装载单个 target。普通库只取生产源码，可执行入口彼此隔离，测试入口只加入测试 target。
    /// 标准库由调用方决定是否并入：编译器自身构建必须关，否则改标准库就要重建编译器。
    public static func load(
        package plan: WorkspacePackagePlan, target: WorkspaceTargetPlan,
        withStdlib: Bool = true
    ) throws -> WorkspaceLoadedTarget {
        let loaded = try FileLoader.loadDirectory(
            path: plan.rootPath, manifest: plan.manifest, withStdlib: false)
        func relative(_ unit: FileUnit) -> String { loaded.relativeFileName(unit.fileName) }
        let production = loaded.fileUnits.filter { relative($0).hasPrefix("src/") }
        let executableEntries = Set(plan.manifest.targets.filter { $0.kind == .executable }.map(\.entry))
        let common = production.filter { !executableEntries.contains(relative($0)) }
        var selected: [FileUnit]
        switch target.kind {
        case .library:
            selected = common
        case .executable:
            selected = common + production.filter { relative($0) == target.entry }
        case .test:
            let prefix = target.entry.hasSuffix("/") ? target.entry : target.entry + "/"
            selected =
                common
                + loaded.fileUnits.filter {
                    relative($0) == target.entry || relative($0).hasPrefix(prefix)
                }
        }
        guard !selected.isEmpty else {
            throw WorkspaceError.sourceMissing(package: plan.name, target: target.name)
        }
        if target.kind == .executable,
            !production.contains(where: { relative($0) == target.entry })
        {
            throw WorkspaceError.sourceMissing(package: plan.name, target: target.name)
        }
        // 生成模块不在源码树里，`src/` 过滤与点前缀扫描都看不见它；由计划显式登记后接上。
        let interfacePackage = try GeneratedModules.attach(
            to: Package(name: plan.name, fileUnits: selected, rootPath: plan.rootPath),
            packageRoot: plan.rootPath)
        let symbols = try PackageSymbolIndex.build(package: interfacePackage).publicSymbols
        let interface = (["package=\(plan.name)"] + symbols).joined(separator: "\n") + "\n"
        if let drift = try ModuleToolchain.checkRequireImportAlignment(
            rootDir: plan.rootPath, manifest: plan.manifest, package: interfacePackage)
        {
            // 测试 target 的 import 是包依赖的子集：只拦「用了未声明」，不因少用而判漂移。
            let blocking =
                target.kind == .test ? !drift.missingInRequire.isEmpty : drift.hasDrift
            if blocking {
                throw WorkspaceError.dependencyDrift(
                    package: plan.name,
                    missing: drift.missingInRequire, extra: drift.extraInRequire)
            }
        }
        let assembled = withStdlib ? interfacePackage.assemblingStdlib() : interfacePackage
        return WorkspaceLoadedTarget(
            package: assembled, publicInterface: interface)
    }

    private static func targetPlans(
        for manifest: ModuleManifest, packageRoot: String,
        workspaceRoot: String, profile: String
    ) throws -> [WorkspaceTargetPlan] {
        guard !manifest.targets.isEmpty else {
            throw WorkspaceError.invalidTarget(
                package: manifest.name, target: manifest.name,
                reason: "工作区成员必须显式声明 [lib]、[[bin]] 或 [[test]]")
        }
        var names: Set<String> = []
        let packageBuild = "\(workspaceRoot)/.build/\(profile)/packages/\(manifest.name)"
        return try manifest.targets.map { target in
            guard names.insert(target.name).inserted else {
                throw WorkspaceError.duplicateTarget(package: manifest.name, target: target.name)
            }
            guard isPathComponent(target.name), isPathComponent(manifest.name) else {
                throw WorkspaceError.invalidTarget(
                    package: manifest.name, target: target.name,
                    reason: "包名与 target 名必须是单一路径分量")
            }
            let components = target.entry.components(separatedBy: "/")
            guard !target.entry.isEmpty, !target.entry.hasPrefix("/"),
                !components.contains(".."), !components.contains(".")
            else {
                throw WorkspaceError.invalidTarget(
                    package: manifest.name, target: target.name,
                    reason: "entry 必须是包根相对路径且不得含 '.' 或 '..'")
            }
            let executable =
                target.kind == .executable
                ? "\(workspaceRoot)/.build/\(profile)/bin/\(target.name)"
                : nil
            return WorkspaceTargetPlan(
                name: target.name, kind: target.kind, entry: target.entry,
                irPath: "\(packageBuild)/\(target.name).ll",
                executablePath: executable,
                interfacePath: "\(packageBuild)/interface.txt")
        }
    }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private static func topologicalOrder(
        _ packages: [String: WorkspacePackagePlan]
    ) throws -> [String] {
        var state: [String: Int] = [:]
        var stack: [String] = []
        var ordered: [String] = []
        func visit(_ name: String) throws {
            if state[name] == 2 { return }
            if state[name] == 1 {
                let start = stack.firstIndex(of: name) ?? 0
                throw WorkspaceError.dependencyCycle(chain: Array(stack[start...]) + [name])
            }
            state[name] = 1
            stack.append(name)
            guard let package = packages[name] else { return }
            var required = Set(package.manifest.require.keys)
            for table in package.manifest.requireTaps.values { required.formUnion(table.keys) }
            for dependency in required.intersection(Set(packages.keys)).sorted() {
                try visit(dependency)
            }
            stack.removeLast()
            state[name] = 2
            ordered.append(name)
        }
        for name in packages.keys.sorted() { try visit(name) }
        return ordered
    }
}
