import Foundation

/// 批 6（G52 批 3）阶段 3：模块工具链核心——版本约束、MVS 求解、SHA-256 校验和、
/// `pini-summary.toml` 读写。语义权威 = G52 决议（模块系统规则工单）的字段规范与命令规范；
/// 本文件只实现，不改语义。
///
/// v1 边界（如实记录）：
/// - **批 7**：远程 tap（`github:`/`git:`）由 `TapFetcher` 抓取，抓取**只发生在 refresh**
///   （`resolveFetching`）；`resolve` / `graph` 等只读路径不联网，只能读已落地的依赖。
/// - `file:` tap 仍是「来源元数据 + git submodule / 手工拷贝落地」（批 6 已 Landed 语义，批 7 不动）。
/// - 依赖落地 `deps/<name>/`（D23：无全局缓存）。远程依赖的候选版本来自 tag，
///   经典 MVS 在其中取满足全部约束的最小版本（`TapFetcher.selectVersion`）。
/// - 依赖的版本决定它自己的 `[require]` 内容 ⇒ 约束集随选择而变 ⇒ 求解须**迭代到不动点**
///   （`resolveFetching`，上限 `fetchIterationLimit`，不收敛即报错不静默取某一轮）。
public enum ModuleToolchain {

 // MARK: - 错误

 public enum ToolchainError: Error, Equatable {
 /// 依赖目录缺失（deps/<name>/ 无 pini.toml）——v1 无下载，须先 submodule/手工落地。
 case missingDependency(name: String, requirer: String, expectedPath: String)
 /// 远程 tap 的依赖尚未落地，且本次解析不抓取（抓取只发生在 refresh）。
 /// 批 6 的 D-A 是「远程一律不支持」，批 7 后收窄为这一种情形：依赖还没抓下来。
 case remoteTapNotMaterialized(name: String, tap: String)
 /// 资源未落地（批 7 前是静默跳过，现改为显式报错）。
 case resourceNotMaterialized(name: String, path: String)
 /// **R7 根检（D20/D26 反向）**：`resources X` 而 X 的根含 `pini.toml` ⇒ 它是 Pini 模块，
 /// 应改用 `[require]`。只查根、不查深层。
 case resourceTargetIsModule(name: String, path: String)
 /// 版本求解在限定迭代内未收敛（依赖的约束集随其版本而变）。
 case resolutionDidNotConverge(limit: Int)
 /// 约束不可满足：可用版本不满足某个（或多个）requirer 的约束。
 case unsatisfiable(name: String, available: String, conflicts: [String])
 /// 平表 [require] 条目但清单未声明 [tap] default（D11：org 显式书写）。
 case missingDefaultTap(name: String)
 /// replace 指向的本地路径不存在。
 case replaceTargetMissing(name: String, path: String)
 /// 锁文件与清单身份不符（模块名对不上）。
 case summaryIdentityMismatch(path: String)
 }


 // MARK: - 抓取会话（批 7）

 /// 跨迭代缓存「已选版本 / 已取 commit」，并标记本轮是否发生过重新选择。
 ///
 /// 存在性即「本次解析允许抓取」的开关：`resolve` 传 `nil` 表示只读（refresh 之外的路径）。
 final class FetchSession {
 /// name → 选中的版本（无版本 tag 的仓库为 `nil`，表示取默认分支 HEAD）。
 private(set) var selections: [String: String?] = [:]
 /// name → 落地的 commit（G52 D12 来源定位符）。
 private(set) var commits: [String: String] = [:]
 /// name → 展开后的源（写进锁文件的 `source` 字段）。
 private(set) var sources: [String: String] = [:]
 /// 本轮是否发生过重新选择——不动点迭代的收敛判据。
 private(set) var selectionChanged = false

 func beginIteration() { selectionChanged = false }

 func record(name: String, version: String?, commit: String, source: String) {
 if let prev = selections[name] {
 if prev != version { selectionChanged = true }
 } else {
 selectionChanged = true // 首见即变化（需要与「已存在但无需改动」区分）
 }
 selections[name] = version
 commits[name] = commit
 sources[name] = source
 }

 /// 是否已有选中记录（含「无版本 tag → 取 HEAD」这一 nil 选择）。
 func hasSelection(_ name: String) -> Bool { selections.keys.contains(name) }
 }

