import Foundation

/// 源码映射：根据文件名 + 行号返回源码文本行，供调试器在断点处展示上下文。
public struct SourceMap {
 private let fileLines: [String: [String]]

 public init(sources: [String: String]) {
 var m: [String: [String]] = [:]
 for (name, text) in sources {
 m[name] = text.components(separatedBy: "\n")
 }
 self.fileLines = m
 }

 public init(source: String, fileName: String) {
 self.init(sources: [fileName: source])
 }

 /// 返回指定文件指定行（1-based）的源码文本；越界或未知文件返回 nil。
 public func line(_ fileName: String, _ line: Int) -> String? {
 guard let lines = fileLines[fileName], line >= 1, line <= lines.count else { return nil }
 return lines[line - 1]
 }

 public func lineCount(_ fileName: String) -> Int {
 return fileLines[fileName]?.count ?? 0
 }
}
