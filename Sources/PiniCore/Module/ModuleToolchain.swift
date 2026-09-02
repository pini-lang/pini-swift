import Foundation

/// 批 6（G52 批 3）阶段 3：模块工具链核心——版本约束、MVS 求解、SHA-256 校验和、
/// `pini-summary.toml` 读写。语义权威 = G52 决议（模块系统规则工单）的字段规范与命令规范；
/// 本文件只实现，不改语义。
///
/// v1 边界（如实记录）：
/// - 仅本地 tap（`file:`）；远程 tap（`github:`/`git:`）在收集期即报错（本批 D-A，批 7 解除）。
/// - 依赖落地 `deps/<name>/` 由 git submodule / 手工拷贝管理（D23：无全局缓存）；
///   每个依赖目录只有**一个**可用版本——MVS 退化为「校验全部约束是否被该版本满足」，
///   冲突即报错；远程 registry 出现后这里升级为真正的多候选最小版本选择。
public enum ModuleToolchain {

 // MARK: - 错误

 public enum ToolchainError: Error, Equatable {
 /// 依赖目录缺失（deps/<name>/ 无 pini.toml）——v1 无下载，须先 submodule/手工落地。
 case missingDependency(name: String, requirer: String, expectedPath: String)
 /// 远程 tap（D-A：批 6 报错退出，不跳过）。
 case remoteTapUnsupported(tapName: String, spec: String, requiredBy: String)
 /// 约束不可满足：可用版本不满足某个（或多个）requirer 的约束。
 case unsatisfiable(name: String, available: String, conflicts: [String])
 /// 平表 [require] 条目但清单未声明 [tap] default（D11：org 显式书写）。
 case missingDefaultTap(name: String)
 /// replace 指向的本地路径不存在。
 case replaceTargetMissing(name: String, path: String)
 /// 锁文件与清单身份不符（模块名对不上）。
 case summaryIdentityMismatch(path: String)
 }


 // MARK: - 版本约束（G52 §3.2：^ / ~ / = / 区间 / * / 裸版本）

 /// 约束 = 原子列表（全部满足才算满足）。
 public struct Constraint: Equatable {
 public enum Op: Equatable { case ge, lt, eq }
 public struct Atom: Equatable { let op: Op; let version: [Int] }
 let atoms: [Atom]
 let raw: String

 /// `*` → 空约束（任意版本满足）。
 static let any = Constraint(atoms: [], raw: "*")

 /// 解析失败返回 nil（调用方决定报错或当 `*`——tidy 侧未知写 `*`，refresh 侧报错）。
 static func parse(_ raw: String) -> Constraint? {
 let s = raw.trimmingCharacters(in: .whitespaces)
 if s == "*" || s.isEmpty { return any }
 var atoms: [Atom] = []
 // 区间：`">=1.0, <2.0"` 按逗号拆分（引号已由 TOML 层剥掉）。
 for partRaw in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
 let part = partRaw
 if part.hasPrefix("^") {
 guard let v = versionComponents(String(part.dropFirst())) else { return nil }
 atoms.append(Atom(op: .ge, version: v))
 atoms.append(Atom(op: .lt, version: caretUpper(v)))
 } else if part.hasPrefix("~") {
 guard let v = versionComponents(String(part.dropFirst())) else { return nil }
 atoms.append(Atom(op: .ge, version: v))
 atoms.append(Atom(op: .lt, version: tildeUpper(v)))
 } else if part.hasPrefix("=") {
 guard let v = versionComponents(String(part.dropFirst())) else { return nil }
 atoms.append(Atom(op: .eq, version: v))
 } else if part.hasPrefix(">=") {
 guard let v = versionComponents(String(part.dropFirst(2))) else { return nil }
 atoms.append(Atom(op: .ge, version: v))
 } else if part.hasPrefix("<") {
 guard let v = versionComponents(String(part.dropFirst())) else { return nil }
 atoms.append(Atom(op: .lt, version: v))
 } else {
 // 裸版本 = 下界（>=）。
 guard let v = versionComponents(part) else { return nil }
 atoms.append(Atom(op: .ge, version: v))
 }
 }
 return Constraint(atoms: atoms, raw: s)
 }