 /// 不动点迭代上限。超过即报错——不静默取某一轮的结果。
 static let fetchIterationLimit = 8

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
 try resolve(rootDir: rootDir, manifest: manifest, session: nil)
 }

 /// 带抓取会话的解析。`session == nil` = **只读**（refresh 之外的路径：已落地的依赖照常解析，
 /// 未落地的远程依赖报 `remoteTapNotMaterialized`）；非 nil 则由 `TapFetcher` 抓取远程依赖。
 static func resolve(rootDir: String, manifest: ModuleManifest,
                     session: FetchSession?) throws -> Resolution {
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

    sourceByName[name] = specStr
    tapNameByName[name] = edgeTap
    // v1 落地模型（D23）：依赖固定落 deps/<name>/。
    // - [replace] 的 file: 形式可把本地 fork 指为落地目录（批 6 已 Landed 语义）；
    // - file: tap 仍是「来源元数据 + 手工/submodule 落地」（批 7 不动）；
    // - 远程 tap（github:/git:）由 TapFetcher 抓取——仅当 session 存在（即 refresh）。
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
    // 抓取（或复核已选版本）——约束可能在后续 requirer 出现后变严，故每次经过都要复核。
    try ensureMaterialized(name: name, spec: specStr, dir: depDir,
                           constraints: (constraints[name] ?? []).map(\.0),
                           session: session)
    // 已解析过则不再重复读清单——但**抓取/复核已在上面发生**，故后到的更严约束仍会触发重新选择。
    if moduleByName[name] != nil { continue }

    let manifestPath = depDir + "/pini.toml"
    guard FileManager.default.fileExists(atPath: manifestPath),
          let depManifest = try FileLoader.loadManifest(directory: depDir) else {
      // 已落地的远程依赖（refresh 之后）可正常解析，故只读路径（graph）也能用。
      guard specStr.hasPrefix("file:") else {
        throw ToolchainError.remoteTapNotMaterialized(name: name, tap: edgeTap)
      }
      throw ToolchainError.missingDependency(name: name, requirer: from, expectedPath: manifestPath)
    }

    moduleByName[name] = (depManifest, depDir)
 try enqueueDeps(of: depManifest, from: name)
 }

 // 约束复核：遍历期只看到**部分**约束，故在约束齐全后按完整约束集重选一次。
 // 这是不动点迭代的驱动点——重选发生 ⇒ 依赖清单内容改变 ⇒ 需再走一轮。
 if let session = session {
 for (name, entry) in moduleByName.sorted(by: { $0.key < $1.key }) {
 try reconcileSelection(name: name, spec: sourceByName[name] ?? "", dir: entry.dir,
 constraints: (constraints[name] ?? []).map(\.0),
 session: session)
 }
 }

 // MVS 校验：选中的版本必须满足**全部** requirer 的约束。
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
 // 本轮发生过重新选择 ⇒ 清单是**旧版本**的，约束集还在变——交给下一轮复核，
 // 不能据此判「不可满足」（否则不动点迭代永远走不到第二轮）。
 if session?.selectionChanged == true { continue }
 throw ToolchainError.unsatisfiable(name: name, available: available,
 conflicts: failed.map { "\($0.1) 要求 \($0.0)" })
 }
 let depDir = entry.dir
 let moduleTap = tapNameByName[name] ?? "default"
 let moduleSource = session?.sources[name] ?? sourceByName[name] ?? "-"
 resolved.append(ResolvedModule(
 name: name,
 version: available,
 tapName: moduleTap,
 source: moduleSource,
 commit: session?.commits[name] ?? "-",
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
 let dir = materializedResourceDir(rootDir: rootDir, name: entry.name)
 var commit = "-"
 var displaySource = specStr
 if let session = session, !specStr.hasPrefix("file:") {
 // 批 7：资源也由 refresh 落地（G52 §4.2「下载缺失的依赖与资源」）。
 // **不参与 MVS**（§3.3）：默认取 HEAD；仅当声明串本身就是一个已存在的 tag 时检出它
 // ——那是「显式指定」，不是「求解」。
 let source = try TapFetcher.expand(spec: specStr, name: entry.name)
 let declared = entry.spec.trimmingCharacters(in: .whitespaces)
 let pinned = try TapFetcher.availableVersions(source).contains(declared) ? declared : nil
 commit = try TapFetcher.materialize(source, version: pinned, into: dir)
 displaySource = source.display
 }
 guard FileManager.default.fileExists(atPath: dir) else {
 // 批 7 前是静默跳过——资源因此可能永远不进锁文件。改为显式报错。
 guard specStr.hasPrefix("file:") else {
 throw ToolchainError.remoteTapNotMaterialized(name: entry.name, tap: tapName)
 }
 throw ToolchainError.resourceNotMaterialized(name: entry.name, path: dir)
 }
 // R7 根检（D20/D26）——双通道分区的另一半：写错一侧即报错并指引到另一侧。
 // **只查根**：`.pini/resources/` 不被扫描，深层清单物理上无害（R7 明定不查深层）。
 if FileManager.default.fileExists(atPath: dir + "/pini.toml") {
 throw ToolchainError.resourceTargetIsModule(name: entry.name, path: dir)
 }
 resolvedResources.append(ResolvedResource(
 name: entry.name,
 version: entry.spec,
 tapName: tapName,
 source: displaySource,
 commit: commit,
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

 // MARK: - 抓取与不动点迭代（批 7）

 /// **首次**抓取一个远程依赖（遍历期调用）。
 ///
 /// ⚠ 这里**只看当时已知的约束**，因此绝不能在已选过之后再调用——
 /// 后到的更严约束会把选择改小，下一轮遍历又从部分约束重新选大 ⇒ **振荡不收敛**。
 /// 已选过的一律交给 `reconcileSelection`（在约束齐全后统一复核）。
 ///
 /// - `file:` tap 直接返回——批 6 的「元数据 + 手工/submodule 落地」语义批 7 不动。
 /// - `session == nil` 时直接返回——只读路径不抓取，缺落地由调用方报错。
 private static func ensureMaterialized(name: String, spec: String, dir: String,
                                        constraints: [String],
                                        session: FetchSession?) throws {
 guard let session = session, !spec.hasPrefix("file:") else { return }
 guard !session.hasSelection(name) else { return }
 let source = try TapFetcher.expand(spec: spec, name: name)
 let candidates = try TapFetcher.availableVersions(source)
 // 无版本 tag 的仓库没有可解的版本图：取默认分支 HEAD，
 // 由 resolve 里的「清单版本 vs 约束」校验把关（宁严勿纵）。
 let picked = candidates.isEmpty
 ? nil
 : TapFetcher.selectVersion(candidates: candidates, constraints: constraints)
 if !candidates.isEmpty, picked == nil {
 throw ToolchainError.unsatisfiable(name: name, available: candidates.joined(separator: ", "),
 conflicts: constraints)
 }
 let commit = try TapFetcher.materialize(source, version: picked, into: dir)
 session.record(name: name, version: picked, commit: commit, source: source.display)
 }

 /// 约束齐全后统一复核选择（不动点迭代的驱动点）。
 private static func reconcileSelection(name: String, spec: String, dir: String,
                                        constraints: [String],
                                        session: FetchSession) throws {
 guard !spec.hasPrefix("file:") else { return }
 let source = try TapFetcher.expand(spec: spec, name: name)
 let candidates = try TapFetcher.availableVersions(source)
 guard !candidates.isEmpty else { return } // 无版本 tag：保持 HEAD，由 MVS 校验把关
 guard let picked = TapFetcher.selectVersion(candidates: candidates, constraints: constraints) else {
 throw ToolchainError.unsatisfiable(name: name, available: candidates.joined(separator: ", "),
 conflicts: constraints)
 }
 if let current = session.selections[name], current == picked { return }
 let commit = try TapFetcher.materialize(source, version: picked, into: dir)
 session.record(name: name, version: picked, commit: commit, source: source.display)
 }

 /// 抓取 + 求解到不动点。
 ///
 /// 依赖的版本决定它自己的 `[require]` 内容 ⇒ 约束集随选择而变 ⇒ 一轮不够。
 /// 故重复「解析（顺带抓取 / 重新选择）」直到某轮不再发生重新选择。
 /// 不收敛（超过 `fetchIterationLimit`）即报错——不静默取某一轮的结果。
 public static func resolveFetching(rootDir: String, manifest: ModuleManifest) throws -> Resolution {
 let session = FetchSession()
 var last: Resolution?
 for _ in 0..<fetchIterationLimit {
 session.beginIteration()
 let r = try resolve(rootDir: rootDir, manifest: manifest, session: session)
 last = r
 if !session.selectionChanged { return r }
 }
 _ = last
 throw ToolchainError.resolutionDidNotConverge(limit: fetchIterationLimit)
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
 /// ⚠ 批 7 补齐 `commit` / `tap` / `source`：此前锁文件写了这三项、解析时全部丢弃——
 /// 批 7 前 `commit` 恒为 `"-"`，故无人察觉；现在它是真实的来源定位符（G52 D12），
 /// 读不回来等于字段形同虚设。`tap` / `source` 回读后供 `verify` 报错时回显来源。
 public var modules: [(name: String, version: String, sum: String, manifestSum: String, path: String,
 importedBy: [String], commit: String, tap: String, source: String)] = []
 public var resources: [(name: String, version: String, sum: String, path: String,
 commit: String, tap: String, source: String)] = []
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
 MiniTOML.parseArray(e["imported-by"] ?? "[]"),
 e["commit"] ?? "-", e["tap"] ?? "", e["source"] ?? ""))
 }
 for e in doc.arrayTables["resource"] ?? [] {
 s.resources.append((e["name"] ?? "", e["version"] ?? "", e["sum"] ?? "", e["path"] ?? "",
 e["commit"] ?? "-", e["tap"] ?? "", e["source"] ?? ""))
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
 + "file: 通道的依赖请用 git submodule 或手工拷贝落到 deps/\(name)/"
 case .remoteTapNotMaterialized(let name, let tap):
 return "依赖 '\(name)' 来自远程 tap '\(tap)'，但 deps/\(name)/ 尚未落地。"
 + "抓取只发生在 `pini mod refresh`；其余命令（含 graph）只读已落地的依赖"
 case .resourceNotMaterialized(let name, let path):
 return "资源 '\(name)' 尚未落地到 \(path)（file: 通道需手工放置，远程通道由 `pini mod refresh` 抓取）"
 case .resourceTargetIsModule(let name, let path):
 return "资源 '\(name)'（\(path)）的根含 pini.toml —— 它是 **Pini 模块**，应改用 [require]"
 + "（G52 R7/D20：双通道以「有无 pini.toml」为判据，双向强制；本检查只看目标根，不查深层）"
 case .resolutionDidNotConverge(let limit):
 return "版本求解在 \(limit) 轮迭代内未收敛：依赖的约束随其版本变化，可能构成互相抬升的约束环。"
 + "请钉住其中一方的版本（[replace] 或精确约束）后重试"
 case .unsatisfiable(let name, let available, let conflicts):
 return "依赖 '\(name)' 可用版本 \(available) 不满足约束：\(conflicts.joined(separator: "；"))"
 case .missingDefaultTap(let name):
 return "依赖 '\(name)' 未指定 tap，且清单缺 [tap] default（G52 D11：org 须显式书写）"
 case .replaceTargetMissing(let name, let path):
 return "[replace] '\(name)' 指向的本地路径不存在：\(path)"
 case .summaryIdentityMismatch(let path):
 return "pini-summary.toml 与清单身份不符：\(path)"
 }
 }
}

