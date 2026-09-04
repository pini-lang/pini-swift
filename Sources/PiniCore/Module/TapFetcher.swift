import Foundation

/// 批 7（G52）：远端 tap 抓取器——把 `[tap]` 声明的源变成 `deps/<name>/` 里的一次真实检出。
///
/// tap 沿用 Homebrew 的心智模型（`brew tap user/repo`）：**tap 即一个 git 仓库**，默认源为 github。
/// 三协议见 `expand`：
///
/// | spec | 展开为 | 备注 |
/// |---|---|---|
/// | `github:<org>` | `https://github.com/<org>/<name>.git` | org **必须显式书写**（G52 D11，可复现性） |
/// | `git:<url>` | 原样 | git 能懂的 URL 均可，**含本地路径**——故整条链路可离线端到端测试 |
/// | `file:<path>` | 原样路径 | 批 7 **不落地**它（见下） |
///
/// `<name>` 为占位符，展开时替换为模块名（G52 §3.1）。
///
/// v1 边界（如实记录，不假装已解决）：
/// - **`file:` 不由本文件落地**——批 6 已 Landed 的语义是「tap 作来源元数据 + 依赖由
///   git submodule / 手工拷贝到 `deps/<name>/`」，本批**不动**该语义（用户裁决 2026-09-04）。
///   `expand` 仍解析 `file:`，以便调用方判定通道；`materialize` 对它显式报错而非静默跳过。
/// - 抓取经 `Process` 调 git 子进程。git 缺失或非零退出**一律抛错**，不静默降级——
///   延续批 6 D-A 的判据：半成品依赖比报错更危险。
/// - 无中心化 sumdb（v1 不做）。`commit` 只是**来源定位符**，内容凭证仍是 `sum`（G52 D6/D12）。
/// - 本文件只提供能力，**不接进 `ModuleToolchain.resolve`**（接线属批 7 的阶段 4）。
public enum TapFetcher {

 // MARK: - 错误

 public enum TapError: Error, Equatable {
 /// 协议前缀不是 `github:` / `git:` / `file:`。
 case unsupportedScheme(String)
 /// `github:` 后未写 org（G52 D11：禁止从全局配置或环境变量推断）。
 case missingOrg(String)
 /// `git:` 后未写 URL。
 case missingURL(String)
 /// 找不到可执行的 git（`/usr/bin/git`）。
 case gitUnavailable
 /// git 非零退出。**stderr 全文入错误**，便于诊断（不吞掉）。
 case gitFailed(args: [String], status: Int32, stderr: String)
 /// 候选版本里没有该版本的 tag。
 case versionNotFound(version: String, source: String)
 /// 目标目录已存在但不是 git 检出——不代为删除（避免吞掉用户数据）。
 case destinationOccupied(path: String)
 /// `materialize` 收到 `file:`：批 7 不落地它，显式报错而非静默跳过。
 case fileTapNotMaterialized(path: String)
 }

 // MARK: - 源

 public enum Scheme: String, Equatable { case github, git, file }

 /// 展开后的 tap 源。
 public struct Source: Equatable {
 public let scheme: Scheme
 /// 可直接交给 git 的 URL（本地路径亦可）。
 public let url: String
 /// 写进 `pini-summary.toml` 的 `source` 字段。
 public let display: String
 }

 /// tap spec → 源。`<name>` 占位符在此替换为模块名。
 public static func expand(spec: String, name: String) throws -> Source {
 let s = spec.trimmingCharacters(in: .whitespaces)
 if s.hasPrefix("github:") {
 let org = String(s.dropFirst("github:".count)).replacingOccurrences(of: "<name>", with: name)
 guard !org.isEmpty else { throw TapError.missingOrg(spec) }
 let url = "https://github.com/\(org)/\(name).git"
 return Source(scheme: .github, url: url, display: url)
 }
 if s.hasPrefix("git:") {
 var rest = String(s.dropFirst("git:".count)).replacingOccurrences(of: "<name>", with: name)
 guard !rest.isEmpty else { throw TapError.missingURL(spec) }
 // 目录形式的本地路径去掉尾斜杠，`git clone` 对两者都接受，但统一后更好比对。
 if rest.hasSuffix("/") && rest != "/" { rest = String(rest.dropLast()) }
 return Source(scheme: .git, url: rest, display: rest)
 }
 if s.hasPrefix("file:") {
 let path = String(s.dropFirst("file:".count)).replacingOccurrences(of: "<name>", with: name)
 return Source(scheme: .file, url: path, display: "file:" + path)
 }
 throw TapError.unsupportedScheme(spec)
 }

