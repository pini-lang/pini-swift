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
 guard rel.hasSuffix(LangConfig.sourceSuffix), !rel.contains("__MACOSX"),
       !FileLoader.isInsideDotPath(rel) else { continue }   // R5 点前缀不扫描
 if excludeEntries.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
 // 批 6 D-4 前置（G52 ① R1 补全）：嵌套清单词法包含——相对路径上任一祖先目录含
 // `pini.toml` 即属嵌套模块，其源码不进父包（此前仅在 import 加载侧实现，父扫描侧缺席；
 // 由 D-4 冲突语义测试暴露：两个 deps 模块的同名顶级符号在父包相撞）。
 var nested = false
 var dirParts = (rel as NSString).deletingLastPathComponent
 var checked = Set<String>()
 while dirParts != "." && dirParts != "/" && !dirParts.isEmpty {
 if checked.contains(dirParts) { break }
 checked.insert(dirParts)
 if fm.fileExists(atPath: (path as NSString).appendingPathComponent(dirParts + "/" + manifestFileName)) {
 nested = true
 break
 }
 dirParts = (dirParts as NSString).deletingLastPathComponent
 }
 if nested { continue }
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

 /// R5（issue-pini-dir-namespace-2026-08-29）：点前缀路径组件不参与源码扫描。
 ///
 /// **只取 `.`，不取 `_`**——`_` 前缀在 Pini 是 package 级可见性语义，Go 的「工具不可见」
 /// 语义不可照搬（照搬会撞车）。与 R1 正交：R1 切「另一个模块」，R5 切「不是源码」。
 ///
 /// 实现注：按**路径组件**判断（任一组件以 `.` 开头即整棵子树跳过），而非仅判断首段——
 /// 嵌套的点目录（如 `src/.gen/x.pini`）同样要跳过。由于 `subpathsOfDirectory` 返回的
 /// 相对路径无法区分「末段是文件还是目录」，以点开头的**文件**也一并跳过——这是 R5
 /// 「目录不扫描」的**超集**，与意图一致（以点开头的东西本就不是给人写的模块源码）。
 ///
 /// ⚠ 这条规则的存在有实证理由：命名空间根 `.pini/` 本身以 `.pini` 结尾，
 /// 若无此规则，`hasSuffix(LangConfig.sourceSuffix)` 会把**目录 `.pini`** 当源文件去读，
 /// 报「The file ".pini" couldn't be opened」——症状离原因很远。
 public static func isInsideDotPath(_ relativePath: String) -> Bool {
     relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
 }

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
 ffi: normalized, buildExclude: manifest.buildExclude)
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

 /// 解析单个源文件为 `FileUnit`。
 /// 非 private：`ModuleDependencyLoader` 复用它，使两条加载路径共享**一份**解析实现
 /// （G52 §9 Def-11——此前各写一遍词法/语法解析，行为随调用点漂移）。
 static func parseUnit(fileName: String, source: String) throws -> FileUnit {
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
/// `[ffi]`、`[build] exclude`。
/// 批 6（G52 批 3，2026-09-02）：双通道清单面——`[tap]`（从哪来）、`[require]`/`[require.<tap>]`
/// （模块依赖，可 import、激活 MVS）、`[resources]`/`[resources.<tap>]`（资源，不可 import、
/// 不参与 MVS）、`[replace]`（强制版本/本地/fork 替换，仅主模块生效）。
/// 旧 `[dependencies]` 节已被 spec 移除：**命中即报错**并指引迁移（本批 D-B，与旧
/// `module.toml` 命中即报错同风格——静默忽略等于复活已死语义）。
public struct ModuleManifest: Equatable {
 public let name: String
 public let version: String?
 /// 批 6：`[tap]` 源声明（名 → `github:org` / `git:url` / `file:path`）。
 public let taps: [String: String]
 /// 批 6：`[require]` 模块依赖（名 → 版本约束，未知写 `*` 由 refresh 回填）。
 public let require: [String: String]
 /// 批 6：`[require.<tap>]` 指定 tap 的依赖。
 public let requireTaps: [String: [String: String]]
 /// 批 6：`[resources]` 资源（不可 import、不参与 MVS）。
 public let resources: [String: String]
 /// 批 6：`[resources.<tap>]` 指定 tap 的资源。
 public let resourcesTaps: [String: [String: String]]
 /// 批 6：`[replace]` 强制版本 / 本地 / 换 fork（仅主模块生效，G52 D13）。
 public let replaces: [String: String]
 /// Phase 2b（ADR-017）：`[ffi]` FFI 配置；无 `[ffi]` 表时为 `nil`（解释器回退 `FFIConfig.default`）。
 public let ffi: FFIConfig?
 /// G49（issue-tdd-module-blockers-2026-08-28）：`[build] exclude`——模块包加载排除路径
 /// （相对模块根；目录前缀匹配；`loadDirectory` 统一生效，`pini test` 显式路径可加回）。
 public let buildExclude: [String]
 /// G52 §9 Def-3：`[[bin]].entry` / `[lib].entry` 声明的入口文件（相对模块根）。
 ///
 /// 声明后，解释器要求 `main` 必须定义在其中之一（详见 `Interpreter.entryFiles`）。
 /// **空数组 = 未声明** ⇒ 沿用「全局找 `main`」——`main` 是默认入口，本字段只收窄不替换。
 public let entryPoints: [String]

 public init(name: String, version: String? = nil,
 taps: [String: String] = [:],
 require: [String: String] = [:], requireTaps: [String: [String: String]] = [:],
 resources: [String: String] = [:], resourcesTaps: [String: [String: String]] = [:],
 replaces: [String: String] = [:],
 ffi: FFIConfig? = nil, buildExclude: [String] = [], entryPoints: [String] = []) {
 self.name = name
 self.version = version
 self.taps = taps
 self.require = require
 self.requireTaps = requireTaps
 self.resources = resources
 self.resourcesTaps = resourcesTaps
 self.replaces = replaces
 self.ffi = ffi
 self.buildExclude = buildExclude
 self.entryPoints = entryPoints
 }
}

/// 加载器错误。
public enum LoaderError: Error, Equatable {
 case cannotReadDirectory(path: String)
 case invalidManifest(path: String)
 /// R8：命中旧名 `module.toml`。必须报错而非静默当作「无清单」——
 /// 否则该目录会从模块边界退化为普通文件，源码被父模块扫入。
 case legacyManifestName(path: String)
 /// 批 6（D-B）：命中已移除的旧 `[dependencies]` 节。报错指引迁移到 `[require]`，
 /// 不静默忽略——静默等于复活已死语义。
 case legacyDependenciesSection(path: String)
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
 case .legacyDependenciesSection(let path):
 return "\(path)：`[dependencies]` 节已移除（G52）：模块依赖改用 `[require]`（条目集合由代码中的"
 + " `import` 生成，人工只覆盖版本约束），非 Pini 资源改用 `[resources]`；随后 `pini mod tidy` 对齐集合"
 case .parseErrors(let file, let errors):
 let details = errors.map { " - \(String(describing: $0))" }.joined(separator: "\n")
 return "解析错误（\(file)）：\n\(details)"
 }
 }
}

