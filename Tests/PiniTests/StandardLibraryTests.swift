import Foundation
import Testing
import PiniSyntax
@testable import PiniHost

/// 语言内标准库的装配判据：前端并入后，方法在检查 · 解释 · 发射三条腿上都能被看见并执行。
/// 期望值全部手写；用户同名扩展压过标准库的读数由同一条语料对照给出，不从某次运行结果里抄。
@Suite("StandardLibrary")
struct StandardLibraryTests: Sendable {

    // MARK: - 语料与手写期望

    /// 四条读数钉三件事：命中前缀 · 前缀长于接收者 · 空前缀（两侧空串都对）。
    private static let corpus = #"""
    main|func() -> ():
        print("hello".startsWith("he"))
        print("hello".startsWith("hello!"))
        print("hello".startsWith(""))
        print("".startsWith(""))
        return
    """#

    private static let expected = #"""
    true
    false
    true
    true
    """#

    /// 用户在同一目标上给出同名方法：装配期摘掉标准库那份，读数取用户的 false。
    private static let overrideCorpus = #"""
    ((String))
    startsWith|self(prefix: String,) -> (Bool,):
        return false

    main|func() -> ():
        print("hello".startsWith("he"))
        return
    """#

    private static let overrideExpected = "false"

    /// 文本方法的边界读数：空模板 · 空后缀 · 超长后缀 · 多字素匹配 · 非正次数 · 多字符与空填充。
    private static let textCorpus = #"""
    main|func() -> ():
        print("  pad  ".trim() + "|")
        print("abc".endsWith(""))
        print("abc".endsWith("abcd"))
        print("中文".endsWith("文"))
        print("abc".replace("", "x"))
        print("abc".replace("z", "x"))
        print("aaaa".replace("aa", "b"))
        print("ab".repeat(0))
        print("ab".repeat(-2))
        print("7".padLeft(3, "0"))
        print("7".padLeft(1, "0"))
        print("7".padLeft(4, "ab"))
        print("7".padLeft(3, ""))
        print("7".padRight(3, "0"))
        print("7".padRight(4, "ab"))
        print("abcabc".lastIndexOf("bc"))
        print("abc".lastIndexOf("z"))
        print("abc".lastIndexOf(""))
        return
    """#

    /// 手写期望。两处空行分别来自 `repeat(0)` 与 `repeat(-2)`；`aa` 换 `b` 得 `bb` 钉非重叠匹配。
    private static let textExpected = #"""
    pad|
    true
    false
    true
    abc
    abc
    bb


    007
    7
    aba7
    7
    700
    7aba
    4
    -1
    3
    """#

    /// 容器算法语料：I32 与 String 两种元素 · 空数组 · 零与越界的取放 · 跨类型归约。
    private static let containerCorpus = #"""
    double|func(x: I32,) -> (I32,):
        return x * 2

    upper|func(s: String,) -> (String,):
        return s.upper()

    isEven|func(x: I32,) -> (Bool,):
        return x % 2 == 0

    add|func(acc: I32, x: I32,) -> (I32,):
        return acc + x

    bang|func(acc: String, x: I32,) -> (String,):
        return acc + "!"

    show|func(x: I32,) -> ():
        print(x)
        return

