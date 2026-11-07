import Foundation
import PiniSyntax

/// 模块依赖加载器：按 import 的包路径加载被引入模块——模块根须有 `pini.toml`（物理边界），
/// 解析其根级 `.pini` 源文件，产出声明表与 public 符号集（跨模块引入的门槛只认 public）。
/// 加载栈 + 规范路径缓存实现环检测：import 即依赖，依赖图禁环；缓存读写都在 `cacheLock` 内。
public final class ModuleDependencyLoader: @unchecked Sendable {

    public struct LoadedModule {
        public let rootPath: String
        public let imports: [ImportDecl]
        public let declarations: [TopLevelDecl]
        /// public 符号名集（跨模块仅 public 可引入；按可见性定稿表判定）
        public let publicSymbols: Set<String>
        /// 全部顶级符号名（含非 public，供诊断）
        public let allSymbols: Set<String>
    }

    public static let shared = ModuleDependencyLoader()

    private let cacheLock = NSLock()
    private var cache: [String: LoadedModule] = [:]

    /// 缓存读写不跨递归：锁只裹「取/存」两小段，加载本身在锁外跑，故不会自锁。
    private func cachedModule(_ key: String) -> LoadedModule? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func cacheModule(_ module: LoadedModule, at key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = module
    }

    public init() {}

    /// 计算包路径的规范化绝对路径（供调用方做依赖链环检测）。
    public func canonicalPath(packagePath: String, relativeTo relativeToDir: String) -> String {
        let resolved: String
        if packagePath.hasPrefix("/") {
            resolved = packagePath
        } else if relativeToDir.hasPrefix("/") {
            resolved = relativeToDir + "/" + packagePath
        } else {
            // 相对目录锚定到进程工作目录，保证 canonical 全局可比（环检测依赖）
            let base =
                relativeToDir.isEmpty
                ? FileManager.default.currentDirectoryPath
                : FileManager.default.currentDirectoryPath + "/" + relativeToDir
            resolved = base + "/" + packagePath
        }
        return (resolved as NSString).standardizingPath
    }

    /// 解析并加载 `path` 指向的模块，并**递归预载其全部依赖**（R2 环检测覆盖全图）。
    /// `chain` 为当前依赖链上的祖先规范化路径（含正在加载的模块根）。
    public func load(packagePath: String, relativeTo relativeToDir: String, chain: [String] = []) throws -> LoadedModule {
        let canonical = canonicalPath(packagePath: packagePath, relativeTo: relativeToDir)

        // R2：依赖图禁环——依赖链命中即环（先于缓存检查：环路径不可复用缓存豁免）
        if chain.contains(canonical) {
            let cycleChain = (chain + [canonical]).map { ($0 as NSString).lastPathComponent }
            throw SemanticError.moduleDependencyCycle(chain: cycleChain)
        }
        if let cached = cachedModule(canonical) { return cached }

        // R1：物理边界——模块根须有清单 pini.toml
        let manifest = canonical + "/pini.toml"
        if !FileManager.default.fileExists(atPath: manifest) {
            throw SemanticError.moduleRootMissing(path: canonical)
        }

        // 双策略按来源划分：远程落地（`deps/<name>/`）只扫根级，只为拿到声明与 public 符号集——
        // 为一个只用其接口的依赖递归整棵子树是白付的解析代价；本地目录则递归扫描，
        // 与 `FileLoader.loadDirectory` 共用同一套嵌套剔除：自带 `pini.toml` 的子目录是独立模块，不进本模块。
        let units: [FileUnit] =
            try Self.isRemoteLanding(canonical)
            ? Self.scanRootLevel(at: canonical)
            : FileLoader.loadDirectory(path: canonical, withStdlib: false).fileUnits
        guard !units.isEmpty else {
            throw SemanticError.moduleRootMissing(path: canonical)
        }

        var declarations: [TopLevelDecl] = []
        var moduleImports: [ImportDecl] = []
        var allSymbols: Set<String> = []
        var publicSymbols: Set<String> = []
        for unit in units {
            let module = unit.module
            // 可见性按**相对模块根**的路径判定（`VisibilityLevel.forSymbol` 看的是
            // 文件名与其父目录名）：递归扫描后路径可能带子目录，须剥掉模块根前缀，
            // 否则 `_pkg/foo.pini` 的 package 可见性会被误判为 public。
            let rel =
                unit.fileName.hasPrefix(canonical + "/")
                ? String(unit.fileName.dropFirst(canonical.count + 1))
                : (unit.fileName as NSString).lastPathComponent
            moduleImports.append(contentsOf: module.imports)
            for decl in module.declarations {
                declarations.append(decl)
                if let name = Self.declName(decl) {
                    let level = VisibilityLevel.forSymbol(name: name, fileName: rel)
                    allSymbols.insert(name)
                    if level == .public { publicSymbols.insert(name) }
                }
            }
        }
        let loaded = LoadedModule(
            rootPath: canonical,
            imports: moduleImports,
            declarations: declarations,
            publicSymbols: publicSymbols,
            allSymbols: allSymbols
        )
        // 递归预载依赖（先于缓存写入：全图环检测覆盖）
        for imp in moduleImports {
            let dir = (imp.location.fileName as NSString).deletingLastPathComponent
            _ = try load(packagePath: imp.packagePath, relativeTo: dir, chain: chain + [canonical])
        }
        cacheModule(loaded, at: canonical)
        return loaded
    }

    // MARK: - 扫描策略（G52 §9 Def-11）

    /// 是否位于远程依赖的落地根（`<模块根>/deps/<name>/`）。判据取「父目录名 == `deps`」，
    /// 而非「路径里出现过 `deps` 分量」：后者会误伤自身目录树里恰好有 `deps/` 的本地模块，
    /// 而落地位置是精确的一层。
    private static func isRemoteLanding(_ canonical: String) -> Bool {
        (canonical as NSString).deletingLastPathComponent
            .components(separatedBy: "/").last == "deps"
    }

    /// 根级扫描（远程清单策略）：只读模块根一层，不递归。
    private static func scanRootLevel(at canonical: String) throws -> [FileUnit] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: canonical)) ?? []
        return try entries.filter { $0.hasSuffix(LangConfig.sourceSuffix) }.sorted()
            .map { name in
                let path = canonical + "/" + name
                return try FileLoader.parseUnit(
                    fileName: path,
                    source: String(contentsOfFile: path, encoding: .utf8))
            }
    }

    /// 顶级声明的符号名（extension 无名——方法随宿主类型派发，不跨模块携带）。
    static func declName(_ decl: TopLevelDecl) -> String? {
        switch decl {
        case .funcDecl(let f): return f.name
        case .structDecl(let s): return s.name
        case .objectDecl(let o): return o.name
        case .enumDecl(let e): return e.name
        case .traitDecl(let t): return t.name
        default: return nil
        }
    }
}
