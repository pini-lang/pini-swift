import Foundation
import Testing

/// `split` 的两条分配判据。
///
/// 存在理由（2026-10-01 实测）：LLVM 侧的切分路径有两处分配缺陷，且**两条的可见性不同** ——
/// ① 两次暂存拷贝按固定 1024 字节栈缓冲分配 + 无界 `memcpy` ⇒ 源串一长就砸栈。
///    自举的扫描器正是拿**整份文件文本**调用它（`makeScanner` 里 `source.split("\n")`），
///    于是这条缺陷是「自举整包编得出的原生二进制跑不起来」的直接原因之一。
/// ② token 复制按 `strlen` 分配后 `strcpy` ⇒ 终止符写到区外一字节（ASan：85 写进 84 区）。
///
/// ⚠️ 两条的判据形态不同，理由写在各自的用例里：① 有行为签名（跑两路对比即现形）；
/// ② **没有**行为签名（越界的那一字节通常无声），只有 ASan 或产物结构能判
/// ⇒ ② 由「产出的 IR 里，`malloc` 的尺寸不得直接取 `strlen` 结果」承担 ——
///    `strlen` 只给出内容长度，而写入方要的是内容 + 终止符。
struct SplitPathTests {

    private static var fixturesDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").path
    }

    private func fixtureFile(_ fixture: String) -> URL {
        URL(fileURLWithPath: Self.fixturesDirectory).appendingPathComponent(fixture + ".pini")
    }

    private func launch(_ arguments: [String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let binary = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
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

    private func requireCLI(_ needed: [String]) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        for key in needed where (environment[key] ?? "").isEmpty {
            withKnownIssue("未提供 \(key) ⇒ 本批判据本次未取（跳过 +1）") {
                Issue.record("切分路径分配判据未取：\(key) 缺失")
            }
            return false
        }
        return true
    }

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-split-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - ① 有行为签名的那条：两路读数必须相同

    @Test("长源串：LLVM 侧的读数与解释器逐字节相同（旧实现砸栈）")
    func splitLongSourceMatchesInterpreter() throws {
        guard requireCLI(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }

        for fixture in ["split-long-source", "split-long-token"] {
            let file = fixtureFile(fixture)
            let interpreted = try launch(["run", file.path])
            let compiled = try launch(["run-llvm", file.path])

            try #require(
                interpreted.status == 0, "解释器未跑通 \(fixture)：\(interpreted.stderr)")
            #expect(
                compiled.status == 0,
                "\(fixture)：LLVM 后端未跑通（rc=\(compiled.status)）—— 切分路径的分配按源串长度算，不按常数：\(compiled.stderr)")
            #expect(
                compiled.stdout == interpreted.stdout,
                "\(fixture)：两路读数应逐字节相同。解释器 \(interpreted.stdout.debugDescription)，LLVM \(compiled.stdout.debugDescription)")
        }
    }

    // MARK: - ①′ 定界符**语义**（2026-10-03 · 甲路线）

    @Test("split 的定界符语义两路一致：空定界符 ⇒ 逐字素 · 多字符 ⇒ 子串匹配")
    func splitDelimiterSemanticsMatchInterpreter() throws {
        guard requireCLI(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }

        let file = fixtureFile("split-delimiter-semantics")
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["run-llvm", file.path])

        try #require(interpreted.status == 0, "解释器未跑通：\(interpreted.stderr)")
        try #require(
            compiled.status == 0,
            "LLVM 后端未跑通（rc=\(compiled.status)）：\(compiled.stderr)")

        // 非退化锚点：判据必须在**这一组真的被拆过**时才有意义。
        // ⚠️ 旧实现（`strtok`）在空定界符上返回**整串**，所以 `4-empty-delim|len=2` 会变 1。
        #expect(
            interpreted.stdout.contains("1-single|len=3\n"),
            "夹具自身没跑出预期形状 ⇒ 本判据会空转：\(interpreted.stdout.debugDescription)")
        #expect(
            interpreted.stdout.contains("4-empty-delim|len=2\n"),
            "夹具缺少空定界符那一组 ⇒ 本判据会空转：\(interpreted.stdout.debugDescription)")

        #expect(
            compiled.stdout == interpreted.stdout,
            """
            split 的定界符语义两路应逐字节相同（空定界符 ⇒ 逐字素 · 多字符 ⇒ 子串匹配 · 省略空子序列）。
              · 解释器：\(interpreted.stdout.debugDescription)
              · LLVM  ：\(compiled.stdout.debugDescription)
            """)
    }

    // MARK: - ② 没有行为签名的那条：判产出的 IR

    @Test("切分路径的 malloc 尺寸不得直接取 strlen 结果（终止符要位置）")
    func splitAllocationsReserveRoomForTheTerminator() throws {
        guard requireCLI(["PINI_CLI_BIN"]) else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        for fixture in ["split-long-source", "split-long-token"] {
            let file = fixtureFile(fixture)
            let out = scratch.appendingPathComponent("\(fixture).ll")
            let emit = try launch(["emit", file.path, out.path])
            try #require(emit.status == 0, "\(fixture)：emit 未通过：\(emit.stderr)")
            let ir = try String(contentsOf: out, encoding: .utf8)

            // 非退化：本判据只在切分路径真的被发射时才有意义。
            // ⚠️ 锚点 2026-10-03 换过：改前是 `@strtok`，而切分自本批起**委派给运行时段**
            //    （`@bk_string_split`），`@strtok` 只剩头部的**无条件声明** ⇒ 那个锚点从此
            //    恒真、判据会退化。新锚点认**调用**，不认声明。
            #expect(ir.contains("@bk_string_split"), "\(fixture)：产物里没有切分路径 ⇒ 本判据会空转")

            let offenders = Self.mallocSizesTakenStraightFromStrlen(in: ir)
            #expect(
                offenders.isEmpty,
                "\(fixture)：这些 malloc 直接拿了 strlen 的结果当尺寸（写终止符要越界）：\(offenders)")
        }
    }

    /// `%tN = call i64 @strlen(ptr …)` ⇒ `%tN`
    ///
    /// ⚠️ 发射器写出的 IR 行**以空格起头**（`" %tN = …"`），所以必须先 trim ——
    /// 首版漏了这一步，`hasPrefix("%")` 恒假 ⇒ 集合恒空 ⇒ 判据恒绿（空转）。
    /// 抓出它的正是变异反证：把 `malloc(strlen+1)` 退回 `malloc(strlen)` 时它**没有红**。
    static func strlenResult(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let arrow = text.range(of: " = call i64 @strlen(") else { return nil }
        let name = String(text[text.startIndex..<arrow.lowerBound])
        return name.hasPrefix("%") ? name : nil
    }

    /// `call ptr @malloc(i64 %tN)` ⇒ `%tN`（声明行不含 `call`，天然不命中）
    static func mallocSizeArgument(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let head = text.range(of: "call ptr @malloc(i64 ") else { return nil }
        let rest = text[head.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        return String(rest[rest.startIndex..<close])
    }

    /// 尺寸直接取自 `strlen` 结果的 `malloc` 行。
    ///
    /// 为什么这条能抓住「少一字节」：二者是不同的量 —— `strlen` 给内容长度，
    /// 而 `memcpy`/`strcpy`/`strcat` 这些写入方要的是内容 + 终止符。尺寸等于内容长度，
    /// 就是在说「终止符写在区外」。⚠️ 它只判「直接取自」，不判算错：`strlen+1` 与
    /// `更宽裕的常量` 都放行。
    static func mallocSizesTakenStraightFromStrlen(in ir: String) -> [String] {
        var strlenResults = Set<String>()
        for line in ir.split(separator: "\n") {
            if let name = strlenResult(String(line)) { strlenResults.insert(name) }
        }
        var offenders: [String] = []
        for line in ir.split(separator: "\n") {
            let text = String(line)
            guard let size = mallocSizeArgument(text) else { continue }
            if strlenResults.contains(size) { offenders.append(text.trimmingCharacters(in: .whitespaces)) }
        }
        return offenders
    }
}