    main|func() -> ():
        print(map<I32>([1, 2, 3], double))
        print(map<String>(["a", "b"], upper))
        print(filter<I32>([1, 2, 3, 4], isEven))
        print(filter<I32>([], isEven))
        print(reduce<I32, I32>([1, 2, 3], 0, add))
        print(reduce<I32, String>([1, 2], "x", bang))
        print(reverse<String>(["a", "b"]))
        print(concat<String>(["a"], ["b"]))
        print(take<I32>([1, 2, 3], 2))
        print(drop<I32>([1, 2, 3], 2))
        print(take<I32>([1, 2, 3], 0))
        print(drop<I32>([1, 2, 3], 9))
        forEach<I32>([7], show)
        return
    """#

    /// 手写期望。空数组筛选与零/越界取放都答空数组；归约的初值类型决定结果类型（`x!!`）。
    private static let containerExpected = #"""
    [2, 4, 6]
    [A, B]
    [2, 4]
    []
    6
    x!!
    [b, a]
    [a, b]
    [1, 2]
    [3]
    []
    []
    7
    """#

    /// 字串成员边界：空接收者 · 空模板 · 非重叠计数 · 非正宽度 · 多字符填充 · 前后缀未命中。
    private static let stringsCorpus = #"""
    main|func() -> ():
        print("".isEmpty())
        print(" ".isEmpty())
        print("aaaa".count("aa"))
        print("abc".count(""))
        print("abc".count("abcd"))
        print("abc".stripPrefix(""))
        print("rest".stripPrefix("prefix-"))
        print("abc".stripSuffix(""))
        print("file.txt".stripSuffix(".md"))
        print("abc".ensurePrefix(""))
        print("world".ensurePrefix("hello-"))
        print("abc".ensureSuffix(""))
        print("中文".reversed() + "|")
        print("".reversed() + "|")
        print("a".capitalized() + "|")
        print("".capitalized() + "|")
        print("x".center(4, "ab") + "|")
        print("x".center(4, "") + "|")
        print("7".center(6, "-") + "|")
        print("abcdef".truncate(2) + "|")
        print("abcdef".truncate(9) + "|")
        print("abcdef".truncate(0) + "|")
        print("abcdef".truncate(-2) + "|")
        return
    """#

    /// 手写期望。空前后缀剥出空段仍是原串；居中奇数余量给右侧，非正宽度得空串。
    private static let stringsExpected = #"""
    true
    false
    2
    0
    0
    abc
    rest
    abc
    file.txt
    abc
    hello-world
    abc
    文中|
    |
    A|
    |
    axab|
    x|
    --7---|
    ab|
    abcdef|
    |
    |
    """#

    /// 容器操作边界：空数组 · 非正与越界下标 · 负轮转 · String 元素 · 首尾插删。
    private static let containerOpsCorpus = #"""
    isEven|func(x: I32,) -> (Bool,):
        return x % 2 == 0

    isA|func(s: String,) -> (Bool,):
        return s == "a"

