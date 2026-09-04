import XCTest
@testable import PiniCore
import Foundation

/// 批 7（G52）：远端 tap 抓取器。
///
/// **所有用例离线可跑**——`git:` 协议接受本地路径，故用一个 tmp 里的真实 git 仓库当「远端」，
/// 走通 `ls-remote` → MVS → clone/checkout → `rev-parse` 全链路，不发一个网络包。
/// `github:` 只测 URL 展开（纯函数），真实抓取不在测试里发生。
final class TapFetcherTests: XCTestCase {

 // MARK: - tap 展开（G52 §3.1）

 func testExpandThreeSchemes() throws {
 let gh = try TapFetcher.expand(spec: "github:pini-lang", name: "uni")
 XCTAssertEqual(gh.scheme, .github)
 XCTAssertEqual(gh.url, "https://github.com/pini-lang/uni.git")

 // `<name>` 占位符被替换（D11：org 显式书写，只在 [tap] default 写一次）
 let ghTpl = try TapFetcher.expand(spec: "github:<name>-lang", name: "text")
 XCTAssertEqual(ghTpl.url, "https://github.com/text-lang/text.git")

 let git = try TapFetcher.expand(spec: "git:https://git.example.com/<name>.git", name: "uni")
 XCTAssertEqual(git.scheme, .git)
 XCTAssertEqual(git.url, "https://git.example.com/uni.git")

 let file = try TapFetcher.expand(spec: "file:../vendor/<name>", name: "uni")
 XCTAssertEqual(file.scheme, .file)
 XCTAssertEqual(file.url, "../vendor/uni")
 XCTAssertEqual(file.display, "file:../vendor/uni")
 }

 /// D11：org 必须显式书写；协议不可识别即报错（都不是静默降级）。
 func testExpandRejectsMissingOrgAndUnknownScheme() {
 XCTAssertThrowsError(try TapFetcher.expand(spec: "github:", name: "uni")) { error in
 guard case TapFetcher.TapError.missingOrg = error else {
 return XCTFail("应为 missingOrg（D11），实际：\(error)")
 }
 }
 XCTAssertThrowsError(try TapFetcher.expand(spec: "git:", name: "uni")) { error in
 guard case TapFetcher.TapError.missingURL = error else {
 return XCTFail("应为 missingURL，实际：\(error)")
 }
 }
 XCTAssertThrowsError(try TapFetcher.expand(spec: "https://example.com/uni", name: "uni")) { error in
 guard case TapFetcher.TapError.unsupportedScheme = error else {
 return XCTFail("应为 unsupportedScheme，实际：\(error)")
 }
 }
 }

 // MARK: - 经典 MVS（G52 R3）

