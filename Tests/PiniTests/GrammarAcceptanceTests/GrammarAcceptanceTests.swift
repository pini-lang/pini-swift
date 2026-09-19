import Foundation
import PiniCore
import Testing

/// 遮蔽 `Testing.Expression`，使本文件内 `Expression` 无歧义地指向 `PiniCore.Expression`。
private typealias Expression = PiniCore.Expression

/// 语法接受面的回归判据（来源：2026-09-05 的规范反录勘测探针语料）。
///
/// 组织：**一个夹具一条用例**，夹具在本文件同目录的 `Fixtures/` 下、文件名即消费它的用例名 ——
/// 于是「有夹具而无用例」与「有用例而无夹具」都能一眼看出（前者另有一条判据机械检查）。
/// ⚠️ 夹具之所以独占一层，是为了让清单能**一条** `exclude` 排掉 SwiftPM 的 unhandled 告警
/// （`exclude` 只能按路径、不能按扩展名）；理由与实测见 `PiniFixtureLoader.swift`。
///
/// 每条用例三要素齐备：意图写在显示名与首行注释；接受态断言解析结构、类型结论与
/// 运行产物（推进性测量）；拒绝态断言错误的**类型与判定码**（驳回性测量）。
/// 判定码取首条诊断 —— 解析器会在根因之后级联补报，首条才是根因。
struct GrammarAcceptanceTests {

