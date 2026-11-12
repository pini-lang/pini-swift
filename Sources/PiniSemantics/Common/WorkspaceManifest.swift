import Foundation

/// 生产与测试 target 的类别。测试 target 不进入普通构建产物。
public enum ModuleTargetKind: String, Equatable, Sendable {
    case library
    case executable
    case test
}

/// 包内一个具名构建目标；entry 是包根相对入口，测试 target 也可指向测试目录。
public struct ModuleTarget: Equatable, Sendable {
    public let name: String
    public let kind: ModuleTargetKind
    public let entry: String

    public init(name: String, kind: ModuleTargetKind, entry: String) {
        self.name = name
        self.kind = kind
        self.entry = entry
    }
}

/// 根清单中的工作区面。它只登记成员与共享构建配置，不把成员源码合成一个包。
public struct WorkspaceManifest: Equatable, Sendable {
    public let members: [String]
    public let profile: String

    public init(members: [String], profile: String = "debug") {
        self.members = members
        self.profile = profile
    }

    /// 目录含 `[workspace]` 时返回工作区面；普通包目录返回 nil。
    public static func load(directory: String) throws -> WorkspaceManifest? {
        let path = (directory as NSString).appendingPathComponent(FileLoader.manifestFileName)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let document = MiniTOML.parse(text)
        guard document.tables.keys.contains("workspace") else { return nil }
        let table = document.plain("workspace")
        let members = MiniTOML.parseArray(table["members"] ?? "[]")
        guard !members.isEmpty, members.allSatisfy({ !$0.isEmpty }) else {
            throw LoaderError.invalidWorkspace(path: path, reason: "members 必须是非空路径数组")
        }
        let profile = table["profile"] ?? "debug"
        guard !profile.isEmpty, !profile.contains("/"), !profile.contains("\\") else {
            throw LoaderError.invalidWorkspace(path: path, reason: "profile 必须是单一路径分量")
        }
        return WorkspaceManifest(members: members, profile: profile)
    }
}
