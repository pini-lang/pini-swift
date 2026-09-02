import XCTest
@testable import PiniCore
import Foundation

/// 批 6（G52 批 3）阶段 3：模块工具链核心——SHA-256、版本约束、MVS 求解、锁文件读写。
final class ModuleToolchainTests: XCTestCase {

 // MARK: - SHA-256（FIPS 180-4 标准测试向量）

 func testSHA256KnownVectors() {
 // 空串
 XCTAssertEqual(SHA256.hexDigest(Data()),
 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
 // "abc"（NIST 示例）
 XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)),
 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
 // 两块边界（55/56/64 字节跨越填充边界）
 XCTAssertEqual(SHA256.hexDigest(Data(repeating: UInt8(ascii: "a"), count: 55)).count, 64)
 XCTAssertEqual(SHA256.hexDigest(Data(repeating: UInt8(ascii: "a"), count: 56)).count, 64)
 XCTAssertEqual(SHA256.hexDigest(Data(repeating: UInt8(ascii: "a"), count: 64)).count, 64)
 // 百万 'a'（NIST 向量）——验证多块与长度字段的正确性
 XCTAssertEqual(SHA256.hexDigest(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
 "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
 }

 // MARK: - 版本约束（G52 §3.2 语法）

 func testConstraintParseAndSatisfies() {
 func v(_ s: String) -> [Int] { ModuleToolchain.Constraint.versionComponents(s)! }
 func sat(_ raw: String, _ ver: String) -> Bool {
 ModuleToolchain.Constraint.parse(raw)!.satisfies(v(ver))
 }

 XCTAssertTrue(sat("*", "0.0.1") && sat("*", "99.9"))
 XCTAssertTrue(sat("^1.2", "1.9.0"), "^1.2 = >=1.2 <2.0")
 XCTAssertFalse(sat("^1.2", "2.0.0"))
 XCTAssertTrue(sat("^0.2.3", "0.2.9"), "0.x 的 ^ 只到 minor 上界")
 XCTAssertFalse(sat("^0.2.3", "0.3.0"))
 XCTAssertTrue(sat("~1.2.3", "1.2.9"))
 XCTAssertFalse(sat("~1.2.3", "1.3.0"))
 XCTAssertTrue(sat("=1.2.3", "1.2.3"))
 XCTAssertFalse(sat("=1.2.3", "1.2.4"))
 XCTAssertTrue(sat(">=1.0, <2.0", "1.5.0"))
 XCTAssertFalse(sat(">=1.0, <2.0", "2.0.0"))
 XCTAssertTrue(sat("1.2", "1.2.9"), "裸版本 = 下界")
 XCTAssertNil(ModuleToolchain.Constraint.parse("abc"), "非版本串解析失败返回 nil（refresh 侧宁严勿纵）")
 }

 // MARK: - 本地夹具求解（MVS v1：每依赖一个可用版本）

 /// 构造三方夹具：app →（require）uni ^1.0 →（require）text ^1.0；app 与 uni 都 require text。
 private func makeThreeModuleFixture() throws -> (root: String, cleanup: () -> Void) {
 let base = NSTemporaryDirectory() + "pini_b6_\(UUID().uuidString)"
 let fm = FileManager.default
 func mkdir(_ p: String) throws { try fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
 try mkdir(base + "/app/deps/uni")
 try mkdir(base + "/app/deps/text")
 try mkdir(base + "/vendor")

 try """
 [package]
 name = "app"

 [tap]
 vendor = "file:../vendor/<name>"

 [require.vendor]
 uni = "^1.0"
 text = "*"
 """.write(toFile: base + "/app/pini.toml", atomically: true, encoding: .utf8)

 try """
 [package]
 name = "uni"
 version = "1.2.0"

 [tap]
 default = "file:../vendor/<name>"

 [require]
 text = "^1.0"
 """.write(toFile: base + "/app/deps/uni/pini.toml", atomically: true, encoding: .utf8)

 try """
 [package]
 name = "text"
 version = "1.0.5"
 """.write(toFile: base + "/app/deps/text/pini.toml", atomically: true, encoding: .utf8)

 return (base + "/app", { try? fm.removeItem(atPath: base) })
 }

 func testResolveLocalFixtureProducesCompleteResolution() throws {
 let (root, cleanup) = try makeThreeModuleFixture()
 defer { cleanup() }

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: root))
 let resolution = try ModuleToolchain.resolve(rootDir: root, manifest: manifest)

 // 模块集与版本
 let byName = Dictionary(uniqueKeysWithValues: resolution.modules.map { ($0.name, $0) })
 XCTAssertEqual(Set(byName.keys), ["uni", "text"])
 XCTAssertEqual(byName["uni"]?.version, "1.2.0")
 XCTAssertEqual(byName["text"]?.version, "1.0.5")

 // imported-by（D16：谁 require 了它）
 XCTAssertEqual(byName["uni"]?.importedBy, ["<root>"])
 XCTAssertEqual(Set(byName["text"]?.importedBy ?? []), ["<root>", "uni"])

 // 拓扑序：依赖在前（text 先于 uni）
 let order = resolution.graphOrder
 XCTAssertEqual(order.first, "text")
 XCTAssertEqual(order.last, "uni")

 // 校验和字段齐全且格式为 sha256:hex
 for m in resolution.modules {
 XCTAssertTrue(m.manifestSum.hasPrefix("sha256:"))
 XCTAssertTrue(m.sum.hasPrefix("sha256:"))
 XCTAssertEqual(m.manifestSum.count, "sha256:".count + 64)
 XCTAssertEqual(m.commit, "-", "file: 源的 commit 为 `-`（G52 D12）")
 }
 }

