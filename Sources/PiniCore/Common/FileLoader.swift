import Foundation

/// P4 文件 / 目录加载器：将磁盘上的源文件（后缀见 `LangConfig.sourceSuffix`）解析为 `Package`。
///
/// 本阶段（Phase 1）仅负责「读取 + 词法/语法解析 + 聚合」，
/// **不处理**跨文件符号解析 / 可见性 enforce / `pini.toml` 语义化
/// （那些在 P4 后续阶段，由 `SemanticAnalyzer` / `TypeChecker` / `Interpreter`
/// 消费 `Package` 时落地）。CLI 行为本阶段保持不变（仍单文件）。
public struct FileLoader {

 /// 解析单个文件为 `Package`（单文件模式，向后兼容）。
 /// - 模块名：目录名兜底（后续阶段优先取 `pini.toml` 的 `name`）。
 public static func loadFile(path: String) throws -> Package {
 let source = try String(contentsOfFile: path, encoding: .utf8)
 let unit = try parseUnit(fileName: path, source: source)
 let dirName = (path as NSString).deletingLastPathComponent
 let name = dirName.components(separatedBy: "/").last ?? "main"
 return Package(name: name, fileUnits: [unit])
 }

 /// 解析目录为 `Package`（目录模式，递归扫描 `LangConfig.sourceSuffix` 源文件）。
 /// - 模块名：优先取目录内 `pini.toml` 的 `[package] name`；无清单时取目录名（隐式根模块兜底）。
 /// - Phase 5：CLI 收目录时通过 `manifest` 激活多文件「模块」语义；无清单的目录在 CLI 层被视为
 /// 一组**独立程序**（见 `main.swift`），此处仅负责物理聚合。
 public static func loadDirectory(path: String, manifest: ModuleManifest? = nil) throws -> Package {
 let fm = FileManager.default
 guard let enumerator = fm.enumerator(atPath: path) else {
 throw LoaderError.cannotReadDirectory(path: path)
 }
 // G49（issue-tdd-module-blockers-2026-08-28）：`[build] exclude` 显式排除——
 // 被排除路径（目录前缀或全路径）从模块包加载中剔除，run/check/build/test 全目标统一生效。
 let excludeEntries = (manifest?.buildExclude ?? []).map { (entry: String) -> String in
 let trimmed = entry.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
 return trimmed.isEmpty ? entry : trimmed
 }
 var units: [FileUnit] = []
 for case let rel as String in enumerator {
 guard rel.hasSuffix(LangConfig.sourceSuffix), !rel.contains("__MACOSX") else { continue }
 if excludeEntries.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
 let full = (path as NSString).appendingPathComponent(rel)
 let source = try String(contentsOfFile: full, encoding: .utf8)
 units.append(try parseUnit(fileName: full, source: source))
 }
 // 显式排序，使跨文件注册 / 检查顺序确定（避免 enumerator 顺序不确定导致的偶发行为）。
 units.sort { $0.fileName < $1.fileName }
 let name = manifest?.name ?? (path as NSString).lastPathComponent
 return Package(name: name, fileUnits: units)
 }

 /// R8（issue-pini-dir-namespace-2026-08-29）：模块清单文件名。
 /// R1 以「目录内是否存在此文件」作**哨兵**判定模块边界，故文件名必须语言级特异——
 /// 旧名 `module.toml` 是通名，外来工程（非 Pini 项目）携带同名文件会导致误判。
 public static let manifestFileName = "pini.toml"
 /// R8：G52 之前的旧名。命中一律**报错**而非静默忽略——旧名若被当作「无清单」，
 /// 该目录会从「模块边界」退化为「普通文件」，其下源码被父模块扫入且**全程不报错**，
 /// 症状（"这目录的文件怎么被扫进去了"）离原因很远。
 public static let legacyManifestFileName = "module.toml"

 /// 在目录中寻找并解析 `pini.toml`；不存在则返回 `nil`（隐式根模块兜底）。
 /// Phase 5 起为 CLI / 加载器识别「这是一个显式多文件模块」的唯一信号。
 public static func loadManifest(directory: String) throws -> ModuleManifest? {
 let tomlPath = (directory as NSString).appendingPathComponent(manifestFileName)
 let legacyPath = (directory as NSString).appendingPathComponent(legacyManifestFileName)
 if !FileManager.default.fileExists(atPath: tomlPath) {
 if FileManager.default.fileExists(atPath: legacyPath) {
 throw LoaderError.legacyManifestName(path: legacyPath)
 }
 return nil
 }
 let text = try String(contentsOfFile: tomlPath, encoding: .utf8)
 let manifest = try parseManifest(text, path: tomlPath)
 // Phase 2b（ADR-017）：将 `[ffi].search_paths` 的非绝对项规一为「相对本模块目录」
 // 的绝对路径，使 FFI 搜索与调用 cwd 解耦（示例可在任意检出位置独立运行）。
 // 绝对路径（如系统库 /usr/lib）原样保留；无 `[ffi]` 表时此步为空操作。
 guard var ffi = manifest.ffi, !ffi.searchPaths.isEmpty else { return manifest }
 let resolved = ffi.searchPaths.map { (sp: String) -> String in
 (sp as NSString).isAbsolutePath
 ? sp
 : (directory as NSString).appendingPathComponent(sp)
 }
 let normalized = FFIConfig(abi: ffi.abi, searchPaths: resolved, libs: ffi.libs)
 return ModuleManifest(name: manifest.name, version: manifest.version,
 dependencies: manifest.dependencies, ffi: normalized,
 buildExclude: manifest.buildExclude)
 }