    main|func() -> ():
        print(any<I32>([], isEven))
        print(all<I32>([], isEven))
        print(countWhere<I32>([1, 3], isEven))
        print(findIndex<I32>([1, 3], isEven))
        print(findIndex<String>(["a", "b"], isA))
        print(takeLast<I32>([1, 2, 3], 0))
        print(takeLast<I32>([1, 2, 3], 9))
        print(dropLast<I32>([1, 2, 3], 9))
        print(repeatElements<I32>([1, 2], 0))
        print(rotate<I32>([1, 2, 3], -1))
        print(rotate<I32>([1, 2, 3], 3))
        print(rotate<I32>([], 2))
        print(insertAt<I32>([1, 2, 3], -1, 9))
        print(insertAt<I32>([1, 2, 3], 9, 9))
        print(removeAt<I32>([1, 2, 3], -1))
        print(removeAt<String>(["a", "b"], 0))
        return
    """#

    /// 手写期望。空数组的全称判定为真、存在判定为假；负轮转等价于左移一位。
    private static let containerOpsExpected = #"""
    false
    true
    0
    -1
    0
    []
    [1, 2, 3]
    []
    []
    [3, 1, 2]
    [1, 2, 3]
    []
    [9, 1, 2, 3]
    [1, 2, 3, 9]
    [1, 2, 3]
    [b]
    """#

    /// 比较算法边界：String 元素 · 空数组 · 缺席 · 长度不同 · 降序 · 重复元素。
    private static let equalityCorpus = #"""
    main|func() -> ():
        print(contains<String>(["a", "b"], "b"))
        print(contains<I32>([], 1))
        print(indexOfElement<String>(["a", "b"], "z"))
        print(unique<String>(["b", "a", "b"]))
        print(unique<I32>([]))
        print(minElement<I32>([3, 1, 2]))
        print(maxElement<I32>([3, 1, 2]))
        print(sorted<I32>([]))
        print(isSorted<I32>([2, 1]))
        print(isSorted<I32>([]))
        print(equalArrays<I32>([1, 2], [1, 3]))
        print(equalArrays<I32>([1], [1, 2]))
        print(equalArrays<String>(["a"], ["a"]))
        return
    """#

    /// 手写期望。缺席答 -1，长度不同即不相等，空数组的有序判定为真。
    private static let equalityExpected = #"""
    true
    false
    -1
    [b, a]
    []
    1
    3
    []
    false
    true
    false
    false
    true
    """#

    // MARK: - 进程内装置

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "标准库探针.pini"
        do {
            let unit = FileUnit(fileName: name, module: try parsed(source, fileName: name))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "标准库", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：标准库方法在解释器腿产生手写期望；标准库源码解析失败会在这里变成未定义方法。
    @Test("解释器腿：标准库方法逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：用户扩展块与标准库同名时取用户那份，装配期不留下两份同名方法。
    @Test("解释器腿：用户同名扩展压过标准库")
    func userExtensionOverridesPrelude() throws {
        let outcome = Self.attempt(Self.overrideCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("覆盖语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.overrideExpected)
    }

    /// 意图：文本方法的边界语义在解释器腿逐行成立，不靠示例覆盖。
    @Test("解释器腿：文本方法边界逐行等于手写期望")
    func interpreterLegCoversTextBoundaries() throws {
        let outcome = Self.attempt(Self.textCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("文本语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.textExpected)
    }

    /// 意图：容器算法在解释器腿逐行成立，两种元素类型与空数组都覆盖。
    @Test("解释器腿：容器算法逐行等于手写期望")
    func interpreterLegCoversContainers() throws {
        let outcome = Self.attempt(Self.containerCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("容器语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.containerExpected)
    }

    /// 意图：字串成员边界在解释器腿逐行成立，不靠示例覆盖。
    @Test("解释器腿：字串成员边界逐行等于手写期望")
    func interpreterLegCoversStringMembers() throws {
        let outcome = Self.attempt(Self.stringsCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("字串语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.stringsExpected)
    }

    /// 意图：容器操作边界在解释器腿逐行成立，空数组与越界下标都覆盖。
    @Test("解释器腿：容器操作边界逐行等于手写期望")
    func interpreterLegCoversContainerOps() throws {
        let outcome = Self.attempt(Self.containerOpsCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("容器操作语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.containerOpsExpected)
    }

    /// 意图：比较算法边界在解释器腿逐行成立，两种元素类型与空数组都覆盖。
    @Test("解释器腿：比较算法边界逐行等于手写期望")
    func interpreterLegCoversEquality() throws {
        let outcome = Self.attempt(Self.equalityCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("比较语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.equalityExpected)
    }

    /// 意图：用户自己写的 `map` 把标准库那份摘掉——标准库不永久占用通用名。
    @Test("解释器腿：用户同名函数压过标准库")
    func userFunctionOverridesPrelude() throws {
        let source = #"""
        map|func(x: I32,) -> (I32,):
            return x + 100

