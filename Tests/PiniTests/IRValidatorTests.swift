import Foundation
import Testing
import PiniSyntax

@testable import PiniCore
@testable import PiniHost
@testable import PiniIR
@testable import PiniSemantics

/// 验证器的判据分两面：阳性面是「真程序降载出来必须零违约」（含全部示例的巡检），
/// 阴性面是「每条规则各有一条手搭的违约 IR 能触发它」。只测阳性面的话，规则全删了也是绿的。
@Suite("IR 结构验证器")
struct IRValidatorTests: Sendable, PiniSourceLowering {

    // MARK: - 夹具

    /// 手搭的最小模块：一个 `main`，语句由调用方给。阴性夹具只关心形状，不关心它能不能跑。
    private func handBuilt(
        _ statements: [IRStmt], returnType: IRType? = nil, types: [IRTypeDecl] = [],
        enums: [IREnumDecl] = [], isAsync: Bool = false, positions: [PiniSyntax.SourceLocation] = []
    ) -> IRModule {
        let body = IRBlock(statements, positions: positions)
        let main = IRFunction(
            name: "main", params: [], returnType: returnType, body: body, isAsync: isAsync)
        return IRModule(functions: [main], types: types, enums: enums)
    }

    private func rules(_ module: IRModule) -> Set<IRValidator.Rule> {
        Set(IRValidator.validate(module).map(\.rule))
    }

    // MARK: - 阳性面