 /// `^` 上界：major>0 → major+1；major=0 → 0.(minor+1)（npm 语义）。
 private static func caretUpper(_ v: [Int]) -> [Int] {
 if v[0] > 0 { return [v[0] + 1, 0, 0] }
 return [0, (v.count > 1 ? v[1] : 0) + 1, 0]
 }
 /// `~` 上界：minor+1（npm 语义）。
 private static func tildeUpper(_ v: [Int]) -> [Int] {
 return [v[0], (v.count > 1 ? v[1] : 0) + 1, 0]
 }

 func satisfies(_ version: [Int]) -> Bool {
 for atom in atoms {
 let cmp = Self.compare(version, atom.version)
 switch atom.op {
 case .ge: if cmp < 0 { return false }
 case .lt: if cmp >= 0 { return false }
 case .eq: if cmp != 0 { return false }
 }
 }
 return true
 }

 /// 版本字符串 → 分量数组（`1.2` → [1,2]；非数字段忽略）。
 static func versionComponents(_ s: String) -> [Int]? {
 let parts = s.split(separator: ".").compactMap { Int($0) }
 return parts.isEmpty ? nil : parts
 }

 /// 补零逐段比较。
 static func compare(_ a: [Int], _ b: [Int]) -> Int {
 let n = max(a.count, b.count)
 for i in 0..<n {
 let x = i < a.count ? a[i] : 0
 let y = i < b.count ? b[i] : 0
 if x != y { return x < y ? -1 : 1 }
 }
 return 0
 }
 }

 // MARK: - 解析结果模型

 /// 一个已解析（锁定）的依赖模块。
 public struct ResolvedModule: Equatable {
 public let name: String
 public let version: String
 public let tapName: String
 /// 展开后的源（file: → 绝对路径；`<name>` 占位符已替换）。
 public let source: String
 /// 来源定位符（file: → `-`，G52 D12）；**永不作校验凭证**。
 public let commit: String
 /// pini.toml 摘要（MVS 可复现性）。
 public let manifestSum: String
 /// 内容树摘要（唯一可信字段，G52 D6）。
 public let sum: String
 /// 相对模块根的落地路径（deps/<name>）。
 public let path: String
 /// 谁 import/require 了它（含 `<root>`；D16）。
 public let importedBy: [String]
 }

 /// 资源解析结果（[[resource]]；无 manifest_sum——它没有 Pini 清单）。
 public struct ResolvedResource: Equatable {
 public let name: String
 public let version: String
 public let tapName: String
 public let source: String
 public let commit: String
 public let sum: String
 /// 相对模块根的落地路径（.pini/resources/<name>，R6）。
 public let path: String
 }

 /// 完整求解结果：模块 + 资源 + 拓扑序（build 调度用）。
 public struct Resolution: Equatable {
 public let modules: [ResolvedModule]
 public let resources: [ResolvedResource]
 /// 拓扑序（依赖在前，根最后；环已在批 1 的 R2 检测拦截）。
 public let graphOrder: [String]
 }

 // MARK: - 求解

 /// 在 require 传递闭包上求解（R3）。
 /// - Parameters:
 ///   - rootDir: 主模块根（绝对路径；deps/ 与 .pini/resources/ 相对它落定）。
 ///   - manifest: 主模块清单。
 public static func resolve(rootDir: String, manifest: ModuleManifest) throws -> Resolution {
 var moduleByName: [String: (manifest: ModuleManifest, dir: String)] = [:]
 var importedBy: [String: [String]] = [:]
 var edges: [String: Set<String>] = [:] // requirer → deps
 // 约束账本：name → [(constraintRaw, requirer)]——**每个 requirer 的约束都入账**（多向 MVS）。
 var constraints: [String: [(String, String)]] = [:]

 // 待处理边 = (依赖名, requirer, requirer 侧约束, 来源 spec)。
 // spec 在入队时按 **requirer 自己的清单**解析（平表 → 其 [tap] default，具名子表 → 对应 tap；
 // D11：缺 [tap] 即报错，带 requirer 信息）。
 var pending: [(name: String, from: String, constraint: String?, spec: String, tap: String)] = []
 var sourceByName: [String: String] = [:] // 首次落地时的来源（写进 summary）
 var tapNameByName: [String: String] = [:]
 func enqueueDeps(of m: ModuleManifest, from: String) throws {
 let defaultSpec = m.taps["default"]
 for (n, c) in m.require.sorted(by: { $0.key < $1.key }) {
 guard let spec = defaultSpec else { throw ToolchainError.missingDefaultTap(name: n) }
 pending.append((n, from, c, spec, "default"))
 }
 for (tn, kv) in m.requireTaps.sorted(by: { $0.key < $1.key }) {
 for (n, c) in kv.sorted(by: { $0.key < $1.key }) {
 guard let spec = m.taps[tn] else { throw ToolchainError.missingDefaultTap(name: n) }
 pending.append((n, from, c, spec, tn))
 }
 }
 }
 try enqueueDeps(of: manifest, from: "<root>")

 while let (name, from, constraint, specStr, edgeTap) = pending.popLast() {
 // 边与约束**无论首见与否都入账**（首见短路会丢多 requirer 的 imported-by 与约束）。
 constraints[name, default: []].append((constraint ?? "*", from))
 importedBy[name, default: []].append(from)
 edges[from, default: []].insert(name)
 if moduleByName[name] != nil { continue }

 // tap 校验（D-A：远程报错退出）。
 guard specStr.hasPrefix("file:") else {
 throw ToolchainError.remoteTapUnsupported(tapName: edgeTap, spec: specStr, requiredBy: from)
 }
 sourceByName[name] = specStr
 tapNameByName[name] = edgeTap
 // v1 落地模型（D23）：依赖固定落 deps/<name>/（git submodule / 手工拷贝管理），
 // tap 只作来源元数据（source 字段）；[replace] 的 file: 形式可把本地 fork 指为落地目录。
 var depDir = rootDir + "/deps/" + name
 if let rep = manifest.replaces[name], rep.hasPrefix("file:") {
 let expanded = rep.replacingOccurrences(of: "<name>", with: name)
 let rel = String(expanded.dropFirst("file:".count))
 let p = rel.hasPrefix("/") ? rel : rootDir + "/" + rel
 guard FileManager.default.fileExists(atPath: p + "/pini.toml") else {
 throw ToolchainError.replaceTargetMissing(name: name, path: p)
 }
 depDir = p
 }
 let manifestPath = depDir + "/pini.toml"
 guard FileManager.default.fileExists(atPath: manifestPath),
 let depManifest = try FileLoader.loadManifest(directory: depDir) else {
 throw ToolchainError.missingDependency(name: name, requirer: from, expectedPath: manifestPath)
 }

 moduleByName[name] = (depManifest, depDir)
 try enqueueDeps(of: depManifest, from: name)
 }

 // MVS：v1 每依赖一个可用版本——全部约束必须被它满足（G52 R3 的本地退化形态）。
 var resolved: [ResolvedModule] = []
 for (name, entry) in moduleByName.sorted(by: { $0.key < $1.key }) {
 let available = entry.manifest.version ?? "0"
 let comps = Constraint.versionComponents(available) ?? []
 let failed = (constraints[name] ?? []).filter { raw, requirer in
 guard let c = Constraint.parse(raw) else {
 return true // 无法解析的约束按不满足处理（refresh 侧宁严勿纵）
 }
 return !c.satisfies(comps)
 }
 if !failed.isEmpty {
 throw ToolchainError.unsatisfiable(name: name, available: available,
 conflicts: failed.map { "\($0.1) 要求 \($0.0)" })
 }
 let depDir = entry.dir
 let moduleTap = tapNameByName[name] ?? "default"
 let moduleSource = sourceByName[name] ?? "-"
 resolved.append(ResolvedModule(
 name: name,
 version: available,
 tapName: moduleTap,
 source: moduleSource,
 commit: "-",
 manifestSum: "sha256:" + fileSum(depDir + "/pini.toml"),
 sum: "sha256:" + treeSum(depDir),
 path: depDir.hasPrefix(rootDir + "/") ? String(depDir.dropFirst(rootDir.count + 1)) : depDir,
 importedBy: importedBy[name] ?? []))
 }

 // 资源（不参与 MVS，同样受校验和约束；R6 落地 .pini/resources/<name>）。
 var resolvedResources: [ResolvedResource] = []
 var resourceEntries: [(name: String, tap: String?, spec: String)] = []
 for (name, spec) in manifest.resources.sorted(by: { $0.key < $1.key }) {
 resourceEntries.append((name, nil, spec))
 }
 for (tapName, kv) in manifest.resourcesTaps.sorted(by: { $0.key < $1.key }) {
 for (name, spec) in kv.sorted(by: { $0.key < $1.key }) {
 resourceEntries.append((name, tapName, spec))
 }
 }
 for entry in resourceEntries {
 let tapName = entry.tap ?? "default"
 guard let specStr = manifest.taps[tapName] else {
 throw ToolchainError.missingDefaultTap(name: entry.name)
 }
 guard specStr.hasPrefix("file:") else {
 throw ToolchainError.remoteTapUnsupported(tapName: tapName, spec: specStr, requiredBy: "<root>")
 }
 let dir = materializedResourceDir(rootDir: rootDir, name: entry.name)
 guard FileManager.default.fileExists(atPath: dir) else { continue } // 未落地资源不进 summary（refresh 落地后重跑即入）
 resolvedResources.append(ResolvedResource(
 name: entry.name,
 version: entry.spec,
 tapName: tapName,
 source: specStr,
 commit: "-",
 sum: "sha256:" + treeSum(dir),
 path: ".pini/resources/" + entry.name))
 }

 // 拓扑序：DAG 上依赖在前（环已由批 1 R2 拦截；此处再防御一次）。
 var topo: [String] = []
 var visited: Set<String> = []
 func visit(_ name: String, _ stack: inout Set<String>) throws {
 if visited.contains(name) { return }
 guard stack.insert(name).inserted else {
 let cycle = Array(stack) + [name]
 throw ToolchainError.unsatisfiable(name: name, available: "-",
 conflicts: ["依赖成环（应由 R2 拦截）：\(cycle.joined(separator: " → "))"])
 }
 for d in (edges[name] ?? []).sorted() { try visit(d, &stack) }
 stack.remove(name)
 visited.insert(name)
 topo.append(name)
 }
 var stack: Set<String> = []
 try visit("<root>", &stack)

 return Resolution(modules: resolved, resources: resolvedResources, graphOrder: topo.filter { $0 != "<root>" })
 }

 // MARK: - 校验和（G52 §3.6：SHA-256；TOFU）

 /// 单文件摘要。
 public static func fileSum(_ path: String) -> String {
 guard let data = FileManager.default.contents(atPath: path) else { return sha256(Data()) }
 return sha256(data)
 }

 /// 内容树摘要：相对路径字典序遍历（对齐 loadDirectory 的排序），路径与字节先后入摘要。
 /// 排除：`.git/`、`pini-summary.toml` 自身、`.build/`（构建产物）、`.DS_Store`。
 /// `.pini/` **不排除**——resources 落地其中且受校验和约束（R6/D6）。
 public static func treeSum(_ root: String) -> String {
 var entries: [(rel: String, data: Data)] = []
 let rootURL = URL(fileURLWithPath: root)
 if let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]) {
 for case let url as URL in e {
 let rel = url.path.hasPrefix(rootURL.path + "/")
 ? String(url.path.dropFirst(rootURL.path.count + 1)) : url.lastPathComponent
 let comps = rel.split(separator: "/").map(String.init)
 if comps.contains(".git") || comps.contains(".build") { continue }
 if rel == "pini-summary.toml" || rel == ".DS_Store" { continue }
 if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]), vals.isRegularFile == true,
 let data = FileManager.default.contents(atPath: url.path) {
 entries.append((rel, data))
 }
 }
 }
 entries.sort { $0.rel < $1.rel }
 var buffer = Data()
 for e in entries {
 buffer.append(Data(e.rel.utf8))
 buffer.append(Data([0x00])) // 路径/内容分隔符
 buffer.append(e.data)
 }
 return SHA256.hexDigest(buffer)
 }

 static func sha256(_ data: Data) -> String {
 SHA256.hexDigest(data)
 }

 // MARK: - 锁文件（G52 §3.5：生成物，必须提交）

 /// 生成 `pini-summary.toml` 文本（G52 §3.5 格式）。
 public static func renderSummary(resolution: Resolution, toolchainVersion: String,
 generated: Date = Date()) -> String {
 let fmt = ISO8601DateFormatter()
 var out = "# 由 `pini mod refresh` 生成（G52 R3/D6）——生成物但必须提交；手工编辑无意义。\n"
 out += "[build]\n"
 out += "toolchain = \"\(toolchainVersion)\"\n"
 out += "generated = \"\(fmt.string(from: generated))\"\n\n"
 for m in resolution.modules {
 out += "[[module]]\n"
 out += "name = \"\(m.name)\"\n"
 out += "version = \"\(m.version)\"\n"
 out += "tap = \"\(m.tapName)\"\n"
 out += "source = \"\(m.source)\"\n"
 out += "commit = \"\(m.commit)\"\n"
 out += "manifest_sum = \"\(m.manifestSum)\"\n"
 out += "sum = \"\(m.sum)\"\n"
 out += "path = \"\(m.path)\"\n"
 out += "imported-by = [\(m.importedBy.map { "\"\($0)\"" }.joined(separator: ", "))]\n\n"
 }
 for r in resolution.resources {
 out += "[[resource]]\n"
 out += "name = \"\(r.name)\"\n"
 out += "version = \"\(r.version)\"\n"
 out += "tap = \"\(r.tapName)\"\n"
 out += "source = \"\(r.source)\"\n"
 out += "commit = \"\(r.commit)\"\n"
 out += "sum = \"\(r.sum)\"\n"
 out += "path = \"\(r.path)\"\n\n"
 }
 out += "[graph]\n"
 out += "order = [\(resolution.graphOrder.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
 return out
 }

 /// 解析锁文件（verify / build 调度消费；格式与 renderSummary 对成）。
 public struct Summary {
 public var toolchain: String = ""
 public var generated: String = ""
 public var modules: [(name: String, version: String, sum: String, manifestSum: String, path: String, importedBy: [String])] = []
 public var resources: [(name: String, version: String, sum: String, path: String)] = []
 public var graphOrder: [String] = []
 }

 public static func parseSummary(_ text: String) -> Summary {
 let doc = MiniTOML.parse(text)
 var s = Summary()
 s.toolchain = doc.plain("build")["toolchain"] ?? ""
 s.generated = doc.plain("build")["generated"] ?? ""
 for e in doc.arrayTables["module"] ?? [] {
 s.modules.append((e["name"] ?? "", e["version"] ?? "", e["sum"] ?? "",
 e["manifest_sum"] ?? "", e["path"] ?? "",
 MiniTOML.parseArray(e["imported-by"] ?? "[]")))
 }
 for e in doc.arrayTables["resource"] ?? [] {
 s.resources.append((e["name"] ?? "", e["version"] ?? "", e["sum"] ?? "", e["path"] ?? ""))
 }
 s.graphOrder = MiniTOML.parseArray(doc.plain("graph")["order"] ?? "[]")
 return s
 }

 // MARK: - 内部

 static func materializedResourceDir(rootDir: String, name: String) -> String {
 return (rootDir as NSString).appendingPathComponent(".pini/resources/\(name)")
 }

}

