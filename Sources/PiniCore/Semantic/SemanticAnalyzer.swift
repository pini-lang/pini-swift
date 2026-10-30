import Foundation

/// 语义分析器
/// 负责语义检查：变量是否定义、函数是否定义、类型是否定义等
public final class SemanticAnalyzer {
    public var symbolTable: SymbolTable

    /// 本模块枚举的「case 名 → 父枚举名列表」与「枚举名 → 全部 case 名」，在
    /// `registerTopLevelDecl` 预登记阶段填充，供 `checkValidatedMatch` 做 best-effort 穷尽性校验。
    /// case 名按枚举命名空间隔离，故天然是多父映射，穷尽性校验对跨枚举同名碰撞做退化处理。
    private var enumCaseParents: [String: [String]] = [:]
    private var enumAllCases: [String: [String]] = [:]

    /// 名字级「变量 / 参数 / 方法可见字段 → 类型名」登记，`typeNameOf` 的输入：让 `match` 按被匹配
    /// 值的类型解析父枚举，而不是按 case 名反查。判不出类型时不留登记，上层据此跳过校验。
    /// 进入块 / 函数时快照、离开时回滚，使同名遮蔽不把外层类型带给内层之后的判断。
    private var declaredTypes: [String: String] = [:]

    /// 声明上下文收紧·规则 3.2/3.14：类型字段表（register 阶段填充），供扩展块方法体检查时注入 self 字段作用域。
    private var typeFields: [String: [FieldDecl]] = [:]

    /// 语义警告（非致命）：目前只含未使用局部变量，检测点在块作用域。
    public private(set) var warnings: [SemanticWarning] = []

    // 当前文件的注入导入（`_` 前缀别名 → 目标 public 符号集）与裸名集。
    // 注入 = 全导入：目标 public 符号进入本文件裸名空间（文件级）；冲突即 E3-013。
    private struct InjectedImport {
        let alias: String
        let symbols: Set<String>
        let location: SourceLocation
    }
    private var currentInjections: [InjectedImport] = []
    private var currentInjectNames: Set<String> = []
    private var deferredInjectConflict: SemanticError? = nil

    /// B2：已被读取引用的符号名集合（`requireDefined` 解析命中时记录）。
    /// 已知限制：name 级键，跨作用域同名符号会互相"洗白"未使用判定——首版接受，待符号表结构化（唯一 id）后升级。
    private var usedSymbols: Set<String> = []

    /// import 别名登记表：别名 → (publicSymbols 跨模块可引入集, allSymbols 全部顶级符号)。
    /// D-2 静态互斥：本地符号声明与别名同名即重声明错误。
    private var importAliasInfos: [String: (publicSymbols: Set<String>, allSymbols: Set<String>)] = [:]
    /// 点号用例构造（成员意图）的名字登记集：全部已见枚举用例名（含内建 Optional 的
    /// some/none）。与前导点解析配套——`.name` 只要求名字是某枚举的用例，不受本地位
    /// 遮蔽影响（前导点已声明成员归属，期望类型决议在类型层完成）。
    private var enumCaseNames: Set<String> = ["some", "none"]

    /// H-1 capture 校验上下文栈：每个活跃匿名函数字面量一层
    ///（boundary = 字面量体作用域边界；captured = 已先行声明的捕获名集合）。
    /// ①引用外层局部未捕获 → captureWithoutDeclaration；嵌套字面量各持独立一层。
    private var captureContexts: [(boundary: Scope, captured: Set<String>)] = []

    /// P4 Phase 3：多文件包分析时的包级符号索引与「当前正在分析的文件」。
    /// 单文件模式（`analyze(module:)`）下恒为 `nil`，故单文件行为零回归。
    private var packageContext: (index: PackageSymbolIndex, currentFileName: String)? = nil

    public init() {
        self.symbolTable = SymbolTable()
        registerBuiltins()
    }

    /// 重置符号表为干净全局作用域并重新登记内建（多文件模式下每个文件独立分析用）。
    private func resetSymbolTable() {
        symbolTable = SymbolTable()
        enumCaseParents = [:]
        enumAllCases = [:]
        usedSymbols = []  // B2：每文件独立的读取引用集（跨文件同名不互相洗白）
        registerBuiltins()
    }

    private func registerBuiltins() {
        let dummyLoc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
        /// 内建符号从单点登记表（BuiltinRegistry）派生：名字与归组只声明一次，解释器 / 类型检查 /
        /// 本层各自取用。本层不登记则示例或用户代码调用这些自由函数会被误报 undefinedFunction；
        /// 字符串成员方法走成员调用路径、不经符号表，无需登记。表里除函数还有值，按值类型分流登记。
        for decl in BuiltinRegistry.decls where decl.definesSymbol {
            let kind: SymbolKind = decl.valueType == nil
                ? .function
                : .variable(isMutable: false)
            symbolTable.define(Symbol(name: decl.name, kind: kind, location: dummyLoc))
        }
    }

