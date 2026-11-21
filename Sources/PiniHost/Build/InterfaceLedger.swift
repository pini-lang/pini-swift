import Foundation
import PiniSemantics
import PiniSyntax

/// 宿主侧接口记录：与自产 `interfaces.toml` 同形（版本 2），文件名区分（`interfaces.host.toml`），`path` 指向
/// `interface.txt`，两条链写各自的记录、互不覆盖。
public struct WorkspaceInterfaceDep: Equatable, Sendable {
    public let name: String
    public let hash: String

    public init(name: String, hash: String) {
        self.name = name
        self.hash = hash
    }
}

/// 接口条目：包名、根相对快照路径、整份文本摘要、本包源码摘要与依赖接口摘要。
public struct WorkspaceInterfaceEntry: Equatable, Sendable {
    public let name: String
    public let path: String
    public let hash: String
    public let source: String
    public let deps: [WorkspaceInterfaceDep]

    public init(name: String, path: String, hash: String, source: String, deps: [WorkspaceInterfaceDep] = []) {
        self.name = name
        self.path = path
        self.hash = hash
        self.source = source
        self.deps = deps
    }
}

/// 接口记录：profile 与按包名排好的条目。
public struct WorkspaceInterfaceLedger: Equatable, Sendable {
    public static let version = 2

    public let profile: String
    public let entries: [WorkspaceInterfaceEntry]

    public init(profile: String, entries: [WorkspaceInterfaceEntry]) {
        self.profile = profile
        self.entries = entries
    }

    /// 记录路径：`<根>/.build/<profile>/interfaces.host.toml`。
    public static func path(root: String, profile: String) -> String {
        "\(root)/.build/\(profile)/interfaces.host.toml"
    }

    /// 快照路径：`<根>/.build/<profile>/packages/<包>/interface.txt`，与宿主 build 的产物一致。
    public static func artifactPath(root: String, profile: String, name: String) -> String {
        "\(root)/.build/\(profile)/packages/\(name)/interface.txt"
    }

    /// 渲染：头段一次、条目逐段；与自产 `ledgerText` 同形，条目按包名字节序。
    public func render() -> String {
        var text = "[interfaces]\nversion = \(WorkspaceInterfaceLedger.version)\nprofile = \"\(profile)\"\n"
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            text += "\n[[interface]]\n"
            text += "package = \"\(entry.name)\"\n"
            text += "path = \"\(entry.path)\"\n"
            text += "hash = \"\(entry.hash)\"\n"
            text += "source = \"\(entry.source)\"\n"
            text += "deps = \"\(WorkspaceInterfaceLedger.depsText(entry.deps))\"\n"
        }
        return text
    }

    /// 依赖串：`名:摘要` 逗号分隔。
    public static func depsText(_ deps: [WorkspaceInterfaceDep]) -> String {
        deps.map { "\($0.name):\($0.hash)" }.joined(separator: ",")
    }

    /// 读记录：文件缺失、版本不符或没有头段答 nil，调用方按「无记录」处理；缺 package 的条目丢弃。
    public static func read(at path: String) -> WorkspaceInterfaceLedger? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var profile: String?
        var versionSeen: String?
        var entries: [WorkspaceInterfaceEntry] = []
        var current: [String: String]?
        func flush() {
            guard let fields = current else { return }
            defer { current = nil }
            guard let name = fields["package"], !name.isEmpty else { return }
            let deps = fields["deps"].map(parseDeps) ?? []
            entries.append(
                WorkspaceInterfaceEntry(
                    name: name, path: fields["path"] ?? "", hash: fields["hash"] ?? "",
                    source: fields["source"] ?? "", deps: deps))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line == "[interfaces]" { continue }
            if line == "[[interface]]" { flush(); current = [:]; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if current != nil {
                current?[key] = value
            } else if key == "profile" {
                profile = value
            } else if key == "version" {
                versionSeen = value
            }
        }
        flush()
        guard versionSeen == "\(version)" else { return nil }
        return WorkspaceInterfaceLedger(profile: profile ?? "debug", entries: entries)
    }

    static func parseDeps(_ text: String) -> [WorkspaceInterfaceDep] {
        text.split(separator: ",").compactMap { item in
            let one = item.trimmingCharacters(in: .whitespaces)
            guard let colon = one.firstIndex(of: ":") else { return nil }
            let name = String(one[..<colon])
            let hash = String(one[one.index(after: colon)...])
            guard !name.isEmpty, !hash.isEmpty else { return nil }
            return WorkspaceInterfaceDep(name: name, hash: hash)
        }
    }

    /// 文本摘要：sha256 十六进制小写，与自产 `sha256Hex` 同值。
    public static func digest(_ text: String) -> String {
        SHA256.hexDigest(Data(text.utf8))
    }

    /// 包源码摘要：逐单元「相对路径=文本摘要」按字节序排好再整串取摘要；stdlib 单元不参与。
    public static func sourceDigest(package: Package, root: String) -> String {
        var parts: [String] = []
        for unit in package.fileUnits {
            if unit.fileName == "<stdlib>" { continue }
            let base = package.rootPath ?? root
            let relative = unit.fileName.hasPrefix(base + "/")
                ? String(unit.fileName.dropFirst(base.count + 1)) : unit.fileName
            let absolute = unit.fileName.hasPrefix("/") ? unit.fileName : base + "/" + unit.fileName
            let text = (try? String(contentsOfFile: absolute, encoding: .utf8)) ?? ""
            parts.append("\(relative)=\(digest(text))")
        }
        parts.sort()
        return digest(parts.joined(separator: "\n"))
    }

    /// 行级差异：去掉空行后逐行比首个不同处，两侧多出的行各列一份；相同答 nil。
    public static func diffDetail(recorded: String, current: String) -> String? {
        func lines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.isEmpty }
        }
        let left = lines(recorded)
        let right = lines(current)
        if left == right { return nil }
        let missing = left.filter { !right.contains($0) }.count
        let extra = right.filter { !left.contains($0) }.count
        var index = 0
        while index < left.count && index < right.count && left[index] == right[index] {
            index += 1
        }
        if missing > 0 || extra > 0 {
            return "第 \(index + 1) 行起不同（少 \(missing) 行，多 \(extra) 行）"
        }
        return "第 \(index + 1) 行不同"
    }
}

/// 包接口与下游记录不一致：E3-021。没有源码位置（记录是包级产物），渲染成不带 at 行的诊断。
public struct WorkspaceInterfaceDriftError: Error, Equatable, DiagnosticProviding {
    public let packageName: String
    public let detailText: String

    public init(packageName: String, detailText: String) {
        self.packageName = packageName
        self.detailText = detailText
    }

    public var diagnosticCode: String { "E3-021" }
    public var diagnosticSeverity: DiagnosticSeverity { .error }
    public var suggestion: String? {
        "确认这次接口变化是有意的；有意则更新下游记录，无意说明包内公开面被意外改动"
    }
    public var diagnosticLocation: SourceLocation {
        SourceLocation(line: 0, column: 0, fileName: "")
    }
}