/// 清单解析（批 6 重构）：通用两级收集委托给 `MiniTOML`，此处只做清单形状的归类：
/// `[package]`（name 必需）、`[ffi]`、`[build]`、`[tap]`/`[require]`/`[resources]`/`[replace]`
/// 及其点分子表；**`[dependencies]` 命中即报错**（D-B）；未知表容错忽略。
private func parseManifest(_ text: String, path: String) throws -> ModuleManifest {
 let doc = MiniTOML.parse(text)

 // [dependencies] 报错须在容错判断**之前**——该节已从 spec 移除，静默 = 复活已死语义（D-B）。
 if doc.tables.keys.contains("dependencies") {
 throw LoaderError.legacyDependenciesSection(path: path)
 }
 guard let n = doc.plain("package")["name"], !n.isEmpty else {
 throw LoaderError.invalidManifest(path: path)
 }
 let pkg = doc.plain("package")
 let ffiRaw = doc.plain("ffi")
 let ffi: FFIConfig? = (ffiRaw["abi"] != nil || !(ffiRaw["search_paths"] ?? "").isEmpty || !(ffiRaw["libs"] ?? "").isEmpty)
 ? FFIConfig(abi: ffiRaw["abi"] ?? "C",
 searchPaths: MiniTOML.parseArray(ffiRaw["search_paths"] ?? "[]"),
 libs: MiniTOML.parseArray(ffiRaw["libs"] ?? "[]"))
 : nil
 // [tap.X] 子表：取其（单一）值的键值并入 taps（X → spec）；[tap] 平表条目同名优先。
 var taps = doc.plain("tap")
 for (tapName, kv) in doc.subTables("tap") where taps[tapName] == nil {
 taps[tapName] = kv.values.first
 }
 let buildExclude = MiniTOML.parseArray(doc.plain("build")["exclude"] ?? "[]")

 // Def-3：入口文件。`[[bin]]` 是数组表（可多个可执行目标），`[lib]` 是平表（至多一个）。
 // 只取 `entry`，按出现顺序去重；`[[bin]]` 的 `name` 目前无消费者（v1 入口函数名恒为 `main`），
 // 不因解析而默认它有意义。
 var entryPoints: [String] = []
 for entry in doc.arrayTables["bin"] ?? [] {
 if let e = entry["entry"], !e.isEmpty, !entryPoints.contains(e) { entryPoints.append(e) }
 }
 if let e = doc.plain("lib")["entry"], !e.isEmpty, !entryPoints.contains(e) { entryPoints.append(e) }

 return ModuleManifest(
 name: n, version: pkg["version"],
 taps: taps,
 require: doc.plain("require"), requireTaps: doc.subTables("require"),
 resources: doc.plain("resources"), resourcesTaps: doc.subTables("resources"),
 replaces: doc.plain("replace"),
 ffi: ffi, buildExclude: buildExclude, entryPoints: entryPoints)
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