    /// 分析模块
    public func analyze(module: Module) throws {
        warnings = []  // B2：每次分析重置（实例可复用）
        usedSymbols = []
        // 登记 import 别名（加载被引入模块，R1 边界 + R2 禁环由加载器负责）
        for imp in module.imports {
            let dir = (imp.location.fileName as NSString).deletingLastPathComponent
            let loaded = try ModuleDependencyLoader.shared.load(packagePath: imp.packagePath, relativeTo: dir)
            importAliasInfos[imp.alias] = (loaded.publicSymbols, loaded.allSymbols)
        }

        try setupInjections(for: module)
        defer { teardownInjections() }
        /// 预置声明（宿主提供）先注册，让语言预置的名字在本文件里存在——缺了这步，该名字落在值位会被
        /// 判「未定义变量」，而它确实存在、只是不能作值。只注册未被本模块占名的那些：用户已占名时
        /// 再注册会被判重声明，而这类名字的处置承诺是用户声明优先（让位规则，与降载层同源）。
        for decl in PredefinedDecls.effective(in: module.declarations) {
            try registerTopLevelDecl(decl)
        }
        // 第一遍：预注册所有顶级声明
        for decl in module.declarations {
            try registerTopLevelDecl(decl)
        }

        // 第二遍：检查函数体
        for decl in module.declarations {
            try checkTopLevelDecl(decl)
        }
        if let c = deferredInjectConflict { throw c }
    }

    /// 分析包（多文件 / 单文件统一入口）。单文件包直接委托 `analyze(module:)`，行为等价；多文件包
    /// 先建包级符号索引（跨文件重声明在此抛出），再逐文件分析——每个文件用干净符号表承载自身
    /// 顶级声明，跨文件引用经索引解析并 enforce 4 级可见性。
    public func analyze(package: Package) throws {
        warnings = []  // B2：每包重置（实例可复用）
        if package.fileUnits.count <= 1 {
            let module =
                package.fileUnits.first?.module
                ?? Module(
                    declarations: [], imports: [], exports: [],
                    location: SourceLocation(line: 0, column: 0, fileName: package.name))
            try analyze(module: module)
            return
        }

        let index = try PackageSymbolIndex.build(package: package)
        for unit in package.fileUnits {
            resetSymbolTable()
            packageContext = (index: index, currentFileName: unit.fileName)
            defer { packageContext = nil }
            try setupInjections(for: unit.module)
            defer { teardownInjections() }

            // 预置声明先注册（理由见单模块入口）；本路径逐文件独立符号表，
            // 故每个文件各注册一份，互不冲突。
            for decl in PredefinedDecls.effective(in: unit.module.declarations) {
                try registerTopLevelDecl(decl)
            }
            // 第一遍：预注册当前文件自身的顶级声明（跨文件符号不入本表，防 private 泄漏）
            for decl in unit.module.declarations {
                try registerTopLevelDecl(decl)
            }
            // 第二遍：检查当前文件函数体（引用点经索引做跨文件可见性 enforce）
            for decl in unit.module.declarations {
                try checkTopLevelDecl(decl)
            }
            if let c = deferredInjectConflict { throw c }
        }
    }

    // MARK: - 隐式别名注入（全导入 + 裸调用，冲突即 E3-013）

    /// 收集本文件的注入导入并安装哨兵。`_别名 = path` 的别名不必等于目标模块名，不一致仅发弱警告；
    /// 注入的 public 符号进入本文件裸名空间，可裸调用或 `_别名.符号` 限定；与本文件任何可裸引用名
    /// 相撞即报错，修复方式是改写显式别名并限定调用。
    private func setupInjections(for module: Module) throws {
        currentInjections = []
        currentInjectNames = []
        var explicitAliasNames = Set<String>()
        for imp in module.imports {
            if imp.alias.hasPrefix("_") {
                let dir = (imp.location.fileName as NSString).deletingLastPathComponent
                let loaded = try ModuleDependencyLoader.shared.load(packagePath: imp.packagePath, relativeTo: dir)
                currentInjections.append(
                    InjectedImport(
                        alias: imp.alias, symbols: loaded.publicSymbols,
                        location: imp.location))
                // #1 弱警告：别名（去 `_`）与目标模块名不一致——检查但不强制
                let canonical = ModuleDependencyLoader.shared.canonicalPath(
                    packagePath: imp.packagePath,
                    relativeTo: dir)
                if let m = try? FileLoader.loadManifest(directory: canonical), m.name != String(imp.alias.dropFirst()) {
                    warnings.append(
                        .implicitAliasNameMismatch(
                            alias: imp.alias, targetName: m.name,
                            location: imp.location))
                }
            } else {
                explicitAliasNames.insert(imp.alias)
            }
        }
        for inj in currentInjections { currentInjectNames.formUnion(inj.symbols) }

        // (b) 注入 vs 注入：两个隐式模块导出同名符号
        for i in 0..<currentInjections.count {
            for j in (i + 1)..<currentInjections.count {
                let a = currentInjections[i], b = currentInjections[j]
                if let s = a.symbols.intersection(b.symbols).sorted().first {
                    throw SemanticError.injectedSymbolConflict(
                        symbol: s,
                        holder: "注入别名 \(a.alias) 与 \(b.alias)（两模块均裸导出）",
                        location: b.location)
                }
            }
        }
        // (c) 注入 vs 显式别名 / 内建
        let builtinNames = Set(BuiltinRegistry.decls.filter(\.definesSymbol).map(\.name))
        for inj in currentInjections {
            for s in inj.symbols.sorted() {
                if explicitAliasNames.contains(s) {
                    throw SemanticError.injectedSymbolConflict(
                        symbol: s,
                        holder: "注入别名 \(inj.alias) 与显式别名 \(s)", location: inj.location)
                }
                if builtinNames.contains(s) {
                    throw SemanticError.injectedSymbolConflict(
                        symbol: s,
                        holder: "注入别名 \(inj.alias) 与内建 \(s)", location: inj.location)
                }
            }
        }
        // (a) 注入 vs 本文件顶级/局部声明：哨兵挂到符号表，define 命中即记录（两遍均生效）
        symbolTable.forbiddenNames = currentInjectNames
        symbolTable.onForbiddenDefine = { [weak self] name in
            guard let self, self.deferredInjectConflict == nil else { return }
            if let inj = self.currentInjections.first(where: { $0.symbols.contains(name) }) {
                self.deferredInjectConflict = SemanticError.injectedSymbolConflict(
                    symbol: name,
                    holder: "注入别名 \(inj.alias) 与本文件声明 \(name)",
                    location: inj.location)
            }
        }
    }