 /// G49（issue-tdd-module-blockers-2026-08-28）：自 `path`（文件或目录）向上定位所属模块根
 /// （逐级寻找含合法 `pini.toml` 的目录）；抵达文件系统根仍未见则返回 `nil`
 /// （独立文件 / 目录语义）。清单非法（`invalidManifest`）向上抛出——坏清单不应被
 /// 静默当作「无模块」。
 public static func locateModuleRoot(for path: String) throws -> String? {
 var isDir: ObjCBool = false
 let start =
 (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
 ? path
 : (path as NSString).deletingLastPathComponent
 var dir = URL(fileURLWithPath: start).standardized.path
 while true {
 if try loadManifest(directory: dir) != nil { return dir }
 let parent = (dir as NSString).deletingLastPathComponent
 if parent == dir { return nil }
 dir = parent
 }
 }

 // MARK: - 内部

 private static func parseUnit(fileName: String, source: String) throws -> FileUnit {
 let lexer = Lexer(source: source, fileName: fileName)
 let tokens = try lexer.tokenize()
 let parser = Parser(tokens: tokens, fileName: fileName)
 let result = parser.parseModuleCollectingErrors()
 if !result.errors.isEmpty {
 // 聚合该文件的所有解析错误一次性抛出（而非只抛首个），避免错误被吞。
 if result.errors.count == 1 {
 throw result.errors.first!
 }
 throw LoaderError.parseErrors(file: fileName, errors: result.errors)
 }
 return FileUnit(fileName: fileName, module: result.module)
 }
}

/// FFI 模块配置（`pini.toml` 的 `[ffi]` 表，ADR-017 Phase 2b）。
///
/// - `abi`：全局唯一，默认 `"C"`，子模块**不可覆盖**（与模块级 ABI 决策一致）。
/// - `searchPaths`：库搜索路径，**分层追加**（子模块追加到父模块之后）。
/// - `libs`：需链接的库列表，**全局统一链接**（LLVM 阶段拼接 `-L`/`-l`）。
public struct FFIConfig: Equatable {
 public let abi: String
 public let searchPaths: [String]
 public let libs: [String]

 public init(abi: String = "C", searchPaths: [String] = [], libs: [String] = []) {
 self.abi = abi
 self.searchPaths = searchPaths
 self.libs = libs
 }

 /// 系统默认搜索路径（libc 等系统库无需显式 `[ffi].search_paths`）。
 public static let `default` = FFIConfig(
 abi: "C",
 searchPaths: ["/usr/lib", "/usr/local/lib", "/opt/homebrew/lib"],
 libs: []
 )

 /// 子模块 `[ffi]` 追加到父模块之后（分层追加语义）；`abi` 以父（根）为准、不可覆盖。
 public func merging(submodule other: FFIConfig) -> FFIConfig {
 FFIConfig(abi: self.abi, searchPaths: self.searchPaths + other.searchPaths, libs: self.libs + other.libs)
 }
}

/// 模块清单（`pini.toml`）。
///
/// Phase 5 解析 `[package] name`（必需，覆盖目录名作为模块身份）与 `version`、
/// `[dependencies]`（记录但**不解析**——跨模块依赖加载属 P6+ 范畴，本阶段仅占位）。
/// 依赖解析的硬约束（package 锚定 pini.toml 身份、非目录名）见 spec 。
public struct ModuleManifest: Equatable {
 public let name: String
 public let version: String?
 public let dependencies: [String: String]
 /// Phase 2b（ADR-017）：`[ffi]` FFI 配置；无 `[ffi]` 表时为 `nil`（解释器回退 `FFIConfig.default`）。
 public let ffi: FFIConfig?
 /// G49（issue-tdd-module-blockers-2026-08-28）：`[build] exclude`——模块包加载排除路径
 /// （相对模块根；目录前缀匹配；`loadDirectory` 统一生效，`pini test` 显式路径可加回）。
 public let buildExclude: [String]

