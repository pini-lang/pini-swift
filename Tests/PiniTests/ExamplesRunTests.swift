import XCTest
import PiniCore

/// 示例运行黄金输出测试门（P2 交付）：对精选子集断言 `pini run` 的实际输出
/// 与黄金输出完全一致。这是「示例即文档」的真正防线——`ExamplesConformanceTests`
/// 只跑 `check`（解析+语义+类型），抓不住「声明了特性却不演示」的语义退化；
/// 本门通过进程内解释执行并比对 stdout，让空壳/退化示例一旦回归即红灯。
final class ExamplesRunTests: XCTestCase {

    /// 从当前测试文件向上回溯到 Package.swift，定位包根目录（构建产物路径无关）。
    private func packageRoot() -> String {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            let pkg = url.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return url.path
    }

    /// 进程内运行单个示例文件并捕获其 stdout。
    /// 复刻 CLI 单文件 run 路径：Lexer → Parser.parseModule() → Interpreter.run(module:)。
    /// 每个 `print` 经由 `Interpreter.outputSink` 重定向时，本方法在内容后补一个换行，
    /// 与 CLI 的 `print` 行为逐字节一致（含末尾换行）。最终直接拼接各段（不再额外加分隔符），
    /// 使得返回值与 `pini run <file>` 的子进程 stdout 完全等价——golden 串据此标注（含尾换行）。
    private func runExample(at path: String) throws -> String {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let fileName = (path as NSString).lastPathComponent

        let tokens = try Lexer(source: source, fileName: fileName).tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        let module = try parser.parseModule()

        let interpreter = Interpreter()
        var segments: [String] = []
        interpreter.outputSink = { segments.append($0 + "\n") }
        try interpreter.run(module: module)

        return segments.joined(separator: "")
    }

    /// 黄金用例表：文件名 → 期望输出。
    /// 仅收录输出确定、稳定、快速的示例；
    /// 并发类示例（含真实线程调度 / 超时 / sleep）输出非确定或耗时，不纳入本门。
    /// 意图：对精选示例逐一批量执行 `pini run` 等价路径并断言 stdout 与黄金串完全一致，任何语义退化（输出变化）即红灯。
    func testGoldenOutputs() throws {
        let cases: [(file: String, golden: String)] = [
            ("hello.pini", "Hello, World!\n欢迎使用Pini语言\n"),
            ("lambda.pini", "42\n"),
            ("control_if.pini", "大于5\n"),
            ("compound_assign.pini", "15\n12\n24\n6\n2\n8\n9\n10\n40\n20\n"),
            ("operators.pini", "30\n10\n200\n2\n"),
            ("defer.pini", "bodyfirstmiddlelast\nblockinnerouter\n"),
            ("composition.pini", "2\n1\n默认\n"),
            ("object.pini", "3\n"),
            ("generic-func.pini", "100\n泛型函数\n"),
            ("match.pini", "78.53975\n12.0\n6.0\n"),
            ("comments.pini", "Pini\n"),
            ("try.pini", "读取失败\n"),
            ("access.pini", "秒表\n60\n60\n"),
            ("enum.pini", "12.56636\n12.0\n"),
            ("generic.pini", "7\n泛型值\n"),
            ("struct.pini", "3.0\n4.0\n5.0\n"),
            ("trait.pini", "旺财\n"),
            ("stdlib.pini", "HELLO, WORLD\nhello, world\ntrue\nHello\n[Hello,  World]\na-b-c\n42\n3\n9\n5.0\n0.0\n1.0\n0.0\n"),
            ("tuple.pini", "[3, 2]\n"),
            ("array_basic.pini", "20\n3\nworld\n3\ntrue\n3\nb\n10\n7\n"),
            ("dict_set_d2.pini", "25\n3\n26\n99\n5\n3\n"),
            // #46-D D4：集合值语义 / COW（别名分裂、容器内快照、嵌套与混合嵌套递归分裂）。
            ("cow.pini", "[1, 2, 3]\n[99, 2, 3]\n{a: 1}\n{a: 9}\n[42, 2]\n[[1, 2]]\n"
                + "[[99, 2], [3, 4]]\n[[1, 2], [3, 4]]\n[{k: 9}, {k: 2}]\n[{k: 1}, {k: 2}]\n"),
            ("recursion.pini", "120\n55\n"),
            // G41（test 块）：|test 函数 + assert 内建——main 直接调用测试函数演示（pini test 路径由 TestBlockSwiftTests / CLI 覆盖）。
            ("test.pini", "全部测试通过\n"),
            // G40（LazyRef）：懒加载引用语义——首访初始化一次、复制共享缓存（.value 双后端一致）。
            ("lazyref.pini", "init\n42\n42\n42\n"),
            ("optional.pini", "42\nnone\n"),
            ("higher-order.pini", "10\n21\n36\n"),
            ("lambda-typed.pini", "6\n5\n10\n"),
            ("control_while.pini", "0\n1\n2\n1\n3\n5\n0\n1\n"),
        ]

        let root = packageRoot()
        let examplesDir = (root as NSString).appendingPathComponent("examples")

        for c in cases {
            let path = (examplesDir as NSString).appendingPathComponent(c.file)
            let got: String
            do {
                got = try runExample(at: path)
            } catch {
                XCTFail("示例 \(c.file) 运行抛错（解析/执行失败）：\(error)")
                continue
            }
            XCTAssertEqual(got, c.golden,
                           "示例 \(c.file) 运行输出与黄金不一致（示例语义退化？）\n  期望：\(c.golden)\n  实际：\(got)")
        }
    }

    /// 占位 print 守卫（P2 防退化核心）：
    /// 任一示例若仍含 "示例运行成功" 这类空壳占位输出，直接红灯——
    /// 这正是 P0 已清除的玩具示例特征，不得死灰复燃。
    /// 该检查独立于运行，扫描源码文本即可，零执行成本。
    /// 意图：递归扫描 examples/ 下全部 .pini，任一仍含「示例运行成功」空壳占位打印即红灯，防止 P0 已清除的玩具示例死灰复燃。
    func testNoPlaceholderOutput() throws {
        let root = packageRoot()
        let dir = (root as NSString).appendingPathComponent("examples")

        // 递归枚举 examples/ 下所有 .pini（含 multifile/、package-demo/ 子模块），
        // 确保空壳占位打印无处藏身。
        let enumerator = FileManager.default.enumerator(atPath: dir)
        var offenders: [(file: String, line: String)] = []
        while let entry = enumerator?.nextObject() as? String {
            guard entry.hasSuffix(".pini") else { continue }
            let path = (dir as NSString).appendingPathComponent(entry)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            content.enumerateLines { line, _ in
                if line.contains("示例运行成功") {
                    offenders.append((entry, line))
                }
            }
        }

        if !offenders.isEmpty {
            let report = offenders.map { "· \($0.file): \($0.line)" }.joined(separator: "\n")
            XCTFail("发现空壳占位输出，示例质量退化：\n\(report)")
        }
    }
}