    private func teardownInjections() {
        symbolTable.forbiddenNames = []
        symbolTable.onForbiddenDefine = nil
        currentInjections = []
        currentInjectNames = []
    }

    /// 引用点解析单点：先查当前文件作用域；未命中且处于多文件包时查包级索引，
    /// 按 spec enforce 可见性（private/internal 跨文件不可见 → `inaccessibleSymbol`）。
    /// 单文件模式下 `packageContext` 为 nil，行为与原 `symbolTable.resolve` 判定完全一致。
    private func requireDefined(_ name: String, _ location: SourceLocation, isFunction: Bool) throws {
        // 内建 Optional 枚举类型标识符（裸 Optional / Optional.none 引用），静态层无需注册即可解析，
        // 与解释器对 Optional.some/Optional.none 的特判对齐（闭合 B2 静态缺口）。
        if name == "Optional" { return }
        if let hit = symbolTable.resolveWithScope(name) {
            // H-1①：匿名函数体内引用外层局部变量，其 capture 声明须先于本使用出现
            if let ctx = captureContexts.last,
                !hit.scope.isWithin(ctx.boundary),
                Self.isCapturableKind(hit.symbol.kind),
                !ctx.captured.contains(name)
            {
                throw SemanticError.captureWithoutDeclaration(name: name, location: location)
            }
            usedSymbols.insert(name)  // B2：记录读取引用（未使用检测依据）
            return
        }
        if let ctx = packageContext,
            let entry = ctx.index.lookup(name)
        {
            if entry.isVisible(from: ctx.currentFileName) { return }
            throw SemanticError.inaccessibleSymbol(
                name: name, definedIn: entry.fileName, level: entry.visibility, location: location
            )
        }
        // 未命中本地/包级时，注入的 public 符号可裸引用（文件级全导入；冲突已由哨兵排除）
        if currentInjectNames.contains(name) { return }
        if isFunction {
            throw SemanticError.undefinedFunction(name: name, location: location)
        } else {
            throw SemanticError.undefinedVariable(name: name, location: location)
        }
    }

    /// 收集模式分析：不抛出，返回模块内全部语义错误，用于多错误同报。注册阶段逐顶级声明 catch 并
    /// 继续（遇重声明仍尝试登记该名，避免后续误报未定义）；检查阶段同样逐声明继续，但函数体内
    /// 仍遇错即抛，不跨函数累积。
    public func analyzeCollecting(module: Module) -> [SemanticError] {
        warnings = []  // B2：收集模式同样重置（实例可复用）
        usedSymbols = []
        var errors: [SemanticError] = []
        // 登记 import 别名（与 analyze(module:) 同规则）；加载失败收集为诊断
        for imp in module.imports {
            let dir = (imp.location.fileName as NSString).deletingLastPathComponent
            do {
                let loaded = try ModuleDependencyLoader.shared.load(packagePath: imp.packagePath, relativeTo: dir)
                importAliasInfos[imp.alias] = (loaded.publicSymbols, loaded.allSymbols)
            } catch let e as SemanticError {
                errors.append(e)
            } catch {
                errors.append(.moduleRootMissing(path: imp.packagePath))
            }
        }

        // 预置声明先注册 —— 与单错误入口同一规则、同一顺序，理由见那里。
        //  注意  本入口是 `pini check` 实际走的那个：只在另一处加，命令行探针会**照旧**报
        // 「未定义的变量」，而单元测试（走前者）却绿 ⇒ 一处漏改会伪装成「已修好」。
        for decl in PredefinedDecls.effective(in: module.declarations) {
            do {
                try registerTopLevelDecl(decl)
            } catch let error as SemanticError {
                errors.append(error)
            } catch {
                // 非 SemanticError 不阻断后续（与下面同规）
            }
        }

        for decl in module.declarations {
            do {
                try registerTopLevelDecl(decl)
            } catch let error as SemanticError {
                errors.append(error)
                recoverRegister(decl)
            } catch {
                // 非 SemanticError 不阻断后续（理论不应发生）
            }
        }

        for decl in module.declarations {
            do {
                try checkTopLevelDecl(decl)
            } catch let error as SemanticError {
                errors.append(error)
            } catch {
                // 同上
            }
        }

        return errors
    }

