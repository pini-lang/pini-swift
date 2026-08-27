import Foundation

/// 跳转定义提供器：根据标识符查找定义位置。
public struct DefinitionProvider {

 /// 查找标识符的定义位置
 /// - Parameters:
 /// - name: 要查找的标识符名
 /// - scope: 当前位置的作用域（用于本地查找）
 /// - index: 包级符号索引（用于跨文件查找）
 /// - uri: 当前文档 URI
 /// - Returns: 定义位置，未找到返回 nil
 public func findDefinition(
 name: String,
 scope: Scope?,
 index: PackageSymbolIndex?,
 currentURI: String
 ) -> Location? {
 // 1. 本地作用域查找
 if let scope = scope, let sym = scope.resolve(name) {
 return makeLocation(from: sym, uri: currentURI)
 }

 // 2. 包级索引查找
 if let index = index, let pkgSym = index.lookup(name) {
 let uri = fileURL(for: pkgSym.fileName)
 return Location(uri: uri, range: makeRange(pkgSym.location))
 }

 return nil
 }

 private func makeLocation(from sym: Symbol, uri: String) -> Location {
 let loc = sym.location
 let range = makeRange(loc)
 // 如果符号定义在当前文件中且文件路径匹配，用传入的 uri
 // 否则构造 file:// URI
 let resultURI: String
 if loc.fileName == "<builtin>" {
 resultURI = uri // 内建符号显示在当前文件
 } else if uri.hasSuffix(loc.fileName) || fileURL(for: loc.fileName) == uri {
 resultURI = uri
 } else {
 resultURI = fileURL(for: loc.fileName)
 }
 return Location(uri: resultURI, range: range)
 }

 private func makeRange(_ loc: SourceLocation) -> LSPRange {
 let line = max(0, loc.line - 1)
 let col = max(0, loc.column - 1)
 let pos = Position(line: line, character: col)
 return LSPRange(start: pos, end: Position(line: line, character: col + 1))
 }

 private func fileURL(for path: String) -> String {
 return "file://\(path)"
 }
}
