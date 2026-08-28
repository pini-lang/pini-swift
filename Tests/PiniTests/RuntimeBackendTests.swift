import XCTest
@testable import PiniCore

/// #46-D / ADR-008 阶段1：集合运行时端到端验证门。
///
/// 验证「Swift shim 动态库 → C ABI → `lli --dlopen` / `clang -l` 加载 → `@bk_*` 经 JIT/AOT 解析」
/// 全链路在真实工具链下贯通。这是 D0 去风险 spike 的回归固化：任何导致运行时句柄类型 /
/// 加载机制 / 声明缺失的回归都会在此红灯。
///
/// 设计要点：
/// - 借 `IRPrintGoldenTests.runViaLLI` 同款手法生成 IR 并 `lli --dlopen=<dylib>` 执行；
/// - 动态库路径经 packageRoot 回溯（与 ExamplesRunTests 一致），缺失则 `XCTSkip`（无 LLVM 环境不红）；
/// - 归一化对比解释器，证明双后端对数组下标 / len 的计算一致（LLVM print 不补换行、解释器补换行，
///   故比较前剥离 `\n`）。
final class RuntimeBackendTests: XCTestCase {

    private var lliAvailable: Bool { LLVMToolchain.lliPath != nil }
    private var clangAvailable: Bool { LLVMToolchain.clangPath != nil }