extension ModuleToolchain.ToolchainError: LocalizedError {
 public var errorDescription: String? {
 switch self {
 case .missingDependency(let name, let requirer, let expectedPath):
 return "依赖 '\(name)'（由 \(requirer) require）未落地：缺少 \(expectedPath)。"
 + "v1 不联网下载（批 7 前）：请用 git submodule 或手工拷贝落地到 deps/\(name)/"
 case .remoteTapUnsupported(let tapName, let spec, let requiredBy):
 return "tap '\(tapName)'（\(spec)，requiredBy \(requiredBy)）为远程源：批 6 仅支持 file: 本地 tap，"
 + "远程下载属批 7。请改用 [replace] 指向本地路径，或等待批 7"
 case .unsatisfiable(let name, let available, let conflicts):
 return "依赖 '\(name)' 可用版本 \(available) 不满足约束：\(conflicts.joined(separator: "；"))"
 + "（MVS 无多候选可解——v1 每个依赖目录只有一个版本）"
 case .missingDefaultTap(let name):
 return "依赖 '\(name)' 未指定 tap，且清单缺 [tap] default（G52 D11：org 须显式书写）"
 case .replaceTargetMissing(let name, let path):
 return "[replace] '\(name)' 指向的本地路径不存在：\(path)"
 case .summaryIdentityMismatch(let path):
 return "pini-summary.toml 与清单身份不符：\(path)"
 }
 }
}