 // MARK: - 候选版本（tag 列举）

 /// 可用版本：远端 tag 剥掉 `v` 前缀后**可解析为版本号**者，去重并按版本升序。
 ///
 /// 经 `git ls-remote --tags`——本地路径同样适用，故可离线测试。
 /// 剥不出的 tag（如 `nightly`、带非数字段的）不进候选：它们无法参与 MVS 比较。
 public static func availableVersions(_ source: Source) throws -> [String] {
 guard source.scheme != .file else { return [] } // file: 无版本图可解（G52 §3.3）
 let out = try runGit(["ls-remote", "--tags", source.url])
 var seen = Set<String>()
 var versions: [String] = []
 for line in out.split(separator: "\n") {
 let cols = line.split(separator: "\t").map(String.init)
 guard cols.count == 2, cols[1].hasPrefix("refs/tags/") else { continue }
 let tag = String(cols[1].dropFirst("refs/tags/".count))
 // 附注 tag 会多出一条 `^{}` 解引用行，指向同一对象——跳过，避免重复候选。
 if tag.hasSuffix("^{}") { continue }
// 剥 `v` 前缀是**规范化**而非解析兜底：剥出的串既是 MVS 候选、也用于拼 `refs/tags/v<v>`、
// 并写进锁文件，故必须是 `1.0.0` 而非 `v1.0.0`。解析侧的 v 前缀容忍由
// `Constraint.versionComponents` 统一负责（G52 §9 Def-9）。
var v = tag
if v.hasPrefix("v") { v = String(v.dropFirst()) }
guard ModuleToolchain.Constraint.versionComponents(v) != nil else { continue }
 if seen.insert(v).inserted { versions.append(v) }
 }
 return versions.sorted { lhs, rhs in
 ModuleToolchain.Constraint.compare(
 ModuleToolchain.Constraint.versionComponents(lhs) ?? [],
 ModuleToolchain.Constraint.versionComponents(rhs) ?? []) < 0
 }
 }

 // MARK: - 经典 MVS（G52 R3）

 /// 经典 MVS：在升序候选里返回**满足全部约束的最小版本**。
 ///
/// 「最小」是相对于「取最新版」而言——每个约束给出一个下界，MVS 取所有下界的最大值
/// 再向上对齐到可用版本，等价于「升序候选中第一个全部满足者」。
///
/// - 约束不可解析 → 返回 `nil`（宁严勿纵，与 `ModuleToolchain.resolve` 侧一致：
///   无法解析的约束按不满足处理，不静默当作 `*`）。
/// - **全为 `*` / 空约束 → 返回最高可用版本**。这不是经典 MVS 的推论，而是 D21 的
///   回填语义：`tidy` 为新增 import 写的 `*` 表示「版本未知」，`refresh` 回填时取最新。
///   ⚠ 两种策略在同一函数内由「是否存在非空约束」分派——若将来要分离，这是切点。
///
/// - Returns: 选中的版本字符串；无满足候选时 `nil`（调用方据此报 `unsatisfiable`）。
 public static func selectVersion(candidates: [String], constraints: [String]) -> String? {
 typealias C = ModuleToolchain.Constraint
 let parsed: [(version: String, comps: [Int])] = candidates.compactMap { v in
 C.versionComponents(v).map { (version: v, comps: $0) }
 }.sorted { C.compare($0.comps, $1.comps) < 0 }

 var effective: [C] = []
 for raw in constraints {
 guard let c = C.parse(raw) else { return nil } // 不可解析 → 无解
 if !c.atoms.isEmpty { effective.append(c) } // `*` 是空约束
 }
 guard !effective.isEmpty else { return parsed.last?.version } // D21 回填 → 最新
 for entry in parsed where effective.allSatisfy({ $0.satisfies(entry.comps) }) {
 return entry.version
 }
 return nil
 }

 // MARK: - 落地（clone / fetch + checkout）

