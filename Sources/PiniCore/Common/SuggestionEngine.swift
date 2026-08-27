import Foundation

/// T1/B1（2026-08-24）：did-you-mean 建议引擎。
///
/// 架构决策（渲染层方案）：建议在 `ErrorFormatter` 渲染 undefined*（E3-001/002/003）时计算，
/// 输入 = 源码文本 + 未定义名 → 输出最近标识符（编辑距离 ≤ 2），不侵入语义层/错误构造点。
/// 候选集为全文件标识符（跨作用域），属启发式；用距离阈值 + 排除完全相等控制误报。
/// 已知限制：多文件 check 的 source 为空时不出建议（后续可改为文件 ID + 调用方提供源码）。
public enum SuggestionEngine {

 /// Levenshtein 编辑距离（字符级，按 `Character` 计——中文标识符同样适用）。
 public static func levenshtein(_ a: String, _ b: String) -> Int {
 let aChars = Array(a)
 let bChars = Array(b)
 var dp = [[Int]](repeating: [Int](repeating: 0, count: bChars.count + 1), count: aChars.count + 1)
 for i in 0...aChars.count { dp[i][0] = i }
 for j in 0...bChars.count { dp[0][j] = j }
 for i in 1...aChars.count {
 for j in 1...bChars.count {
 let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
 dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
 }
 }
 return dp[aChars.count][bChars.count]
 }

 /// 建议：候选集中与 target 编辑距离 ≤ maxDistance 的**最短**者；排除完全相等；并列取首个；无则 nil。
 public static func suggest(target: String, candidates: [String], maxDistance: Int = 2) -> String? {
 var best: (candidate: String, distance: Int)?
 for candidate in candidates where candidate != target {
 let distance = levenshtein(target, candidate)
 if distance <= maxDistance {
 if best == nil || distance < best!.distance {
 best = (candidate, distance)
 }
 }
 }
 return best?.candidate
 }

 /// 从源码提取标识符（**词法 token 级**：复用 Lexer，天然排除字符串/注释/文档注释内容）。
 /// 词法错误时容错返回空（建议是启发式，不因词法异常阻断诊断渲染）。
 public static func identifiers(in source: String, fileName: String = "suggestion") -> [String] {
 guard let tokens = try? Lexer(source: source, fileName: fileName).tokenize() else { return [] }
 var seen = Set<String>()
 var result: [String] = []
 for token in tokens {
 if case .identifier(let name, _) = token, seen.insert(name).inserted {
 result.append(name)
 }
 }
 return result
 }
}
