import Foundation

/// 编译前端：源码 → 词法 → 语法 → pass 清单。六个解析入口（模块装载、CLI 解析、CLI 单文件测试、
/// REPL、DAP、LSP）都从这里取 `Module`，入口自身只决定错误怎么呈现。
/// 不变量：拿到 `Module` 的每条通道都跑过同一份 pass 清单；漏一处的后果不是少一次优化，是那段代码在该通道上不存在。
public enum FrontEnd {

    /// 语言内标准库的虚拟文件名。诊断与降载都按它定位；用户源码里不存在同名文件。
    public static let stdlibFileName = "<stdlib>"

    /// pass 清单。顺序即语义：常量折叠先把字面量算成结果，展开须落在类型检查之前。
    /// 新增 pass 只在这里加一行；六个入口与全部测试助手自动跟上。
    /// 展开失败抛 `UnrollExpander.Failure`——整批错误一起带走，不因第一处停下。
    public static func passes(module: Module) throws(UnrollExpander.Failure) -> Module {
        try UnrollExpander.expand(ConstantFolder.foldConstants(in: module))
    }

    /// 装配：标准库并入模块并排在用户声明之前；用户同名扩展摘掉标准库那份——两份同名会在 LLVM 通道重定义。
    /// 幂等：模块已含 `<stdlib>` 声明时原样返回，调用方不必关心自己是不是第一个装配的。
    /// 装配不属于 `passes`：语法与后端测试拿的是给定片段，不是完整程序。
    public static func assemble(module: Module) -> Module {
        guard let prelude = stdlibModule, !prelude.declarations.isEmpty else { return module }
        guard !containsStdlibDeclaration(module) else { return module }
        let claimed = extensionMethodKeys(in: module)
        var declarations: [TopLevelDecl] = []
        for decl in prelude.declarations {
            guard case .extensionDecl(let ext) = decl else {
                declarations.append(decl)
                continue
            }
            let kept = ext.methods.filter {
                !claimed.contains(methodKey(target: ext.targetType, name: $0.name))
            }
            guard !kept.isEmpty else { continue }
            declarations.append(
                .extensionDecl(
                    ExtensionDecl(
                        kind: ext.kind, targetType: ext.targetType, genericParams: ext.genericParams,
                        targetTypeAnnotation: ext.targetTypeAnnotation, methods: kept, location: ext.location)))
        }
        declarations.append(contentsOf: module.declarations)
        return Module(
            declarations: declarations,
            imports: module.imports,
            exports: module.exports,
            location: module.location
        )
    }

    /// 模块是否已含标准库声明。标准库当前只提供扩展块方法，故按扩展块的位置判定。
    private static func containsStdlibDeclaration(_ module: Module) -> Bool {
        for decl in module.declarations {
            guard case .extensionDecl(let ext) = decl else { continue }
            if ext.location.fileName == stdlibFileName { return true }
        }
        return false
    }

    /// 标准库模块：固化的仓内资产，解析一次后复用——REPL 每行都走装配，重复解析没有意义。
    /// 解析失败返回 nil，用户程序按「没有标准库」继续；`StandardLibraryTests` 在构建期把这条通道钉红。
    private static let stdlibModule: Module? = {
        guard let url = Bundle.module.url(forResource: "stdlib", withExtension: "pini"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        guard case .parsed(let module) = syntaxOnly(source: source, fileName: stdlibFileName).outcome else {
            return nil
        }
        return module
    }()

    /// 装配：标准库声明排在用户声明之前，用户扩展块里已有的同名方法从标准库里摘掉。
    /// 摘而不只靠「后声明者覆盖」——扩展方法在 IR 里按 `名__类型` 出符号，两份同名会在 LLVM 通道重定义。
    private static func extensionMethodKeys(in module: Module) -> Set<String> {
        var keys = Set<String>()
        for decl in module.declarations {
            guard case .extensionDecl(let ext) = decl else { continue }
            for method in ext.methods {
                keys.insert(methodKey(target: ext.targetType, name: method.name))
            }
        }
        return keys
    }

    private static func methodKey(target: String, name: String) -> String {
        "\(target)\u{0}\(name)"
    }

    /// 收集模式的结果。`.parseFailed` 带残模：诊断要位置，LSP 还拿它继续跑语义与类型检查。
    /// 有错时不跑 `passes` —— 残缺树进 pass 只会把一处错误变成另一处。
    public enum Outcome {
        case parsed(Module)
        case lexFailed(Error)
        case parseFailed(Module, [ParserError])
        /// 语法过关、展开不过关：`unroll` 的表或体不成立，产物没有可跑的东西。
        case expandFailed([UnrollError])
    }

    /// 收集模式：不抛错，一次带回全部错误。词法错误单列，因为它与语法错误的呈现方式不同。
    public static func collect(source: String, fileName: String) -> Outcome {
        scan(source: source, fileName: fileName).outcome
    }

    /// 一次扫描的完整结果。注释与位置旁路都不在 AST 里，只能由词法带回；打印器要保住原写法就得拿这两份。
    public struct Scan {
        public let outcome: Outcome
        public let comments: CommentTable
        /// 字面量原文与行前导空格。无源模式传 `PrintHints.empty`。
        public let hints: PrintHints

        public init(outcome: Outcome, comments: CommentTable, hints: PrintHints) {
            self.outcome = outcome
            self.comments = comments
            self.hints = hints
        }
    }

    /// 与 `collect` 同一条路径，额外带回注释表。词法失败时表里是失败点之前的注释。
    public static func scan(source: String, fileName: String) -> Scan {
        let scan = syntaxOnly(source: source, fileName: fileName)
        guard case .parsed(let module) = scan.outcome else { return scan }
        do {
            return Scan(outcome: .parsed(try passes(module: module)), comments: scan.comments, hints: scan.hints)
        } catch {
            return Scan(outcome: .expandFailed(error.errors), comments: scan.comments, hints: scan.hints)
        }
    }

    /// 只到语法为止，不跑 pass。`fmt` 走这条：折叠与展开都改写程序，
    /// 打印跑过 pass 的树得到的就不是同一份程序的另一种排版。`.parsed` 在此表示语法过关、树是原样的。
    public static func syntaxOnly(source: String, fileName: String) -> Scan {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens: [Token]
        do {
            tokens = try lexer.tokenize()
        } catch {
            return Scan(outcome: .lexFailed(error), comments: lexer.comments, hints: lexer.hints)
        }
        let result = Parser(tokens: tokens, fileName: fileName).parseModuleCollectingErrors()
        guard result.errors.isEmpty else {
            return Scan(outcome: .parseFailed(result.module, result.errors), comments: lexer.comments, hints: lexer.hints)
        }
        return Scan(outcome: .parsed(result.module), comments: lexer.comments, hints: lexer.hints)
    }

    /// 抛出模式：词法错误原样抛，语法错误抛首条，展开失败抛整批。适用于「有错即中止」的调用点。
    public static func parse(source: String, fileName: String) throws -> Module {
        switch collect(source: source, fileName: fileName) {
        case .parsed(let module): return module
        case .lexFailed(let error): throw error
        case .parseFailed(_, let errors): throw errors[0]
        case .expandFailed(let errors): throw UnrollExpander.Failure(errors: errors)
        }
    }
}