// MARK: - 阶段 4：工具链命令核心（tidy / verify / graph）与 build 漂移检查

extension ModuleToolchain {

 /// 一次 import 的解析结果（tidy 与漂移检查共用）。
 public struct ImportFacts {
 public let alias: String
 /// 依赖的模块名（目标根 pini.toml 的 [package] name）。
 public let depName: String
 /// 目标根目录（canonical）。
 public let targetDir: String
 public let sourceFile: String
 }

 public enum ToolchainFailure: Error, Equatable {
 /// import 目标根无 pini.toml——不是 Pini 模块（R7 双向强制：资源应写 [resources]）。
 case importTargetNotModule(packagePath: String, sourceFile: String)
 }


 /// 收集包内全部文件 import 的依赖模块名（tidy 与漂移检查共用；离线，只读本地清单）。
 public static func collectImports(package: Package) throws -> [ImportFacts] {
 var facts: [ImportFacts] = []
 var seen = Set<String>()
 for unit in package.fileUnits {
 let dir = (unit.fileName as NSString).deletingLastPathComponent
 for imp in unit.module.imports {
 let target = ModuleDependencyLoader.shared.canonicalPath(packagePath: imp.packagePath,
 relativeTo: dir)
 guard FileManager.default.fileExists(atPath: target + "/pini.toml"),
 let depManifest = try? FileLoader.loadManifest(directory: target),
 let depName = Optional(depManifest.name) else {
 throw ToolchainFailure.importTargetNotModule(packagePath: imp.packagePath,
 sourceFile: unit.fileName)
 }
 let key = depName + "@" + target
 if seen.insert(key).inserted {
 facts.append(ImportFacts(alias: imp.alias, depName: depName,
 targetDir: target, sourceFile: unit.fileName))
 }
 }
 }
 return facts
 }

