/// 编译前端：源码 → 词法 → 语法 → pass 清单。六个解析入口（模块装载、CLI 解析、CLI 单文件测试、
/// REPL、DAP、LSP）都从这里取 `Module`，入口自身只决定错误怎么呈现。
/// 不变量：拿到 `Module` 的每条通道都跑过同一份 pass 清单；漏一处的后果不是少一次优化，是那段代码在该通道上不存在。
public enum FrontEnd {

    /// pass 清单。顺序即语义：常量折叠先把字面量算成结果，展开须落在类型检查之前。
    /// 新增 pass 只在这里加一行；六个入口与全部测试助手自动跟上。
    /// 展开失败抛 `UnrollExpander.Failure`——整批错误一起带走，不因第一处停下。
    public static func passes(module: Module) throws(UnrollExpander.Failure) -> Module {
        try UnrollExpander.expand(ConstantFolder.foldConstants(in: module))
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

    /// 一次扫描的完整结果。注释不在 AST 里，只能由词法旁路带回；打印器要保住注释就得拿这份表。
    public struct Scan {
        public let outcome: Outcome
        public let comments: CommentTable
    }

    /// 与 `collect` 同一条路径，额外带回注释表。词法失败时表里是失败点之前的注释。
    public static func scan(source: String, fileName: String) -> Scan {
        let scan = syntaxOnly(source: source, fileName: fileName)
        guard case .parsed(let module) = scan.outcome else { return scan }
        do {
            return Scan(outcome: .parsed(try passes(module: module)), comments: scan.comments)
        } catch {
            return Scan(outcome: .expandFailed(error.errors), comments: scan.comments)
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
            return Scan(outcome: .lexFailed(error), comments: lexer.comments)
        }
        let result = Parser(tokens: tokens, fileName: fileName).parseModuleCollectingErrors()
        guard result.errors.isEmpty else {
            return Scan(outcome: .parseFailed(result.module, result.errors), comments: lexer.comments)
        }
        return Scan(outcome: .parsed(result.module), comments: lexer.comments)
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
