import Foundation

/// G52 批 1（2026-08-31）：模块依赖加载器——R1 物理边界 + R2 依赖图无环。
///
/// 职责：按 import 项的包路径加载被引入模块（根须有 `pini.toml`，R1），
/// 解析其全部根级 `.pini` 源文件，产出声明表与 public 符号集（跨模块引入
/// 门槛 = 仅 public，G52 D8）。加载栈 + 规范路径缓存实现环检测（R2：
/// import 即依赖、依赖图禁环）。
public final class ModuleDependencyLoader {

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

    private var cache: [String: LoadedModule] = [:]

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
            let base = relativeToDir.isEmpty ? FileManager.default.currentDirectoryPath
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
        if let cached = cache[canonical] { return cached }

        // R1：物理边界——模块根须有清单 pini.toml
        let manifest = canonical + "/pini.toml"
        if !FileManager.default.fileExists(atPath: manifest) {
            throw SemanticError.moduleRootMissing(path: canonical)
        }

        // 扫描根级 .pini 源文件（批 1 平铺；模块树/子模块随批 3）
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: canonical)) ?? []
        let sourceFiles = entries.filter { $0.hasSuffix(".pini") }.sorted()
        guard !sourceFiles.isEmpty else {
            throw SemanticError.moduleRootMissing(path: canonical)
        }

        var declarations: [TopLevelDecl] = []
        var moduleImports: [ImportDecl] = []
        var allSymbols: Set<String> = []
        var publicSymbols: Set<String> = []
        for file in sourceFiles {
            let filePath = canonical + "/" + file
            let source = try String(contentsOfFile: filePath, encoding: .utf8)
            let lexer = Lexer(source: source, fileName: filePath)
            let tokens = try lexer.tokenize()
            let parser = Parser(tokens: tokens, fileName: filePath)
            let module = try parser.parseModule()
            moduleImports.append(contentsOf: module.imports)
            for decl in module.declarations {
                declarations.append(decl)
                if let name = Self.declName(decl) {
                    let level = VisibilityLevel.forSymbol(name: name, fileName: file)
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
        cache[canonical] = loaded
        return loaded
    }

    /// 顶级声明的符号名（extension 无名——方法随宿主类型派发，批 1 不跨模块携带）。
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
