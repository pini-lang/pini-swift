import Foundation

/// 语言级配置：集中管理此前散落在源码各处的魔法值（如源文件后缀），避免硬编码。
///
/// 资源：`Resources/LangConfig.toml`，经 SwiftPM `Bundle.module` 加载
/// （见 `Package.swift` 的 `resources: [.process("Resources")]`）。
/// 资源缺失或解析失败时回退到内建默认值，保证 CLI 不依赖资源文件一定存在。
public enum LangConfig {
 /// 源文件后缀（不含前导点），如 `bk` ⇒ 识别 `.pini` 文件。
 /// 后续如需切换源文件后缀，仅改 `LangConfig.toml` 一处即可，无需改动加载器 / CLI。
 public static let sourceExtension: String = {
 guard let url = Bundle.module.url(forResource: "LangConfig", withExtension: "toml"),
 let text = try? String(contentsOf: url, encoding: .utf8) else {
 return "pini"
 }
 for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
 let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !line.isEmpty, !line.hasPrefix("#") else { continue }
 guard let eq = line.firstIndex(of: "=") else { continue }
 let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
 let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
 .stripQuotes()
 if key == "source_extension", !value.isEmpty { return value }
 }
 return "pini"
 }()

 /// 源文件匹配后缀（含前导点），如 `.pini`。
 public static var sourceSuffix: String { ".\(sourceExtension)" }
}