 func testSelectVersionClassicalMVS() {
 let candidates = ["2.0.0", "1.0.0", "1.2.0", "1.2.3"] // 故意乱序传入

 // 「最小」是相对「取最新版」而言：约束给出下界，MVS 取满足下界的**最低**可用版本。
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: [">=1.2"]), "1.2.0")
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: [">=1.2.1"]), "1.2.3")
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: ["=1.2.0"]), "1.2.0")

 // 多个 requirer：取所有下界的最大值再向上对齐（MVS 的定义）
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: ["1.0", "1.2.0"]), "1.2.0")

 // ⚠ caret / 区间是「范围」而非「下界」，故 MVS 取到的是**范围内最低**版本：
 // `^1.0` = `>=1.0.0, <2.0.0`，最低满足者即 1.0.0（**不是** 1.2.3）。
 // 这与「取最新兼容版」的直觉相反，但它是经典 MVS 的直接推论，不是缺陷——
 // 需要「最新兼容版」时应显式写 `*` 走 D21 回填通道。
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: ["^1.0"]), "1.0.0")
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates,
 constraints: [">=1.0", "<2.0.0"]), "1.0.0")

 // 无满足候选 → nil（调用方据此报 unsatisfiable，不静默取最新）
 XCTAssertNil(TapFetcher.selectVersion(candidates: candidates, constraints: [">=3.0"]))

 // 不可解析的约束 → nil（宁严勿纵，与 resolve 侧一致：不当作 `*`）
 XCTAssertNil(TapFetcher.selectVersion(candidates: candidates, constraints: ["not-a-version"]))
 }

 /// D21 回填语义：全为 `*` 时取**最新**可用版本（未知约束由 refresh 回填）。
 /// ⚠ 这是本函数里唯一的非经典 MVS 分支，由「是否存在非空约束」分派。
 func testSelectVersionBackfillsLatestWhenUnconstrained() {
 let candidates = ["1.0.0", "1.2.0", "2.0.0"]
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: []), "2.0.0")
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: ["*"]), "2.0.0")
 // 但只要有一条真实约束，就回到经典 MVS（取范围内最低满足者）
 XCTAssertEqual(TapFetcher.selectVersion(candidates: candidates, constraints: ["*", "^1.0"]), "1.0.0")
 }

 // MARK: - 本地 git 夹具（离线「远端」）

 /// 建一个真实 git 仓库作远端：`versions` 逐个写进清单、提交并打 `v<版本>` tag。
 ///
 /// `manifestExtra` 追加在 `[package]` 之后（各版本相同）——用于让依赖仓库自带
 /// `[tap]` / `[require]`，从而构造传递依赖。
 private func makeGitRepo(at path: String, moduleName: String, versions: [String],
 manifestExtra: String = "") throws {
 func git(_ args: [String]) throws { _ = try TapFetcher.runGit(args) }
 try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
 try git(["init", "-q", path])
 try git(["-C", path, "config", "user.email", "tap@pini.local"])
 try git(["-C", path, "config", "user.name", "Pini Tap Fixture"])
 try git(["-C", path, "config", "commit.gpgsign", "false"])
 for v in versions {
 let manifest = "[package]\nname = \"\(moduleName)\"\nversion = \"\(v)\"\n" + manifestExtra
 try manifest.write(toFile: path + "/pini.toml", atomically: true, encoding: .utf8)
 try git(["-C", path, "add", "-A"])
 try git(["-C", path, "commit", "-qm", "v\(v)"])
 try git(["-C", path, "tag", "v\(v)"])
 }
 }

 /// 单仓库夹具：tag v1.0.0 / v1.2.0 / v2.0.0，外加一个**非版本** tag。
 private func makeGitTapFixture() throws -> (base: String, source: TapFetcher.Source,
 cleanup: () -> Void) {
 let base = NSTemporaryDirectory() + "pini_b7_\(UUID().uuidString)"
 let src = base + "/src"
 try makeGitRepo(at: src, moduleName: "demo", versions: ["1.0.0", "1.2.0", "2.0.0"])
 // 非版本 tag：无法参与 MVS 比较，必须从候选里剔除
 _ = try TapFetcher.runGit(["-C", src, "tag", "nightly"])

 let source = try TapFetcher.expand(spec: "git:" + src, name: "demo")
 return (base, source, { try? FileManager.default.removeItem(atPath: base) })
 }

 /// 建一个非 Pini 的资源仓库（**无 pini.toml**，G52 §3.3 的判据），打 `v<tag>`。
 private func makeResourceRepo(at path: String, tag: String? = nil) throws {
 func git(_ args: [String]) throws { _ = try TapFetcher.runGit(args) }
 try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
 try "corpus data\n".write(toFile: path + "/data.txt", atomically: true, encoding: .utf8)
 try git(["init", "-q", path])
 try git(["-C", path, "config", "user.email", "tap@pini.local"])
 try git(["-C", path, "config", "user.name", "Pini Tap Fixture"])
 try git(["-C", path, "add", "-A"])
 try git(["-C", path, "commit", "-qm", "data"])
 if let tag { try git(["-C", path, "tag", "v\(tag)"]) }
 }

 /// 意图：候选只含可解析为版本的 tag，且升序；`nightly` 与附注 tag 的 `^{}` 行不得混入。
 func testAvailableVersionsFromLocalRepo() throws {
 let fixture = try makeGitTapFixture()
 defer { fixture.cleanup() }

 let versions = try TapFetcher.availableVersions(fixture.source)
 XCTAssertEqual(versions, ["1.0.0", "1.2.0", "2.0.0"], "非版本 tag 必须被剔除，且结果升序")
 }

 /// 意图：端到端——列候选 → MVS 选中 → clone 到该 tag → commit 有值 → 清单版本即选中版本。
 func testMaterializeLocalGitRepoEndToEnd() throws {
 let fixture = try makeGitTapFixture()
 defer { fixture.cleanup() }
 let dest = fixture.base + "/deps/demo"

 let versions = try TapFetcher.availableVersions(fixture.source)
 let selected = try XCTUnwrap(TapFetcher.selectVersion(candidates: versions, constraints: [">=1.2"]),
 "约束 >=1.2 下应有满足的候选")
 XCTAssertEqual(selected, "1.2.0", "经典 MVS：取满足 >=1.2 的最低版本，而非已存在的 2.0.0")

 let commit = try TapFetcher.materialize(fixture.source, version: selected, into: dest)

 // 落地内容 = 选中版本
 XCTAssertTrue(FileManager.default.fileExists(atPath: dest + "/pini.toml"))
 let landed = try XCTUnwrap(FileLoader.loadManifest(directory: dest))
 XCTAssertEqual(landed.name, "demo")
 XCTAssertEqual(landed.version, "1.2.0", "落地清单版本必须等于 MVS 选中的版本")
 // commit 是真实来源定位符（D12），不是占位
 XCTAssertEqual(commit.count, 40, "commit 应为完整 SHA-1，实际：\(commit)")
 XCTAssertEqual(try TapFetcher.headCommit(dest), commit)

 // 升版本：同一目录再次 materialize 应走 fetch + checkout，而非重新 clone
 let sumBefore = ModuleToolchain.treeSum(dest)
 let commit2 = try TapFetcher.materialize(fixture.source, version: "2.0.0", into: dest)
 XCTAssertNotEqual(commit, commit2, "换版本后 HEAD 必须改变")
 let reloaded = try XCTUnwrap(FileLoader.loadManifest(directory: dest))
 XCTAssertEqual(reloaded.version, "2.0.0")
 // 内容树摘要随之改变（D6 校验和的基础）
 XCTAssertNotEqual(ModuleToolchain.treeSum(dest), sumBefore, "换版本后内容树摘要必须改变")
 }

 /// 意图：目标已存在但不是 git 检出 → 报错，**不代为删除**（避免吞掉用户数据）。
 func testMaterializeRefusesToClobberNonGitDirectory() throws {
 let fixture = try makeGitTapFixture()
 defer { fixture.cleanup() }
 let dest = fixture.base + "/deps/demo"
 try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
 try "handwritten".write(toFile: dest + "/keep.txt", atomically: true, encoding: .utf8)

 XCTAssertThrowsError(try TapFetcher.materialize(fixture.source, version: "1.0.0", into: dest)) { error in
 guard case TapFetcher.TapError.destinationOccupied(let path) = error else {
 return XCTFail("应为 destinationOccupied，实际：\(error)")
 }
 XCTAssertEqual(path, dest)
 }
 XCTAssertTrue(FileManager.default.fileExists(atPath: dest + "/keep.txt"), "不得删除既有内容")
 }

 /// 意图：git 失败必须带着 stderr 抛错，不静默降级为「无依赖」。
 /// 用不存在的本地路径触发——git 立即失败，不发任何网络请求。
 func testGitFailureSurfacesStderr() throws {
 let source = try TapFetcher.expand(spec: "git:/tmp/pini-definitely-not-here-\(UUID().uuidString)",
 name: "demo")
 let dest = NSTemporaryDirectory() + "pini_b7_missing_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: dest) }

 XCTAssertThrowsError(try TapFetcher.materialize(source, version: nil, into: dest)) { error in
 guard case TapFetcher.TapError.gitFailed(let args, let status, let stderr) = error else {
 return XCTFail("应为 gitFailed，实际：\(error)")
 }
 XCTAssertNotEqual(status, 0)
 XCTAssertTrue(args.contains("clone"))
 XCTAssertFalse(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
 "stderr 必须带入错误，否则无法诊断")
 }
 }

 /// 意图：`file:` 通道不由 refresh 落地（批 7 范围外）——显式报错，不静默跳过。
 func testMaterializeRejectsFileTap() throws {
 let source = try TapFetcher.expand(spec: "file:../vendor/demo", name: "demo")
 XCTAssertThrowsError(try TapFetcher.materialize(source, version: nil, into: "/tmp/pini-nope")) { error in
 guard case TapFetcher.TapError.fileTapNotMaterialized = error else {
 return XCTFail("应为 fileTapNotMaterialized，实际：\(error)")
 }
 }
 XCTAssertEqual(try TapFetcher.availableVersions(source), [], "file: 无版本图可解（G52 §3.3）")
 }

 // MARK: - refresh 接线（批 7 阶段 3-4）

 /// 端到端：本地 git 仓库当远端 tap —— refresh 抓取 → 落 `deps/` → 写锁文件（commit 为真值）
 /// → `verify` 通过 → 篡改后**必须**检出不符（D6 的执行点）。
 func testRefreshFetchesRemoteTapAndVerifies() throws {
 let base = NSTemporaryDirectory() + "pini_b7_refresh_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: base) }
 try makeGitRepo(at: base + "/remote/demo", moduleName: "demo",
 versions: ["1.0.0", "1.2.0", "2.0.0"])
 let app = base + "/app"
 try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
 try "[package]\nname = \"app\"\n\n[tap]\nlocal = \"git:\(base)/remote/<name>\"\n\n[require.local]\ndemo = \">=1.2\"\n"
 .write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
 let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
 toolchainVersion: "pini 0.51.0 (spec 0.1)")

 // 落地内容 = MVS 选中版本（>=1.2 → 1.2.0，不是已存在的 2.0.0）
 let landed = try XCTUnwrap(FileLoader.loadManifest(directory: app + "/deps/demo"))
 XCTAssertEqual(landed.version, "1.2.0")
 // 锁文件里的 commit 是真值，不再是占位符 "-"
 let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
 XCTAssertEqual(mod.name, "demo")
 XCTAssertEqual(mod.version, "1.2.0")
 XCTAssertEqual(mod.commit.count, 40, "commit 应为完整 SHA-1，实际：\(mod.commit)")
 XCTAssertNotEqual(mod.commit, "-")

 XCTAssertTrue(try ModuleToolchain.verify(rootDir: app).isOK)
 // 篡改后 verify 必须报错——否则 sum 字段只是摆设（G52 §4.3）
 let target = app + "/deps/demo/pini.toml"
 let text = try String(contentsOfFile: target, encoding: .utf8)
 try (text + "\n# tampered\n").write(toFile: target, atomically: true, encoding: .utf8)
 XCTAssertFalse(try ModuleToolchain.verify(rootDir: app).isOK, "篡改后 verify 必须检出不符")
 }

 /// 阶段 3：资源也由 refresh 落地到 `.pini/resources/<name>/`（R6），并同样记录 commit。
 /// 批 7 前这里是**静默跳过**——资源因此永远不进锁文件。
 func testRefreshMaterializesResource() throws {
 let base = NSTemporaryDirectory() + "pini_b7_res_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: base) }
 try makeResourceRepo(at: base + "/remote/corpus", tag: "1.0")
 let app = base + "/app"
 try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
 try "[package]\nname = \"app\"\n\n[tap]\nlocal = \"git:\(base)/remote/<name>\"\n\n[resources.local]\ncorpus = \"1.0\"\n"
 .write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
 let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
 toolchainVersion: "pini 0.51.0 (spec 0.1)")

 XCTAssertTrue(FileManager.default.fileExists(atPath: app + "/.pini/resources/corpus/data.txt"),
 "资源必须落地到 .pini/resources/<name>/（R6）")
 let res = try XCTUnwrap(ModuleToolchain.parseSummary(summary).resources.first)
 XCTAssertEqual(res.name, "corpus")
 XCTAssertEqual(res.commit.count, 40, "资源同样记录来源定位符（G52 D12）")
 XCTAssertEqual(res.path, ".pini/resources/corpus")
 }

 /// 不动点迭代：root 对 b 只写 `*`（D21 回填 → 取最新 2.0.0），而传递依赖 a 要求 b `^1.2`。
 /// 单轮解析会停在 2.0.0 或直接判「不可满足」；只有迭代到不动点才收敛到 1.2.0。
 func testRefreshConvergesOnTransitiveConstraint() throws {
 let base = NSTemporaryDirectory() + "pini_b7_fix_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: base) }
 let remote = base + "/remote/<name>"
 try makeGitRepo(at: base + "/remote/a", moduleName: "a", versions: ["1.0.0"],
 manifestExtra: "\n[tap]\ndefault = \"git:\(remote)\"\n\n[require]\nb = \"^1.2\"\n")
 try makeGitRepo(at: base + "/remote/b", moduleName: "b", versions: ["1.0.0", "1.2.0", "2.0.0"])

 let app = base + "/app"
 try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
 try "[package]\nname = \"app\"\n\n[tap]\nlocal = \"git:\(remote)\"\n\n[require.local]\na = \"*\"\nb = \"*\"\n"
 .write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
 let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
 toolchainVersion: "pini 0.51.0 (spec 0.1)")
 let versions = Dictionary(uniqueKeysWithValues:
 ModuleToolchain.parseSummary(summary).modules.map { ($0.name, $0.version) })
 XCTAssertEqual(versions["b"], "1.2.0", "传递依赖的 ^1.2 必须压过 root 的 * 回填（2.0.0）")
 XCTAssertEqual(versions["a"], "1.0.0")
 XCTAssertTrue(try ModuleToolchain.verify(rootDir: app).isOK)
 }

 // MARK: - 收尾补修（Def-1 / Def-7）

 /// **Def-1 · R7 根检（D20/D26 反向）**：`resources X` 而 X 的根含 `pini.toml`
 /// ⇒ 它是 Pini 模块，应改用 `[require]`。此前双通道只兑现正向，这一半缺失。
 func testResourceTargetThatIsAModuleIsRejected() throws {
 let base = NSTemporaryDirectory() + "pini_b7_r7_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: base) }
 // 目标**是**一个 Pini 模块（根有 pini.toml），却写进了 [resources]
 try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0"])
 let app = base + "/app"
 try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
 try "[package]\nname = \"app\"\n\n[tap]\nlocal = \"git:\(base)/remote/<name>\"\n\n[resources.local]\ndemo = \"1.0\"\n"
 .write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
 XCTAssertThrowsError(try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
 toolchainVersion: "t")) { error in
 guard case ModuleToolchain.ToolchainError.resourceTargetIsModule(let name, _) = error else {
 return XCTFail("应为 resourceTargetIsModule（R7 根检），实际：\(error)")
 }
 XCTAssertEqual(name, "demo")
 }
 }

 /// **Def-7 · 锁文件 `tap` / `source` 回读**：此前 `parseSummary` 丢弃这两个字段（只写不读），
 /// 故 `verify` 报错时无法回显来源——篡改发生时不知道该去哪里核对。
 func testSummaryRoundTripsTapSourceAndVerifyEchoesOrigin() throws {
 let base = NSTemporaryDirectory() + "pini_b7_src_\(UUID().uuidString)"
 defer { try? FileManager.default.removeItem(atPath: base) }
 try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0", "1.2.0"])
 let app = base + "/app"
 try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
 try "[package]\nname = \"app\"\n\n[tap]\nlocal = \"git:\(base)/remote/<name>\"\n\n[require.local]\ndemo = \">=1.2\"\n"
 .write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
 let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
 toolchainVersion: "pini 0.51.0 (spec 0.1)")

 let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
 XCTAssertEqual(mod.tap, "local", "tap 应可回读")
 XCTAssertEqual(mod.source, base + "/remote/demo",
 "source 应可回读，且 <name> 占位符已替换为模块名")

 let target = app + "/deps/demo/pini.toml"
 let text = try String(contentsOfFile: target, encoding: .utf8)
 try (text + "\n# tampered\n").write(toFile: target, atomically: true, encoding: .utf8)
  let bad = try ModuleToolchain.verify(rootDir: app)
  XCTAssertFalse(bad.isOK)
  XCTAssertTrue(bad.mismatches.contains { $0.contains("来源 \(base)/remote/demo") },
  "verify 报错应回显来源，实际：\(bad.mismatches)")
 }

 // MARK: - Def-6：`[replace]` 三种形态（G52 D13）

 /// 三形态归类（批 7 前只有 `file:` 生效，另两种静默落空）。
 func testParseReplaceClassifiesThreeForms() {
  func rep(_ raw: String) -> ModuleToolchain.Replacement {
   ModuleToolchain.parseReplace(raw, name: "demo")
  }
  XCTAssertEqual(rep("1.2.0"), .version("1.2.0"), "裸版本 = 版本覆盖（来源不变）")
  XCTAssertEqual(rep("^1.2"), .version("^1.2"), "约束写法同样只换版本")
  XCTAssertEqual(rep("v2.0.0"), .version("2.0.0"),
           "v 前缀必须剥掉：否则 versionComponents(\"v2.0.0\") 只剩 [0]（见 §9 Def-9）")
  XCTAssertEqual(rep("file:../dev"), .local("../dev"))
  XCTAssertEqual(rep("file:/abs/<name>"), .local("/abs/demo"), "<name> 占位符替换为模块名")
  XCTAssertEqual(rep("github:me/fork@v1.0"), .fork(spec: "github:me/fork", pin: "1.0"))
  XCTAssertEqual(rep("git:/srv/r.git"), .fork(spec: "git:/srv/r.git", pin: nil))
  XCTAssertEqual(rep("git:https://u@host/r.git"), .fork(spec: "git:https://u@host/r.git", pin: nil),
           "userinfo 里的 @ 不是版本分隔符")
  XCTAssertEqual(rep("git:https://u@host/r.git@2.0"),
           .fork(spec: "git:https://u@host/r.git", pin: "2.0"))
 }

 /// **版本覆盖**：`replace demo = "1.2.0"` 只抬下界、来源不变。
 ///
 /// 判据是「无 replace 时选中什么」——经典 MVS 取满足全部约束的**最低**版本，
 /// 故 `^1.0` 单独会选中 1.0.0；`<replace>` 这条约束把下界抬到 1.2.0 后选中 1.2.0。
 func testReplaceVersionOverrideRaisesSelection() throws {
  let base = NSTemporaryDirectory() + "pini_b7_repv_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  try makeGitRepo(at: base + "/remote/demo", moduleName: "demo",
            versions: ["1.0.0", "1.2.0", "2.0.0"])
  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(base)/remote/<name>"

