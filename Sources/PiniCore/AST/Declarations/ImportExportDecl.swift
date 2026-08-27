import Foundation

/// `import` 声明（P4 模块化）：引入一个外部模块的公开 API。
///
/// 语法：`import <模块名>`。Phase 2 仅解析并暂存原始模块名，**不解析、不 enforce**；
/// 真正的跨模块符号解析在 Phase 4（解释器模块加载）落地。
public struct ImportDecl: Equatable, ASTNode {
 /// 被引入的模块名（暂为单标识符；后续可扩展为点分路径）。
 public let moduleName: String
 public let location: SourceLocation

 public init(moduleName: String, location: SourceLocation) {
 self.moduleName = moduleName
 self.location = location
 }
}

/// `export` 声明（P4 模块化）：按符号覆盖默认可见性的逃生舱。
///
/// 语法：`export <符号名>`。在约定制 4 级模型下，绝大部分符号按文件 / 目录 `_` 前缀
/// 自动判定可见性；`export` 用于把本应更窄（如位于 `_` 文件）的符号显式提升为对外导出。
/// Phase 2 仅解析并暂存原始符号名，**不 enforce**；语义作用在 P4 后续阶段落地。
public struct ExportDecl: Equatable, ASTNode {
 /// 被显式导出的符号名。
 public let symbolName: String
 public let location: SourceLocation

 public init(symbolName: String, location: SourceLocation) {
 self.symbolName = symbolName
 self.location = location
 }
}