    /// 重声明导致 registerTopLevelDecl 中途失败时，尽力把该声明头登记进符号表，
    /// 以免后续合法引用被误报为未定义（P2-4.3 收集模式专用）。
    private func recoverRegister(_ decl: TopLevelDecl) {
        switch decl {
        case .structDecl(let s):
            symbolTable.define(Symbol(name: s.name, kind: .struct, location: s.location))
        case .objectDecl(let o):
            symbolTable.define(Symbol(name: o.name, kind: .object, location: o.location))
        case .enumDecl(let e):
            symbolTable.define(Symbol(name: e.name, kind: .enum, location: e.location))
            for enumCase in e.cases {
                symbolTable.define(Symbol(name: enumCase.name, kind: .enumCase, location: enumCase.location))
                enumCaseNames.insert(enumCase.name)
            }
        case .funcDecl(let f):
            symbolTable.define(Symbol(name: f.name, kind: .function, location: f.location))
        case .traitDecl(let t):
            symbolTable.define(Symbol(name: t.name, kind: .trait, location: t.location))
        case .givenDecl(let g):
            // 给定块是具名复合类型 ⇒ 纳入包级符号表（与对象同族）。
            symbolTable.define(Symbol(name: g.name, kind: .object, location: g.location))
        case .extensionDecl, .foreignDecl, .varDecl, .statement, .importDecl, .exportDecl:
            break
        }
    }

    // MARK: - 注册阶段（P2-3 重声明检测）

    // 第一遍预注册：若同名顶级符号已存在则抛出 redeclaredSymbol。
    // 注：当前为「遇错即抛」单错误模式；错误收集接入后可累积多错误。
    private func registerTopLevelDecl(_ decl: TopLevelDecl) throws {
        switch decl {
        case .structDecl(let s):
            typeFields[s.name] = s.fields
            return try registerStructLike(s.name, fields: s.fields, methods: s.methods, location: s.location)
        case .objectDecl(let o):
            typeFields[o.name] = o.fields
            return try registerStructLike(o.name, fields: o.fields, methods: o.methods, location: o.location)
        case .givenDecl(let g):
            // 给定块与对象体同规 ⇒ 同路径注册（字段表 / 符号表 / 重声明检测 / 成员名冲突）。
            typeFields[g.name] = g.fields
            return try registerStructLike(g.name, fields: g.fields, methods: g.methods, location: g.location)
        case .enumDecl(let e):
            try defineUnique(name: e.name, kind: .enum, location: e.location)
            /// case 名按枚举命名空间隔离，只检测同一枚举内重名；跨枚举同名 case 允许共存。
            /// case 名仍以 `symbolTable.define` 登记（覆盖、不抛错），保证未限定构造 `圆(5.0)` 的
            /// requireDefined 能解析通过。
            var seenInEnum: Set<String> = []
            for enumCase in e.cases {
                if seenInEnum.contains(enumCase.name) {
                    throw SemanticError.redeclaredSymbol(name: enumCase.name, location: enumCase.location)
                }
                seenInEnum.insert(enumCase.name)
                symbolTable.define(Symbol(name: enumCase.name, kind: .enumCase, location: enumCase.location))
                enumCaseNames.insert(enumCase.name)
            }
            // P3/P5-5：填充本模块枚举映射，供 validated 匹配模式做 best-effort 穷尽性校验。
            for enumCase in e.cases {
                enumCaseParents[enumCase.name, default: []].append(e.name)
            }
            enumAllCases[e.name] = e.cases.map { $0.name }
        case .funcDecl(let f):
            try defineUnique(name: f.name, kind: .function, location: f.location)
        case .traitDecl(let t):
            try defineUnique(name: t.name, kind: .trait, location: t.location)
        case .extensionDecl(let x):
            // 扩展块不引入新符号；方法名须与目标类型字段/其它方法不冲突（声明上下文收紧·规则 3.2/3.14）。
            let targetFields = typeFields[x.targetType] ?? []
            var seen: [String: SourceLocation] = [:]
            for f in targetFields { seen[f.name] = f.location }
            for method in x.methods {
                if let previous = seen[method.name] {
                    throw SemanticError.redeclaredSymbol(name: method.name, location: method.location)
                }
                seen[method.name] = method.location
            }
            return
        case .foreignDecl(let fd):
            // Phase 2a（FFI 子系统）：foreign 函数注册为模块级函数符号（调用点可解析）；
            // 块本身不引入新符号，外部 C 符号运行时经原生函数表解析。
            for f in fd.funcs {
                try defineUnique(name: f.name, kind: .function, location: f.location)
            }
            return
        case .varDecl, .statement, .importDecl, .exportDecl:
            break
        }
    }

    /// struct/object 的注册公共路径（含方法成员冲突检测）。
    private func registerStructLike(_ name: String, fields: [FieldDecl], methods: [FuncDecl], location: SourceLocation) throws {
        try defineUnique(name: name, kind: .struct, location: location)
        try checkMemberNameConflicts(fields: fields, methods: methods)
    }

    private func defineUnique(name: String, kind: SymbolKind, location: SourceLocation) throws {
        if symbolTable.resolve(name) != nil {
            throw SemanticError.redeclaredSymbol(name: name, location: location)
        }
        // G52 D-2 静态互斥：本地顶级符号不得与 import 别名同名
        if importAliasInfos[name] != nil {
            throw SemanticError.redeclaredSymbol(name: name, location: location)
        }
        symbolTable.define(Symbol(name: name, kind: kind, location: location))
    }

    /// 类型成员名冲突检测（P2-3.3）：结构体/对象内部的字段与字段、方法与字段、
    /// 方法与方法之间不允许同名。名字在「类型自身」范围内唯一，不污染全局符号表。
    private func checkMemberNameConflicts(fields: [FieldDecl], methods: [FuncDecl]) throws {
        var seen: [String: SourceLocation] = [:]
        for field in fields {
            if let previous = seen[field.name] {
                throw SemanticError.redeclaredSymbol(name: field.name, location: field.location)
            }
            seen[field.name] = field.location
        }
        for method in methods {
            if let previous = seen[method.name] {
                throw SemanticError.redeclaredSymbol(name: method.name, location: method.location)
            }
            seen[method.name] = method.location
        }
    }