    /// 套件目录（夹具在本文件同目录下的 `Fixtures/` 子目录）。
    static var suiteDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").path
    }

    // MARK: - 私有 helper

    private func source(_ name: String) throws -> String {
        try loadPiniFixture(name, filePath: #filePath)
    }

    /// 解析夹具并折叠常量（与命令行 `check` 同序：命令行也在解析后折叠）。
    private func parse(_ name: String) throws -> (module: Module, errors: [ParserError]) {
        let lexer = Lexer(source: try source(name), fileName: name + ".pini")
        let result = Parser(tokens: try lexer.tokenize(), fileName: name + ".pini")
            .parseModuleCollectingErrors()
        return (ConstantFolder.foldConstants(in: result.module), result.errors)
    }

    private func semanticErrors(in module: Module) -> [SemanticError] {
        SemanticAnalyzer().analyzeCollecting(module: module)
    }

    private func typeErrors(in module: Module) -> [TypeError] {
        TypeChecker().checkCollecting(module: module)
    }

    /// 解析 + 语义 + 类型都放行，返回模块；任一层拒绝即抛出首条诊断。
    private func checkedModule(_ name: String) throws -> Module {
        let (module, errors) = try parse(name)
        guard errors.isEmpty else { throw errors[0] }
        let semantic = semanticErrors(in: module)
        guard semantic.isEmpty else { throw semantic[0] }
        let types = typeErrors(in: module)
        guard types.isEmpty else { throw types[0] }
        return module
    }

    /// 运行夹具，返回标准输出逐行。
    ///
    /// 镜像命令行 `run` 的**单文件**路径：解析（含常量折叠）→ 语义门禁 → 类型收集 →
    /// 降载 → 执行。刻意不走包级运行器 —— 它对「没有 main」报的是运行期判定码，
    /// 而命令行报降载判定码，两条入口对同一份夹具给出的结论不同（对账用例会把它抓出来）。
    private func runFixture(_ name: String) throws -> [String] {
        let (module, errors) = try parse(name)
        guard errors.isEmpty else { throw errors[0] }
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = HIRExecutor(programBase: Self.suiteDirectory)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 运行级缺口的判定码；能跑通则返回 nil。
    private func runFailureCode(_ name: String) -> String? {
        do {
            _ = try runFixture(name)
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    private func body(ofFunc funcName: String, in module: Module) -> Block? {
        for decl in module.declarations {
            if case .funcDecl(let f) = decl, f.name == funcName { return f.body }
        }
        return nil
    }

    private func statements(ofMainIn module: Module) -> [Statement] {
        body(ofFunc: "main", in: module)?.statements ?? []
    }

    private func fixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.suiteDirectory)
            .filter { $0.hasSuffix(".pini") }
            .map { String($0.dropLast(".pini".count)) }
            .sorted()
    }

    // MARK: - 尾逗号七形态

    @Test("数组字面量容忍尾逗号")
    func testParserAcceptsTrailingCommaInArrayLiteral() throws {
        /// 意图：`[1, 2,]` 解析为两个元素的数组，且实参表尾逗号不吞参数。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInArrayLiteral")
        #expect(errors.isEmpty, "数组字面量尾逗号应被接受，实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .varDecl(_, _, let initializer, _, _) = statements(ofMainIn: module).first else {
            Issue.record("首条语句应为变量声明"); return
        }
        guard case .arrayLiteral(let elements, _) = initializer else {
            Issue.record("初始化器应为数组字面量，实际：\(String(describing: initializer))"); return
        }
        #expect(elements.count == 2, "尾逗号不应吞元素，实际 \(elements.count) 个")
        #expect(try runFixture("testParserAcceptsTrailingCommaInArrayLiteral") == ["[1, 2]"])
    }

    @Test("实参表与返回元组容忍尾逗号")
    func testParserAcceptsTrailingCommaInCallArguments() throws {
        /// 意图：形参表 `(a: I32, b: I32,)`、返回元组 `(I32, F64,)` 与实参表 `f(1, 2,)` 三处尾逗号都不吞位。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInCallArguments")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .funcDecl(let f) = module.declarations.first else {
            Issue.record("首条声明应为函数 f"); return
        }
        #expect(f.params.count == 2, "形参尾逗号不应吞参，实际 \(f.params.count) 个")
        #expect(f.returnTypes.count == 2, "返回元组尾逗号不应吞类型，实际 \(f.returnTypes.count) 个")
        guard case .expressionStmt(let expr, _) = statements(ofMainIn: module).first,
            case .call(_, let printArgs, _) = expr, printArgs.count == 1,
            case .call(_, let callArgs, _) = printArgs[0].expression
        else {
            Issue.record("应打印一次两层调用"); return
        }
        #expect(callArgs.count == 2, "实参尾逗号不应吞实参，实际 \(callArgs.count) 个")
        #expect(try runFixture("testParserAcceptsTrailingCommaInCallArguments") == ["[1, 1.5]"])
    }

    @Test("字典字面量容忍尾逗号")
    func testParserAcceptsTrailingCommaInDictionaryLiteral() throws {
        /// 意图：`["x" = 1, "y" = 2,]` 解析为两条目的字典字面量。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInDictionaryLiteral")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .varDecl(_, _, let initializer, _, _) = statements(ofMainIn: module).first,
            case .dictionaryLiteral(let entries, _) = initializer
        else {
            Issue.record("初始化器应为字典字面量"); return
        }
        #expect(entries.count == 2, "尾逗号不应吞条目，实际 \(entries.count) 条")
        #expect(try runFixture("testParserAcceptsTrailingCommaInDictionaryLiteral") == ["{x: 1, y: 2}"])
    }

    @Test("集合字面量容忍尾逗号")
    func testParserAcceptsTrailingCommaInSetLiteral() throws {
        /// 意图：`{1, 2,}` 解析为两个元素的集合字面量。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInSetLiteral")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .varDecl(_, _, let initializer, _, _) = statements(ofMainIn: module).first,
            case .setLiteral(let elements, _) = initializer
        else {
            Issue.record("初始化器应为集合字面量"); return
        }
        #expect(elements.count == 2, "尾逗号不应吞元素，实际 \(elements.count) 个")
        #expect(try runFixture("testParserAcceptsTrailingCommaInSetLiteral") == ["{1, 2}"])
    }

    @Test("类型注解元组容忍尾逗号")
    func testParserAcceptsTrailingCommaInTypeAnnotationTuple() throws {
        /// 意图：类型位 `(I32, F64,)` 与字面量位 `(1, 2.5,)` 两处尾逗号都不吞位。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInTypeAnnotationTuple")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .varDecl(_, let annotation, let initializer, _, _) = statements(ofMainIn: module).first else {
            Issue.record("首条语句应为变量声明"); return
        }
        guard case .tuple(_, let annotatedElements, _) = annotation else {
            Issue.record("类型标注应为元组，实际：\(String(describing: annotation))"); return
        }
        #expect(annotatedElements.count == 2, "类型位尾逗号不应吞位")
        guard case .tuple(_, let literalElements, _) = initializer else {
            Issue.record("初始化器应为元组字面量"); return
        }
        #expect(literalElements.count == 2, "字面量位尾逗号不应吞位")
        #expect(try runFixture("testParserAcceptsTrailingCommaInTypeAnnotationTuple") == ["[1, 2.5]"])
    }

    @Test("函数类型标注容忍尾逗号")
    func testParserAcceptsTrailingCommaInFunctionType() throws {
        /// 意图：`let h: (I32,) -> (F64,) = func (a: I32,) -> (F64,):` 的四处尾逗号都不吞位。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInFunctionType")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .varDecl(_, let annotation, let initializer, _, _) = statements(ofMainIn: module).first else {
            Issue.record("首条语句应为变量声明"); return
        }
        guard case .function(let params, let returns, _, _, _) = annotation else {
            Issue.record("类型标注应为函数类型，实际：\(String(describing: annotation))"); return
        }
        #expect(params.count == 1 && returns.count == 1, "函数类型两侧尾逗号都不应吞位")
        guard case .funcLiteral(let decl, _) = initializer else {
            Issue.record("初始化器应为匿名函数"); return
        }
        #expect(decl.params.count == 1 && decl.returnTypes.count == 1, "匿名函数两侧尾逗号都不应吞位")
        #expect(try runFixture("testParserAcceptsTrailingCommaInFunctionType") == ["1.5"])
    }

    @Test("泛型实参加实参表容忍尾逗号")
    func testParserAcceptsTrailingCommaInGenericCall() throws {
        /// 意图：`f<I32>(a = 1, b = 2,)` 解析为泛型构造，实参尾逗号不吞参。
        let (module, errors) = try parse("testParserAcceptsTrailingCommaInGenericCall")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        guard case .expressionStmt(let expr, _) = statements(ofMainIn: module).first,
            case .call(_, let printArgs, _) = expr,
            case .genericConstruct(let typeName, let typeArgs, let arguments, _) = printArgs[0].expression
        else {
            Issue.record("应为打印一次泛型构造调用"); return
        }
        #expect(typeName == "f")
        #expect(typeArgs.count == 1, "泛型实参不应被尾逗号吞掉")
        #expect(arguments.count == 2, "实参尾逗号不应吞参，实际 \(arguments.count) 个")
        // 运行级：显式泛型实参尚未降载，以判定码记账（缺口合拢时本条会转红，提示更新期望）。
        #expect(runFailureCode("testParserAcceptsTrailingCommaInGenericCall") == "E6-004")
    }

    // MARK: - 调用位标签

    @Test("调用位标签取 `=`")
    func testParserTakesCallArgumentLabelFromEquals() throws {
        /// 意图：`f(a = 1, b = 2)` 的标签被解析为具名实参，而不是赋值表达式。
        let module = try checkedModule("testParserTakesCallArgumentLabelFromEquals")
        guard case .funcDecl(let f) = module.declarations.first else {
            Issue.record("首条声明应为函数 f"); return
        }
        #expect(f.params.count == 2)
        guard case .expressionStmt(let expr, _) = statements(ofMainIn: module).first,
            case .call(_, let printArgs, _) = expr,
            case .call(_, let arguments, _) = printArgs[0].expression
        else {
            Issue.record("应为打印一次调用 f"); return
        }
        let labels = arguments.map(\.label)
        #expect(labels == ["a", "b"], "实参标签应取 `=` 左侧的名字，实际 \(labels)")
        #expect(try runFixture("testParserTakesCallArgumentLabelFromEquals") == ["1"])
    }

    @Test("调用位标签用 `:` 被拒")
    func testParserRejectsColonCallArgumentLabel() throws {
        /// 意图：旧写法 `f(a: 1, b: 2)` 被拒，且报的是表达式无效而不是静默当赋值。
        let (_, errors) = try parse("testParserRejectsColonCallArgumentLabel")
        guard case .invalidExpression(let reason, _) = errors.first else {
            Issue.record("首条应为 invalidExpression，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-006")
        #expect(reason.contains("="), "报错应指向 `=` 记法，实际：\(reason)")
    }

    // MARK: - 元组解构

    @Test("`var` 解构声明被接受")
    func testParserAcceptsVarDestructure() throws {
        /// 意图：`var (t, e) = f()` 解析为可变解构声明，两位名字按序绑定。
        let module = try checkedModule("testParserAcceptsVarDestructure")
        guard
            case .varDestructure(let names, _, let initializer, let mutable, _) =
                statements(ofMainIn: module).first
        else {
            Issue.record("首条语句应为解构声明"); return
        }
        #expect(names == ["t", "e"])
        #expect(mutable, "`var` 解构应可变")
        guard case .call(_, let arguments, _) = initializer else {
            Issue.record("解构右值应为调用 f"); return
        }
        #expect(arguments.isEmpty)
        #expect(try runFixture("testParserAcceptsVarDestructure") == ["1", "2.5"])
    }

    @Test("`let` 解构声明被接受")
    func testParserAcceptsLetDestructure() throws {
        /// 意图：`let (t, e) = f()` 与 `var` 形态同一节点，仅可变性不同。
        let module = try checkedModule("testParserAcceptsLetDestructure")
        guard
            case .varDestructure(let names, _, _, let mutable, _) =
                statements(ofMainIn: module).first
        else {
            Issue.record("首条语句应为解构声明"); return
        }
        #expect(names == ["t", "e"])
        #expect(!mutable, "`let` 解构应不可变")
        #expect(try runFixture("testParserAcceptsLetDestructure") == ["1", "2.5"])
    }

    @Test("解构声明缺初始值被拒")
    func testParserRejectsDestructureWithoutInitializer() throws {
        /// 意图：`var (p, q)` 单独成句被拒 —— 解构必须给出右值。
        let (_, errors) = try parse("testParserRejectsDestructureWithoutInitializer")
        guard case .invalidStatement = errors.first else {
            Issue.record("首条应为 invalidStatement，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-007")
    }

    // MARK: - 后缀强制解包与 unsafe 上下文

    @Test("unsafe 上下文内的强制解包被接受")
    func testParserAcceptsForceUnwrapInsideUnsafeContext() throws {
        /// 意图：`unsafe (x!)` 解析为 unsafe 消耗点包住后缀 `!`，且类型层放行。
        let module = try checkedModule("testParserAcceptsForceUnwrapInsideUnsafeContext")
        guard case .varDecl(_, _, let initializer, _, _) = statements(ofMainIn: module)[1],
            case .unsafe(let operand, _) = initializer,
            case .unary(let op, let target, _) = operand
        else {
            Issue.record("第二条语句应为 unsafe 包住后缀 `!`"); return
        }
        #expect(op == .forceUnwrap, "后缀 `!` 应落在 forceUnwrap 上，实际 \(op)")
        guard case .identifier(let name, _) = target else {
            Issue.record("操作数应为标识符 x"); return
        }
        #expect(name == "x")
        // 运行级：forceUnwrap 尚未降载，以判定码记账。
        #expect(runFailureCode("testParserAcceptsForceUnwrapInsideUnsafeContext") == "E6-004")
    }

    @Test("非 unsafe 上下文的强制解包被类型层拒绝")
    func testTypeCheckerRejectsForceUnwrapOutsideUnsafeContext() throws {
        /// 意图：`let v = x!` 在安全上下文里被类型层拒绝（与 `&` 取址同构的门禁）。
        let (module, errors) = try parse("testTypeCheckerRejectsForceUnwrapOutsideUnsafeContext")
        #expect(errors.isEmpty, "拒绝应发生在类型层，而不是解析层")
        #expect(semanticErrors(in: module).isEmpty, "拒绝应发生在类型层，而不是语义层")
        let types = typeErrors(in: module)
        guard case .mismatch(let expected, let got, _) = types.first else {
            Issue.record("首条应为 mismatch，实际：\(String(describing: types.first))"); return
        }
        #expect(types.first?.diagnosticCode == "E4-001")
        #expect(expected.contains("unsafe"), "期望值应点明 unsafe 上下文，实际：\(expected)")
        #expect(got.contains("forceUnwrap") || got.contains("强制解包"), "实际值应点明强制解包，实际：\(got)")
    }

    @Test("`unsafe (复合表达式)` 前缀被接受")
    func testParserAcceptsUnsafeCompoundExpression() throws {
        /// 意图：`unsafe (1 + 2)` 解析为 unsafe 消耗点，常量折叠后操作数为字面量 3。
        let module = try checkedModule("testParserAcceptsUnsafeCompoundExpression")
        guard case .varDecl(_, _, let initializer, _, _) = statements(ofMainIn: module).first,
            case .unsafe(let operand, _) = initializer,
            case .integerLiteral(let value, _) = operand
        else {
            Issue.record("初始化器应为 unsafe 包住折叠后的字面量"); return
        }
        #expect(value == 3, "复合表达式应折叠为 3，实际 \(value)")
        #expect(try runFixture("testParserAcceptsUnsafeCompoundExpression") == ["3"])
    }

    // MARK: - 类型体与扩展块

    @Test("类型体带 trait 约束被拒")
    func testParserRejectsConstraintOnStructBody() throws {
        /// 意图：`(盒<T>:显示)` 被拒 —— 约束写在扩展块位，不写在类型体位。
        let (_, errors) = try parse("testParserRejectsConstraintOnStructBody")
        guard case .unexpectedToken(let expected, let actual, _) = errors.first else {
            Issue.record("首条应为 unexpectedToken，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-001")
        #expect(actual == ":", "拒绝点应是 `:`，实际 \(actual)（期望 \(expected)）")
    }

    @Test("扩展块带 trait 约束被接受")
    func testParserAcceptsExtensionConstraint() throws {
        /// 意图：`((盒:显示))` 解析为扩展块，约束被记入扩展声明的目标类型标注。
        let (module, errors) = try parse("testParserAcceptsExtensionConstraint")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        #expect(semanticErrors(in: module).isEmpty)
        #expect(typeErrors(in: module).isEmpty)
        guard case .extensionDecl(let ext) = module.declarations.last else {
            Issue.record("末条声明应为扩展块"); return
        }
        #expect(ext.targetType == "盒")
        #expect(ext.targetTypeAnnotation != nil, "约束应被记入目标类型标注")
        #expect(ext.methods.count == 1)
    }

    @Test("泛型扩展块带 trait 约束被接受")
    func testParserAcceptsGenericExtensionConstraint() throws {
        /// 意图：`((取值<T>:显示))` 同时带泛型形参与约束，两项都不吞掉方法。
        let (module, errors) = try parse("testParserAcceptsGenericExtensionConstraint")
        #expect(errors.isEmpty, "实际首条：\(errors.first.map(String.init(describing:)) ?? "无")")
        #expect(semanticErrors(in: module).isEmpty)
        #expect(typeErrors(in: module).isEmpty)
        guard case .extensionDecl(let ext) = module.declarations.last else {
            Issue.record("末条声明应为扩展块"); return
        }
        #expect(ext.targetType.hasPrefix("取值"), "目标类型应为 取值，实际 \(ext.targetType)")
        #expect(ext.targetTypeAnnotation != nil, "约束应被记入目标类型标注")
        #expect(ext.methods.count == 1, "泛型形参与约束都不应吞掉方法")
    }

    @Test("泛型类型体与泛型扩展块被接受")
    func testParserAcceptsGenericExtensionBlock() throws {
        /// 意图：`(盒<T>)` 与 `((取值<T>))` 两块的泛型形参都落在各自声明上。
        let module = try checkedModule("testParserAcceptsGenericExtensionBlock")
        guard case .structDecl(let box) = module.declarations.first else {
            Issue.record("首条声明应为类型体 盒"); return
        }
        #expect(box.genericParams.count == 1, "类型体的泛型形参不应被吞掉")
        guard case .extensionDecl(let ext) = module.declarations.last else {
            Issue.record("末条声明应为扩展块"); return
        }
        #expect(ext.targetType.hasPrefix("取值"), "扩展目标应为 取值，实际 \(ext.targetType)")
        #expect(ext.methods.count == 1)
    }

    @Test("扩展未声明类型被接受（带约束）")
    func testParserAcceptsConstraintOnUndeclaredExtensionTarget() throws {
        /// 意图：语言面与扩展目标类型均未声明时仍放行 —— 记录这一宽松面，不是给它背书。
        let module = try checkedModule("testParserAcceptsConstraintOnUndeclaredExtensionTarget")
        #expect(module.declarations.count == 1, "本夹具只有一个扩展块，目标类型与约束都未声明")
        guard case .extensionDecl(let ext) = module.declarations.first else {
            Issue.record("唯一声明应为扩展块"); return
        }
        #expect(ext.targetType == "盒")
        #expect(ext.targetTypeAnnotation != nil, "约束应被记入目标类型标注")
    }

    @Test("扩展未声明类型被接受（不带约束）")
    func testParserAcceptsExtensionWithoutDeclaredTarget() throws {
        /// 意图：与带约束的姊妹夹具成对 —— 无约束时目标类型标注应为空，证明该字段确实承载约束。
        let module = try checkedModule("testParserAcceptsExtensionWithoutDeclaredTarget")
        #expect(module.declarations.count == 1)
        guard case .extensionDecl(let ext) = module.declarations.first else {
            Issue.record("唯一声明应为扩展块"); return
        }
        #expect(ext.targetType == "盒")
        #expect(ext.targetTypeAnnotation == nil, "无约束时目标类型标注应为空")
    }

    // MARK: - trait 块终止性

    @Test("trait 块后的类型体被解析（抽象方法）")
    func testParserClosesTraitBodyBeforeStructDecl() throws {
        /// 意图：抽象方法的 trait 块之后接类型体，两条顶级声明都要在（此前的解析失败点）。
        let module = try checkedModule("testParserClosesTraitBodyBeforeStructDecl")
        #expect(module.declarations.count == 2, "trait 块应在其后的类型体之前闭合")
        guard case .traitDecl(let trait) = module.declarations.first,
            case .structDecl(let box) = module.declarations.last
        else {
            Issue.record("应为 trait 块加类型体"); return
        }
        #expect(trait.name == "显示")
        #expect(trait.signatures.count == 1)
        #expect(trait.signatures.first?.body == nil, "抽象方法应无体")
        #expect(box.name == "盒")
        #expect(box.fields.count == 1)
    }

    @Test("trait 块后的类型体被解析（带方法体）")
    func testParserClosesTraitBodyWithMethodBeforeStructDecl() throws {
        /// 意图：与抽象方法的姊妹夹具成对 —— 方法带体时 trait 块同样要能闭合。
        let module = try checkedModule("testParserClosesTraitBodyWithMethodBeforeStructDecl")
        #expect(module.declarations.count == 2)
        guard case .traitDecl(let trait) = module.declarations.first,
            case .structDecl = module.declarations.last
        else {
            Issue.record("应为 trait 块加类型体"); return
        }
        #expect(trait.signatures.count == 1)
        #expect(trait.signatures.first?.body != nil, "本夹具的方法应带体")
    }

    // MARK: - foreign 声明

    @Test("foreign 元组返回形态被接受")
    func testParserAcceptsForeignTupleReturnForm() throws {
        /// 意图：`malloc(大小: I64,) -> (*I8,)` 的返回位写元组，且块内函数自动 unsafe。
        let module = try checkedModule("testParserAcceptsForeignTupleReturnForm")
        guard case .foreignDecl(let foreign) = module.declarations.first else {
            Issue.record("唯一声明应为 foreign 块"); return
        }
        #expect(foreign.name == "libc")
        guard let malloc = foreign.funcs.first else {
            Issue.record("foreign 块内应有 malloc"); return
        }
        #expect(malloc.name == "malloc")
        #expect(malloc.modifiers.contains("unsafe"), "块内函数应自动标记 unsafe，实际 \(malloc.modifiers)")
        guard case .pointer(let element, _) = malloc.returnTypes.first else {
            Issue.record("返回类型应为指针，实际：\(String(describing: malloc.returnTypes.first))"); return
        }
        guard case .simple(let elementName, _) = element else {
            Issue.record("指针元素应为简单类型"); return
        }
        #expect(elementName == "I8")
    }

    @Test("draft foreign 形态被拒")
    func testParserRejectsDraftForeignSignatureForm() throws {
        /// 意图：`malloc|unsafe(大小: I64) -> *I8` 被拒 —— 单类型返回位不合法。
        let (_, errors) = try parse("testParserRejectsDraftForeignSignatureForm")
        guard case .unexpectedToken(_, let actual, _) = errors.first else {
            Issue.record("首条应为 unexpectedToken，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-001")
        #expect(actual == "*", "拒绝点应落在单类型返回位，实际 \(actual)")
    }

    // MARK: - 限定 case 模式与返回糖

    @Test("match 模式位的限定写法被拒")
    func testParserRejectsQualifiedCasePattern() throws {
        /// 意图：`case 形状.圆(r)` 被拒 —— 点号用例构造不在 match 模式位。
        let (_, errors) = try parse("testParserRejectsQualifiedCasePattern")
        guard case .unexpectedToken(_, let actual, _) = errors.first else {
            Issue.record("首条应为 unexpectedToken，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-001")
        #expect(actual == ".", "拒绝点应落在限定符上，实际 \(actual)")
    }

    @Test("单类型返回糖被拒")
    func testParserRejectsSingleTypeReturnSugar() throws {
        /// 意图：`f|func() -> I32` 被拒 —— 返回位必须写成元组，该草稿意图未落地。
        let (_, errors) = try parse("testParserRejectsSingleTypeReturnSugar")
        guard case .unexpectedToken(let expected, let actual, _) = errors.first else {
            Issue.record("首条应为 unexpectedToken，实际：\(String(describing: errors.first))"); return
        }
        #expect(errors.first?.diagnosticCode == "E2-001")
        #expect(expected == "(" && actual == "I32", "应在返回位要求元组，实际期望 \(expected) / 实际 \(actual)")
    }

    // MARK: - 模块解析

    @Test("导入不存在的模块根被语义层拒绝")
    func testSemanticRejectsImportOfMissingModuleRoot() throws {
        /// 意图：import 块头名合法的前提下，导入目标不存在时由模块解析报错（与语法无关）。
        let (module, errors) = try parse("testSemanticRejectsImportOfMissingModuleRoot")
        #expect(errors.isEmpty, "失败应发生在模块解析阶段，而不是语法阶段")
        let semantic = semanticErrors(in: module)
        guard case .moduleRootMissing = semantic.first else {
            Issue.record("首条应为 moduleRootMissing，实际：\(String(describing: semantic.first))"); return
        }
        #expect(semantic.first?.diagnosticCode == "E3-011")
    }

    // MARK: - 执行产物

    @Test("while 的 step 块每轮迭代后执行")
    func testRunExecutesWhileStepBlockAfterEachIteration() throws {
        /// 意图：step 块不是装饰 —— 计数器在 step 里自增，程序因此迭代三次并终止。
        let module = try checkedModule("testRunExecutesWhileStepBlockAfterEachIteration")
        guard
            case .whileStatement(let condition, let body, let step, _, _) =
                module.declarations.first.map({ _ in statements(ofMainIn: module) })?[1]
        else {
            Issue.record("第二条语句应为 while"); return
        }
        #expect(step != nil, "step 块应被解析并挂在 while 上")
        #expect(body.statements.count == 1)
        guard case .binary(_, let op, _, _) = condition else {
            Issue.record("循环条件应为二元运算"); return
        }
        #expect(op == .lessThan)
        #expect(try runFixture("testRunExecutesWhileStepBlockAfterEachIteration") == ["0", "1", "2"])
    }

    // MARK: - 语料自身的闭合判据

    @Test("每个夹具都被一条用例消费")
    func testEveryFixtureIsConsumedByATest() throws {
        /// 意图：夹具名必须等于消费它的用例名，否则该夹具是孤儿（改了名或删了用例都会在此显形）。
        let names = try fixtureNames()
        #expect(!names.isEmpty, "套件目录里没有夹具：\(Self.suiteDirectory)")
        let ownSource = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        for name in names {
            #expect(ownSource.contains("func \(name)("), "\(name).pini：没有同名用例消费它")
        }
    }

    @Test("命令行与进程内前端逐夹具结论一致")
    func testCommandLineAgreesWithTheFrontEndOnEveryFixture() throws {
        /// 意图：两侧对同一夹具必须给出同一结论 —— 钉住命令行的接线，绝对值另由各夹具的用例钉住。
        let names = try fixtureNames()
        guard let cli = ProcessInfo.processInfo.environment["PINI_CLI_BIN"], !cli.isEmpty else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ 命令行面本次未参与核对（0/\(names.count) 条）") {
                Issue.record("这批结论只由进程内前端得出，命令行接线未参与核对")
            }
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: cli), "PINI_CLI_BIN 不可执行：\(cli)")

        var verdicts: [String] = []
        var runAgreements = 0
        for name in names {
            let path = Self.suiteDirectory + "/" + name + ".pini"
            let checked = try launch(cli, ["check", path])
            let fromCLI =
                checked.status == 0
                ? "accept"
                : "reject " + (firstCode(in: checked.stderr) ?? "?")
            let inProcess = checkedVerdict(name)
            #expect(inProcess == fromCLI, "\(name)：进程内 \(inProcess) ≠ 命令行 \(fromCLI)")
            verdicts.append(inProcess)

            let ran = try launch(cli, ["run", path])
            let ranInProcess = runVerdict(name)
            let fromCLIRun =
                ran.status == 0
                ? "ok " + ran.stdout.split(separator: "\n").joined(separator: "|")
                : "fail " + (firstCode(in: ran.stderr) ?? "?")
            #expect(ranInProcess == fromCLIRun, "\(name)：运行级 进程内 \(ranInProcess) ≠ 命令行 \(fromCLIRun)")
            if ranInProcess.hasPrefix("ok ") { runAgreements += 1 }
        }
        // 非退化：两臂全「接受」会掩盖「两边都没真的跑起来」这类共同失败。
        #expect(verdicts.contains("accept"), "没有任何夹具被接受 ⇒ 两臂可能都没跑起来")
        #expect(verdicts.contains { $0.hasPrefix("reject") }, "没有任何夹具被拒 ⇒ 同上")
        #expect(runAgreements > 0, "没有任何夹具真的跑出产物 ⇒ 运行级对账是空转")
    }

    // MARK: - 命令行对账 helper

    private func checkedVerdict(_ name: String) -> String {
        do {
            _ = try checkedModule(name)
            return "accept"
        } catch {
            return "reject " + ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?")
        }
    }

    private func runVerdict(_ name: String) -> String {
        do {
            return "ok " + (try runFixture(name)).joined(separator: "|")
        } catch {
            return "fail "
                + ((error as? any DiagnosticProviding)?.diagnosticCode
                    ?? String(describing: type(of: error)))
        }
    }

    private func launch(_ executable: String, _ arguments: [String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    /// 命令行诊断里的首条判定码，与进程内「首条即根因」同口径。
    private func firstCode(in stderr: String) -> String? {
        guard let range = stderr.range(of: #"\[E[0-9]+-[0-9]+\]"#, options: .regularExpression) else {
            return nil
        }
        return String(stderr[range].dropFirst().dropLast())
    }
}
