import Foundation

/// 单个源文件编译单元（P4 多文件模型基础）。
///
/// 携带源文件**路径**（`fileName`），作为后续阶段按「文件名 / 目录名 `_` 前缀」
/// 计算可见性级别（`private` / `internal` / `package` / `public`）的物理锚点。
/// 当前阶段仅承载解析结果，跨文件解析与可见性 enforce 在 P4 后续阶段落地。
public struct FileUnit: Equatable, ASTNode {
 /// 源文件绝对/相对路径；可见性判定的物理锚点（与 `SourceLocation.fileName` 同源）。
 public let fileName: String
 /// 该文件经 `Parser.parseModule` 解析出的单文件 `Module`。
 public let module: Module

 public var location: SourceLocation { module.location }

 public init(fileName: String, module: Module) {
 self.fileName = fileName
 self.module = module
 }
}

/// 包（编译单元集合）——P4 之前 Pini 为纯单文件世界，
/// `Package` 以**向后兼容**的方式包裹一个或多个 `FileUnit`：
/// - 单文件模式：`Package.singleFile(...)` 包裹 1 个 `FileUnit`，等价于旧 `Module` 世界；
/// - 目录 / 模块模式：`Package(name:fileUnits:)` 聚合多文件，供后续阶段做跨文件
/// 符号解析与可见性 enforce。
///
/// 设计约束（用户指令）：本类型**仅做聚合与路径归属**，不在本阶段改变
/// `Module` 消费管线（`SemanticAnalyzer` / `TypeChecker` / `Interpreter` 仍吃 `Module`）。
public struct Package: Equatable, ASTNode {
 /// 模块名：来自 `module.toml`，或在无清单时由目录名推导（隐式根模块兜底）。
 public let name: String
 /// 包内所有源文件单元（递归扫描所得，含嵌套 `_` 目录以支持后续包级可见性）。
 public let fileUnits: [FileUnit]

 public var location: SourceLocation {
 fileUnits.first?.location ?? SourceLocation(line: 0, column: 0, fileName: name)
 }

 public init(name: String, fileUnits: [FileUnit]) {
 self.name = name
 self.fileUnits = fileUnits
 }

 /// 向后兼容：单文件世界等价于一个只含 1 个 `FileUnit` 的包。
 public static func singleFile(name: String, fileName: String, module: Module) -> Package {
 return Package(name: name,
 fileUnits: [FileUnit(fileName: fileName, module: module)])
 }
}