 public init(name: String, version: String? = nil, dependencies: [String: String] = [:],
 ffi: FFIConfig? = nil, buildExclude: [String] = []) {
 self.name = name
 self.version = version
 self.dependencies = dependencies
 self.ffi = ffi
 self.buildExclude = buildExclude
 }
}

/// 加载器错误。
public enum LoaderError: Error, Equatable {
 case cannotReadDirectory(path: String)
 case invalidManifest(path: String)
 /// R8：命中旧名 `module.toml`。必须报错而非静默当作「无清单」——
 /// 否则该目录会从模块边界退化为普通文件，源码被父模块扫入。
 case legacyManifestName(path: String)
 /// 单文件解析产生的多个错误（聚合一次性抛出，避免只报首个而吞没其余）。
 case parseErrors(file: String, errors: [ParserError])
}

extension LoaderError: LocalizedError {
 public var errorDescription: String? {
 switch self {
 case .cannotReadDirectory(let path):
 return "无法读取目录：\(path)"
 case .invalidManifest(let path):
 return "非法的 pini.toml：\(path)"
 case .legacyManifestName(let path):
 return "模块清单已由 module.toml 更名为 pini.toml，请将 \(path) 重命名为 pini.toml"
 + "（旧名不会被静默忽略：否则该目录将从模块边界退化为普通文件，其下源码被父模块扫入）"
 case .parseErrors(let file, let errors):
 let details = errors.map { " - \(String(describing: $0))" }.joined(separator: "\n")
 return "解析错误（\(file)）：\n\(details)"
 }
 }
}

/// 最小 TOML 解析（覆盖 `[package]` + `[dependencies]` + `[ffi]` 的 `key = "value"` 表项；
/// 值可为字符串或内联数组 `["a", "b"]`）。
/// 设计取舍：不引入完整 TOML 文法（那是 P6+ 依赖加载才需要的复杂度）；
/// 本阶段只需可靠提取模块名、依赖占位与 FFI 配置，故采用逐行扫描 + 区段的轻量实现。
/// 行为：跳过空行与 `#` 注释；`[section]` 切换当前区段；`key = value` 按区段归类；
/// 值支持可选双引号包裹与 `["a", "b"]` 内联数组。**未知 `[section]` 与未知 `key` 容错忽略**
/// （缝 ⑦：写了尚未消费的 `[ffi]` 等表也不应导致解析失败）。
/// `[package]` 缺 `name` 视为非法清单。
private func parseManifest(_ text: String, path: String) throws -> ModuleManifest {
 var currentSection: String? = nil
 var name: String? = nil
 var version: String? = nil
 var dependencies: [String: String] = [:]
 var ffiAbi: String? = nil
 var ffiSearchPaths: [String] = []
 var ffiLibs: [String] = []
 var buildExclude: [String] = []

 for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
 var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
 if line.isEmpty || line.hasPrefix("#") { continue }

 if line.hasPrefix("["), line.hasSuffix("]") {
 currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
 continue
 }

 guard let eq = line.firstIndex(of: "=") else { continue }
 let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
 let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
 let unquoted = value.stripQuotes()

 switch currentSection {
 case "package":
 if key == "name" { name = unquoted }
 else if key == "version" { version = unquoted }
 case "dependencies":
 dependencies[key] = unquoted
 case "ffi":
 // Phase 2b（ADR-017）：[ffi] 配置。abi 单值；search_paths/libs 内联数组。
 if key == "abi" { ffiAbi = unquoted }
 else if key == "search_paths" { ffiSearchPaths = parseTOMLArray(value) }
 else if key == "libs" { ffiLibs = parseTOMLArray(value) }
 case "build":
 // G49（issue-tdd-module-blockers-2026-08-28）：[build] exclude 内联数组（相对模块根路径）。
 if key == "exclude" { buildExclude = parseTOMLArray(value) }
 default:
 break
 }
 }

 guard let n = name, !n.isEmpty else {
 throw LoaderError.invalidManifest(path: path)
 }
 let ffi: FFIConfig? = (ffiAbi != nil || !ffiSearchPaths.isEmpty || !ffiLibs.isEmpty)
 ? FFIConfig(abi: ffiAbi ?? "C", searchPaths: ffiSearchPaths, libs: ffiLibs)
 : nil
 return ModuleManifest(name: n, version: version, dependencies: dependencies, ffi: ffi,
 buildExclude: buildExclude)
}

/// 解析 TOML 内联数组字面量 `["a", "b"]` / `[ "a" ]` → 字符串数组；非数组原样返回单元素。
private func parseTOMLArray(_ value: String) -> [String] {
 let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
 guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return [trimmed.stripQuotes()] }
 let inner = trimmed.dropFirst().dropLast()
 return inner
 .split(separator: ",", omittingEmptySubsequences: true)
 .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).stripQuotes() }
 .filter { !$0.isEmpty }
}

extension String {
 /// 去除字符串首尾的双引号（用于解析 `key = "value"` 形式的 TOML 值）。
 func stripQuotes() -> String {
 var s = self
 if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
 s = String(s.dropFirst().dropLast())
 }
 return s
 }
}