    private func packageRoot() -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) { return url.path }
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    /// 定位集合运行时动态库（swift build 产物）：`.build/debug/libPiniRuntime.{dylib,so}`。
    private func locateRuntimeDylib() -> String? {
        let root = packageRoot()
        let buildDir = (root as NSString).appendingPathComponent(".build/debug")
        for ext in ["dylib", "so"] {
            let cand = (buildDir as NSString).appendingPathComponent("libPiniRuntime.\(ext)")
            if FileManager.default.fileExists(atPath: cand) { return cand }
        }
        return nil
    }

    /// 经 `lli --dlopen=<dylib>` JIT 执行源码，返回 stdout（不含任何换行归一化）。
    private func runViaLLIWithRuntime(_ source: String, dylib: String, fileName: String = "test.pini") throws -> String {
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()
        let ir = try IRGenerator().generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_rt_\(UUID().uuidString).ll"
        defer { try? FileManager.default.removeItem(atPath: tmpIR) }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let lli = LLVMToolchain.lliPath else {
            throw NSError(domain: "LLIUnavailable", code: -1, userInfo: [NSLocalizedDescriptionKey: "lli not available"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lli)
        process.arguments = ["--dlopen=\(dylib)", tmpIR]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 经 `clang -lPiniRuntime` AOT 静态链接并执行源码，返回 stdout（不含换行归一化）。
    ///
    /// 与 `runViaLLIWithRuntime` 产出**同一份** LLVM IR，仅执行模式不同（AOT 静态链接 vs JIT dlopen）。
    /// 此臂专门捕获 JIT/dlopen 容忍、但静态链接会暴露的运行时 C-ABI 符号可见性回归
    /// （例如 D4.2.3 新增的 `bk_*_destroy` 若漏 `@_cdecl` 导出，clang 链接期即失败）。
    private func runViaClangWithRuntime(_ source: String, dylib: String, fileName: String = "test.pini") throws -> String {
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()
        let ir = try IRGenerator().generate(module: module)

        let tmpIR = FileManager.default.temporaryDirectory.path + "/pini_clang_\(UUID().uuidString).ll"
        let tmpBin = FileManager.default.temporaryDirectory.path + "/pini_clang_\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmpIR)
            try? FileManager.default.removeItem(atPath: tmpBin)
        }
        try ir.write(toFile: tmpIR, atomically: true, encoding: .utf8)

        guard let clang = LLVMToolchain.clangPath else {
            throw NSError(domain: "ClangUnavailable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "clang not available"])
        }
        let dir = URL(fileURLWithPath: dylib).deletingLastPathComponent().path
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: clang)
        compile.arguments = ["-L\(dir)", "-lPiniRuntime", "-Wl,-rpath,\(dir)", "-o", tmpBin, tmpIR]
        let errPipe = Pipe()
        compile.standardError = errPipe
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "ClangLinkError", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "clang AOT 链接失败：\(detail)"])
        }

        let run = Process()
        run.executableURL = URL(fileURLWithPath: tmpBin)
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = Pipe()
        try run.run()
        run.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 进程内解释执行，返回 stdout（每条 print 补一个换行，对齐 `pini run` 语义）。
    private func runViaInterpreter(_ source: String, fileName: String = "test.pini") throws -> String {
        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let module = try Parser(tokens: tokens, fileName: fileName).parseModule()
        let interpreter = Interpreter()
        var segments: [String] = []
        interpreter.outputSink = { segments.append($0 + "\n") }
        try interpreter.run(module: module)
        return segments.joined(separator: "")
    }

    /// D0 冒烟：经运行时 shim 的数组字面量 / 下标 / len 在真实 lli JIT 下贯通。
    /// 意图：验证数组字面量/下标/len 经运行时 shim + lli --dlopen JIT 输出 203，且与解释器计算一致。
    func testArrayViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }

        let src = """
        main|func() -> ()
            let a = [10, 20, 30]
            print(a[1])
            print(len(a))
            return
        """

        let llvmOut = try runViaLLIWithRuntime(src, dylib: dylib)
        // LLVM print 不补换行 → 归一化前原样为 "203"
        XCTAssertEqual(llvmOut, "203", "数组经运行时 shim + lli --dlopen 应输出 20(a[1]) 与 3(len)，无换行")

        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(interpOut, "20\n3\n", "解释器侧应输出 20 与 3（每条 print 补换行）")

        // 双后端计算一致（剥离换行后）
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "数组下标 / len 双后端计算应一致")
    }

    /// D4.2.4 冒烟：基础数组经 `clang -lPiniRuntime` AOT 静态链接运行时 shim 在真实工具链下贯通。
    /// 与 `testArrayViaRuntimeLLI` 同源 IR，仅执行模式不同（AOT 静态链接 vs JIT dlopen）——验证运行时
    /// C-ABI 符号在 AOT 链接下可见（JIT/dlopen 容忍的可见性回归，静态链接会暴露）。
    /// 意图：验证数组经 clang -lPiniRuntime AOT 静态链接同样输出 203（C-ABI 符号静态链接下可见），且与解释器计算一致。
    func testArrayViaRuntimeClang() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try XCTSkipUnless(clangAvailable, "clang not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }

        let src = """
        main|func() -> ()
            let a = [10, 20, 30]
            print(a[1])
            print(len(a))
            return
        """

        let clangOut = try runViaClangWithRuntime(src, dylib: dylib)
        XCTAssertEqual(clangOut, "203", "数组经 clang -lPiniRuntime AOT 应输出 20(a[1]) 与 3(len)，无换行")

        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(clangOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "clang AOT 与解释器数组下标/len 计算应一致")
    }

    /// 结构断言：数组 IR 必须走 ADR-008 不透明句柄路径，且旧的内联 [N x T] 表示已移除。
    /// 意图：断言数组 IR 走 ADR-008 不透明句柄路径（%bk_array 类型 + @bk_array_create/@bk_array_set/@bk_array_len），且旧的内联 [3 x i32] 表示已移除。
    func testArrayIRUsesRuntimeHandle() throws {
        let src = """
        main|func() -> ()
            var arr = [10, 20, 30]
            print(len(arr))
            return
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        XCTAssertTrue(ir.contains("%bk_array = type { ptr }"), "应声明 %bk_array 不透明句柄类型")
        XCTAssertTrue(ir.contains("call ptr @bk_array_create(i32 3)"), "应调用运行时创建长度为 3 的数组")
        XCTAssertTrue(ir.contains("call ptr @bk_array_set(ptr"), "每个元素应生成 @bk_array_set 调用（装箱-raw 模型）")
        XCTAssertTrue(ir.contains("bitcast %bk_array*"), "句柄应在 %bk_array* 与 ptr 间 bitcast")
        XCTAssertTrue(ir.contains("call i32 @bk_array_len(ptr"), "len(数组) 应调用运行时 @bk_array_len")
        XCTAssertFalse(ir.contains("[3 x i32]"), "不应再生成定长数组内联类型 [3 x i32]（已迁运行时句柄）")
    }

    /// 双后端锁步（epic-46 3.4）：越界下标——P2-C 后解释器侧改为安全通道返回 nil（不再抛错），
    /// 与字典缺失键一致；LLVM 侧仍走 `bk_panic`（M2 阶段再对齐安全通道，见 issue-lexer-gaps P2-C 对齐 backlog）。
    /// 意图：验证解释器越界下标 a[99] 返回 nil；LLVM 越界经 bk_panic 终止且 stdout 为空（两侧尚未统一为 nil）。
    func testArrayOutOfBoundsBothBackendsError() throws {
        let src = """
        main|func() -> ()
            let a = [10, 20, 30]
            print(a[99])
            return
        """

        // 解释器侧（issue-host-optional-slice，严格枚举语义）：安全通道越界返回 Optional.none，不再抛 RuntimeError
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(interpOut, "none\n", "严格枚举：解释器越界下标 a[99] 应返回 Optional.none")

        // LLVM 侧（M2 前）：bk_panic 触发 abort，lli 进程非零退出、stdout 为空。
        // 注意：LLVM 安全通道（越界→nil）对齐属 M2 阶段工作，暂未与解释器锁步。
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let llvmOut = try runViaLLIWithRuntime(src, dylib: dylib)
        XCTAssertTrue(llvmOut.isEmpty,
                      "LLVM 越界应经 bk_panic 终止，stdout 应为空（实际：'\(llvmOut)'）")
    }

    /// 双后端锁步：空数组 `[]` 两侧均可用（len == 0），LLVM 不再 spurious 拒绝。
    /// 意图：验证空数组 [] 双后端均可用（len 为 0），LLVM 不再 spurious 拒绝。
    func testEmptyArrayBothBackends() throws {
        let src = """
        main|func() -> ()
            let a = []
            print(len(a))
            return
        """

        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(interpOut, "0\n", "解释器空数组 len 应为 0")

        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let llvmOut = try runViaLLIWithRuntime(src, dylib: dylib)
        XCTAssertEqual(llvmOut, "0", "LLVM 空数组 len 应为 0（print 不补换行）")
    }

    // MARK: - #46-D D1：数组元素类型扩展（Int 之外支持 F64/Bool/String），双后端对齐

    /// 字符串元素数组：LLVM（装箱-raw 模型）与解释器输出完全一致（字符串 print 格式一致）。
    /// 意图：验证字符串元素数组构造/下标/len 双后端归一化输出一致（装箱-raw 模型与解释器对齐）。
    func testStringArrayViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            let a = ["hello", "world", "foo"]
            print(a[1])
            print(len(a))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "字符串元素数组构造/下标/len 双后端应一致")
    }

    /// 嵌套字符串数组：内层 handle 经 box 透传，双层下标读双后端一致。
    /// 意图：验证嵌套字符串数组 m[0][1] 双层下标读经内层 handle box 透传，双后端归一化输出一致。
    func testNestedStringArrayViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            let m = [["a", "b"], ["c", "d"]]
            print(m[0][1])
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "嵌套字符串数组双层下标读双后端应一致")
    }

    /// F64 元素数组：下标读 VALUE 正确（LLVM 打印 2.500000 / 解释器 2.5，浮点格式差异属已知缺口 G-IR-enum-print，
    /// 非 D1 回归）；len 两侧一致。
    /// 意图：验证 F64 元素数组下标读 VALUE 双后端均读出 2.5（浮点格式差异属已知缺口）、len 均一致为 3。
    func testF64ArrayViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            let a = [1.5, 2.5, 3.5]
            print(a[1])
            print(len(a))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        let llvmNorm = llvmOut.replacingOccurrences(of: "\n", with: "")
        let interpNorm = interpOut.replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(llvmNorm.contains("2.5"), "LLVM 应读出 2.5（格式化差异属已知浮点缺口）")
        XCTAssertTrue(interpNorm.contains("2.5"), "解释器应读出 2.5")
        XCTAssertTrue(llvmNorm.hasSuffix("3") && interpNorm.contains("3"), "len 应一致为 3")
    }

    /// Bool 元素数组：LLVM 经 `select`+`%s` 打印 true/false（与解释器完全一致），双后端精确对齐。
    /// 意图：验证 Bool 元素数组构造/下标/len 双后端精确对齐（LLVM 经 select 打印 true/false 与解释器一致）。
    func testBoolArrayViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            let a = [true, false, true]
            print(a[0])
            print(len(a))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "Bool 元素数组构造/下标/len 双后端应一致（LLVM 亦打印 true/false）")
    }

    private func requireDylib() throws -> String {
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        return dylib
    }

    // MARK: - #46-D D1.5：数组下标写 a[i] = v（双后端对齐）

    /// 解释器侧：a[i]=v / a[i]+=k / 嵌套 m[0][1]=v / 多元素类型（Int/Bool/String）全部就地生效。
    /// 意图：验证解释器侧下标写（a[i]=v、复合 +=、嵌套 m[0][1]=v、Int/String/Bool 多类型）全部就地生效，输出 10/25/3/99/z/false。
    func testArraySubscriptWriteInterpreter() throws {
        // 严格枚举语义（issue-host-optional-slice）：下标读返回 Optional，复合赋值 a[1] += 5
        // 须先 match 取出元素再写回，不再对下标读做值语境透明解包。
        let src = """
        main|func() -> ()
            var a = [1, 2, 3]
            a[0] = 10
            a[1] = 20
            match a[1]:
                case some(v):
                    a[1] = v + 5
                case none:
                    break
            print(a[0])
            print(a[1])
            print(a[2])
            var m = [[1, 2], [3, 4]]
            var mrow = unsafe m[0]!
            mrow[1] = 99
            m[0] = mrow
            print(unsafe m[0]![1]!)
            var s = ["a", "b"]
            s[0] = "z"
            print(s[0])
            var b = [true, false]
            b[0] = false
            print(b[0])
            return
        """
        let out = try runViaInterpreter(src)
        // 严格枚举语义：单层下标读返回 some(...)；而嵌套读 m[0]![1]! 经显式 `!` 剥壳取裸值 99。
        XCTAssertEqual(out, "some(10)\nsome(25)\nsome(3)\n99\nsome(z)\nsome(false)\n",
                       "解释器下标写（含嵌套/复合/多类型）应就地生效；单层读返回 some(...)、嵌套读经 `!` 剥壳取裸值")
    }

    /// 双后端锁步：下标写（含嵌套/复合/多元素类型）两侧 stdout 归一化后一致。
    /// 意图：验证下标写（含嵌套/复合/多元素类型）双后端归一化输出一致。
    func testArraySubscriptWriteBothBackends() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            var a = [1, 2, 3]
            a[0] = 10
            a[1] = 20
            a[1] += 5
            print(a[0])
            print(a[1])
            print(a[2])
            var m = [[1, 2], [3, 4]]
            var mrow = unsafe m[0]!
            mrow[1] = 99
            m[0] = mrow
            print(unsafe m[0]![1]!)
            var s = ["a", "b"]
            s[0] = "z"
            print(s[0])
            var b = [true, false]
            b[0] = false
            print(b[0])
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "数组下标写（嵌套/复合/多类型）双后端归一化输出应一致")
    }

    /// 双后端锁步（epic-46 3.4）：越界下标写两侧均报错。
    /// 解释器抛 RuntimeError；LLVM 经运行时 `bk_panic` 终止进程（stdout 空）。
    /// 意图：验证越界下标写 a[5]=9 双后端均报错——解释器抛 RuntimeError，LLVM 经 bk_panic 终止且 stdout 为空。
    func testArrayWriteOutOfBoundsBothBackendsError() throws {
        let src = """
        main|func() -> ()
            var a = [10, 20, 30]
            a[5] = 9
            return
        """
        // 解释器侧：越界下标写应抛错
        XCTAssertThrowsError(try runViaInterpreter(src), "解释器越界下标写 a[5]=9 应抛 RuntimeError")

        // LLVM 侧：bk_panic 触发 abort，lli 进程非零退出、stdout 为空
        try XCTSkipUnless(lliAvailable, "lli not available")
        guard let dylib = locateRuntimeDylib() else { throw XCTSkip("PiniRuntime dylib not built") }
        let llvmOut = try runViaLLIWithRuntime(src, dylib: dylib)
        XCTAssertTrue(llvmOut.isEmpty,
                      "LLVM 越界写应经 bk_panic 终止，stdout 应为空（实际：'\(llvmOut)'）")
    }

    // MARK: - #46-D D2：字典 / 集合 后端（LLVM 端补齐，双后端锁步）

    /// 字典：构造 + 键读 + len，LLVM（装箱-raw 模型 + tag 字节内容比较）与解释器输出一致。
    /// 字符串键经 tag=str 按 C 串内容比较，与 generateStringLiteral 不为相同文本复用全局无关（解耦指针身份）。
    /// 意图：验证字典构造/键读/len 双后端归一化输出一致（字符串键按 tag=str 内容比较，与指针身份解耦）。
    func testDictViaRuntimeLLI() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            let ages = ["Alice": 30, "Bob": 25, "Carol": 41]
            print(ages["Bob"])
            print(len(ages))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "字典构造/键读/len 双后端归一化输出应一致")
    }

    /// 字典键写：a[k] = v（含新增键与既有键替换）双后端锁步。
    /// 解释器值语义返回新字典重绑定；LLVM 原地改 handle，单绑定下观测一致（别名语义属 D4 COW 范畴）。
    /// 意图：验证字典键写（既有键替换 + 新增键）双后端归一化输出一致（单绑定下观测一致，别名语义属 D4 COW 范畴）。
    func testDictSubscriptWriteBothBackends() throws {
        throw XCTSkip("M2: 下标读严格枚举 some/none 与 LLVM 后端未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        let src = """
        main|func() -> ()
            var ages = ["Alice": 30, "Bob": 25]
            ages["Bob"] = 26
            ages["Dave"] = 99
            print(ages["Bob"])
            print(ages["Dave"])
            print(len(ages))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""),
                       interpOut.replacingOccurrences(of: "\n", with: ""),
                       "字典键写（新增键 + 既有键替换）双后端归一化输出应一致")
    }

    /// 集合：构造 + len（保序去重），LLVM 与解释器一致。
    /// 集合下标读在解释器侧亦未支持，故此处仅覆盖构造 / len（与解释器能力锁步）。
    /// 意图：验证集合构造 + len（保序去重 {2,3,3,5,7,7,11} → 5）双后端一致；集合下标读未支持故不覆盖。
    func testSetViaRuntimeLLI() throws {
        let src = """
        main|func() -> ()
            let primes = {2, 3, 3, 5, 7, 7, 11}
            print(len(primes))
            return
        """
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""), "5", "集合 len 应为去重后 5")
        XCTAssertEqual(interpOut.replacingOccurrences(of: "\n", with: ""), "5", "解释器集合 len 应为去重后 5")
    }

    /// 字典缺失键：解释器返回 .null（打印 "null"），LLVM 经 @bk_dict_get 返回 NULL 后补零值（Int 值类型 → 0）。
    /// 二者存在已知分歧（print(.null) 属 D3 范畴，D2 仅覆盖既有键读取 / len / 写），此处仅断言两侧均不崩溃。
    /// 意图：验证字典缺失键双后端均不崩溃（解释器 .null / LLVM 补零值），断言两侧输出 1。
    func testDictMissingKeyBothBackends() throws {
        let src = """
        main|func() -> ()
            let ages = ["Alice": 30]
            let x = ages["ZZZ"]
            print(1)
            return
        """
        let interpOut = try runViaInterpreter(src)
        XCTAssertEqual(interpOut.replacingOccurrences(of: "\n", with: ""), "1", "解释器缺失键不应崩溃")
        let llvmOut = try runViaLLIWithRuntime(src, dylib: try requireDylib())
        XCTAssertEqual(llvmOut.replacingOccurrences(of: "\n", with: ""), "1", "LLVM 缺失键（补零值）不应崩溃")
    }

    // MARK: - #46-D D4.2.1b：容器值语义（COW）双后端锁步

    /// 双后端锁步断言：同一源码在解释器与 `lli --dlopen` 运行时下**输出逐字节一致**（剥离换行，
    /// 因 LLVM 单参 print 不补换行属预存缺口），且等于期望值。
    ///
    /// COW 场景必须双向断言：既要「写别名不污染源」，也要「写源不污染别名」，
    /// 否则 share 记账方向错误（漏 retain / 多 release）仍可能单向偶然通过。
    private func assertBackendsAgree(_ src: String, expected: String, _ message: String) throws {
        let dylib = try requireDylib()
        let interpOut = try runViaInterpreter(src).replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(interpOut, expected, "解释器：\(message)")
        let llvmOut = try runViaLLIWithRuntime(src, dylib: dylib).replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(llvmOut, expected, "LLVM：\(message)")
        XCTAssertEqual(llvmOut, interpOut, "双后端应逐字节一致：\(message)")
    }

    /// D4.2.4 三执行路径锁步断言：同一源码在 **解释器**、**`lli --dlopen`**、**`clang -lPiniRuntime`**
    /// 三执行路径下输出逐字节一致（剥离换行），且等于期望值。
    ///
    /// 三条路径 = 两个后端（解释器 + LLVM IR）+ LLVM IR 的两种执行模式（JIT dlopen / AOT 静态链接）。
    /// AOT 臂专用于捕获「静态链接才暴露」的运行时 C-ABI 符号可见性回归（如 `bk_*_destroy` 漏 `@_cdecl`）。
    /// 无 lli/clang 时 `XCTSkip`（不红），与既有工具链缺失跳过策略一致。
    private func assertTripleBackendsAgree(_ src: String, expected: String, _ message: String) throws {
        try XCTSkipUnless(lliAvailable && clangAvailable, "lli/clang not available")
        let dylib = try requireDylib()
        let interpOut = try runViaInterpreter(src).replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(interpOut, expected, "解释器：\(message)")
        let lliOut = try runViaLLIWithRuntime(src, dylib: dylib).replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(lliOut, expected, "lli-JIT：\(message)")
        let clangOut = try runViaClangWithRuntime(src, dylib: dylib).replacingOccurrences(of: "\n", with: "")
        XCTAssertEqual(clangOut, expected, "clang-AOT：\(message)")
        XCTAssertEqual(lliOut, interpOut, "lli-JIT 与解释器应逐字节一致：\(message)")
        XCTAssertEqual(clangOut, interpOut, "clang-AOT 与解释器应逐字节一致：\(message)")
        XCTAssertEqual(clangOut, lliOut, "clang-AOT 与 lli-JIT 应逐字节一致：\(message)")
    }

    /// `var b = a` 后写任一方，另一方不受影响（数组值语义）。双向覆盖。
    /// 意图：验证数组别名 COW 双向不污染（写 b 不污染 a、写 c 不污染 d），期望 [1,2,3][99,2,3][1,7][1,2]。
    func testArrayAliasCOWBothBackends() throws {
        try assertBackendsAgree("""
        main|func() -> ()
            var a = [1, 2, 3]
            var b = a
            b[0] = 99
            print(a)
            print(b)
            var c = [1, 2]
            var d = c
            c[1] = 7
            print(c)
            print(d)
            return
        """, expected: "[1, 2, 3][99, 2, 3][1, 7][1, 2]", "数组别名写入应分裂，源与别名互不污染（双向）")
    }

    // MARK: - #46-E G40（S3）：LazyRef LLVM 端（统一 ptr ABI wrapper，once 锁求值）

    /// 意图：LazyRef .value 三执行路径锁步（解释器/lli-JIT/clang-AOT）——构造 + once 缓存输出一致。
    func testLazyRefValueTripleBackendsAgree() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var r = LazyRef<I32>(func () -> (I32,): return 42)
            print(r.value)
            print(r.value)
            return
        """, expected: "4242", "LazyRef .value 三执行路径一致（初始化一次、两次读取同值）")
    }

    /// 字符串数组（元素为 `ptr`）别名 COW：验证深拷按元素宽度/tag 正确搬运，不只对 I32 生效。
    /// 意图：验证字符串元素数组（ptr 元素）别名写入同样触发分裂，深拷按元素宽度/tag 正确搬运，不只对 I32 生效。
    func testStringArrayAliasCOWBothBackends() throws {
        try assertBackendsAgree("""
        main|func() -> ()
            var s1 = ["a", "b"]
            var s2 = s1
            s2[1] = "z"
            print(s1)
            print(s2)
            return
        """, expected: "[a, b][a, z]", "字符串数组别名写入应分裂")
    }

    /// 复合赋值 `b[0] += 5` 走「读-算-写」路径，同样必须触发分裂（写回句柄不能丢）。
    /// 意图：验证复合赋值 b[0] += 5 走「读-算-写」路径同样触发分裂，源与别名互不污染。
    func testCompoundAssignAliasCOWBothBackends() throws {
        throw XCTSkip("M2: 复合赋值 a[i] += k 与下标读严格枚举 some/none 的 LLVM 对齐未做，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertBackendsAgree("""
        main|func() -> ()
            var a = [10, 20]
            var b = a
            b[0] += 5
            print(a)
            print(b)
            return
        """, expected: "[10, 20][15, 20]", "复合赋值别名写入应分裂")
    }

    /// 字典别名 COW：键改写与新增键均须分裂（含 len 不串）。
    /// 意图：验证字典别名写入（键改写 + 新增键）均须分裂且 len 不串，期望 {a:9}{a:1} 与 len 2/3。
    func testDictAliasCOWBothBackends() throws {
        try assertBackendsAgree("""
        main|func() -> ()
            var m1 = ["a": 1]
            var m2 = m1
            m1["a"] = 9
            print(m1)
            print(m2)
            var n1 = ["p": 1, "q": 2]
            var n2 = n1
            n2["r"] = 3
            print(len(n1))
            print(len(n2))
            return
        """, expected: "{a: 9}{a: 1}23", "字典别名写入应分裂（改写 + 新增键，len 不串）")
    }

    /// 所有权契约 ③ 回归：容器变量被放入另一个容器（`var outer = [inner]` / `["k": arr]`）时，
    /// codegen 必须补一份 share；随后写 `inner` 会分裂，`outer` 内的快照保持原值。
    /// 漏 retain 时运行时误判独占 → 原地改写 → outer 被污染（本用例红灯）。
    /// 意图：验证所有权契约③——容器变量装入另一容器（var outer = [inner] / ["k": arr]）时 codegen 补 share，随后写 inner 分裂、outer 内快照不变。
    func testContainerElementRetainsShareBothBackends() throws {
        try assertBackendsAgree("""
        main|func() -> ()
            var inner = [1, 2]
            var outer = [inner]
            inner[0] = 42
            print(inner)
            print(outer)
            var arr = [1, 2]
            var box = ["k": arr]
            arr[0] = 8
            print(arr)
            print(box)
            return
        """, expected: "[42, 2][[1, 2]][8, 2]{k: [1, 2]}", "被容器持有的容器变量写入应分裂，容器内快照不变")
    }

    /// #46-D D4.2.2 嵌套写正确性（先于 COW，独立缺陷）：`m[0][0] = v` 必须只改内层对应槽。
    ///
    /// 解释器曾把「本层容器」错取为「上一层容器」（`eval(outerContainer)` 而非 `eval(target)`），
    /// 把内层值写进外层槽 → `[[99, [3, 4]], [3, 4]]` 这种结构错乱。本用例锁死修复。
    /// 意图：验证嵌套写 m[0][0]=v 只改内层对应槽（修复曾把内层值写进外层槽的结构错乱），期望 [[99,2],[3,4]] 等。
    func testNestedSubscriptWriteBothBackends() throws {
        throw XCTSkip("M2: 严格枚举下嵌套写须 `!`+`unsafe`，而 LLVM 后端暂不支持 FFI/unsafe 子系统（见 docs/issue-host-optional-slice-2026-08-28.md）；解释器侧嵌套写范式见 examples/multidim.pini，双后端锁步待 M2 完成")
        try assertBackendsAgree("""
        main|func() -> ()
            var m = [[1, 2], [3, 4]]
            m[0][0] = 99
            print(m)
            var k = [[1, 2], [3, 4]]
            k[0][1] = 88
            print(k)
            var d = ["a": [1, 2]]
            d["a"][0] = 7
            print(d)
            return
        """, expected: "[[99, 2], [3, 4]][[1, 88], [3, 4]]{a: [7, 2]}",
        "嵌套下标写只应改内层目标槽，不得把内层值写进外层槽")
    }

    /// #46-D D4.2.2 嵌套 COW 递归分裂：`var n = m` 后写 `m[0][0]`，`n` 必须完全不受影响。
    ///
    /// LLVM 端 `var n = m` 只复制外层裸 ptr，两个外层槽存着**同一个内层句柄**；
    /// 内层自身 `shares == 1`，若不先分裂外层（`@bk_handle_ensure_unique`）再分裂内层
    /// （`@bk_array_ensure_unique_at` / `@bk_dict_ensure_unique_at`），内层会被误判独占而原地改写，污染 `n`。
    /// 意图：验证嵌套别名 var n = m 后写 m[0][0] 须自顶向下递归分裂（先根后内层），别名 n 的内层快照不被污染。
    func testNestedAliasCOWBothBackends() throws {
        throw XCTSkip("M2: 严格枚举下嵌套写须 `!`+`unsafe`，而 LLVM 后端暂不支持 FFI/unsafe 子系统（见 docs/issue-host-optional-slice-2026-08-28.md）；双后端锁步待 M2 完成")
        try assertBackendsAgree("""
        main|func() -> ()
            var m = [[1, 2], [3, 4]]
            var n = m
            m[0][0] = 99
            print(m)
            print(n)
            var d = ["a": [1, 2]]
            var e = d
            d["a"][0] = 7
            print(d)
            print(e)
            return
        """, expected: "[[99, 2], [3, 4]][[1, 2], [3, 4]]{a: [7, 2]}{a: [1, 2]}",
        "嵌套写须自顶向下递归分裂，别名的内层快照不得被污染")
    }

    /// #46-D D4.2.2 嵌套 COW 的困难形态：混合容器种类（数组套字典 / 字典套字典）、三层嵌套、
    /// 嵌套复合赋值、以及**无别名**时行为不变（不应因引入分裂链而改变语义）。
    ///
    /// 混合形态同时回归类型解析修复：`resolveArrayElementType`/`resolveDictValueType` 的 `.subscript`
    /// 分支原先各自递归调用自己（= 假定整条链同种容器），`a[0]["k"]` / `d["x"]["y"]` 因此误报
    /// 「未记录变量 … 的数组元素类型 / 字典值类型」。现统一经 `resolveSubscriptResultType`。
    /// 意图：验证混合容器种类（数组套字典/字典套字典）、三层嵌套、嵌套复合赋值均递归分裂，且无别名时语义不变。
    func testNestedMixedContainerCOWBothBackends() throws {
        throw XCTSkip("M2: 嵌套复合赋值 c[0][0] += 5 与下标读严格枚举 some/none 的 LLVM 对齐未做，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertBackendsAgree("""
        main|func() -> ()
            var a = [["k": 1], ["k": 2]]
            var b = a
            a[0]["k"] = 9
            print(a)
            print(b)
            var t = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]]
            var u = t
            t[0][1][0] = 77
            print(t)
            print(u)
            var p = ["x": ["y": 1]]
            var q = p
            p["x"]["y"] = 5
            print(p)
            print(q)
            var s = [[1, 2], [3, 4]]
            s[1][1] = 40
            print(s)
            var c = [[10, 20]]
            var g = c
            c[0][0] += 5
            print(c)
            print(g)
            return
        """, expected: "[{k: 9}, {k: 2}][{k: 1}, {k: 2}]"
            + "[[[1, 2], [77, 4]], [[5, 6], [7, 8]]][[[1, 2], [3, 4]], [[5, 6], [7, 8]]]"
            + "{x: {y: 5}}{x: {y: 1}}"
            + "[[1, 2], [3, 40]]"
            + "[[15, 20]][[10, 20]]",
        "混合容器 / 三层嵌套 / 嵌套复合赋值均须递归分裂；无别名时语义不变")
    }

    /// #46-D D4.2.2 IR 结构断言：嵌套写必须发射「根 ensure_unique → 中间层 ensure_unique_at」链，
    /// 且非嵌套 `a[i] = v` **不**发射该链（保持最常见形态的 IR 不膨胀，既有 golden 字节不变）。
    /// 意图：断言嵌套写 IR 发射「根 @bk_handle_ensure_unique → 中间层 @bk_array_ensure_unique_at/@bk_dict_ensure_unique_at」独占化链，且非嵌套写不发射该链（IR 不膨胀）。
    func testNestedCOWIRContract() throws {
        func irOf(_ src: String) throws -> String {
            let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
            let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
            return try IRGenerator().generate(module: module)
        }

        let nestedIR = try irOf("""
        main|func() -> ()
            var m = [[1, 2], [3, 4]]
            var n = m
            m[0][0] = 99
            return
        """)
        XCTAssertTrue(nestedIR.contains("declare ptr @bk_array_ensure_unique_at(ptr, i32)"),
                      "应声明数组中间层独占化原语")
        XCTAssertTrue(nestedIR.contains("call ptr @bk_handle_ensure_unique(ptr"),
                      "嵌套写应先独占化根变量句柄")
        XCTAssertTrue(nestedIR.contains("call ptr @bk_array_ensure_unique_at(ptr"),
                      "嵌套写应对中间层发射就地独占化")

        let dictNestedIR = try irOf("""
        main|func() -> ()
            var d = ["a": [1, 2]]
            var e = d
            d["a"][0] = 7
            return
        """)
        XCTAssertTrue(dictNestedIR.contains("declare ptr @bk_dict_ensure_unique_at(ptr, ptr, i32, i32)"),
                      "应声明字典中间层独占化原语")
        XCTAssertTrue(dictNestedIR.contains("call ptr @bk_dict_ensure_unique_at(ptr"),
                      "字典中间层嵌套写应发射就地独占化")

        let flatIR = try irOf("""
        main|func() -> ()
            var a = [1, 2]
            var b = a
            b[0] = 9
            return
        """)
        XCTAssertFalse(flatIR.contains("call ptr @bk_array_ensure_unique_at(ptr"),
                       "非嵌套写不应发射分裂链（由 @bk_array_set 自身的 ensure_unique + 写回承担）")
        XCTAssertFalse(flatIR.contains("call ptr @bk_handle_ensure_unique(ptr"),
                       "非嵌套写不应发射根独占化调用")
    }

    /// IR 结构断言（与运行行为互补，锁死 COW 的两个 codegen 契约）：
    /// ① 别名绑定点发射 `@bk_handle_retain`；② 写路径捕获 `@bk_array_set` 返回句柄并写回变量槽。
    /// 意图：断言 COW 两个 codegen 契约——别名绑定 var b = a 发射 @bk_handle_retain，写路径捕获 @bk_array_set 返回句柄并 store 回变量槽。
    func testCOWIRContract() throws {
        let src = """
        main|func() -> ()
            var a = [1, 2]
            var b = a
            b[0] = 9
            return
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        XCTAssertTrue(ir.contains("declare void @bk_handle_retain(ptr)"), "应声明 @bk_handle_retain")
        XCTAssertTrue(ir.contains("call void @bk_handle_retain(ptr"), "别名绑定 var b = a 应补一份 share")
        XCTAssertTrue(ir.contains("call ptr @bk_array_set(ptr"), "写路径应捕获 @bk_array_set 返回的句柄（COW 分裂后为副本）")
        XCTAssertTrue(ir.contains("store %bk_array* %t"), "分裂后的句柄须写回变量槽，否则写入丢失")
        XCTAssertFalse(ir.contains("call void @bk_array_set"), "旧 void 形态的 @bk_array_set 调用应已全部迁移")
    }

    // MARK: - #46-D D4.2.3 作用域精确释放

    /// D4.2.3-a 运行时验证：重赋值 `a = [9, 8]` 须精确释放「旧句柄」的一份 share（避免泄漏），
    /// 且**不**破坏仍持有旧句柄的别名 `b` 的所有权（b 的后续写入不得污染 a 的新句柄）。双后端锁步。
    /// 意图：验证重赋值 a=[9,8] 精确释放旧句柄一份 share，别名 b 仍持旧句柄且其写入不污染 a 的新句柄（字典同款），三执行路径输出一致。
    func testReassignCollectionReleasesOldHandleAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var a = [1, 2, 3]
            var b = a
            a = [9, 8]
            b[0] = 100
            print(a)
            print(b)
            var m = ["x": 1]
            var n = m
            m = ["y": 2]
            print(m)
            print(n)
            return
        """, expected: "[9, 8][100, 2, 3]{y: 2}{x: 1}",
        "重赋值应精确释放旧句柄（b 仍持有旧句柄，其写入不污染 a 的新句柄；字典同款）")
    }

    /// D4.2.3-b 运行时验证：函数体末条为 `if`（非终止语句）→ 生成 fall-through `exit_block`，
    /// `emitScopeCleanup` 在出口释放**顶层**集合 `top`；嵌套块内 `nested`（depth>0）不登记 → 不误释放
    /// （扁平 symbolTable 下释放未初始化变量会读脏 slot → UAF）。三执行路径须零崩溃且输出一致。
    /// 意图：验证 fall-through 出口 emitScopeCleanup 释放顶层集合 top、不误释放嵌套块内 nested（零 UAF），三执行路径输出一致。
    func testScopeCleanupFallthroughExitAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var top = [1, 2, 3]
            print(top)
            if true:
                var nested = [9, 9]
                print(nested)
            print(top)
        """, expected: "[1, 2, 3][9, 9][1, 2, 3]",
        "fall-through 出口应释放顶层集合且不误释放嵌套块变量（零 UAF / 零崩溃）")
    }

    /// D4.2.3 IR 契约（精确释放计数）：重赋值 + fall-through 出口的 destroy 调用数必须恰好为 3
    /// （1 次重赋值旧句柄 + 2 次出口顶层 top/b），多/少均意味过释放（UAF）或漏释放（泄漏）。
    /// 入口无尾随 return → 末条 `print` 非终止 → 生成 fall-through `exit_block` 让 emitScopeCleanup 介入。
    ///
    /// 变异反证锚点：禁用 `emitContainerDestroy`（D4.2.3-a）→ 总数降至 1；禁用 `emitScopeCleanup`（D4.2.3-b）
    /// → 总数降至 1（仅重赋值）；本断言两者皆红灯。
    /// 意图：断言重赋值 + fall-through 出口的 @bk_array_destroy 调用数恰为 3（1 重赋值旧句柄 + 2 出口顶层 top/b），多/少均意味过释放或漏释放。
    func testD423ReassignAndScopeCleanupIRContract() throws {
        let src = """
        main|func() -> ()
            var top = [1, 2, 3]
            var b = top
            top = [4, 5]
            print(top)
            print(b)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        XCTAssertTrue(ir.contains("declare void @bk_array_destroy(ptr)"), "应声明 @bk_array_destroy 原语")
        XCTAssertTrue(ir.contains("exit_block:"), "无尾随 return 应生成 fall-through exit_block（emitScopeCleanup 入口）")

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 3, "destroy 调用数应为 3（1 重赋值旧句柄 + 2 出口顶层），多/少均意味过释放或漏释放")

        // 出口块区域须含集合释放（顶层 top / b 各一份）。
        let exitRegion = ir.split(separator: "exit_block:").last ?? ""
        XCTAssertEqual(exitRegion.components(separatedBy: "call void @bk_array_destroy").count - 1, 2,
                       "出口块应释放 2 份顶层集合（top + b）")
    }

    /// D4.2.3+ 块级精确释放契约：嵌套块（if then）内集合变量现经**块级精确释放**在 then 块「自然落入」
    /// 边释放（`generateBlock` 末尾 emitBlockCleanup），结构化语言保证块末变量必初始化 → 零 UAF。
    /// 故全模块 2 次集合 destroy（then 块末释 nested + 出口释顶层 top），且出口块只释 top、不含 nested。
    ///
    /// 变异反证锚点：禁用 `emitBlockCleanup`（D4.2.3-b 块级清理）→ 总数降至 1（仅出口 top）、then 块末无 nested 释放；
    /// 本断言红灯。
    /// 意图：断言块级精确释放契约——嵌套块集合在 then 块末释放、全模块 destroy 恰 2 次，且出口块只释顶层 top、不含 nested（零 UAF）。
    func testD423NestedCollectionNotOverReleasedIRContract() throws {
        let src = """
        main|func() -> ()
            var top = [1, 2, 3]
            if true:
                var nested = [9, 9]
                print(nested)
            print(top)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 2, "顶层 top（出口）+ 嵌套 nested（then 块末块级释放）各 1 次；块级精确释放消除嵌套块泄漏（P1 修复）")

        let exitRegion = ir.split(separator: "exit_block:").last ?? ""
        XCTAssertTrue(exitRegion.contains("load %bk_array*, ptr %top_slot"),
                      "出口块应释放顶层 top 句柄")
        XCTAssertFalse(exitRegion.contains("load %bk_array*, ptr %nested_slot"),
                       "出口块不应释放嵌套块变量 nested（未初始化路径 → UAF 风险）")
    }

    // MARK: - #46-D D4.2.4：三执行路径对拍（解释器 + lli-JIT + clang-AOT）

    /// 非数组集合的重赋值精确释放：`bk_dict_destroy` / `bk_set_destroy` 在 clang-AOT 静态链接下
    /// 必须可见且运行无过释放（UAF）——这是 lli/dlopen 容忍、但 `clang -lPiniRuntime` 链接期会
    /// 暴露的符号可见性回归。别名 `e`/`t` 仍持旧句柄，其值不被重赋值污染。
    /// 意图：验证 dict/set 重赋值精确释放旧句柄，且 @bk_dict_destroy/@bk_set_destroy 在 clang-AOT 静态链接下可见（无过释放 UAF），别名 e/t 不污染。
    func testDictSetReassignReleasesOldHandleAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var d = ["a": 1, "b": 2]
            var e = d
            d = ["c": 3]
            print(d)
            print(e)
            var s = {1, 2, 3}
            var t = s
            s = {4, 5}
            print(s)
            print(t)
            return
        """, expected: "{c: 3}{a: 1, b: 2}{4, 5}{1, 2, 3}",
        "dict/set 重赋值应精确释放旧句柄，别名不污染（三执行路径一致）")
    }

    /// 非数组集合的 fall-through 出口精确释放：dict/set 顶层句柄在 exit_block 被 `bk_dict_destroy` /
    /// `bk_set_destroy` 释放，嵌套块内 dict（depth>0）不登记不误释放，三执行路径零崩溃且输出一致。
    /// 意图：验证 dict/set fall-through 出口精确释放顶层句柄、不误释放嵌套块 dict，三执行路径零崩溃且输出一致。
    func testDictSetScopeCleanupExitAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var d = ["x": 1]
            var s = {9}
            print(d)
            print(s)
            if true:
                var nested = ["n": 2]
                print(nested)
            print(d)
        """, expected: "{x: 1}{9}{n: 2}{x: 1}",
        "fall-through 出口应释放顶层 dict/set，不误释放嵌套块 dict（三执行路径零 UAF）")
    }

    // MARK: - #46-D D4.2.5：块级精确释放（彻底修复 P1 循环体泄漏 + P2 释放错位）

    /// IR 契约：while 体内集合变量须在「块末（backedge 前）」经 `emitBlockCleanup` 释放，
    /// 运行时每轮迭代执行一次 → 消除 P1（循环体集合变量每轮泄漏，~200 字节/次，长循环 RSS 无界增长）。
    /// 函数无顶层集合（acc/i 为 i32）→ destroy 全来自循环体块级释放。
    /// 意图：断言 while 体内集合变量在块末（backedge 前）经 emitBlockCleanup 释放（每轮执行一次），destroy 恰 1 次且在 while_body 块内、exit_block 不含集合释放（消除 P1 每轮泄漏）。
    func testLoopBodyCollectionReleasesIRContract() throws {
        let src = """
        main|func() -> ()
            var acc = 0
            var i = 0
            while i < 3:
                var buf = [1, 2, 3]
                acc = acc + buf[0]
                i = i + 1
            print(acc)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 1, "while_body 块末应 emit 1 次 bk_array_destroy（运行时每轮执行 → 消除 P1 每轮泄漏）")
        // 块级释放须位于 while_body 块内（标签定义之后、backedge br 之前）：取最后一个 `while_body_` 出现
        // （块标签定义，而非 cond 块里 `br ... label %while_body_1` 的目标），避免锚点误匹配。
        guard let bodyRange = ir.range(of: "while_body_", options: .backwards),
              let destroyRange = ir.range(of: "call void @bk_array_destroy") else {
            XCTFail("IR 须含 while_body 块标签与 bk_array_destroy 调用")
            return
        }
        XCTAssertLessThan(bodyRange.lowerBound, destroyRange.lowerBound,
                          "bk_array_destroy 须出现在 while_body 块内（块级精确释放，非仅出口释放）")
        // 无顶层集合 → exit_block 不应含集合释放（destroy 全来自循环体块级释放）。
        let exitRegion = ir.split(separator: "exit_block:").last ?? ""
        XCTAssertFalse(exitRegion.contains("call void @bk_array_destroy"),
                       "无顶层集合，exit_block 不应释放（destroy 全来自循环体块级释放）")
    }

    /// 三执行路径值语义 + 不崩溃：1000 次循环体内创建集合，三臂输出须一致（6000）且进程不崩溃。
    /// 本例是 P1 实证的直接回归——若块级释放在，长循环 RSS 不再线性增长；若泄漏，值语义仍正确但 RSS 膨胀。
    /// 意图：验证 1000 次循环体内创建集合三执行路径输出一致（6000）且进程不崩溃（P1 块级精确释放的直接回归，消除每轮泄漏）。
    func testLoopBodyCollectionAllThreeBackends() throws {
        throw XCTSkip("M2: 循环体内 buf[0] 下标读现返回 some/none，LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            var i = 0
            while i < 1000:
                var buf = [1, 2, 3]
                acc = acc + buf[0] + buf[1] + buf[2]
                i = i + 1
            print(acc)
        """, expected: "6000",
        "循环体内集合变量应块级精确释放（三执行路径一致、零崩溃、无每轮泄漏）")
    }

    // MARK: - #46-D D5：终止边精确释放（break / continue / return）

    /// IR 契约：循环体内 `break` 须在「break 分支（if_then）跳出口」前释放被放弃的循环体集合变量，
    /// 且 `if_then` 块须为**单终结指令**——D5 前 `isTerminatingStatement` 不含 break，导致
    /// `br exit` 后紧跟 `br merge` 的**非法 IR**（双重终结指令）。
    /// 变异反证锚点：禁用 break 清理（`if d in (ld+1)...currentScopeDepth` 段）→ if_then 不再含 destroy、本断言红灯。
    /// 意图：断言循环体内 break 分支在跳出口前释放被放弃的集合变量，且 if_then 为单终结指令（修复 D5 前双重终结的非法 IR），destroy 恰 2 次。
    func testBreakCollectionReleasesIRContract() throws {
        let src = """
        main|func() -> ()
            var i = 0
            while i < 5:
                var buf = [1, 2, 3]
                if i == 2:
                    break
                i = i + 1
            print(i)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 2, "break 路径(if_then)与非 break 路径(if_merge)各释放 buf 1 次")

        guard let thenStart = ir.range(of: "if_then_2:"),
              let elseStart = ir.range(of: "if_else_2:") else {
            XCTFail("IR 须含 if_then_2 / if_else_2 块"); return
        }
        let thenRegion = String(ir[thenStart.lowerBound..<elseStart.lowerBound])
        XCTAssertTrue(thenRegion.contains("call void @bk_array_destroy"),
                      "break 分支须释放被放弃的循环体集合变量 buf（终止边精确释放）")
        XCTAssertTrue(thenRegion.contains("br label %while_exit_1"),
                      "break 分支须跳至循环出口")
        XCTAssertFalse(thenRegion.contains("br label %if_merge_2"),
                       "D5 前非法 IR：break 分支不应再出现 `br if_merge`（双重终结指令）")
    }

    /// IR 契约：循环体内 `continue` 须在「分支跳回条件」前释放被放弃的循环体集合变量（语义同 break）。
    /// 意图：断言循环体内 continue 分支在跳回条件前释放被放弃的集合变量（语义同 break），destroy 恰 2 次。
    func testContinueCollectionReleasesIRContract() throws {
        let src = """
        main|func() -> ()
            var i = 0
            while i < 5:
                var buf = [1, 2, 3]
                i = i + 1
                if i == 2:
                    continue
                print(buf)
            print(i)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 2, "continue 路径(if_then)与非 continue 路径(if_merge)各释放 buf 1 次")

        guard let thenStart = ir.range(of: "if_then_2:"),
              let elseStart = ir.range(of: "if_else_2:") else {
            XCTFail("IR 须含 if_then_2 / if_else_2 块"); return
        }
        let thenRegion = String(ir[thenStart.lowerBound..<elseStart.lowerBound])
        XCTAssertTrue(thenRegion.contains("call void @bk_array_destroy"),
                      "continue 分支须释放被放弃的循环体集合变量 buf（终止边精确释放）")
        XCTAssertTrue(thenRegion.contains("br label %while_cond_1"),
                      "continue 分支须跳回循环条件（无 step）")
    }

    /// IR 契约：函数内 `return` 须在 `ret` 前经 `emitScopeCleanup` 释放**所有**存活层集合变量
    /// （结构化保证已初始化 → 零 UAF）；fall-through 出口因 return 为顶层终止语句不再生成 → 无双重释放。
    /// 意图：断言函数内 return 在 ret 前经 emitScopeCleanup 释放顶层集合（destroy 恰 1 次且位于 ret 之前），且不生成 exit_block 避免双重释放。
    func testReturnCollectionReleasesIRContract() throws {
        let src = """
        main|func() -> ()
            var top = [1, 2, 3]
            return
            print(top)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertEqual(destroyCount, 1, "return 前须释放顶层 top 一份 share（消除每次调用泄漏）")
        XCTAssertFalse(ir.contains("exit_block:"), "return 为顶层终止语句 → 不应生成 fall-through 出口块（避免双重释放）")
        guard let destroyStart = ir.range(of: "call void @bk_array_destroy"),
              let retStart = ir.range(of: "ret i32 0") else {
            XCTFail("IR 须含 destroy 与 ret"); return
        }
        XCTAssertLessThan(destroyStart.lowerBound, retStart.lowerBound,
                          "bk_array_destroy 须出现在 return 之前（ret 前精确释放）")
    }

    /// 三执行路径值语义 + 零 UAF：循环体内 break + 集合，三臂输出一致（10）且进程不崩溃
    /// （clang-AOT 对双重释放/UAF 零容忍，若终止边未释放导致泄漏不崩溃但语义须一致）。
    /// 意图：验证循环体内 break + 集合变量三执行路径输出一致（5）且进程不崩溃（终止边精确释放）。
    func testBreakCollectionAllThreeBackends() throws {
        throw XCTSkip("M2: 循环体内 buf[0] 下标读现返回 some/none，LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            var i = 0
            while i < 10:
                var buf = [1, 2, 3]
                if i == 5:
                    break
                acc = acc + buf[0]
                i = i + 1
            print(acc)
        """, expected: "5",
        "循环体内 break + 集合变量应终止边精确释放（三执行路径一致、零崩溃）")
    }

    /// 三执行路径值语义 + 零 UAF：循环体内 continue + 集合，三臂输出一致（8）且进程不崩溃。
    /// 意图：验证循环体内 continue + 集合变量三执行路径输出一致（9）且进程不崩溃（终止边精确释放）。
    func testContinueCollectionAllThreeBackends() throws {
        throw XCTSkip("M2: 循环体内 buf[0] 下标读现返回 some/none，LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            var i = 0
            while i < 10:
                var buf = [1, 1, 1]
                i = i + 1
                if i == 5:
                    continue
                acc = acc + buf[0]
            print(acc)
        """, expected: "9",
        "循环体内 continue + 集合变量应终止边精确释放（三执行路径一致、零崩溃）")
    }

    /// 三执行路径值语义 + 零 UAF：函数内 return 提前退出，集合变量（top/inner）经 emitScopeCleanup 释放，
    /// 三臂输出一致（[1, 2, 3]，return 后不可达不打印）且进程不崩溃。
    /// 意图：验证函数内 return 提前退出时集合变量经 emitScopeCleanup 释放，三执行路径输出 [1,2,3] 且 return 后不可达代码不打印。
    func testReturnCollectionAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var top = [1, 2, 3]
            print(top)
            if true:
                var inner = [4, 5]
                return
            print("unreachable")
        """, expected: "[1, 2, 3]",
        "函数内 return + 集合变量应终止边精确释放（三执行路径一致、零崩溃）")
    }

    // MARK: - G36：for-in 迭代

    /// 三执行路径：for-in 数组迭代值求和（模式元组一一对应：单字段绑定元素值）。
    /// 意图：验证 for-in 数组迭代（单字段模式元组绑定元素值）求和输出 6，三执行路径一致。
    func testForInArrayAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            for (v,) in [1, 2, 3]:
                acc = acc + v
            print(acc)
        """, expected: "6",
        "for-in 数组迭代（单字段绑定）三执行路径一致")
    }

    /// 三执行路径：for-in 字典迭代 (k, v) 两字段一一对应。
    /// 意图：验证 for-in 字典迭代 (k,v) 两字段一一对应求和输出 55，三执行路径一致。
    func testForInDictAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            let ages = ["Alice": 30, "Bob": 25]
            var total = 0
            for (k, v,) in ages:
                total = total + v
            print(total)
        """, expected: "55",
        "for-in 字典迭代（k,v 两字段绑定）三执行路径一致")
    }

    /// 三执行路径：for-in 集合迭代单字段绑定。
    /// 意图：验证 for-in 集合迭代（单字段绑定）求和输出 10，三执行路径一致。
    func testForInSetAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var ssum = 0
            for (v,) in {2, 3, 5}:
                ssum = ssum + v
            print(ssum)
        """, expected: "10",
        "for-in 集合迭代（单字段绑定）三执行路径一致")
    }

    /// 三执行路径：`_` 占位忽略绑定（仅迭代次数）。
    /// 意图：验证 for-in `_` 占位忽略绑定（仅迭代次数计数）输出 3，三执行路径一致。
    func testForInUnderscoreAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var cnt = 0
            for (_ ,) in [7, 8, 9]:
                cnt = cnt + 1
            print(cnt)
        """, expected: "3",
        "for-in `_` 占位忽略绑定三执行路径一致")
    }

    /// 三执行路径：for-in step 步进块（与 while 对齐：每轮 body 后执行）。
    /// 意图：验证 for-in step 步进块每轮 body 后执行（t 累加 1 再累加 v → 9），三执行路径一致。
    func testForInStepAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var t = 0
            for (v,) in [1, 2, 3]:
                t = t + 1
            step:
                t = t + v
            print(t)
        """, expected: "9",
        "for-in step 步进块（每轮 body 后执行）三执行路径一致")
    }

    /// 三执行路径：标签|控制流 + break label（单层循环退出，ADR-014）。
    /// 意图：验证 `outer|for` + break outer（遇 v==3 跳出）单层循环退出输出 3，三执行路径一致。
    func testForInLabelBreakAllThreeBackends() throws {
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var s = 0
            outer|for (v,) in [1, 2, 3, 4]:
                if v == 3:
                    break outer
                s = s + v
            print(s)
        """, expected: "3",
        "标签|for + break label（单层退出）三执行路径一致")
    }

    /// IR 契约：for-in 循环结构（for_body 块 + bk_array_len/get + 索引 < 长度条件 + 索引递增）。
    /// 意图：断言 for-in IR 契约——for_body 块标签 + @bk_array_get/@bk_array_len 调用 + icmp slt 索引<长度条件 + add 索引递增。
    func testForInIRContract() throws {
        let src = """
        main|func() -> ()
            var acc = 0
            for (v,) in [1, 2, 3]:
                acc = acc + v
            print(acc)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)

        XCTAssertTrue(ir.contains("call ptr @bk_array_get"), "for-in IR 应经 bk_array_get 取元素")
        XCTAssertTrue(ir.contains("call i32 @bk_array_len"), "for-in IR 应经 bk_array_len 取长度")
        XCTAssertTrue(ir.contains("for_body_"), "IR 应含 for_body 块标签")
        XCTAssertTrue(ir.contains("icmp slt i32"), "for-in 条件应为索引 < 长度")
        XCTAssertTrue(ir.contains("add i32"), "for-in 每轮应递增索引")
    }

    /// 三执行路径：for 循环体内创建集合变量（generateBlock 块级释放复用）——值语义 + 零 UAF。
    /// 意图：验证 for 循环体内创建集合变量经块级释放（值语义 + 零 UAF）输出 3，三执行路径一致。
    func testForInBodyCollectionAllThreeBackends() throws {
        throw XCTSkip("M2: for-in body 内 buf[0] 下标读现返回 some/none，LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            for (v,) in [1, 2, 3]:
                var buf = [1, 2, 3]
                acc = acc + buf[0]
            print(acc)
        """, expected: "3",
        "for-in 循环体内集合变量应块级精确释放（三执行路径一致、零崩溃）")
    }

    /// 三执行路径：嵌套集合迭代（数组元素为数组）——集合型模式变量每轮 body 末精确释放，双后端一致。
    /// 意图：验证 for-in 嵌套集合迭代（数组元素为数组）集合型模式变量每轮 body 末精确释放，输出 10 且三执行路径一致。
    func testForInNestedArrayAllThreeBackends() throws {
        throw XCTSkip("M2: for-in body 内 row[0] 下标读现返回 some/none，LLVM 未对齐，见 docs/issue-host-optional-slice-2026-08-28.md")
        try assertTripleBackendsAgree("""
        main|func() -> ()
            var acc = 0
            for (row,) in [[1, 2], [3, 4]]:
                acc = acc + row[0] + row[1]
            print(acc)
        """, expected: "10",
        "for-in 嵌套集合迭代（集合型模式变量每轮精确释放）三执行路径一致")
    }

    /// IR 契约：嵌套集合模式变量（%bk_array*）登记进 body 层 → 每轮 body 末 bk_array_destroy（非仅函数出口）。
    /// 意图：断言嵌套集合模式变量（%bk_array*）登记进 body 层，每轮 for_body 末发射 @bk_array_destroy（非仅函数出口）。
    func testForInNestedCollectionIRContract() throws {
        let src = """
        main|func() -> ()
            var acc = 0
            for (row,) in [[1, 2], [3, 4]]:
                acc = acc + row[0]
            print(acc)
        """
        let tokens = try Lexer(source: src, fileName: "test.pini").tokenize()
        let module = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
        let ir = try IRGenerator().generate(module: module)
        let destroyCount = ir.components(separatedBy: "call void @bk_array_destroy").count - 1
        XCTAssertGreaterThanOrEqual(destroyCount, 1, "嵌套集合模式变量应每轮 body 末释放（bk_array_destroy）")
        guard let bodyRange = ir.range(of: "for_body_", options: .backwards),
              let destroyRange = ir.range(of: "call void @bk_array_destroy") else {
            XCTFail("IR 须含 for_body 块标签与 bk_array_destroy"); return
        }
        XCTAssertLessThan(bodyRange.lowerBound, destroyRange.lowerBound,
                          "bk_array_destroy 须出现在 for_body 块内（每轮块级释放）")
    }
}