 // MARK: tidy（离线；集合对齐）

 public struct TidyReport: Equatable {
 public let added: [String]
 public let removed: [String]
 public let kept: Int
 public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
 }

 /// `pini mod tidy`：令 [require]（含子表）条目集合与代码 import 一致（G52 §4.1，D21 离线）。
 /// 新增条目约束写 `*`（回填由 refresh）；既有条目的约束与 tap 位置**原样保留**；
 /// 多余条目删除。经文本段落替换写回（require 区段外的注释不受影响）。
 @discardableResult
 public static func tidy(rootDir: String, manifest: ModuleManifest, package: Package) throws -> TidyReport {
 let facts = try collectImports(package: package)
 let desired = Set(facts.map(\.depName))

 // 既有条目：名 → (约束, tapName or nil)。replace 的非 file: 约束覆盖不算集合成员。
 var existing: [String: (constraint: String, tap: String?)] = [:]
 for (n, c) in manifest.require { existing[n] = (c, nil) }
 for (tn, kv) in manifest.requireTaps { for (n, c) in kv { existing[n] = (c, tn) } }

 let existingNames = Set(existing.keys)
 let toAdd = desired.subtracting(existingNames).sorted()
 let toRemove = existingNames.subtracting(desired).sorted()

 guard !(toAdd.isEmpty && toRemove.isEmpty) else {
 return TidyReport(added: [], removed: [], kept: existing.count)
 }

 var newEntries: [(name: String, constraint: String, tap: String?)] = []
 for n in existing.keys.sorted() where !toRemove.contains(n) {
 newEntries.append((n, existing[n]!.constraint, existing[n]!.tap))
 }
 for n in toAdd {
 newEntries.append((n, "*", nil)) // D21：未知约束写 `*`
 }

 let manifestPath = rootDir + "/pini.toml"
 let original = try String(contentsOfFile: manifestPath, encoding: .utf8)
 let updated = replaceRequireSections(in: original, entries: newEntries)
 try updated.write(toFile: manifestPath, atomically: true, encoding: .utf8)
 return TidyReport(added: toAdd, removed: toRemove, kept: newEntries.count - toAdd.count)
 }

