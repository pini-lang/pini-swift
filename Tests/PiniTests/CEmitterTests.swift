import Foundation
@testable import PiniCore
import Testing

/// C 后端骨架期的判据：入口形态、预置声明的剪枝、未支持节点的拒绝、字面量与类型拼写。
/// 生成的 C 能否编过由 `pini build --c-backend` 的端到端比对兜底，此处只钉发射器自身的边界。
@Suite("C 后端发射")
struct CEmitterTests {

    private func mainModule(_ statements: [IRStmt]) -> IRModule {
        let function = IRFunction(
            name: "main", params: [], returnType: nil, body: IRBlock(statements))
        return IRModule(functions: [function])
    }

    @Test("最小入口产出 int main(void) 并含回退返回")
    func minimalEntry() throws {
        let files = try CEmitter().emit(
            module: mainModule([.returnStmt(value: nil)]), programName: "t")
        #expect(files.count == 1)
        #expect(files[0].name == "t.c")
        #expect(files[0].contents.contains("#include \"pini_rt.h\""))
        #expect(files[0].contents.contains("int main(void) {"))
        #expect(files[0].contents.contains("return 0;"))
    }

    @Test("预置声明的函数不进产物")
    func predefinedFunctionsAreDropped() throws {
        let scheduler = IRFunction(
            name: "收下", params: [], returnType: nil,
            body: IRBlock([.returnStmt(value: nil)]),
            sourceFile: PredefinedDecls.sourceName)
        let main = IRFunction(
            name: "main", params: [], returnType: nil,
            body: IRBlock([.returnStmt(value: nil)]))
        let files = try CEmitter().emit(
            module: IRModule(functions: [main, scheduler]), programName: "t")
        #expect(!files[0].contents.contains("pini__u6536"))
    }

    @Test("未支持的语句抛错而不是降级")
    func unsupportedStatementThrows() {
        let body = IRBlock([
            .tryStmt(
                operand: .intConst(value: 0, type: .i32), errorVar: "e",
                handler: IRBlock([]), okTarget: nil, type: .i32)
        ])
        let function = IRFunction(name: "main", params: [], returnType: nil, body: body)
        #expect(throws: CBackendError.self) {
            _ = try CEmitter().emit(module: IRModule(functions: [function]), programName: "t")
        }
    }

    /// `defer` 体里的 `return` 不回头重放自己那一帧：少了这道闸，重放与终止边会互相再进，
    /// 编译期栈溢出 —— 那不是报错，是把编译器打崩。
    @Test("defer 体里的 return 不会自递归重放")
    func deferBodyWithReturnTerminates() throws {
        let body = IRBlock([
            .deferStmt(body: IRBlock([.returnStmt(value: nil)])),
            .returnStmt(value: nil),
        ])
        let function = IRFunction(name: "main", params: [], returnType: nil, body: body)
        let files = try CEmitter().emit(module: IRModule(functions: [function]), programName: "t")
        #expect(files[0].contents.contains("return 0;"))
    }

    @Test("无 main 的模块被拒绝")
    func missingMainIsRejected() {
        let function = IRFunction(
            name: "helper", params: [], returnType: nil,
            body: IRBlock([.returnStmt(value: nil)]))
        #expect(throws: CBackendError.self) {
            _ = try CEmitter().emit(module: IRModule(functions: [function]), programName: "t")
        }
    }

    @Test("C 字符串字面量的转义")
    func literalEscaping() {
        #expect(CEmitter.cLiteral("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        #expect(CEmitter.cLiteral("欢迎") == "\"欢迎\"")
    }

    @Test("类型拼写与拒绝")
    func typeSpelling() throws {
        #expect(try CTypeMap.spelling(of: .i32) == "int32_t")
        #expect(try CTypeMap.spelling(of: .u64) == "uint64_t")
        #expect(try CTypeMap.spelling(of: .string) == "char *")
        // 容器是运行时段的不透明句柄；Optional 按载荷类型特化出一个具名结构体。
        #expect(try CTypeMap.spelling(of: .array(element: .i32)) == "void *")
        #expect(try CTypeMap.spelling(of: .optional(wrapped: .i32)) == "PiniOpt_i32")
        // 元组是按值聚合体，名字由字段类型派生；LazyRef 与容器同为不透明句柄。
        #expect(
            try CTypeMap.spelling(of: .tuple(labels: [nil, nil], fieldTypes: [.i32, .i32]))
                == "PiniTuple_i32_i32")
        #expect(try CTypeMap.spelling(of: .lazyRef(element: .i32)) == "void *")
        // 表外的类型仍然拒绝：静默退化成 `void *` 会让产物编得过而在运行时读错位。
        #expect(throws: CBackendError.self) {
            _ = try CTypeMap.spelling(of: .result(ok: .i32))
        }
    }

    @Test("I32 最小值不写成溢出形态")
    func integerLiteralMinimum() throws {
        #expect(try CTypeMap.integerLiteral(-2147483648, type: .i32) == "(-2147483647 - 1)")
        #expect(try CTypeMap.integerLiteral(3, type: .i64) == "INT64_C(3)")
    }
}