    @Test("降载出来的程序零违约：变量、分支、循环、闭包、集合、match")
    func loweredProgramIsClean() throws {
        let module = try lowered(
            #"""
            (盒子)
            v: I32

            ((盒子))
            读|self() -> (I32,):
                return self.v

            任务|func() => (I32,):
                return ok(7)

            main|func() -> ():
                var xs = [1, 2, 3]
                var total = 0
                for (x,) in xs:
                    total = total + x
                if total > 5:
                    print(total)
                else:
                    print(0)
                var sq = func (n,) -> (I32,):
                    return n * n
                print(sq(3))
                var box = 盒子()
                box.v = 1
                print(box.读())
                var h = 任务()
                var r = wait h
                match r:
                    case ok(v):
                        print(v)
                    case err(e):
                        print(e)
                return
            """#)
        #expect(IRValidator.validate(module).isEmpty)
    }

    @Test("示例巡检：examples 下每个 .pini 降载后零违约")
    func examplesAreClean() throws {
        let directory = PiniTestEnvironment.repositoryRoot.appendingPathComponent("examples")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".pini") }
            .sorted()
        #expect(names.count > 40, "示例目录没读到：巡检空跑就等于没测")
        var failures: [String] = []
        for name in names {
            let path = directory.appendingPathComponent(name)
            let source = try String(contentsOf: path, encoding: .utf8)
            do {
                let issues = IRValidator.validate(try lowered(source))
                if !issues.isEmpty {
                    failures.append("\(name): \(issues.map(\.description).joined(separator: "；"))")
                }
            } catch {
                /// 降载本身被门控挡下的示例不算违约：那是能力缺口，不是结构坏了。
                continue
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: - 阴性面：逐规则

    @Test("读一个不存在的名字 ⇒ undeclared-variable")
    func undeclaredVariable() {
        let module = handBuilt([.exprStmt(.load(name: "x", type: .i32))])
        #expect(rules(module) == [.undeclaredVariable])
    }

    @Test("赋值给不存在的名字 ⇒ undeclared-variable")
    func undeclaredStore() {
        let module = handBuilt([
            .storeVar(
                name: "y", type: .i32, value: .intConst(value: 1, type: .i32), adopt: .none,
                releaseOld: false)
        ])
        #expect(rules(module) == [.undeclaredVariable])
    }

    @Test("try 的 ok 目标没分配 ⇒ undeclared-target")
    func undeclaredTryTarget() {
        let result = IRType.result(ok: .i32)
        let module = handBuilt([
            .tryStmt(
                operand: .resultConstruct(
                    isOk: true, payload: .intConst(value: 1, type: .i32), errorBaseCode: 0, errorTagged: false, errorCodes: nil, type: result),
                errorVar: "e",
                handler: IRBlock([.returnStmt(value: nil, adopt: .none)]),
                okTarget: "缺",
                type: result)
        ])
        #expect(rules(module) == [.undeclaredTarget])
    }

    @Test("ok 构造的 type 不是 Result ⇒ node-shape")
    func resultConstructShape() {
        let module = handBuilt([
            .exprStmt(
                .resultConstruct(
                    isOk: true, payload: .intConst(value: 1, type: .i32), errorBaseCode: 0, errorTagged: false, errorCodes: nil, type: .i32))
        ])
        #expect(rules(module) == [.nodeShape])
    }

    @Test("构造一个未登记的具名类型 ⇒ unknown-nominal")
    func unknownNominal() {
        let module = handBuilt([.exprStmt(.construct(type: .nominal(name: "盒", isObject: false)))])
        #expect(rules(module) == [.unknownNominal])
    }

    @Test("读一个声明里没有的字段 ⇒ unknown-field")
    func unknownField() {
        let decl = IRTypeDecl(name: "盒", isObject: false, fields: [], methods: [])
        let module = handBuilt(
            [
                .exprStmt(
                    .fieldGet(
                        base: .construct(type: .nominal(name: "盒", isObject: false)), field: "缺",
                        type: .i32))
            ], types: [decl])
        #expect(rules(module) == [.unknownField])
    }

    @Test("用例绑定的元数超过载荷槽数 ⇒ enum-payload-arity")
    func enumPayloadArity() {
        let decl = IREnumDecl(
            name: "形状",
            cases: [
                IREnumCase(name: "点", tag: 0, paramNames: [nil], payloadTypes: [.i32])
            ])
        let module = handBuilt(
            [
                .exprStmt(
                    .enumConstruct(
                        enumName: "形状", caseName: "点", tag: 0,
                        payloads: [
                            .intConst(value: 1, type: .i32), .intConst(value: 2, type: .i32),
                        ],
                        payloadTypes: [.i32, .i32], type: .enumeration(name: "形状")))
            ], enums: [decl])
        #expect(rules(module) == [.enumPayloadArity])
    }

    @Test("枚举构造的用例名不在声明里 ⇒ unknown-enum-case")
    func unknownEnumCase() {
        let decl = IREnumDecl(
            name: "形状",
            cases: [IREnumCase(name: "点", tag: 0, paramNames: [], payloadTypes: [])])
        let module = handBuilt(
            [
                .exprStmt(
                    .enumConstruct(
                        enumName: "形状", caseName: "线", tag: 0, payloads: [], payloadTypes: [],
                        type: .enumeration(name: "形状")))
            ], enums: [decl])
        #expect(rules(module) == [.unknownEnumCase])
    }

    @Test("match 的分支名不在枚举里 ⇒ match-case")
    func unknownMatchCase() {
        let decl = IREnumDecl(
            name: "形状",
            cases: [IREnumCase(name: "点", tag: 0, paramNames: [], payloadTypes: [])])
        let module = handBuilt(
            [
                .exprStmt(.construct(type: .nominal(name: "盒", isObject: false))),
                .matchStmt(
                    scrutinee: .enumConstruct(
                        enumName: "形状", caseName: "点", tag: 0, payloads: [], payloadTypes: [],
                        type: .enumeration(name: "形状")),
                    cases: [
                        IRMatchCase(caseName: "线", bindings: [], body: IRBlock([]))
                    ],
                    scrutineeType: .enumeration(name: "形状")),
            ], enums: [decl])
        #expect(rules(module).contains(.matchCase))
    }

    @Test("顶层 break 的深度越过任何帧 ⇒ control-flow-depth")
    func breakDepth() {
        let module = handBuilt([.breakStmt(depth: 2)])
        #expect(rules(module) == [.controlFlowDepth])
    }

    @Test("闭包捕获一个看不见的名字 ⇒ capture-visibility")
    func captureVisibility() {
        let module = handBuilt([
            .exprStmt(
                .closureLiteral(
                    id: 1, paramNames: [], paramTypes: [], returnType: nil,
                    captures: [IRCapture(name: "外层", type: .i32)],
                    body: IRBlock([]),
                    type: .function(params: [], returnType: nil, usingIndices: [])))
        ])
        #expect(rules(module) == [.captureVisibility])
    }

    @Test("初值类型与槽类型不符 ⇒ type-mismatch")
    func initializerTypeMismatch() {
        let module = handBuilt([
            .allocVar(
                name: "x", type: .i32, mutable: true,
                initializer: .stringConst(value: "字"), adopt: .none)
        ])
        #expect(rules(module) == [.typeMismatch])
    }

    @Test("位置表与语句表不等长 ⇒ block-positions")
    func blockPositions() {
        let location = PiniSyntax.SourceLocation(line: 2, column: 1, fileName: "inline.pini")
        let module = handBuilt(
            [.exprStmt(.intConst(value: 1, type: .i32))],
            positions: [location, location])
        #expect(rules(module) == [.blockPositions])
    }

    @Test("异步函数的返回类型不是 Result ⇒ async-body")
    func asyncBody() {
        let module = handBuilt([], returnType: .i32, isAsync: true)
        #expect(rules(module) == [.asyncBody])
    }

    @Test("wait 一个既非句柄也非 Result 的值 ⇒ join-shape")
    func joinShape() {
        let module = handBuilt([
            .allocVar(
                name: "x", type: .i32, mutable: true, initializer: .intConst(value: 1, type: .i32),
                adopt: .none),
            .returnStmt(
                value: .join(future: .load(name: "x", type: .i32), type: .result(ok: .i32), form: .waits),
                adopt: .none),
        ], returnType: .result(ok: .i32))
        #expect(rules(module) == [.joinShape])
    }

    @Test("await 一个已结算的 Result ⇒ join-shape")
    func awaitOnSettledResult() {
        let result = IRType.result(ok: .i32)
        let module = handBuilt([
            .allocVar(
                name: "r", type: result, mutable: true,
                initializer: .resultConstruct(
                    isOk: true, payload: .intConst(value: 1, type: .i32), errorBaseCode: 0, errorTagged: false, errorCodes: nil, type: result),
                adopt: .none),
            .returnStmt(
                value: .join(future: .load(name: "r", type: result), type: result, form: .awaits),
                adopt: .none),
        ], returnType: result)
        #expect(rules(module) == [.joinShape])
    }

    @Test("函数值引用一个不存在的函数 ⇒ closure-shape")
    func unknownFunctionValue() {
        let module = handBuilt([
            .exprStmt(
                .functionValue(
                    functionName: "缺",
                    type: .function(params: [], returnType: nil, usingIndices: [])))
        ])
        #expect(rules(module) == [.closureShape])
    }

    // MARK: - 抛出与位置

    @Test("有违约时 check 抛出，且带上首处的位置")
    func checkThrowsWithLocation() {
        let location = PiniSyntax.SourceLocation(line: 7, column: 5, fileName: "inline.pini")
        let module = handBuilt(
            [.exprStmt(.load(name: "x", type: .i32))], positions: [location])
        do {
            try IRValidator.check(module)
            #expect(Bool(false), "应当抛出")
        } catch let failure as IRValidator.Failure {
            #expect(failure.issues.count == 1)
            #expect(failure.issues[0].rule == .undeclaredVariable)
            #expect(failure.issues[0].location.line == 7)
            #expect(failure.diagnosticCode == "E6-011")
        } catch {
            #expect(Bool(false), "抛的不是 IRValidator.Failure：\(error)")
        }
    }

    @Test("一次报全，不在首错停下")
    func reportsEveryIssue() {
        let module = handBuilt([
            .exprStmt(.load(name: "a", type: .i32)),
            .exprStmt(.load(name: "b", type: .i32)),
        ])
        #expect(IRValidator.validate(module).count == 2)
    }

    @Test("规则表：每条规则各有各的一句说明")
    func ruleCatalogue() {
        let summaries = IRValidator.Rule.allCases.map(\.summary)
        #expect(summaries.count == 15, "规则增减时，同笔改动里补上对应的阴性夹具")
        #expect(summaries.allSatisfy { !$0.isEmpty })
        #expect(Set(summaries).count == summaries.count, "两条规则写了同一句话，说明其中一条是抄的")
    }
}