[require.local]
demo = "^1.0"

[replace]
demo = "1.2.0"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest, toolchainVersion: "t")
  let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
  XCTAssertEqual(mod.version, "1.2.0", "版本覆盖把下界抬到 1.2.0（无 replace 时 ^1.0 选中 1.0.0）")
  XCTAssertEqual(mod.tap, "local", "只换版本 ⇒ 来源不变，tap 仍是声明它的 tap")
  XCTAssertEqual(mod.source, base + "/remote/demo")
  XCTAssertTrue(try ModuleToolchain.verify(rootDir: app).isOK)
 }

 /// **版本覆盖到不存在的版本**：须报不可满足并带上被覆盖的版本串——
 /// 否则「replace 被静默忽略」与「replace 生效但无解」无法区分。
 func testReplaceVersionOverrideConflictSurfacesReplaceConstraint() throws {
  let base = NSTemporaryDirectory() + "pini_b7_repc_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0", "1.2.0"])
  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(base)/remote/<name>"

[require.local]
demo = "^1.0"

[replace]
demo = "3.0.0"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  XCTAssertThrowsError(try ModuleToolchain.refresh(rootDir: app, manifest: manifest,
                         toolchainVersion: "t")) { error in
   guard case ModuleToolchain.ToolchainError.unsatisfiable(let name, _, let conflicts) = error else {
    return XCTFail("应为 unsatisfiable，实际：\(error)")
   }
   XCTAssertEqual(name, "demo")
   XCTAssertTrue(conflicts.contains { $0.contains("3.0.0") },
           "报错须带上 [replace] 指定的版本，实际：\(conflicts)")
  }
 }

 /// **fork 替换**：换来源；锁文件 `tap` 记 `replace`（来源由 [replace] 声明，不是任何 tap）。
 func testReplaceForkRedirectsSourceAndRecordsReplaceTap() throws {
  let base = NSTemporaryDirectory() + "pini_b7_repf_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0"])
  try makeGitRepo(at: base + "/fork/demo", moduleName: "demo", versions: ["1.5.0"])
  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(base)/remote/<name>"