    // MARK: - 检查阶段

    private func checkTopLevelDecl(_ decl: TopLevelDecl) throws {
        switch decl {
        case .funcDecl(let f):
            try checkFuncDecl(f)
        case .structDecl(let s):
            for method in s.methods {
                try checkFuncDecl(method, fields: s.fields)
            }
        case .objectDecl(let o):
            for method in o.methods {
                try checkFuncDecl(method, fields: o.fields)
            }
        case .enumDecl(let e):
            for method in e.methods {
                try checkFuncDecl(method)
            }
        case .extensionDecl(let x):
            // 扩展方法体检查：注入目标类型字段作用域（同文件扩展块可访问私有字段）。
            let targetFields = typeFields[x.targetType] ?? []
            for method in x.methods {
                try checkFuncDecl(method, fields: targetFields)
            }
        case .givenDecl(let g):
            // 给定块的方法体按字段作用域检查（`methods` 目前恒空 —— 方法写扩展块再归并；
            // 此处按同规处理，归并实装后无需回改本处）。
            for method in g.methods {
                try checkFuncDecl(method, fields: g.fields)
            }
        case .foreignDecl:
            // Phase 2a（FFI 子系统）：仅签名、无函数体，无检查项。
            break
        case .traitDecl, .varDecl, .statement, .importDecl, .exportDecl:
            break
        }
    }

    private func checkFuncDecl(_ funcDecl: FuncDecl, fields: [FieldDecl] = []) throws {
        let savedTypes = declaredTypes
        symbolTable.enterScope(name: funcDecl.name)
        defer {
            declaredTypes = savedTypes
            symbolTable.exitScope()
        }

        // 方法体作用域：注册 self 与所属类型的字段，使方法体可直接引用字段
        // （P3-1 示例 trait.pini 的 `描述|self() -> (String,)` 返回 `名字` 字段触发此需求）。
        // 字段先于参数注册，参数可遮蔽同名字段。
        if !fields.isEmpty {
            symbolTable.define(Symbol(name: "self", kind: .variable(isMutable: false), location: funcDecl.location))
            for field in fields {
                symbolTable.define(Symbol(name: field.name, kind: .variable(isMutable: false), location: field.location))
                recordDeclaredType(field.name, typeNameOfAnnotation(field.typeAnnotation))
            }
        }

        // 注册参数
        for param in funcDecl.params {
            symbolTable.define(Symbol(name: param.name, kind: .parameter, location: funcDecl.location))
            if let annotation = param.typeAnnotation {
                recordDeclaredType(param.name, typeNameOfAnnotation(annotation))
            }
        }

        // 检查函数体：包一层 body scope，使局部 var 在独立作用域——B2 未使用检测只在此与嵌套块
        // （checkBlock）执行，参数（函数 scope）、方法字段（函数 scope）、for 模式变量（for-loop scope）天然排除。
        if let body = funcDecl.body {
            symbolTable.enterScope(name: "body")
            defer {
                emitUnusedWarnings()
                symbolTable.exitScope()
            }
            for stmt in body.statements {
                try checkStatement(stmt)
            }
        }
    }

    // MARK: - 语句检查