        main|func() -> ():
            print(map(5))
            return
        """#
        let outcome = Self.attempt(source)
        guard case .ran(let lines) = outcome else {
            Issue.record("覆盖语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == "105")
    }

    /// 意图：多文件包只在第一个单元并入标准库，跨文件检查同样看得见它。
    @Test("包通道：标准库并入第一个单元")
    func packageLegSeesPrelude() throws {
        let mainSource = #"""
        main|func() -> ():
            print(add(2, 3))
            print("hello".startsWith("he"))
            return
        """#
        let utilsSource = #"""
        add|func(a: I32, b: I32,) -> (I32,):
            return a + b
        """#
        do {
            let mainModule = try Self.parsed(mainSource, fileName: "main.pini")
            let utilsModule = try Self.parsed(utilsSource, fileName: "utils.pini")
            let package = Package(name: "包探针", fileUnits: [
                FileUnit(fileName: "main.pini", module: mainModule),
                FileUnit(fileName: "utils.pini", module: utilsModule),
            ])
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: package)
            #expect(lines.joined(separator: "\n") == "5\ntrue")
        } catch {
            Issue.record("包语料应可跑，实际被拒：\(error)")
        }
    }

    /// 解析 + pass，不装配：包通道的装配由 `Package.assemblingStdlib()` 负责。
    private static func parsed(_ source: String, fileName: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let result = Parser(tokens: try lexer.tokenize(), fileName: fileName).parseModuleCollectingErrors()
        guard result.errors.isEmpty else { throw result.errors[0] }
        return try FrontEnd.passes(module: result.module)
    }

    // MARK: - 命令行三腿

    /// 取被测命令行：优先环境变量，其次自寻构建产物；两者都取不到 ⇒ CI 记失败。
    private func cliPath() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    /// 解析 LLVM 工具链**目录**；取不到 ⇒ nil（调用方响亮跳过 `run-llvm` 腿）。
    private func llvmToolchainDir() -> String? {
        let fromEnv = PiniTestEnvironment.llvmBinDirectory() ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv + "/lli") {
            return fromEnv
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["lli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readAllData()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let text = String(decoding: data, as: UTF8.self).split(separator: "\n").first
        else { return nil }
        return URL(fileURLWithPath: String(text)).deletingLastPathComponent().path
    }

    private func launch(
        _ binary: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func scratchFile(named name: String, contents: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-stdlib-prelude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// 意图：检查期就能看见标准库方法——检查通过即判据，缺装配会在这里报未定义。
    @Test("命令行 check 腿：标准库方法在检查期可见")
    func cliCheckLegSeesPrelude() throws {
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "stdlib-check.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["check", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
    }

    /// 意图：命令行 `run` 与进程内同一条期望。
    @Test("命令行 run 腿：标准库方法逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "stdlib-run.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm` 逐行等于同一份期望；lli 取不到 ⇒ 响亮跳过。
    @Test("命令行 run-llvm 腿：标准库方法逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-llvm.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：覆盖语料在发射腿同样只留一份符号——两份同名会在 LLVM 通道重定义。
    @Test("命令行 run-llvm 腿：用户同名扩展压过标准库")
    func cliLLVMLegHonorsOverride() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-llvm-override.pini", contents: Self.overrideCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.overrideExpected + "\n")
    }

    /// 意图：同一份文本边界语料在发射腿逐行相同——两端填充与末次查找都走同一条 Pini 实现。
    @Test("命令行 run-llvm 腿：文本方法边界逐行等于手写期望")
    func cliLLVMLegCoversTextBoundaries() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-text.pini", contents: Self.textCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.textExpected + "\n")
    }

    /// 意图：容器算法在发射腿逐行相同——单态化后的特化函数在两条通道上语义一致。
    @Test("命令行 run-llvm 腿：容器算法逐行等于手写期望")
    func cliLLVMLegCoversContainers() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-container.pini", contents: Self.containerCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.containerExpected + "\n")
    }

    /// 意图：字串成员边界在发射腿逐行相同——字素切片与填充走同一条 Pini 实现。
    @Test("命令行 run-llvm 腿：字串成员边界逐行等于手写期望")
    func cliLLVMLegCoversStringMembers() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-strings.pini", contents: Self.stringsCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.stringsExpected + "\n")
    }

    /// 意图：容器操作边界在发射腿逐行相同——单态化后的副本与追加在两条通道一致。
    @Test("命令行 run-llvm 腿：容器操作边界逐行等于手写期望")
    func cliLLVMLegCoversContainerOps() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-container-ops.pini", contents: Self.containerOpsCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.containerOpsExpected + "\n")
    }

    /// 意图：比较算法边界在发射腿逐行相同——泛型元素的相等与小于经单态化后两通道一致。
    @Test("命令行 run-llvm 腿：比较算法边界逐行等于手写期望")
    func cliLLVMLegCoversEquality() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-equality.pini", contents: Self.equalityCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.equalityExpected + "\n")
    }
}