 func testResolveUnsatisfiableConstraintThrows() throws {
 let (root, cleanup) = try makeThreeModuleFixture()
 defer { cleanup() }

 // 把根约束改成 ^2.0（可用版本 1.2.0 不满足）——改写根清单后重解析。
 let manifestPath = root + "/pini.toml"
 let text = try String(contentsOfFile: manifestPath, encoding: .utf8)
 try text.replacingOccurrences(of: "^1.0", with: "^2.0")
 .write(toFile: manifestPath, atomically: true, encoding: .utf8)

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: root))
 XCTAssertThrowsError(try ModuleToolchain.resolve(rootDir: root, manifest: manifest)) { error in
 guard case ModuleToolchain.ToolchainError.unsatisfiable(let name, let available, _) = error else {
 return XCTFail("应为 unsatisfiable，实际：\(error)")
 }
 XCTAssertEqual(name, "uni")
 XCTAssertEqual(available, "1.2.0")
 }
 }

 func testResolveRemoteTapErrorsOutPerDA() throws {
 let base = NSTemporaryDirectory() + "pini_b6_\(UUID().uuidString)"
 try FileManager.default.createDirectory(atPath: base + "/app/deps/uni", withIntermediateDirectories: true)
 try """
 [package]
 name = "app"

 [tap]
 gh = "github:pini-lang"

 [require.gh]
 uni = "*"
 """.write(toFile: base + "/app/pini.toml", atomically: true, encoding: .utf8)
 try """
 [package]
 name = "uni"
 version = "1.0.0"
 """.write(toFile: base + "/app/deps/uni/pini.toml", atomically: true, encoding: .utf8)
 defer { try? FileManager.default.removeItem(atPath: base) }

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: base + "/app"))
 XCTAssertThrowsError(try ModuleToolchain.resolve(rootDir: base + "/app", manifest: manifest)) { error in
 guard case ModuleToolchain.ToolchainError.remoteTapUnsupported(let tap, _, _) = error else {
 return XCTFail("应为 remoteTapUnsupported（D-A），实际：\(error)")
 }
 XCTAssertEqual(tap, "gh")
 }
 }

 // MARK: - 锁文件（G52 §3.5）

 func testSummaryRoundTrip() throws {
 let (root, cleanup) = try makeThreeModuleFixture()
 defer { cleanup() }

 let manifest = try XCTUnwrap(FileLoader.loadManifest(directory: root))
 let resolution = try ModuleToolchain.resolve(rootDir: root, manifest: manifest)
 let rendered = ModuleToolchain.renderSummary(
 resolution: resolution, toolchainVersion: "pini 0.51.0 (spec 0.1)",
 generated: ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z")!)

 // 生成文本含 G52 §3.5 的关键结构
 XCTAssertTrue(rendered.contains("[[module]]"))
 XCTAssertTrue(rendered.contains("imported-by = ["))
 XCTAssertTrue(rendered.contains("[graph]"))

 // 回读字段一致
 let parsed = ModuleToolchain.parseSummary(rendered)
 XCTAssertEqual(parsed.toolchain, "pini 0.51.0 (spec 0.1)")
 XCTAssertEqual(parsed.modules.map(\.name), resolution.modules.map(\.name))
 XCTAssertEqual(parsed.modules.map(\.sum), resolution.modules.map(\.sum))
 XCTAssertEqual(parsed.modules.map(\.importedBy.count), resolution.modules.map(\.importedBy.count))
 XCTAssertEqual(parsed.graphOrder, resolution.graphOrder)
 }

 /// 意图：treeSum 对内容篡改敏感（D6 校验和的实际价值）——改一个字节即变。
 func testTreeSumDetectsContentChange() throws {
 let (root, cleanup) = try makeThreeModuleFixture()
 defer { cleanup() }

 let before = ModuleToolchain.treeSum(root + "/deps/text")
 let target = root + "/deps/text/pini.toml"
 let text = try String(contentsOfFile: target, encoding: .utf8)
 try (text + "\n# tampered\n").write(toFile: target, atomically: true, encoding: .utf8)
 let after = ModuleToolchain.treeSum(root + "/deps/text")

 XCTAssertNotEqual(before, after, "内容树任一文件被篡改，摘要必须改变")
 // 排除项：锁文件自身与 .git 不影响摘要
 try "x".write(toFile: root + "/deps/text/pini-summary.toml", atomically: true, encoding: .utf8)
 XCTAssertEqual(after, ModuleToolchain.treeSum(root + "/deps/text"),
 "pini-summary.toml 自身应被排除在树摘要之外")
 }
}