    private func checkStatement(_ stmt: Statement) throws {
        if case .captureStatement(let name, let location) = stmt {
            // H-1：解析器已把 capture 限制在匿名函数体缩进体顶层；此处防御非常规构造路径
            guard !captureContexts.isEmpty else {
                throw SemanticError.invalidCaptureTarget(
                    name: name, reason: "capture 仅允许出现在匿名函数体顶层语句位", location: location)
            }
            // ②捕获一致性：目标必须是创建点外层的局部变量
            if name == "self" {
                throw SemanticError.invalidCaptureTarget(
                    name: name, reason: "self 由 |self 修饰符表达，不进 capture 列表（A2）", location: location)
            }
            if symbolTable.isDefinedInCurrentScope(name) {
                throw SemanticError.invalidCaptureTarget(
                    name: name, reason: "已是本匿名函数的参数或体内已声明局部", location: location)
            }
            let boundary = captureContexts[captureContexts.count - 1].boundary
            guard let hit = symbolTable.resolveWithScope(name),
                Self.isCapturableKind(hit.symbol.kind),
                !hit.scope.isWithin(boundary)
            else {
                throw SemanticError.invalidCaptureTarget(
                    name: name, reason: "须是创建点外层的局部变量（参数/体内局部/内建函数/类型/不可见名不可捕获）", location: location)
            }
            captureContexts[captureContexts.count - 1].captured.insert(name)
            usedSymbols.insert(name)  // capture 即引用（B2 未使用判定）
            return
        }
        switch stmt {
        case .varDecl(let name, let annotation, let initializer, let isMutable, let location):
            if let initExpr = initializer {
                try checkExpression(initExpr)
            }
            if symbolTable.isDefinedInCurrentScope(name) {
                throw SemanticError.redeclaredSymbol(name: name, location: location)
            }
            try checkAliasNameConflict(name, location)
            symbolTable.define(Symbol(name: name, kind: .variable(isMutable: isMutable), location: location))
            recordDeclaredType(name, declaredTypeName(annotation: annotation, initializer: initializer))

        case .varDestructure(let names, _, let initializer, let isMutable, let location):
            // 草稿 A1（批次 1）：逐个定义非 `_` 分量（`_` 为占位不定义）；先检查初始值子表达式。
            if let initExpr = initializer {
                try checkExpression(initExpr)
            }
            for name in names where name != "_" {
                if symbolTable.isDefinedInCurrentScope(name) {
                    throw SemanticError.redeclaredSymbol(name: name, location: location)
                }
                try checkAliasNameConflict(name, location)
                symbolTable.define(Symbol(name: name, kind: .variable(isMutable: isMutable), location: location))
            }

        case .assign(let target, let value, let location):
            switch target {
            case .identifier(let name):
                try requireDefined(name, location, isFunction: false)
            case .member(let obj, _):
                try checkExpression(obj)
            case .subscript(let containerExpr, let indexExpr):
                try checkExpression(containerExpr)
                try checkExpression(indexExpr)
            }
            try checkExpression(value)

        case .returnStatement(let value, _):
            if let v = value {
                try checkExpression(v)
            }

        case .breakStatement, .continueStatement:
            break

        case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
            try checkExpression(condition)
            try checkBlock(thenBlock)
            for elif in elifs {
                try checkExpression(elif.condition)
                try checkBlock(elif.block)
            }
            if let elseBlk = elseBlock {
                try checkBlock(elseBlk)
            }

        case .whileStatement(let condition, let body, let step, _, _):
            try checkExpression(condition)
            try checkBlock(body)
            if let step = step { try checkBlock(step) }

        case .forStatement(let pattern, let iterable, let body, let step, _, let loc):
            try checkExpression(iterable)
            // 模式变量注入 for 作用域（`_` 占位不登记），否则 body/step 内引用会被误报 undefinedVariable
            symbolTable.enterScope(name: "for-loop")
            for name in pattern where name != "_" {
                symbolTable.define(Symbol(name: name, kind: .variable(isMutable: true), location: loc))
            }
            try checkBlock(body)
            if let step = step { try checkBlock(step) }
            symbolTable.exitScope()

        case .scopedBlock(_, let body, _):
            try checkBlock(body)

        case .matchStatement(let value, let cases, let location):
            try checkExpression(value)
            for matchCase in cases {
                // 将 match 模式绑定变量（如 case 圆(半径: r,): 中的 r）注入该 case 作用域，
                // 否则 case 体内引用绑定变量会被误报 undefinedVariable。
                symbolTable.enterScope(name: "match-case")
                for binding in matchCase.bindings {
                    symbolTable.define(Symbol(name: binding.varName, kind: .variable(isMutable: false), location: matchCase.location))
                }
                try checkBlock(matchCase.block)
                symbolTable.exitScope()
            }
            /// 穷尽性 / 可达性检查总是开启，`case _:` 通配兜底豁免；`default:` / `pass` 通配子块不受支持。
            try checkMatchExhaustive(value: value, cases: cases, location: location)

        case .expressionStmt(let expr, _):
            try checkExpression(expr)

        case .detachStatement(let expr, _):
            try checkExpression(expr)

        case .deferStatement(let statement, _):
            try checkStatement(statement)
        case .passStatement(_):
            break
        case .captureStatement:
            return
        }
    }

    // MARK: - 类型名解析（match 的父枚举判据）

    /// 确定不是枚举的内建标量类型名。未列出的名字一律不作「非枚举」判断 —— 判不出就不校验，
    /// 这样导入 / 内建 / 尚未登记的类型不会被误拒。
    private static let scalarTypeNames: Set<String> = [
        "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64",
        "F32", "F64", "Bool", "Char", "String", "Nothing",
    ]

    /// 注解 → 类型名；元组 / 函数 / 指针 / 泛型不判定（返回 ""）。
    private func typeNameOfAnnotation(_ annotation: TypeAnnotation) -> String {
        switch annotation {
        case .simple(let name, _): return name
        default: return ""
        }
    }

    /// 该名字是否已登记为本模块的具名类型（结构体 / 对象 / trait）。
    private func isNominalTypeName(_ name: String) -> Bool {
        guard !name.isEmpty, let symbol = symbolTable.resolve(name) else { return false }
        switch symbol.kind {
        case .struct, .object, .trait: return true
        default: return false
        }
    }

    /// 该名字是否**确定不是枚举**（内建标量，或本模块已登记的具名类型）。
    private func isDefinitelyNonEnumType(_ name: String) -> Bool {
        if Self.scalarTypeNames.contains(name) { return true }
        return isNominalTypeName(name)
    }

    /// 表达式 → 类型名；判不出返回 ""。
    /// 覆盖：标识符（登记表，其次裸枚举用例）、成员（限定用例 `形.甲`，其次字段声明）、
    /// 构造调用（`形.甲(...)` / `箱(...)`）、四类字面量。
    private func typeNameOf(_ expr: Expression) -> String {
        switch expr {
        case .identifier(let name, _):
            if let recorded = declaredTypes[name], !recorded.isEmpty { return recorded }
            // 裸用例构造 `red`：符号是枚举用例 ⇒ 父枚举（仅单父时可判）
            if let symbol = symbolTable.resolve(name), symbol.kind == .enumCase {
                let parents = enumCaseParents[name] ?? []
                if parents.count == 1 { return parents[0] }
            }
            return ""

        case .member(let obj, let field, _):
            if case .identifier(let owner, _) = obj, enumAllCases[owner]?.contains(field) == true {
                return owner
            }
            let ownerType = typeNameOf(obj)
            if let decl = typeFields[ownerType]?.first(where: { $0.name == field }) {
                return typeNameOfAnnotation(decl.typeAnnotation)
            }
            return ""

        case .call(let callee, _, _):
            if case .member(let obj, let field, _) = callee, case .identifier(let owner, _) = obj,
                enumAllCases[owner]?.contains(field) == true
            {
                return owner
            }
            if case .identifier(let ctor, _) = callee, isNominalTypeName(ctor) { return ctor }
            return ""

        case .integerLiteral: return "I32"
        case .floatLiteral: return "F64"
        case .stringLiteral: return "String"
        case .boolLiteral: return "Bool"
        default: return ""
        }
    }

