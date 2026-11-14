import Foundation
import PiniSyntax
import Testing
@testable import PiniHost

/// 头文件翻译的判据：能承接的照写，接不住的逐条说明理由，同一输入两次生成逐字节相同。
/// 生成文本的块体被逐字节钉死 —— 只钉「含有什么」会让宽度、变参标志、只读标志这类
/// 一字之差的错误照样绿。
@Suite("头文件翻译")
struct CHeaderTranslationTests {
    private static let fixture = """
        #define LIMIT 512
        #define RATIO 0.5
        #define ADD(a, b) ((a) + (b))

        int exit_code(const char *name);
        unsigned long length_of(const char *text);
        void reset_state(void);
        int log_line(const char *format, ...);

        extern int error_count;
        extern const int max_depth;

        struct context { int slot; };
        enum mode { MODE_FAST, MODE_SAFE };
        typedef unsigned long word_t;
        """

    private func writeFixture(_ source: String = fixture, name: String = "probe.h") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = directory.appendingPathComponent(name)
        try source.write(to: header, atomically: true, encoding: .utf8)
        return header
    }

    /// 清掉夹具目录；每个用例自己 defer，避免临时目录越攒越多。
    private func removeDirectory(of header: URL) {
        try? FileManager.default.removeItem(at: header.deletingLastPathComponent())
    }

    /// 块体：从 `[名称|foreign]` 开始到文件尾。头注释里有工具版本，逐字节钉它等于钉住机器。
    private func body(of text: String) -> [String] {
        guard let range = text.range(of: "\n[") else { return [] }
        /// 匹配含那个换行与方括号，故从匹配起点丢掉第一个字符才是块头。
        let block = text[range.lowerBound...].dropFirst()
        return block.split(separator: "\n").map(String.init)
    }

    @Test("能承接的声明按头文件次序写成块：标量、指针、变参、只读与数值宏")
    func translatesTheWhitelistedSurface() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        let result = try CHeaderTranslator.translate(.init(header: header.path))
        let lines = body(of: result.text)
        #expect(lines.first == "[probe|foreign]", "块名应取头文件名：\(result.text)")

        /// `long` 的宽度由 clang 的预定义宏给出：LP64 上 `unsigned long` 是 U64，
        /// LLP64 上只能跳过。期望值跟着目标算，不写死 U64。
        let clang = try #require(CTool.clangPath())
        let target = try CTarget.probe(clang: clang)
        var expected = [
            "exit_code: (String,) -> (I32,)",
            "reset_state: () -> ()",
            "log_line|varargs: (String,) -> (I32,)",
            "error_count: I32",
            "max_depth|readonly: I32",
            "LIMIT|macro: I32",
            "RATIO|macro: F64",
        ]
        if target.longWidth == 8 {
            expected.insert("length_of: (String,) -> (U64,)", at: 1)
        } else {
            #expect(result.skipped.contains { $0.name == "length_of" }, "LLP64 上应记一条跳过")
        }
        #expect(Array(lines.dropFirst()) == expected, "实际：\n\(result.text)")
    }

    @Test("接不住的逐条说明理由：结构体、枚举、typedef、函数式宏")
    func reportsEverySkipWithAReason() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        let result = try CHeaderTranslator.translate(.init(header: header.path))
        let names = Set(result.skipped.map(\.name))
        #expect(names == ["context", "mode", "word_t", "ADD"], "实际：\(result.skipped)")
        for skip in result.skipped {
            #expect(!skip.reason.isEmpty, "\(skip.name) 没有理由")
        }
    }

    @Test("同一输入两次生成逐字节相同")
    func translationIsDeterministic() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        let first = try CHeaderTranslator.translate(.init(header: header.path))
        let second = try CHeaderTranslator.translate(.init(header: header.path))
        #expect(first.text == second.text, "两次生成的文本不同")
    }

    @Test("生成文本是合法 Pini：解析器原样收下")
    func generatedTextParses() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        let result = try CHeaderTranslator.translate(.init(header: header.path))
        let lexer = Lexer(source: result.text, fileName: "generated.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "generated.pini")
            .parseModuleCollectingErrors()
        #expect(parsed.errors.isEmpty, "生成的文本解析失败：\(parsed.errors)")
    }

    @Test("块名可覆盖，来源与工具写进头注释")
    func headerRecordsProvenance() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        let result = try CHeaderTranslator.translate(
            .init(header: header.path, blockName: "自定义"))
        #expect(result.text.contains("[自定义|foreign]"), "块名未生效：\(result.text)")
        #expect(result.text.contains(header.path), "没记来源头文件")
        #expect(result.text.contains("勿手改"), "没写禁止手改")
    }

    // MARK: - 命令行

    @Test("pini bind 把生成文本写到 -o 指定的文件")
    func commandLineWritesOutput() throws {
        let header = try writeFixture()
        defer { removeDirectory(of: header) }
        guard PiniTestEnvironment.requireToolchain(
            available: PiniTestEnvironment.cliPath() != nil, missing: "PINI_CLI_BIN")
        else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())
        let output = header.deletingLastPathComponent().appendingPathComponent("generated.pini")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["bind", header.path, "-o", output.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readAllData(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "stderr：\(stderr)")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("[probe|foreign]"), "生成的文本：\(text)")
    }
}