[require.local]
demo = "*"

[replace]
demo = "git:\(base)/fork/demo"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest, toolchainVersion: "t")
  let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
  XCTAssertEqual(mod.version, "1.5.0", "upstream 只有 1.0.0，取到 1.5.0 说明内容来自 fork")
  XCTAssertEqual(mod.source, base + "/fork/demo")
  XCTAssertEqual(mod.tap, "replace",
           "来源由 [replace] 声明，写回原 tap 名会让锁文件自相矛盾（tap=local 而 source 不是 local）")
  XCTAssertTrue(try ModuleToolchain.verify(rootDir: app).isOK)
 }

 /// **fork 的 `@版本`**：并入 MVS 当下界（不绕过 MVS 精确钉）。
 func testReplaceForkPinParticipatesInMVS() throws {
  let base = NSTemporaryDirectory() + "pini_b7_repp_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0"])
  try makeGitRepo(at: base + "/fork/demo", moduleName: "demo",
            versions: ["1.0.0", "1.5.0", "2.0.0"])
  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(base)/remote/<name>"

[require.local]
demo = "*"

[replace]
demo = "git:\(base)/fork/demo@v1.5"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest, toolchainVersion: "t")
  let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
  XCTAssertEqual(mod.version, "1.5.0", "@v1.5 把下界抬到 1.5（单独 * 会回填到最新的 2.0.0）")
 }

 /// **本地形态不触发抓取**（批 7 引入的回归，见 §9 Def-10）。
 ///
 /// tap 是远程 git，但落地目录被 `[replace]` 换成了本地目录。抓取若只看 tap 的 spec，
 /// 就会往用户的本地目录里 `fetch` + `checkout`——本地目录通常自带 `.git`，
 /// `materialize` 恰会判定「已存在检出」而照做，直接改动开发工作区。
 func testReplaceFileFormDoesNotFetchIntoLocalDirectory() throws {
  let base = NSTemporaryDirectory() + "pini_b7_repl_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  try makeGitRepo(at: base + "/remote/demo", moduleName: "demo", versions: ["1.0.0", "2.0.0"])
  // 本地替换目录 = upstream 的克隆 + 一个**未打 tag** 的本地提交（模拟开发中的工作区）
  try TapFetcher.runGit(["clone", "--quiet", base + "/remote/demo", base + "/dev/demo"])
  for (k, v) in ["user.email": "dev@pini.local", "user.name": "Pini Dev"] {
   try TapFetcher.runGit(["-C", base + "/dev/demo", "config", k, v])
  }
  try "[package]\nname = \"demo\"\nversion = \"3.0.0-local\"\n"
   .write(toFile: base + "/dev/demo/pini.toml", atomically: true, encoding: .utf8)
  try TapFetcher.runGit(["-C", base + "/dev/demo", "add", "-A"])
  try TapFetcher.runGit(["-C", base + "/dev/demo", "commit", "-qm", "wip"])
  let beforeHEAD = try TapFetcher.headCommit(base + "/dev/demo")

  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(base)/remote/<name>"

[require.local]
demo = "*"

[replace]
demo = "file:\(base)/dev/demo"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest, toolchainVersion: "t")
  let mod = try XCTUnwrap(ModuleToolchain.parseSummary(summary).modules.first)
  XCTAssertEqual(mod.version, "3.0.0-local", "内容取自本地替换目录（未打 tag 的 HEAD）")
  XCTAssertEqual(mod.source, "file:\(base)/dev/demo", "锁文件须如实记录内容来自本地")
  XCTAssertEqual(mod.commit, "-", "本地替换无来源定位符（G52 D12）")
  XCTAssertEqual(try TapFetcher.headCommit(base + "/dev/demo"), beforeHEAD,
           "本地替换目录不得被 fetch / checkout——否则用户的开发工作区被静默改动")
 }

 /// **D13 作用域**：依赖清单里的 `[replace]` 一律忽略——否则一个依赖就能劫持整个构建。
 func testDependencyReplaceIsIgnored() throws {
  let base = NSTemporaryDirectory() + "pini_b7_reps_\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: base) }
  let remote = base + "/remote/<name>"
  // a 想把 b 劫持到自己的 fork（evil）
  try makeGitRepo(at: base + "/remote/a", moduleName: "a", versions: ["1.0.0"], manifestExtra: """

[tap]
default = "git:\(remote)"

[require]
b = "*"

[replace]
b = "git:\(base)/evil/<name>"
""")
  try makeGitRepo(at: base + "/remote/b", moduleName: "b", versions: ["1.0.0"])
  try makeGitRepo(at: base + "/evil/b", moduleName: "b", versions: ["9.9.9"])

  let app = base + "/app"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try """
[package]
name = "app"

[tap]
local = "git:\(remote)"

[require.local]
a = "*"
b = "*"
""".write(toFile: app + "/pini.toml", atomically: true, encoding: .utf8)

  let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: app))
  let summary = try ModuleToolchain.refresh(rootDir: app, manifest: manifest, toolchainVersion: "t")
  let mods = Dictionary(uniqueKeysWithValues:
   ModuleToolchain.parseSummary(summary).modules.map { ($0.name, $0) })
  XCTAssertEqual(mods["b"]?.version, "1.0.0", "依赖的 [replace] 不得生效（evil fork 是 9.9.9）")
  XCTAssertEqual(mods["b"]?.source, base + "/remote/b", "b 仍来自 tap 声明的 upstream")
  // tap 字段取「最后遍历到的 requirer 边」——多 requirer 时本就无确定规则（§9 Def-12）。
  // 这里唯一确定的信号是：它**不是** `replace`（依赖的 [replace] 一旦生效就会记成 replace）。
  XCTAssertNotEqual(mods["b"]?.tap, "replace",
           "tap=replace 意味着依赖的 [replace] 生效了（D13 明令禁止）")
 }
}