    /// 声明的类型名：注解优先，其次按初始化式推断；都没结果返回 ""（⇒ 不留登记）。
    private func declaredTypeName(annotation: TypeAnnotation?, initializer: Expression?) -> String {
        if let annotation = annotation {
            let annotated = typeNameOfAnnotation(annotation)
            if !annotated.isEmpty { return annotated }
        }
        if let initializer = initializer { return typeNameOf(initializer) }
        return ""
    }

    /// 写入 / 清除一条声明的类型名（判不出即清除，避免同名旧值残留）。
    private func recordDeclaredType(_ name: String, _ typeName: String) {
        if typeName.isEmpty {
            declaredTypes.removeValue(forKey: name)
        } else {
            declaredTypes[name] = typeName
        }
    }

    // MARK: - R1 穷尽性/可达性检查（D3① 取代 P3 validated 开关）

    /// 穷尽性 / 可达性校验，总是开启，`case _:` 通配兜底豁免。父枚举的唯一判据是被匹配值的类型
    /// （`typeNameOf`）——按 case 名全局反查会把裸值误判成某枚举的 match。已知枚举则逐臂校验可达性
    /// 并查穷尽；确定非枚举则能解析到枚举的臂永不匹配；判不出类型则跳过。另查已知与未知 case 并存。
    private func checkMatchExhaustive(
        value: Expression, cases: [MatchCase], location: SourceLocation
    ) throws {
        var resolvedPatterns: [String] = []
        var unresolvedEnumCases: [MatchCase] = []
        var hasWildcardPattern = false

        for mc in cases {
            switch mc.pattern {
            case .enumCase(let name):
                if (enumCaseParents[name] ?? []).isEmpty {
                    unresolvedEnumCases.append(mc)
                } else {
                    resolvedPatterns.append(name)
                }
            case .wildcard:
                hasWildcardPattern = true
            case .intLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
                break  // 字面量臂不计入覆盖统计；枚举 match 上由 checkEnumMatch 拒绝
            }
        }

        // 合法性：已知 enum case 与未知 enum case 并存 → 未知项大概率是拼写错误
        if !resolvedPatterns.isEmpty && !unresolvedEnumCases.isEmpty {
            let bad = unresolvedEnumCases[0]
            if case .enumCase(let name) = bad.pattern {
                throw SemanticError.unknownMatchCase(caseName: name, location: bad.location)
            }
        }

        let scrutineeType = typeNameOf(value)
        if enumAllCases[scrutineeType] != nil {
            try checkEnumMatch(
                cases: cases, enumName: scrutineeType, resolved: resolvedPatterns,
                hasWildcard: hasWildcardPattern, location: location)
            return
        }

        if isDefinitelyNonEnumType(scrutineeType) {
            for mc in cases {
                if case .enumCase(let name) = mc.pattern, !(enumCaseParents[name] ?? []).isEmpty {
                    throw SemanticError.unknownMatchCase(caseName: name, location: mc.location)
                }
            }
        }
    }

    /// 枚举 match 的两项校验：臂可达性（枚举用例须属本枚举；字面量臂无匹配可能）与穷尽覆盖。
    private func checkEnumMatch(
        cases: [MatchCase], enumName: String, resolved: [String], hasWildcard: Bool,
        location: SourceLocation
    ) throws {
        for mc in cases {
            switch mc.pattern {
            case .wildcard:
                continue
            case .enumCase(let name):
                if !(enumCaseParents[name] ?? []).contains(enumName) {
                    throw SemanticError.unknownMatchCase(caseName: name, location: mc.location)
                }
            case .intLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
                // 被匹配值是枚举 ⇒ 字面量与任何用例都不相等
                throw SemanticError.unknownMatchCase(caseName: mc.pattern.description, location: mc.location)
            }
        }
        let allCases = enumAllCases[enumName] ?? []
        let covered = Set(resolved)
        let missing = allCases.filter { !covered.contains($0) }
        if missing.isEmpty || hasWildcard {
            return
        }
        throw SemanticError.nonExhaustiveMatch(missingCases: missing, location: location)
    }

    private func checkBlock(_ block: Block) throws {
        let savedTypes = declaredTypes
        symbolTable.enterScope(name: "block")
        defer {
            emitUnusedWarnings()  // B2：块作用域结束检测未使用局部变量（参数/顶层/字段/for 模式变量不在本作用域，天然排除）
            declaredTypes = savedTypes
            symbolTable.exitScope()
        }
        for stmt in block.statements {
            try checkStatement(stmt)
        }
    }

    // MARK: - B2 未使用变量检测

    /// 块作用域退出时：对当前作用域内 `kind == .variable` 且未被读取、非 `_`/`_xxx` 前缀的局部变量发 warning。
    private func emitUnusedWarnings() {
        for (name, symbol) in symbolTable.current.symbols {
            guard case .variable = symbol.kind else { continue }
            if name.hasPrefix("_") { continue }
            if usedSymbols.contains(name) { continue }
            warnings.append(.unusedVariable(name: name, location: symbol.location))
        }
    }