 /// 文本级替换 require 区段：平表 `[require]` 与各 `[require.<tap>]` 区段重写为排序后的条目；
 /// 区段不存在则在文末追加。**非 require 区段的文本（含注释）不动**。
 static func replaceRequireSections(in text: String,
 entries: [(name: String, constraint: String, tap: String?)]) -> String {
 var lines = text.components(separatedBy: "\n")
 // 删除既有 require 区段体（保留其它区段）。
 var i = 0
 while i < lines.count {
 let t = lines[i].trimmingCharacters(in: .whitespaces)
 if t == "[require]" || t.hasPrefix("[require.") {
 lines.remove(at: i)
 while i < lines.count {
 let l = lines[i].trimmingCharacters(in: .whitespaces)
 if l.hasPrefix("[") { break } // 下一区段头
 lines.remove(at: i)
 }
 } else {
 i += 1
 }
 }

 // 生成新区段文本：平表（tap == nil）一条 `[require]`；具名各一条 `[require.<tap>]`。
 var blocks: [(header: String, rows: [String])] = []
 let plainEntries = entries.filter { $0.tap == nil }.sorted { $0.name < $1.name }
 if !plainEntries.isEmpty {
 blocks.append(("[require]", plainEntries.map { "\($0.name) = \"\($0.constraint)\"" }))
 }
 for tap in Set(entries.compactMap(\.tap)).sorted() {
 let rows = entries.filter { $0.tap == tap }.sorted { $0.name < $1.name }
 .map { "\($0.name) = \"\($0.constraint)\"" }
 blocks.append(("[require.\(tap)]", rows))
 }
 // 追加到文末（先补一个空行分隔）。
 if !blocks.isEmpty && !(lines.last ?? "").isEmpty { lines.append("") }
 for b in blocks {
 lines.append(b.header)
 lines.append(contentsOf: b.rows)
 lines.append("")
 }
 // 去掉文末多余空行（保留单个换行结尾）。
 while lines.count > 1 && lines.last == "" && lines[lines.count - 2] == "" {
 lines.removeLast()
 }
 return lines.joined(separator: "\n")
 }

