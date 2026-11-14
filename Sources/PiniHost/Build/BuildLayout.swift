import Foundation
import PiniSemantics

/// 构建目录布局。生成物一律落 `<根>/.build/<profile>`，源码树里不出现产物。
/// 根取工作区根；单包以包根为根。路径只在这里拼，其他命令不得自行拼接，
/// 否则装载器与构建器会各算一份，`.build` 的忽略规则就护不住源码树。
public struct BuildLayout: Equatable, Sendable {
    public let root: String
    public let profile: String

    public init(root: String, profile: String) {
        self.root = root
        self.profile = profile
    }

    public var buildDirectory: String { "\(root)/.build/\(profile)" }

    /// 计划文件。它是构建器与其余命令之间唯一的数据接口：构建器写，检查器读。
    public var planPath: String { "\(buildDirectory)/plan.toml" }

    public func packageDirectory(_ name: String) -> String {
        "\(buildDirectory)/packages/\(name)"
    }

    /// 一条翻译步的产物路径。步骤名即文件名，故步骤名必须是合法路径分量。
    public func generatedPath(package: String, step: String) -> String {
        "\(packageDirectory(package))/generated/\(step).pini"
    }

    /// 绝对路径压成根相对路径；落在根外的原样保留。计划的跨机器可比较性靠这一点。
    /// 根本身写 `.`：空串会让读取方分不清「没有这个值」与「就是根」。
    public func relativeToRoot(_ path: String) -> String {
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public func absolute(_ path: String) -> String {
        if path == "." { return root }
        return path.hasPrefix("/") ? path : root + "/" + path
    }

    /// 由包根定位布局：向上找到把该包登记为成员的工作区；找不到则包根自成一库。
    /// 清单读取失败向上抛：坏清单不当「无工作区」，否则产物会悄悄落到别处。
    public static func locate(packageRoot: String) throws -> BuildLayout {
        let canonical = ModuleDependencyLoader.shared.canonicalPath(
            packagePath: packageRoot, relativeTo: FileManager.default.currentDirectoryPath)
        var directory = (canonical as NSString).deletingLastPathComponent
        while !directory.isEmpty && directory != "/" {
            if let workspace = try? WorkspaceManifest.load(directory: directory) {
                let members = workspace.members.map {
                    ModuleDependencyLoader.shared.canonicalPath(
                        packagePath: $0, relativeTo: directory)
                }
                if members.contains(canonical) {
                    return BuildLayout(root: directory, profile: workspace.profile)
                }
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        let profile = (try WorkspaceManifest.load(directory: canonical))?.profile ?? "debug"
        return BuildLayout(root: canonical, profile: profile)
    }
}