    // MARK: - 表达式检查

    private func checkExpression(_ expr: Expression) throws {
        switch expr {
        case .identifier(let name, let location):
            try requireDefined(name, location, isFunction: false)

        case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
            break

        case .stringInterpolation(let segments, _):
            for seg in segments {
                if case .expression(let e) = seg {
                    try checkExpression(e)
                }
            }

        case .binary(let left, _, let right, _):
            try checkExpression(left)
            try checkExpression(right)

        case .unary(_, let operand, _):
            try checkExpression(operand)

        case .tryExpression(let operand, let errorVar, let handler, _):
            // try-else 迁移 迁移批 M2：递归检查 operand；handler 内 errorVar 绑定到子作用域。
            try checkExpression(operand)
            symbolTable.enterScope(name: "try-handler")
            symbolTable.define(Symbol(name: errorVar, kind: .variable(isMutable: true), location: handler.location))
            try checkBlock(handler)
            symbolTable.exitScope()

        case .call(let callee, let arguments, _):
            // 检查是否是未定义的函数调用
            if case .identifier(let name, let location) = callee {
                try requireDefined(name, location, isFunction: true)
            }
            // `别名.符号(...)` 跨模块限定调用——符号存在性 + public 门槛
            if case .member(let objExpr, let memberName, _) = callee,
                case .identifier(let aliasName, let aliasLoc) = objExpr,
                let info = importAliasInfos[aliasName]
            {
                guard info.allSymbols.contains(memberName) else {
                    throw SemanticError.undefinedVariable(name: "\(aliasName).\(memberName)", location: aliasLoc)
                }
                guard info.publicSymbols.contains(memberName) else {
                    throw SemanticError.crossModuleAccessDenied(symbol: "\(aliasName).\(memberName)", location: aliasLoc)
                }
            } else if case .member(let receiver, _, _) = callee {
                // 成员调用的**接收者**必须被检查，否则「只作为
                // 接收者被读」的变量不会被登记为已使用，误报未使用变量。非限定的接收者
                // 是本文件内的表达式，须与独立成员表达式走同一条检查路径。
                try checkExpression(receiver)
            }
            for arg in arguments {
                try checkExpression(arg.expression)
            }

        case .member(let object, _, _):
            // 别名 base 不走本地 requireDefined（限定访问只走跨模块通道）
            if case .identifier(let aliasName, _) = object, importAliasInfos[aliasName] == nil {
                try checkExpression(object)
            }

        case .tupleIndex(let object, _, _):
            // 草稿 A2（批次 1）：`.0` 位置访问——递归检查 object 内的标识符定义。
            try checkExpression(object)

        case .tuple(_, let elements, _):
            for elem in elements {
                try checkExpression(elem)
            }

        case .arrayLiteral(let elements, _):
            for elem in elements { try checkExpression(elem) }

        case .dictionaryLiteral(let entries, _):
            for entry in entries { try checkExpression(entry.key); try checkExpression(entry.value) }

        case .setLiteral(let elements, _):
            for elem in elements { try checkExpression(elem) }

        case .subscript(let container, let index, _):
            try checkExpression(container)
            try checkExpression(index)

        case .funcLiteral(let decl, _):
            symbolTable.enterScope(name: "funcLiteral")
            for param in decl.params {
                symbolTable.define(Symbol(name: param.name, kind: .parameter, location: decl.location))
            }
            // H-1：作用域边界——此之后解析命中点若在边界之外，即为「外层局部」。
            // captured 集**按语句序增量**填充（checkStatement 的 captureStatement 分支），
            // 使「先用后 capture」（①）在语句序上可判定。
            let captureBoundary = symbolTable.current
            if let body = decl.body {
                captureContexts.append((boundary: captureBoundary, captured: []))
                for stmt in body.statements {
                    try checkStatement(stmt)
                }
                captureContexts.removeLast()
            }
            symbolTable.exitScope()

        case .selfKeyword, .selfTypeKeyword:
            break

        case .dotCaseRef(let name, let location):
            // 点号用例构造（成员意图）：名字须为某枚举的用例；本地位遮蔽不影响成员解析
            // （前导点已声明成员归属，期望类型决议在类型层完成，不经 requireDefined）。
            if !enumCaseNames.contains(name) {
                throw SemanticError.undefinedVariable(name: ".\(name)", location: location)
            }

        case .genericConstruct:
            break

        case .join(let inner, _, _):
            try checkExpression(inner)

        case .unsafe(let operand, _):
            // Phase 2a（FFI 子系统）：不安全消耗点——递归检查操作数。
            try checkExpression(operand)
        case .addressOf(let operand, _):
            // Phase 2a（FFI 子系统）：取地址——递归检查操作数。
            try checkExpression(operand)
        }
    }

    /// H-1：可捕获的符号种类——外层局部变量（含外层函数参数）。
    /// 函数/类型/枚举用例等按名字即可引用，不属于「捕获的外部对象」。
    private static func isCapturableKind(_ kind: SymbolKind) -> Bool {
        switch kind {
        case .variable, .parameter: return true
        default: return false
        }
    }

    /// G52 D-2 静态互斥：局部符号不得与 import 别名同名。
    private func checkAliasNameConflict(_ name: String, _ location: SourceLocation) throws {
        if importAliasInfos[name] != nil {
            throw SemanticError.redeclaredSymbol(name: name, location: location)
        }
    }
}
