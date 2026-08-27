import Foundation

/// T1/T11（2026-08-24）：TOML 语言资源驱动的诊断消息。
///
/// - 资源：`Resources/Diagnostics.{zh,en}.toml`（`[错误码] message = "模板" [suggestion = "模板"]`），
/// 经 SwiftPM `Bundle.module` 加载（见 Package.swift `resources: [.process("Resources")]`）。
/// - 模板占位：`{param}`，param = 错误 case 关联值的 label（如 `name`/`expected`/`got`）。
/// - 回退：目标语言未覆盖某码 → 回退 zh；zh 亦未覆盖 → 调用方硬编码兜底。
/// - 约定：错误码表 append-only，**本 TOML（en/zh）为权威映射**；新增错误码只须登记
/// TOML，诊断码文档为派生的迟维护视图（可落后，不纳入门禁）。

public enum DiagnosticLanguage: String {
 case zh
 case en
}

public final class DiagnosticResources {

 public static let shared = DiagnosticResources()

 public struct MessageEntry {
 public let message: String
 public let suggestion: String?
 }

 private var language: DiagnosticLanguage = .en
 private var tables: [DiagnosticLanguage: [String: MessageEntry]] = [:]

 private init() {
 load(.zh)
 load(.en)
 }

 /// 切换诊断语言（`--lang` CLI 参数入口）。未覆盖的码自动回退 zh。
 public func setLanguage(_ lang: DiagnosticLanguage) {
 language = lang
 }

 public var currentLanguage: DiagnosticLanguage { language }

 /// 解析生效语言：显式 language 优先，缺省回退全局当前语言（CLI --lang）。
 public func resolveLanguage(_ lang: DiagnosticLanguage?) -> DiagnosticLanguage {
 lang ?? language
 }

 /// 取消息：目标语言 → zh → 兜底 fallback（硬编码）。`language` 缺省用全局当前语言。
 public func message(code: String, args: [String: String], language: DiagnosticLanguage? = nil, fallback: String) -> String {
 guard let tpl = entry(code: code, language: resolveLanguage(language))?.message else { return fallback }
 return fill(tpl, args: args)
 }

 /// 取建议模板（无则 nil；B1 did-you-mean 接入后可动态传入）。占位未满足（残留 `{...}`）时丢弃。
 public func suggestion(code: String, args: [String: String], language: DiagnosticLanguage? = nil) -> String? {
 guard let tpl = entry(code: code, language: resolveLanguage(language))?.suggestion else { return nil }
 let filled = fill(tpl, args: args)
 guard !filled.contains("{") else { return nil }
 return filled
 }

 /// 错误类型标签（`language` 缺省用全局当前语言；fallback 为硬编码兜底）。
 public func label(key: String, language: DiagnosticLanguage? = nil, fallback: String) -> String {
 let lang = resolveLanguage(language)
 let value = tables[lang]?[key]?.message ?? tables[.zh]?[key]?.message
 return value ?? fallback
 }

 // MARK: - 内部

 private func entry(code: String, language: DiagnosticLanguage) -> MessageEntry? {
 tables[language]?[code] ?? tables[.zh]?[code]
 }

 private func load(_ lang: DiagnosticLanguage) {
 let base = lang == .zh ? "Diagnostics.zh" : "Diagnostics.en"
 guard let url = Bundle.module.url(forResource: base, withExtension: "toml") else { return }
 guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
 tables[lang] = parse(text)
 }

 /// 轻量 TOML 解析（子集）：`[段]` + `key = "value"`（`#` 注释行跳过）。
 /// 仅覆盖诊断资源所需文法；完整 TOML 属 P6+ 依赖加载范畴（现有 `parseManifest` 同款取舍）。
 private func parse(_ text: String) -> [String: MessageEntry] {
 var result: [String: MessageEntry] = [:]
 var current: String?
 var message: String?
 var suggestion: String?
 var isLabels = false

 func flush() {
 if let code = current, let msg = message {
 result[code] = MessageEntry(message: msg, suggestion: suggestion)
 }
 current = nil
 message = nil
 suggestion = nil
 isLabels = false
 }

 for rawLine in text.split(separator: "\n") {
 let line = rawLine.trimmingCharacters(in: .whitespaces)
 if line.isEmpty || line.hasPrefix("#") { continue }
 if line.hasPrefix("[") && line.hasSuffix("]") {
 flush()
 current = String(line.dropFirst().dropLast())
 isLabels = current == "labels"
 } else if let eq = line.firstIndex(of: "=") {
 let key = line[..<eq].trimmingCharacters(in: .whitespaces)
 let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
 let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
 if isLabels {
 // [labels] 段：label 名 → 文案（typeLabel 查表用）。
 result[key] = MessageEntry(message: value, suggestion: nil)
 } else {
 switch key {
 case "message": message = value
 case "suggestion": suggestion = value
 default: break
 }
 }
 }
 }
 flush()
 return result
 }

 private func fill(_ template: String, args: [String: String]) -> String {
 var out = template
 for (key, value) in args {
 out = out.replacingOccurrences(of: "{\(key)}", with: value)
 }
 return out
 }
}
