import XCTest
import PiniCore
import Foundation

final class IRGeneratorTests: XCTestCase {
    
    private func parse(_ source: String, fileName: String = "test.pini") throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return try parser.parseModule()
    }
    
    private func generateIR(_ source: String) throws -> String {
        let module = try parse(source)
        let generator = IRGenerator()
        return try generator.generate(module: module)
    }
    
    // MARK: - B1: IRGenError 基础测试
    
    func testIRGenErrorDescriptions() throws {
        let loc = SourceLocation(line: 1, column: 2, fileName: "test.pini")
        
        let e1 = IRGenError.unsupportedType(name:"String", loc)
        XCTAssertTrue(e1.errorDescription.contains("String"))
        XCTAssertTrue(e1.errorDescription.contains("test.pini"))
        XCTAssertTrue(e1.errorDescription.contains("1:2"))
        
        let e2 = IRGenError.unsupportedExpression(kind:"funcLiteral", loc)
        XCTAssertTrue(e2.errorDescription.contains("funcLiteral"))
        
        let e3 = IRGenError.unsupportedStatement(kind:"match", loc)
        XCTAssertTrue(e3.errorDescription.contains("match"))
        
        let e4 = IRGenError.unsupportedFeature(feature:"async", loc)
        XCTAssertTrue(e4.errorDescription.contains("async"))
        
        let e5 = IRGenError.typeMismatch(expected: "i32", got: "double", loc)
        XCTAssertTrue(e5.errorDescription.contains("i32"))
        XCTAssertTrue(e5.errorDescription.contains("double"))
    }

    // TDD（G-IR-enum-print / T2）：聚合类型 print 现经递归 stringify 生成 IR，不再 fail-loud。
    // 断言：IR 生成成功（不抛错），且包含枚举 stringify 的 switch/merge 标签（证明走 stringify 路径）。
    func testAggregatePrintGeneratesStringifyIR() throws {
        let src = try loadPiniFixture("testAggregatePrintGeneratesStringifyIR", filePath: #filePath)
        let ir = try generateIR(src)
        XCTAssertTrue(ir.contains("str_enum_merge_"),
                      "聚合 print 应生成枚举 stringify 的 switch/merge 块，IR:\n\(ir)")
        XCTAssertFalse(ir.contains("请改用解释器"),
                       "聚合 print 不应再 fail-loud 提示改用解释器，IR:\n\(ir)")
    }

    // Bug A（run-llvm 非法 IR）：函数体末条语句为非终止语句（如 print/表达式/var）
    // 或控制流（if/while/match）的合并块无后续语句时，当前块缺终止指令，紧跟的
    // `exit_block:` 标签会使 lli 报 "expected instruction opcode"。修复须在 exit_block:
    // 前补 `br label %exit_block` 终止当前块。
    func testPrintEndingFunctionEmitsTerminatingBranch() throws {
        let ir = try generateIR(try loadPiniFixture("testPrintEndingFunctionEmitsTerminatingBranch", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("br label %exit_block"),
                      "print 结尾函数必须补 br label %exit_block 终止指令，IR:\n\(ir)")
        if let brRange = ir.range(of: "br label %exit_block"),
           let exitRange = ir.range(of: "exit_block:") {
            XCTAssertTrue(brRange.lowerBound < exitRange.lowerBound,
                          "br 终止指令须位于 exit_block: 标签之前，IR:\n\(ir)")
        }
    }

    func testIfEndingFunctionEmitsTerminatingBranch() throws {
        let ir = try generateIR(try loadPiniFixture("testIfEndingFunctionEmitsTerminatingBranch", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("br label %exit_block"),
                      "if 结尾函数（合并块无后续语句）必须补 br label %exit_block，IR:\n\(ir)")
    }

    // Bug B（G-IR-len-str）：字符串 len 须统计字符数（与解释器 String.count 对齐），
    // 不再是 UTF-8 字节数。LLVM 侧生成「非续行字节(0x80-0xBF)计数」循环（len_loop_）。
    func testLenCountsCharactersNotBytes() throws {
        let ir = try generateIR(try loadPiniFixture("testLenCountsCharactersNotBytes", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("len_loop_"),
                      "len 字符串分支应生成字符计数循环，IR:\n\(ir)")
        // 旧实现用 @strlen 给字节数，len 逻辑中不应再出现该调用。
        XCTAssertFalse(ir.contains("call i64 @strlen("),
                       "len 不应再用 @strlen 计字节数，IR:\n\(ir)")
    }

    // 空串 "" 在 IR 中解析为 stringInterpolation(segments:[])，
    // generateExpression 须按空字面量生成，而非抛 unsupportedExpression（否则 run-llvm 整段报废）。
    func testEmptyStringInterpolationSucceeds() throws {
        let ir = try generateIR(try loadPiniFixture("testEmptyStringInterpolationSucceeds", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("len_loop_"), "空串 len 应正常生成字符计数循环，IR:\n\(ir)")
    }

    // ADR-016 规则 3.15：枚举用例括号内只接受位置类型注解，
    // 「字面量默认」与「表达式默认（iota()）」一并在解析期拒绝——
    // 关联值默认值特性随 3.15 移除（此前 c2/方案 A 只删了 iota 宏，保留字面量默认）。
    func testLiteralEnumDefaultRejected() throws {
        let src = try loadPiniFixture("testLiteralEnumDefaultRejected", filePath: #filePath)
        XCTAssertThrowsError(try generateIR(src)) { error in
            XCTAssertTrue("\(error)".contains("默认值"),
                          "规则 3.15：字面量默认应被解析期拒绝，实际: \(error)")
        }
    }

    func testIotaEnumDefaultRejected() throws {
        let src = try loadPiniFixture("testIotaEnumDefaultRejected", filePath: #filePath)
        XCTAssertThrowsError(try generateIR(src)) { error in
            XCTAssertTrue("\(error)".contains("默认值") || "\(error)".contains("iota"),
                          "iota() 作为枚举关联值默认应被拒绝，实际: \(error)")
        }
    }

    /// 规则 3.15 正向面：位置类型注解的枚举用例正常生成 IR
    func testPositionalEnumCaseAccepted() throws {
        let src = try loadPiniFixture("testPositionalEnumCaseAccepted", filePath: #filePath)
        XCTAssertNoThrow(try generateIR(src), "位置类型注解的枚举用例应正常解析并生成 IR")
    }
    
    // MARK: - B1: IRTypeMapper 测试
    
    func testIRTypeMapperSupportedTypes() throws {
        let mapper = IRTypeMapper()
        let loc = SourceLocation(line: 0, column: 0, fileName: "")
        
        let i32Type = TypeAnnotation.simple(name: "I32", location: loc)
        XCTAssertEqual(try mapper.map(i32Type), "i32")
        
        let f64Type = TypeAnnotation.simple(name: "F64", location: loc)
        XCTAssertEqual(try mapper.map(f64Type), "double")
        
        let boolType = TypeAnnotation.simple(name: "Bool", location: loc)
        XCTAssertEqual(try mapper.map(boolType), "i1")
    }
    
    func testIRTypeMapperUnitType() throws {
        let mapper = IRTypeMapper()
        let loc = SourceLocation(line: 0, column: 0, fileName: "")
        
        let voidType = TypeAnnotation.simple(name: "Void", location: loc)
        XCTAssertEqual(try mapper.map(voidType), "void")
        
        let unitType = TypeAnnotation.simple(name: "Unit", location: loc)
        XCTAssertEqual(try mapper.map(unitType), "void")
    }
    
    func testIRTypeMapperUnsupportedThrows() throws {
        let mapper = IRTypeMapper()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")

        // String 现映射为 ptr（支持聚合字段为字符串，配合 T2 stringify 对齐解释器展示）。
        let stringType = TypeAnnotation.simple(name: "String", location: loc)
        XCTAssertEqual(try mapper.map(stringType), "ptr")

        // 未注册的命名类型仍应抛 unsupportedType。
        let unknownType = TypeAnnotation.simple(name: "MyUnknownType", location: loc)
        XCTAssertThrowsError(try mapper.map(unknownType)) { error in
            guard case IRGenError.unsupportedType(name:let name, _) = error else {
                XCTFail("应为 unsupportedType 错误，实际: \(error)")
                return
            }
            XCTAssertEqual(name, "MyUnknownType")
        }

        let structType = TypeAnnotation.simple(name: "MyStruct", location: loc)
        XCTAssertThrowsError(try mapper.map(structType))
    }
    
    func testIRTypeMapperGenericThrows() throws {
        let mapper = IRTypeMapper()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        
        let genericType = TypeAnnotation.generic(name: "Array", params: [.simple(name: "I32", location: loc)], location: loc)
        XCTAssertThrowsError(try mapper.map(genericType)) { error in
            guard case IRGenError.unsupportedType = error else {
                XCTFail("应为 unsupportedType 错误")
                return
            }
        }
    }
    
    func testIRTypeMapperTupleMaps() throws {
        let mapper = IRTypeMapper()
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")

        let tupleType = TypeAnnotation.tuple(labels: [], elements: [.simple(name: "I32", location: loc), .simple(name: "F64", location: loc)], location: loc)
        XCTAssertEqual(try mapper.map(tupleType), "{ i32, double }")

        let nested = TypeAnnotation.tuple(labels: [], elements: [
            .simple(name: "I32", location: loc),
            .tuple(labels: [], elements: [.simple(name: "I32", location: loc), .simple(name: "Bool", location: loc)], location: loc)
        ], location: loc)
        XCTAssertEqual(try mapper.map(nested), "{ i32, { i32, i1 } }")
    }

    // MARK: - P6-1c: 元组字面量 IR

    func testTupleLiteralIR() throws {
        let ir = try generateIR(try loadPiniFixture("testTupleLiteralIR", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("{ i32, i32 }"), "应生成 struct 类型 { i32, i32 }")
        XCTAssertTrue(ir.contains("insertvalue { i32, i32 }"), "应通过 insertvalue 组装元组")
        XCTAssertTrue(ir.contains("store { i32, i32 }"), "元组应存入变量槽")
    }

    func testTupleMixedIR() throws {
        let ir = try generateIR(try loadPiniFixture("testTupleMixedIR", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("{ i32, double }"), "混合类型元组应生成 { i32, double }")
        let count = ir.components(separatedBy: "insertvalue").count - 1
        XCTAssertEqual(count, 2, "两个元素应生成两个 insertvalue")
    }

    // MARK: - P6-1d: 数组字面量 IR

    func testArrayLiteralIR() throws {
        let ir = try generateIR(try loadPiniFixture("testArrayLiteralIR", filePath: #filePath) as String)
        // ADR-008 / #46-D：数组经运行时 shim 的不透明句柄承载，不再是定长 [N x T]
        XCTAssertTrue(ir.contains("call ptr @bk_array_create(i32 3)"), "应调用运行时创建长度为 3 的数组")
        XCTAssertTrue(ir.contains("%bk_array = type { ptr }"), "应声明 %bk_array 不透明句柄类型")
        XCTAssertTrue(ir.contains("bitcast ptr %t"), "句柄应从 ptr 类型化为 %bk_array*")
        let setCount = ir.components(separatedBy: "call ptr @bk_array_set(ptr").count - 1
        XCTAssertEqual(setCount, 3, "三个元素应生成三个 @bk_array_set 调用（装箱-raw 模型）")
        XCTAssertFalse(ir.contains("[3 x i32]"), "不应再生成定长数组类型 [3 x i32]")
    }

    func testArraySingleElementIR() throws {
        let ir = try generateIR(try loadPiniFixture("testArraySingleElementIR", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("call ptr @bk_array_create(i32 1)"), "单个元素应创建长度为 1 的数组")
        let setCount = ir.components(separatedBy: "call ptr @bk_array_set(ptr").count - 1
        XCTAssertEqual(setCount, 1, "单个元素应生成一个 @bk_array_set 调用（装箱-raw 模型）")
    }

    // MARK: - #46-D D1.5：数组下标写 a[i] = v（IR 结构断言）

    /// 结构断言：纯下标写 `arr[0] = 99` 应经 `@bk_array_set` 写回运行时句柄；
    /// 复合赋值 `arr[0] += 1` 应「读当前 @bk_array_get → 运算 → 写回 @bk_array_set」。
    func testArraySubscriptWriteIR() throws {
        let pure = try generateIR(try loadPiniFixture("testArraySubscriptWriteIR", filePath: #filePath) as String)
        XCTAssertTrue(pure.contains("call ptr @bk_array_set(ptr"), "纯下标写应生成 @bk_array_set 调用（装箱-raw 模型）")
        XCTAssertTrue(pure.contains("bitcast %bk_array*"), "写回前句柄应在 %bk_array* 与 ptr 间 bitcast")

        let compound = try generateIR(try loadPiniFixture("testArraySubscriptWriteIR_2", filePath: #filePath) as String)
        XCTAssertTrue(compound.contains("call ptr @bk_array_get(ptr"), "复合赋值应读当前值（@bk_array_get）")
        // 读-算-写：单元素字面量 1 次 set + 写回 1 次 set = 2
        let setCount = compound.components(separatedBy: "call ptr @bk_array_set(ptr").count - 1
        XCTAssertEqual(setCount, 2, "单元素字面量 1 次 + 复合写回 1 次 @bk_array_set")
    }

    // MARK: - #46-D D2：字典 / 集合 字面量 + 下标 + len（IR 结构断言）

    func testDictLiteralAndSubscriptIR() throws {
        let ir = try generateIR(try loadPiniFixture("testDictLiteralAndSubscriptIR", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("%bk_dict = type { ptr }"), "应声明 %bk_dict 句柄类型")
        XCTAssertTrue(ir.contains("call ptr @bk_dict_create()"), "应调用 @bk_dict_create 构造字典")
        let setCount = ir.components(separatedBy: "call ptr @bk_dict_set(ptr").count - 1
        XCTAssertEqual(setCount, 3, "两对键值各 1 次（字面量 2）+ 键写 ages[\"Bob\"]=26 1 次 = 3 次 @bk_dict_set")
        XCTAssertTrue(ir.contains("call ptr @bk_dict_get(ptr"), "字典键读应生成 @bk_dict_get（键经 boxing）")
        XCTAssertTrue(ir.contains("call i32 @bk_dict_len(ptr"), "len(字典) 应调用 @bk_dict_len")
        XCTAssertTrue(ir.contains("call ptr @bk_dict_set(ptr"), "字典键写（a[k]=v）应生成 @bk_dict_set")
    }

    func testSetLiteralIR() throws {
        let ir = try generateIR(try loadPiniFixture("testSetLiteralIR", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("%bk_set = type { ptr }"), "应声明 %bk_set 句柄类型")
        XCTAssertTrue(ir.contains("call ptr @bk_set_create()"), "应调用 @bk_set_create 构造集合")
        let addCount = ir.components(separatedBy: "call ptr @bk_set_add(ptr").count - 1
        XCTAssertEqual(addCount, 5, "五个元素应各生成一次 @bk_set_add（保序去重由运行时完成）")
        XCTAssertTrue(ir.contains("call i32 @bk_set_len(ptr"), "len(集合) 应调用 @bk_set_len")
    }

    // MARK: - #46-D D3: print(容器) 触发运行时稳定指针访问器声明

    func testD3ContainerPrintEmitsRuntimeAccessors() throws {
        let ir = try generateIR(try loadPiniFixture("testD3ContainerPrintEmitsRuntimeAccessors", filePath: #filePath) as String)
        // D3 编码容器打印需运行时稳定指针访问器（_BkDictBox/_BkSetBox 元素存储改为稳定指针）；
        // 这些符号须经 usesCollections 门控在模块末尾声明。
        XCTAssertTrue(ir.contains("declare ptr @bk_dict_key_at(ptr, i32)"),
                      "打印字典应声明 @bk_dict_key_at 访问器")
        XCTAssertTrue(ir.contains("declare ptr @bk_dict_val_at(ptr, i32)"),
                      "打印字典应声明 @bk_dict_val_at 访问器")
        XCTAssertTrue(ir.contains("declare ptr @bk_set_at(ptr, i32)"),
                      "打印集合应声明 @bk_set_at 访问器")
        XCTAssertTrue(ir.contains("declare i32 @bk_dict_contains(ptr, ptr, i32, i32)"),
                      "打印字典缺失键闭合应声明 @bk_dict_contains 访问器")
    }

    // MARK: - P6-1e: len 内置 + print bool 收口（结构断言）

    func testLenArrayCallsRuntime() throws {
        let ir = try generateIR(try loadPiniFixture("testLenArrayCallsRuntime", filePath: #filePath) as String)
        // ADR-008 / #46-D：数组 len 不再折叠为编译期常量，而是经运行时 @bk_array_len
        XCTAssertTrue(ir.contains("%bk_array = type { ptr }"), "应声明 %bk_array 句柄类型")
        XCTAssertTrue(ir.contains("call i32 @bk_array_len(ptr"),
                      "len(数组) 应调用运行时 @bk_array_len，而非折叠为常量")
        XCTAssertFalse(ir.contains("@printf(ptr @fmt_int, i32 3)"),
                       "数组 len 不应再折叠为 printf 常量实参 3")
    }

    func testLenTupleFoldsToConstant() throws {
        let ir = try generateIR(try loadPiniFixture("testLenTupleFoldsToConstant", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("@printf(ptr @fmt_int, i32 3)"),
                      "len(元组) 应折叠为顶层字段数常量 3")
        XCTAssertFalse(ir.contains("call i64 @strlen"),
                       "元组 len 不应产生 strlen 运行时调用")
    }

    func testPrintBoolUsesTrueFalseSelect() throws {
        let ir = try generateIR(try loadPiniFixture("testPrintBoolUsesTrueFalseSelect", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("select i1"),
                      "print(bool) 应用 select 在 true/false 格式串间择一")
        XCTAssertTrue(ir.contains("ptr @fmt_bool_true, ptr @fmt_bool_false"),
                      "应接线此前声明未用的 fmt_bool_true / fmt_bool_false 常量")
        XCTAssertFalse(ir.contains("@fmt_int, i1"),
                       "print(bool) 不应再走 %d 输出 1/0")
    }

    func testInterpolatedBoolUsesSelect() throws {
        let ir = try generateIR(try loadPiniFixture("testInterpolatedBoolUsesSelect", filePath: #filePath) as String)
        XCTAssertTrue(ir.contains("select i1"),
                      "插值内的 bool 也应 select 出 true/false 字符串指针")
        XCTAssertTrue(ir.contains("ptr @fmt_bool_true, ptr @fmt_bool_false"),
                      "插值 bool 应接线 fmt_bool_* 常量")
    }

    // MARK: - B2: IRGenerator 基础测试
    
    func testIRGlobals() throws {
        let source = try loadPiniFixture("testIRGlobals", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("@printf"), "应包含 printf 声明")
        XCTAssertTrue(ir.contains("@fmt_int"), "应包含 fmt_int 格式串")
        XCTAssertTrue(ir.contains("@fmt_double"), "应包含 fmt_double 格式串")
        XCTAssertTrue(ir.contains("@fmt_bool_true"), "应包含 fmt_bool_true 格式串")
        XCTAssertTrue(ir.contains("@fmt_bool_false"), "应包含 fmt_bool_false 格式串")
    }
    
    func testSimpleFunctionSignature() throws {
        let source = try loadPiniFixture("testSimpleFunctionSignature", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("define i32 @add(i32 %a, i32 %b)"),
                      "应包含 add 函数定义（I32 参数和返回值）")
    }
    
    func testMainFunction() throws {
        let source = try loadPiniFixture("testMainFunction", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("define i32 @main()"),
                      "main 函数应返回 i32")
        XCTAssertTrue(ir.contains("ret i32 0"),
                      "main 函数应返回 0")
    }
    
    func testFunctionWithF64Param() throws {
        let source = try loadPiniFixture("testFunctionWithF64Param", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("define double @multiply(double %x, double %y)"),
                      "应正确生成 F64 参数和返回值")
    }
    
    func testFunctionWithBoolParam() throws {
        let source = try loadPiniFixture("testFunctionWithBoolParam", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("define i1 @negate(i1 %flag)"),
                      "应正确生成 Bool(i1) 参数和返回值")
    }
    
    func testVoidFunctionNoReturn() throws {
        let source = try loadPiniFixture("testVoidFunctionNoReturn", filePath: #filePath)
        let ir = try generateIR(source)
        
        XCTAssertTrue(ir.contains("define void @doNothing()"),
                      "应正确生成 void 返回类型的函数")
    }
    
    // MARK: - B2: 拒绝测试
    
    // MARK: - B2: 并发（`=>` 派发 / `<=` join）IR 生成测试
    // 立场 B（Pini草稿.md（异步函数块））：await 关键字已移除，join 用前缀 `<=`。
    // IR 层当前为 MVP 同步降级：`<=` 透传其操作数，故 IR 形态与同步调用一致。

    func testAsyncFunctionIR() throws {
        let source = try loadPiniFixture("testAsyncFunctionIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("; async function (MVP: synchronous)"),
                      "async 函数应包含 MVP 注释标记")
        XCTAssertTrue(ir.contains("define i32 @fetchData()"),
                      "async 函数应生成普通函数签名（同步语义）")
        XCTAssertTrue(ir.contains("ret i32 42"),
                      "async 函数应正常生成 return IR")
    }

    func testJoinExpressionIR() throws {
        let source = try loadPiniFixture("testJoinExpressionIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("define i32 @fetchData()"),
                      "async 被调函数应正常定义")
        XCTAssertTrue(ir.contains("@printf"),
                      "join 后的 print 应正常生成")
        let callCount = ir.components(separatedBy: "call i32 @fetchData").count - 1
        XCTAssertEqual(callCount, 1, "`<=` join 应生成一次对 async 函数的 call")
    }

    func testAsyncVsSyncParityIR() throws {
        let source = try loadPiniFixture("testAsyncVsSyncParityIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("; async function (MVP: synchronous)"),
                      "async 函数应有标记注释")
        let callAsync = ir.components(separatedBy: "call i32 @computeAsync").count - 1
        let callSync = ir.components(separatedBy: "call i32 @computeSync").count - 1
        XCTAssertEqual(callAsync, 1)
        XCTAssertEqual(callSync, 1)
    }
    
    func testGenericFunctionSupported() throws {
        let source = try loadPiniFixture("testGenericFunctionSupported", filePath: #filePath)
        // P6-4b: 泛型函数模板应被接受（不抛 unsupportedFeature）
        XCTAssertNoThrow(try generateIR(source), "泛型函数模板应被接受")
    }

    // MARK: - P6-4b: 泛型函数单态化

    /// 验证：`identity<I32>(42)` 生成对特化函数 `@identity_i32` 的调用
    func testGenericConstruct_I32_CallsSpecializedFunction() throws {
        let source = try loadPiniFixture("testGenericConstruct_I32_CallsSpecializedFunction", filePath: #filePath)
        let ir = try generateIR(source)
        // 应该包含特化函数定义（IRTypeMapper 将 I32 映射为 i32）
        XCTAssertTrue(ir.contains("@identity_i32"), "IR 应包含特化函数 @identity_i32")
        // 应该包含对特化函数的调用
        XCTAssertTrue(ir.contains("call i32 @identity_i32"), "IR 应包含 call i32 @identity_i32")
    }

    /// 验证：两个不同特化分别生成独立函数体
    func testGenericConstruct_TwoSpecializationsGenerateSeparateFunctions() throws {
        let source = try loadPiniFixture("testGenericConstruct_TwoSpecializationsGenerateSeparateFunctions", filePath: #filePath)
        let ir = try generateIR(source)
        // 两个特化版本都应存在（IRTypeMapper 将 F64 映射为 "double"）
        XCTAssertTrue(ir.contains("@identity_i32"), "应包含 @identity_i32")
        XCTAssertTrue(ir.contains("@identity_double"), "应包含 @identity_double")
        XCTAssertTrue(ir.contains("call i32 @identity_i32"), "应包含 call i32")
        XCTAssertTrue(ir.contains("call double @identity_double"), "应包含 call double")
    }

    // MARK: - P6-4a: 参数缺类型注解推断

    /// 验证：参数无类型注解时，从返回类型推断为 I32
    func testParamWithoutTypeAnnotation_InferredFromReturnType() throws {
        let source = try loadPiniFixture("testParamWithoutTypeAnnotation_InferredFromReturnType", filePath: #filePath)
        let ir = try generateIR(source)
        // 参数 x, y 应被推断为 i32
        XCTAssertTrue(ir.contains("i32 %x"), "参数 x 应推断为 i32")
        XCTAssertTrue(ir.contains("i32 %y"), "参数 y 应推断为 i32")
    }

    /// 验证：参数无类型注解 + 多返回类型时回退为 i32
    func testParamWithoutTypeAnnotation_FallbackToI32() throws {
        let source = try loadPiniFixture("testParamWithoutTypeAnnotation_FallbackToI32", filePath: #filePath)
        let ir = try generateIR(source)
        // 多返回类型时回退为 i32
        XCTAssertTrue(ir.contains("i32 %x"), "参数 x 应回退为 i32")
        XCTAssertTrue(ir.contains("i32 %y"), "参数 y 应回退为 i32")
    }

    /// 结构断言：含方法的 struct/object 声明不再抛 unsupportedFeature（self 主体访问待 refine）。
    func testMethodWithSelfModifierSupported() throws {
        let source = try loadPiniFixture("testMethodWithSelfModifierSupported", filePath: #filePath)
        // 推进性：不应抛 unsupportedFeature
        XCTAssertNoThrow(try generateIR(source), "含方法的类型声明应被接受")
    }

    func testMethodSelfAccessEmitted() throws {
        let source = try loadPiniFixture("testMethodSelfAccessEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("define void @add") && ir.contains("%struct.Point* %self"),
                      "方法应含 self 参数，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("getelementptr %struct.Point"), "应包含 self 字段访问，实际:\n\(ir)")
    }
    
    func testStructDeclSupported() throws {
        let source = try loadPiniFixture("testStructDeclSupported", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("%struct.Point = type { i32 }"),
                      "struct 声明现在应生成命名结构类型，实际:\n\(ir)")
    }
    
    func testEnumDeclSupported() throws {
        let source = try loadPiniFixture("testEnumDeclSupported", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("%enum.Shape = type { i32 }"),
                      "enum 声明现在应生成 tagged union 类型，实际:\n\(ir)")
    }

    // MARK: - B3: 赋值表达式测试

    func testAssignmentIR() throws {
        let source = try loadPiniFixture("testAssignmentIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("store i32 0, ptr %x_slot"),
                      "var 初始化应生成 store 0")
        XCTAssertTrue(ir.contains("store i32 42, ptr %x_slot"),
                      "赋值语句应生成 store 42")
    }

    func testAssignmentWithLoad() throws {
        let source = try loadPiniFixture("testAssignmentWithLoad", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("load i32, ptr %z_slot"),
                      "从 z 读值应生成 load")
        XCTAssertTrue(ir.contains("store i32"),
                      "赋值应生成 store")
    }

    func testCompoundAssignPlus() throws {
        let source = try loadPiniFixture("testCompoundAssignPlus", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("load i32, ptr %a_slot"),
                      "复合赋值应先 load 原值")
        XCTAssertTrue(ir.contains("add i32"),
                      "复合赋值应生成 add 指令")
        XCTAssertTrue(ir.contains("store i32"),
                      "复合赋值结果应 store 回去")
    }

    func testCompoundAssignMinus() throws {
        let source = try loadPiniFixture("testCompoundAssignMinus", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("sub i32"),
                      "-= 应生成 sub 指令")
    }

    func testAssignExpressionInPrint() throws {
        let source = try loadPiniFixture("testAssignExpressionInPrint", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("store"),
                      "赋值表达式应生成 store")
        XCTAssertTrue(ir.contains("@printf"),
                      "print 应生成 printf 调用")
    }

    // MARK: - B4: ifStatement 测试

    func testIfStatementIR() throws {
        let source = try loadPiniFixture("testIfStatementIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("if_cond_"),
                      "应生成条件块标签")
        XCTAssertTrue(ir.contains("if_then_"),
                      "应生成 then 块标签")
        XCTAssertTrue(ir.contains("if_else_"),
                      "应生成 else 块标签")
        XCTAssertTrue(ir.contains("if_merge_"),
                      "应生成 merge 块标签")
        XCTAssertTrue(ir.contains("br i1"),
                      "条件分支应生成 br i1")
    }

    func testIfStatementNoElse() throws {
        let source = try loadPiniFixture("testIfStatementNoElse", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("if_merge_"),
                      "无 else 也应有 merge 块")
        let mergeCount = ir.components(separatedBy: "if_merge_").count - 1
        XCTAssertEqual(mergeCount, 3, "if_merge 应出现3次: 标签定义 + 条件跳转 + then块跳转")
    }

    func testIfStatementWithElif() throws {
        let source = try loadPiniFixture("testIfStatementWithElif", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("elif_cond_"),
                      "elif 应有自己的条件块")
        XCTAssertTrue(ir.contains("elif_then_"),
                      "elif 应有自己的 then 块")
        XCTAssertTrue(ir.contains("if_merge_"),
                      "应有 merge 块")
    }

    func testIfOnlyNoBlockElse() throws {
        let source = try loadPiniFixture("testIfOnlyNoBlockElse", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("br i1"),
                      "应生成条件跳转")
        XCTAssertTrue(ir.contains("if_else_"),
                      "即使无 else 也会有 else entry 块（然后直接 br 到 merge）")
    }

    // MARK: - B4: whileStatement 测试

    func testWhileStatementIR() throws {
        let source = try loadPiniFixture("testWhileStatementIR", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("while_cond_"),
                      "应生成 while 条件块")
        XCTAssertTrue(ir.contains("while_body_"),
                      "应生成 while 体块")
        XCTAssertTrue(ir.contains("while_exit_"),
                      "应生成 while 退出块")
        XCTAssertTrue(ir.contains("br i1"),
                      "条件分支应生成 br i1")
        XCTAssertTrue(ir.contains("br label %while_cond_"),
                      "应生成 back-edge 回到条件块")
    }

    func testWhileEmptyBody() throws {
        let source = try loadPiniFixture("testWhileEmptyBody", filePath: #filePath)
        let ir = try generateIR(source)

        let backEdgeCount = ir.components(separatedBy: "br label %while_cond_").count - 1
        XCTAssertGreaterThanOrEqual(backEdgeCount, 1,
                                     "while 体结束应 br 回 cond 块")
    }

    func testBreakInWhile() throws {
        let source = try loadPiniFixture("testBreakInWhile", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("br label %while_exit_"),
                      "break 应生成跳转到 while_exit 的指令")
    }

    func testContinueInWhile() throws {
        let source = try loadPiniFixture("testContinueInWhile", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("br label %while_cond_"),
                      "continue 应生成跳转到 while_cond 的指令")
    }

    func testBreakOutsideLoopUnsupported() throws {
        let source = try loadPiniFixture("testBreakOutsideLoopUnsupported", filePath: #filePath)
        XCTAssertThrowsError(try generateIR(source),
                              "循环外 break 应抛 unsupported")
    }

    // MARK: - B4: 完整程序测试

    func testProgramWithControlFlow() throws {
        let source = try loadPiniFixture("testProgramWithControlFlow", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("while_cond_"),
                      "应包含 while 条件块")
        XCTAssertTrue(ir.contains("if_cond_"),
                      "应包含 if 条件块")
        XCTAssertTrue(ir.contains("@printf"),
                      "应包含 print 调用")
        XCTAssertTrue(ir.contains("br label %while_cond_"),
                      "while 应有 back-edge")
        XCTAssertTrue(ir.contains("ret i32 0"),
                      "main 应返回 i32 0")
    }

    func testProgramPrintInLoop() throws {
        let source = try loadPiniFixture("testProgramPrintInLoop", filePath: #filePath)
        let ir = try generateIR(source)

        let printfCount = ir.components(separatedBy: "@printf").count - 1
        XCTAssertGreaterThanOrEqual(printfCount, 2,
                                     "应包含至少一个 printf 声明和一个调用")
        XCTAssertTrue(ir.contains("while_body_"),
                      "应包含 while body")
    }

    func testProgramArithmetic() throws {
        let source = try loadPiniFixture("testProgramArithmetic", filePath: #filePath)
        let ir = try generateIR(source)

        XCTAssertTrue(ir.contains("add i32"),
                      "应生成 add 指令")
        XCTAssertTrue(ir.contains("load i32, ptr %a_slot"),
                      "应 load a 的值")
        XCTAssertTrue(ir.contains("load i32, ptr %b_slot"),
                      "应 load b 的值")
    }

    // MARK: - B3/B4: 不支持特性仍正确抛错

    func testUnsupportedMemberAccess() throws {
        let source = try loadPiniFixture("testUnsupportedMemberAccess", filePath: #filePath)
        XCTAssertThrowsError(try generateIR(source),
                              "成员访问应抛 unsupported") { error in
            guard case IRGenError.unsupportedExpression = error else {
                XCTFail("应为 unsupportedExpression 错误，实际: \(error)")
                return
            }
        }
    }

    // 阶段 B 后 LLVM 后端已支持一等函数/闭包（捕获/高阶/间接调用），故匿名函数不再抛 unsupported。
    // 正向断言：closure 被提升为模块级 define（@__closure_N）且被间接调用，IR 成功生成。
    func testFuncLiteralSupportedInIR() throws {
        let source = try loadPiniFixture("testFuncLiteralSupportedInIR", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("@__closure_"),
                      "匿名函数应被提升为模块级 define（@__closure_N），实际:\n\(ir)")
        // 闭包变量经 fat-pointer（{ ptr, ptr }）间接调用：提取 code/env 后 call，
        // 而非直接的 `call @__closure_N`（后者仅当匿名函数字面量直接作为 callee 时出现）。
        XCTAssertTrue(ir.contains("extractvalue { ptr, ptr }"),
                      "闭包变量调用应经 fat-pointer 提取 code/env 间接调用，实际:\n\(ir)")
    }

    // MARK: - P6-2a: struct 类型 IR

    /// 结构断言：struct 声明应 emit 命名结构类型定义 `%struct.Name = type { ... }`。
    func testStructTypeDefinitionEmitted() throws {
        let source = try loadPiniFixture("testStructTypeDefinitionEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("%struct.Point = type { i32, i32 }"),
                      "应 emit struct 类型定义，实际:\n\(ir)")
    }

    /// 结构断言：struct 构造应 alloca + 按字段默认值 store（对齐解释器 createInstance）。
    func testStructConstructionEmitted() throws {
        let source = try loadPiniFixture("testStructConstructionEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("alloca %struct.Point"),
                      "应 alloca struct，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 8080"),
                      "应 store 字段默认值，实际:\n\(ir)")
    }

    /// 结构断言：`.member` 字段访问应 getelementptr + load。
    func testStructMemberAccessEmitted() throws {
        let source = try loadPiniFixture("testStructMemberAccessEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("getelementptr %struct.Point"),
                      "字段访问应 getelementptr，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("load i32"),
                      "字段访问应 load，实际:\n\(ir)")
    }

    // MARK: - P6-2b: object 类型 IR

    func testObjectDeclSupported() throws {
        let source = try loadPiniFixture("testObjectDeclSupported", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("%object.Counter = type { i32, i32 }"),
                      "object 声明现在应生成命名类型（字段 0 为 i32 refcount 头），实际:\n\(ir)")
    }

    /// 结构断言：object 构造应 alloca + refcount 头(i32 1) + 字段默认值 store。
    func testObjectConstructionEmitted() throws {
        let source = try loadPiniFixture("testObjectConstructionEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("alloca %object.Counter"),
                      "应 alloca object，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 1"),
                      "refcount 头应初始化为 1，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 8080"),
                      "应 store 字段默认值，实际:\n\(ir)")
    }

    /// 结构断言：`.member` 访问 object 字段应 GEP 偏移 +1（跳过 refcount 头）+ load。
    func testObjectMemberAccessEmitted() throws {
        let source = try loadPiniFixture("testObjectMemberAccessEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("getelementptr %object.Counter"),
                      "字段访问应 getelementptr，实际:\n\(ir)")
        // 首个字段 x 位于 GEP 索引 1（字段 0 为 refcount 头）
        XCTAssertTrue(ir.contains("i32 0, i32 1"),
                      "首字段访问偏移应为 1（跳过 refcount 头），实际:\n\(ir)")
        XCTAssertTrue(ir.contains("load i32"),
                      "字段访问应 load，实际:\n\(ir)")
    }

    // MARK: - P6-2c: enum 类型 IR

    /// 结构断言：enum case 构造器（标识符）应 alloca + store tag。
    func testEnumCaseConstructionEmitted() throws {
        let source = try loadPiniFixture("testEnumCaseConstructionEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("alloca %enum.Color"),
                      "应 alloca enum，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 0"),
                      "Red 应存储 tag 0，实际:\n\(ir)")
    }

    /// 结构断言：match 应 emit `switch i32` LLVM 指令 + case/default 标签。
    func testEnumMatchEmitted() throws {
        let source = try loadPiniFixture("testEnumMatchEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("switch i32"),
                      "match 应生成 switch i32 指令，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("label %match_default_"),
                      "switch 应有 default 标签，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("match_case_"),
                      "switch 应有 case 标签，实际:\n\(ir)")
    }

    // MARK: - P6-2 衍生：字段写入（member assignment）

    /// 结构断言：`c.x = v` 应生成 store 到 GEP 指针。
    func testStructFieldWriteEmitted() throws {
        let source = try loadPiniFixture("testStructFieldWriteEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("getelementptr %struct.Point"),
                      "字段写入应 getelementptr，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 42"),
                      "字段写入应 store 42，实际:\n\(ir)")
    }

    /// 结构断言：object `c.count = v` 应 store 到偏移 +1 的指针。
    func testObjectFieldWriteEmitted() throws {
        let source = try loadPiniFixture("testObjectFieldWriteEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("getelementptr %object.Counter"),
                      "object 字段写入应 getelementptr，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 99"),
                      "object 字段写入应 store 99，实际:\n\(ir)")
    }

    // MARK: - P6-3a: defer 延迟执行

    /// 结构断言：defer 不应生成立即代码，IR 仍应成功生成（语义由执行测试验证）。
    func testDeferNotEmittedInline() throws {
        let source = try loadPiniFixture("testDeferNotEmittedInline", filePath: #filePath)
        let ir = try generateIR(source)
        // 推进性：IR 成功生成
        XCTAssertTrue(ir.contains("@printf") && ir.contains("declare i32 @printf"),
                      "defer 程序应生成有效 IR，实际:\n\(ir)")
    }

    // MARK: - P6-3b: enum 关联值 + match 绑定

    /// 结构断言：payload enum 布局应含 tag + payload 字段。
    func testEnumPayloadTypeEmitted() throws {
        let source = try loadPiniFixture("testEnumPayloadTypeEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("%enum.Shape = type { i32, i32 }"),
                      "payload enum 应含 tag + 一个 i32 字段，实际:\n\(ir)")
    }

    /// 结构断言：`Circle(42,)` 构造应 store tag + payload。
    func testEnumPayloadConstructionEmitted() throws {
        let source = try loadPiniFixture("testEnumPayloadConstructionEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("alloca %enum.Shape") && ir.contains("store i32 0"),
                      "case 构造应 alloca + store tag 0，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("store i32 42"),
                      "case 构造应 store payload 42，实际:\n\(ir)")
    }

    /// 结构断言：match `case Circle(x,)` 应 extract payload + bind to local var。
    func testEnumMatchBindingEmitted() throws {
        let source = try loadPiniFixture("testEnumMatchBindingEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("getelementptr %enum.Shape") && ir.contains("i32 0, i32 1"),
                      "match 绑定应从 payload 字段（GEP 偏移 1）load，实际:\n\(ir)")
    }

    // MARK: - P5-5 B4: 跨枚举同名 case 的 IR 限定名（命名空间化）

    /// 限定构造 `形状.圆(...)` / `几何.圆(...)` 须各自解析到正确父枚举类型，
    /// 证明限定键避免单值 case 名被覆盖串味。
    /// IR 类型名经 mangle：形状→%enum._u5F62_u72B6，几何→%enum._u51E0_u4F55。
    func testEnumQualifiedConstructionResolvesParent() throws {
        let source = try loadPiniFixture("testEnumQualifiedConstructionResolvesParent", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("alloca %enum._u5F62_u72B6"),
                      "限定构造 形状.圆 应分配 %enum.形状（mangled），实际:\n\(ir)")
        XCTAssertTrue(ir.contains("alloca %enum._u51E0_u4F55"),
                      "限定构造 几何.圆 应分配 %enum.几何（mangled），实际:\n\(ir)")
    }

    /// 匹配值类型为 形状 时，match `case 圆` / `case 矩形` 须按值 IR 类型（%enum.形状）
    /// 反查父枚举生成 switch 分发，不串到同名的 几何.圆（MED-2 的 IR 侧落实）。
    func testEnumMatchQualifiedNoCollision() throws {
        let source = try loadPiniFixture("testEnumMatchQualifiedNoCollision", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("switch i32"),
                      "match 应按值父枚举 %enum.形状 生成 switch 分发，不串到 几何.圆，实际:\n\(ir)")
    }

    // MARK: - P6-4a: 多返回值

    /// 结构断言：多返回函数签名应映射为 LLVM struct 类型。
    func testMultiReturnSignatureEmitted() throws {
        let source = try loadPiniFixture("testMultiReturnSignatureEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("define { i32, i32 } @addAndSub"),
                      "多返回签名应对应 LLVM struct 类型，实际:\n\(ir)")
    }

    /// 结构断言：调用多返回函数应产生 struct 值。
    func testMultiReturnCallEmitted() throws {
        let source = try loadPiniFixture("testMultiReturnCallEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("call { i32, i32 } @addAndSub"),
                      "多返回调用应对应 struct 返回类型，实际:\n\(ir)")
        XCTAssertTrue(ir.contains("ret { i32, i32 }"),
                      "return 应打包为 struct，实际:\n\(ir)")
    }

    // MARK: - P6-4d: trait 方法分发

    /// 结构断言：trait 默认方法被调用时生成独立函数体。
    func testTraitDefaultMethod_GeneratesFunction() throws {
        let source = try loadPiniFixture("testTraitDefaultMethod_GeneratesFunction", filePath: #filePath)
        let ir = try generateIR(source)
        // trait 默认方法应生成独立函数
        XCTAssertTrue(ir.contains("define i32 @describe"),
                      "应生成 trait 方法函数 @describe")
        // 应包含对 describe 的调用
        XCTAssertTrue(ir.contains("call i32 @describe"),
                      "应包含 trait 方法调用")
    }

    /// 结构断言：类型覆盖 trait 方法时，使用类型自身方法。
    func testTraitOverride_UsesTypeMethod() throws {
        let source = try loadPiniFixture("testTraitOverride_UsesTypeMethod", filePath: #filePath)
        let ir = try generateIR(source)
        // 类型自身方法应存在，且 trait 版本不应生成（类型覆盖了）
        XCTAssertTrue(ir.contains("define i32 @describe"),
                      "应有类型自身的 @describe")
        // 应只出现一次 define（只有类型方法，无 trait 方法）
        let count = ir.components(separatedBy: "define i32 @describe").count - 1
        XCTAssertEqual(count, 1, "应只有一个 @describe 函数定义")
    }

    // MARK: - P6-4c: 内置 IO（readLine）

    /// 结构断言：readLine() 应生成 fgets + @stdin 调用。
    func testReadLineEmitted() throws {
        let source = try loadPiniFixture("testReadLineEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("@fgets") && ir.contains("__stdinp"),
                      "readLine 应生成 fgets + __stdinp 调用，实际:\n\(ir)")
    }

    /// 边界断言：readLine 的结果是 ptr 类型，可直接传给 print %s。
    func testReadLineReturnsPtr() throws {
        let source = try loadPiniFixture("testReadLineReturnsPtr", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("call ptr @fgets") && ir.contains("__stdinp"),
                      "readLine 调用应返回 ptr，实际:\n\(ir)")
    }

    /// 结构断言：writeFile 应生成 fopen("w")/fwrite/fclose 链。
    func testWriteFileEmitted() throws {
        let source = try loadPiniFixture("testWriteFileEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("@fopen") && ir.contains("@fwrite") && ir.contains("@fclose"),
                      "writeFile 应生成 fopen/fwrite/fclose 调用链，实际:\n\(ir)")
    }

    /// 结构断言：readFile 应生成 fopen("r")/fseek/ftell/malloc/fread/fclose 链。
    func testReadFileEmitted() throws {
        let source = try loadPiniFixture("testReadFileEmitted", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("@fopen") && ir.contains("@fread"),
                      "readFile 应生成 fopen/fread 调用链，实际:\n\(ir)")
    }

    /// P4：match 带通配子块时，IR 的 switch 兜底块（match_default_）应存在且承载 wildcard 块，
    /// 即 generateMatchStatement 的 `fallback = wildcardBlock ?? defaultCase` 已连通。
    func testWildcardMatchGeneratesFallbackBlock() throws {
        let source = try loadPiniFixture("testWildcardMatchGeneratesFallbackBlock", filePath: #filePath)
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("match_default_"),
                      "wildcard 通配子块应生成兜底块（fallback = wildcardBlock），实际:\n\(ir)")
        XCTAssertTrue(ir.contains("switch i32"),
                      "应生成枚举 tag 的 switch 指令")
    }
}