 // MARK: refresh（写锁文件）

 /// `pini mod refresh` 的宿主侧：抓取 → 求解 → 写 `pini-summary.toml`（G52 §4.2）。
 /// 这是**唯一**会抓取 / 联网的路径（批 7 前只服务本地 tap，现覆盖 github:/git:）。
 /// 返回写入的锁文件文本。
 @discardableResult
 public static func refresh(rootDir: String, manifest: ModuleManifest,
 toolchainVersion: String) throws -> String {
 let resolution = try resolveFetching(rootDir: rootDir, manifest: manifest)
 let text = renderSummary(resolution: resolution, toolchainVersion: toolchainVersion)
 try text.write(toFile: rootDir + "/pini-summary.toml", atomically: true, encoding: .utf8)
 return text
 }

 // MARK: verify（只读；校验和执行点）

 public struct VerifyReport: Equatable {
 public let checked: Int
 public let mismatches: [String]
 public var isOK: Bool { mismatches.isEmpty }
 }

 /// `pini mod verify`：落地内容与锁文件的 sum/manifest_sum 比对（G52 §4.3，D6 执行点）。
 public static func verify(rootDir: String) throws -> VerifyReport {
 let summaryPath = rootDir + "/pini-summary.toml"
 guard FileManager.default.fileExists(atPath: summaryPath) else {
 throw ToolchainError.summaryIdentityMismatch(path: summaryPath + "（不存在：请先运行 pini mod refresh）")
 }
 let summary = parseSummary(try String(contentsOfFile: summaryPath, encoding: .utf8))
 var mismatches: [String] = []
 for m in summary.modules {
 let dir = (m.path.hasPrefix("/") ? m.path : rootDir + "/" + m.path)
 let actualSum = treeSum(dir)
 if actualSum != String(m.sum.dropPrefix("sha256:")) {
 mismatches.append("模块 '\(m.name)' 内容与锁文件不符（\(m.path)）——可能被篡改或过期"
 + Self.originSuffix(m.source))
 }
 let manifestPath = dir + "/pini.toml"
 let actualManifest = fileSum(manifestPath)
 if actualManifest != String(m.manifestSum.dropPrefix("sha256:")) {
 mismatches.append("模块 '\(m.name)' 的 pini.toml 与锁文件不符（\(m.path)）")
 }
 }
 for r in summary.resources {
 let dir = (r.path.hasPrefix("/") ? r.path : rootDir + "/" + r.path)
 let actualSum = treeSum(dir)
 if actualSum != String(r.sum.dropPrefix("sha256:")) {
 mismatches.append("资源 '\(r.name)' 内容与锁文件不符（\(r.path)）" + Self.originSuffix(r.source))
 }
 }
 return VerifyReport(checked: summary.modules.count + summary.resources.count,
 mismatches: mismatches)
 }

 /// 报错里回显来源——锁文件的 `source` 此前只写不读，篡改时无法判断该去哪里核对。
 private static func originSuffix(_ source: String) -> String {
 source.isEmpty ? "" : "；来源 \(source)"
 }

 // MARK: graph（依赖图展示与环诊断）

