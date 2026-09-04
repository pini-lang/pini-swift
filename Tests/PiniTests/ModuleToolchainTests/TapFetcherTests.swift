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

 /// 建一个真实 git 仓库作远端：tag v1.0.0 / v1.2.0 / v2.0.0，外加一个**非版本** tag。
 private func makeGitTapFixture() throws -> (base: String, source: TapFetcher.Source,
 cleanup: () -> Void) {
 let base = NSTemporaryDirectory() + "pini_b7_\(UUID().uuidString)"
 let src = base + "/src"
 try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
 func git(_ args: [String]) throws { _ = try TapFetcher.runGit(args) }
 // `-C` 形式便于把每个 tag 的版本写进清单，模拟真实依赖仓库。
 try git(["init", "-q", src])
 try git(["-C", src, "config", "user.email", "tap@pini.local"])
 try git(["-C", src, "config", "user.name", "Pini Tap Fixture"])
 try git(["-C", src, "config", "commit.gpgsign", "false"])

 for v in ["1.0.0", "1.2.0", "2.0.0"] {
 try "[package]\nname = \"demo\"\nversion = \"\(v)\"\n"
 .write(toFile: src + "/pini.toml", atomically: true, encoding: .utf8)
 try git(["-C", src, "add", "-A"])
 try git(["-C", src, "commit", "-qm", "v\(v)"])
 try git(["-C", src, "tag", "v\(v)"])
 }
 // 非版本 tag：无法参与 MVS 比较，必须从候选里剔除
 try git(["-C", src, "tag", "nightly"])

 let source = try TapFetcher.expand(spec: "git:" + src, name: "demo")
 return (base, source, { try? FileManager.default.removeItem(atPath: base) })
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
}