 /// 把 `source` 的 `version` 落地到 `dir`：首次 clone，已有 `.git` 则 fetch 后 checkout。
 ///
/// - Returns: 检出后的 HEAD commit（G52 D12：来源定位符，**不是**校验凭证）。
 @discardableResult
 public static func materialize(_ source: Source, version: String?, into dir: String) throws -> String {
 guard source.scheme != .file else { throw TapError.fileTapNotMaterialized(path: source.url) }
 let fm = FileManager.default
 if fm.fileExists(atPath: dir) {
 guard fm.fileExists(atPath: dir + "/.git") else { throw TapError.destinationOccupied(path: dir) }
 _ = try runGit(["-C", dir, "fetch", "--tags", "--quiet"])
 } else {
 _ = try runGit(["clone", "--quiet", source.url, dir])
 }
 if let v = version {
 // tag 名可能带也可能不带 `v` 前缀——两种都试，都不在才报错。
 if (try? runGit(["-C", dir, "rev-parse", "--verify", "--quiet", "refs/tags/v\(v)"])) != nil {
 _ = try runGit(["-C", dir, "checkout", "--quiet", "refs/tags/v\(v)"])
 } else if (try? runGit(["-C", dir, "rev-parse", "--verify", "--quiet", "refs/tags/\(v)"])) != nil {
 _ = try runGit(["-C", dir, "checkout", "--quiet", "refs/tags/\(v)"])
 } else {
 throw TapError.versionNotFound(version: v, source: source.url)
 }
 }
 return try headCommit(dir)
 }

 /// 检出的 HEAD commit（`git rev-parse HEAD`）。
 public static func headCommit(_ dir: String) throws -> String {
 try runGit(["-C", dir, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
 }

 // MARK: - git 子进程

 /// 执行 git。非零退出抛 `gitFailed` 并带上 stderr 全文——**不吞掉诊断信息**。
 @discardableResult
 static func runGit(_ args: [String]) throws -> String {
 let exe = "/usr/bin/git"
 guard FileManager.default.isExecutableFile(atPath: exe) else { throw TapError.gitUnavailable }
 let p = Process()
 p.executableURL = URL(fileURLWithPath: exe)
 p.arguments = args
 // 禁止交互式凭据提示：远端不可达时应立刻失败，而不是挂住等输入。
 var env = ProcessInfo.processInfo.environment
 env["GIT_TERMINAL_PROMPT"] = "0"
 env["GIT_ASKPASS"] = "/usr/bin/true"
 p.environment = env
 let out = Pipe(), err = Pipe()
 p.standardOutput = out
 p.standardError = err
 do { try p.run() } catch { throw TapError.gitUnavailable }
 let outData = out.fileHandleForReading.readDataToEndOfFile()
 let errData = err.fileHandleForReading.readDataToEndOfFile()
 p.waitUntilExit()
 guard p.terminationStatus == 0 else {
 throw TapError.gitFailed(args: args, status: p.terminationStatus,
 stderr: String(data: errData, encoding: .utf8) ?? "")
 }
 return String(data: outData, encoding: .utf8) ?? ""
 }
}

extension TapFetcher.TapError: LocalizedError {
 public var errorDescription: String? {
 switch self {
 case .unsupportedScheme(let spec):
 return "无法识别的 tap 源 '\(spec)'：仅支持 github:<org> / git:<url> / file:<path>"
 case .missingOrg(let spec):
 return "tap 源 '\(spec)' 缺少 org（G52 D11）：github: 后必须显式书写 org，"
 + "禁止从全局配置或环境变量推断（否则两台机器会解析到不同模块，锁文件失效）"
 case .missingURL(let spec):
 return "tap 源 '\(spec)' 缺少 URL"
 case .gitUnavailable:
 return "未找到可执行的 git（/usr/bin/git）——远端 tap 依赖 git 抓取"
 case .gitFailed(let args, let status, let stderr):
 return "git \(args.joined(separator: " ")) 失败（退出码 \(status)）：\(stderr)"
 case .versionNotFound(let version, let source):
 return "源 '\(source)' 上找不到版本 \(version) 对应的 tag"
 case .destinationOccupied(let path):
 return "'\(path)' 已存在且不是 git 检出——工具不会代为删除，请手工处理后再重试"
 case .fileTapNotMaterialized(let path):
 return "file: 源 '\(path)' 不由 refresh 落地（批 7 范围）：依赖请改用 git submodule 或手工拷贝，"
 + "本地替换请用 [replace] 的 file: 形态"
 }
 }
}