 /// `pini mod graph`：默认缩进树（D-C）；`--cycles` 输出环路径列表（R2 诊断入口）。
 public static func graph(rootDir: String, manifest: ModuleManifest) throws
 -> (tree: String, cycles: [[String]]) {
 let resolution = try resolve(rootDir: rootDir, manifest: manifest)
 let byName = Dictionary(uniqueKeysWithValues: resolution.modules.map { ($0.name, $0) })

 // 树：从根出发按 importedBy 反查——直接用「谁 require 谁」更直观：按 importedBy 分组。
 var children: [String: [String]] = [:] // requirer(去 <root>) → deps
 for m in resolution.modules {
 for by in m.importedBy where by != "<root>" {
 children[by, default: []].append(m.name)
 }
 }
 var lines: [String] = []
 func render(_ name: String, prefix: String, isLast: Bool, depth: Int) {
 let ver = byName[name].map { " \($0.version)" } ?? ""
 let connector = depth == 0 ? "" : (isLast ? "└─ " : "├─ ")
 lines.append(prefix + connector + name + ver)
 let deps = (children[name] ?? []).sorted()
 for (idx, d) in deps.enumerated() {
 let childPrefix = depth == 0 ? "" : prefix + (isLast ? "   " : "│  ")
 render(d, prefix: childPrefix, isLast: idx == deps.count - 1, depth: depth + 1)
 }
 }
 let roots = resolution.modules.filter { ($0.importedBy.contains("<root>")) }.map(\.name).sorted()
 if roots.isEmpty {
 lines.append("（无依赖）")
 } else {
 for (idx, r) in roots.enumerated() {
 render(r, prefix: "", isLast: idx == roots.count - 1, depth: 0)
 }
 }

 // 环检测：require 图上 DFS（排除 <root>）。
 var cycles: [[String]] = []
 var state: [String: Int] = [:] // 0=未访 1=在栈 2=完成
 var stack: [String] = []
 func dfs(_ name: String) {
 state[name] = 1
 stack.append(name)
 for d in (children[name] ?? []).sorted() {
 switch state[d] ?? 0 {
 case 0: dfs(d)
 case 1:
 if let start = stack.firstIndex(of: d) {
 cycles.append(Array(stack[start...]) + [d])
 }
 default: break
 }
 }
 stack.removeLast()
 state[name] = 2
 }
 for n in resolution.modules.map(\.name).sorted() where (state[n] ?? 0) == 0 {
 dfs(n)
 }
 return (lines.joined(separator: "\n"), cycles)
 }

 // MARK: build 漂移检查（G52 §4.3：每次 build；与 verify 是两个检查）

 public struct Drift: Equatable {
 public let missingInRequire: [String] // import 了但 require 没有
 public let extraInRequire: [String] // require 了但没 import
 public var hasDrift: Bool { !missingInRequire.isEmpty || !extraInRequire.isEmpty }
 }

 /// require ↔ import 集合一致性（**只读**；不符由调用方报错并提示 `pini mod tidy`）。
 /// 仅对采用依赖通道的清单生效（[tap]/[require]/[replace] 任一存在）——
 /// 批 1 落地的旧模块未采用通道，无 drift 概念，静默跳过（向后兼容，如实记录）。
 public static func checkRequireImportAlignment(rootDir: String, manifest: ModuleManifest,
 package: Package) throws -> Drift? {
 let adopted = !manifest.taps.isEmpty || !manifest.require.isEmpty
 || !manifest.requireTaps.isEmpty || !manifest.replaces.isEmpty
 guard adopted else { return nil }
 let imported = Set(try collectImports(package: package).map(\.depName))
 var required = Set(manifest.require.keys)
 for kv in manifest.requireTaps.values { required.formUnion(kv.keys) }
 let missing = imported.subtracting(required).sorted()
 let extra = required.subtracting(imported).sorted()
 guard !missing.isEmpty || !extra.isEmpty else { return nil }
 return Drift(missingInRequire: missing, extraInRequire: extra)
 }
}

extension String {
 /// 去掉前缀（若存在）；verify 比对用。
 func dropPrefix(_ prefix: String) -> String {
 hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
 }
}

extension ModuleToolchain.ToolchainFailure: LocalizedError {
 public var errorDescription: String? {
 switch self {
 case .importTargetNotModule(let packagePath, let sourceFile):
 return "\(sourceFile)：import 目标 '\(packagePath)' 的根缺 pini.toml——不是 Pini 模块，"
 + "不可 import（R7 双向强制）；若是语料/数据等资源，请改写到 [resources]"
 }
 }
 }
