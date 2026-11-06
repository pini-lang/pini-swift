import Foundation
import Testing

@testable import PiniBackendLLVM
@testable import PiniIR
@testable import PiniRuntime

/// 字符串表示的六条判据：字面量在 IR 里带头 · 拼接就地追加与容量倍增 · 有别名时分裂 ·
/// 长度读头而不重算 · 下标按字素取 · 追加不受固定栈缓冲限制。
///  注意  这些判据钉的是**表示**，不是性能：`len` / `s[i]` 的阶由表示决定，时间数字不进 CI。
@Suite(.serialized)
struct StringHeaderRepresentationTests: PiniSourceLowering, Sendable {

    private func emitted(_ source: String) throws -> String {
        try IREmitter().emit(module: try lowered(source))
    }

    private func dup(_ text: String) -> UnsafeMutablePointer<CChar> {
        text.withCString { bk_str_dup($0) }
    }

    @Test("字面量带头：常量前 16 字节是 rc/len/cap/graphemes，取串从偏移 16 起")
    func 字面量带头() throws {
        let ir = try emitted("main|func() -> ():\n    print(\"hi\")\n    return\n")
        #expect(
            ir.contains(
                "private global [19 x i8] "
                    + "c\"\\00\\00\\00\\00\\02\\00\\00\\00\\02\\00\\00\\00\\02\\00\\00\\00\\68\\69\\00\""),
            "字面量常量应为 16 字节头 + 2 字节载荷 + NUL，实际：\(ir.prefix(400))")
        #expect(ir.contains("i32 0, i32 16"), "取串的 GEP 必须跳过 16 字节头")
    }

    @Test("容量够一个块的串留索引表槽：常量长度多出预留的 16 字节")
    func 大串留槽() throws {
        let payload = String(repeating: "a", count: 200)
        let ir = try emitted("main|func() -> ():\n    print(\"\(payload)\")\n    return\n")
        let expected = 200 + 1 + IREmitter.stringHeaderBytes + IREmitter.stringSlotReserve
        #expect(
            ir.contains("private global [\(expected) x i8]"),
            "200 字节的字面量要带槽（容量 ≥ \(IREmitter.stringTableMinCap)），实际：\(ir.prefix(400))")
    }

    @Test("槽的阈值两边同源：发射器常数与运行时导出值相等")
    func 槽阈值同源() {
        #expect(IREmitter.stringTableMinCap == Int(bk_str_table_min_cap()))
    }

    @Test("拼接就地追加：唯一持有且容量够时返回同一指针")
    func 拼接就地追加() {
        let right = dup("y")
        let first = bk_str_concat(dup("x"), right, 1)
        // 首次分配让容量涨到 16；第二次长度 2 + 1 仍在容量内，应原地写。
        let second = bk_str_concat(first, right, 1)
        #expect(UnsafeRawPointer(second) == UnsafeRawPointer(first), "容量够时不该搬家")
        #expect(String(cString: second) == "xyy")
        bk_str_release(right)
        bk_str_release(second)
    }

    @Test("自赋值链复用：`s = s + a + b` 的每一级拼接都带走左操作数")
    func 自赋值链复用() throws {
        let ir = try emitted(
            "main|func() -> ():\n    var s = \"a\"\n    s = s + \"b\" + \"c\"\n    return\n")
        let concats = ir.split(separator: "\n").filter { $0.contains("= call ptr @bk_str_concat") }
        #expect(concats.count == 2, "该形状应有两次拼接，实际：\(concats)")
        #expect(
            concats.allSatisfy { $0.hasSuffix("i32 1)") },
            "链上每一级都应把左操作数的份额交出去（否则每级都要整串复制）：\(concats)")
    }

    @Test("有别名时分裂：计数大于一就不写那块载荷")
    func 有别名时分裂() {
        let source = dup("x")
        let grown = bk_str_concat(source, source, 1)
        bk_str_retain(grown)
        let split = bk_str_concat(grown, grown, 1)
        #expect(UnsafeRawPointer(split) != UnsafeRawPointer(grown), "rc > 1 时不能就地写")
        #expect(bk_str_refcount(grown) == 1, "消耗掉的那一份应已归还")
        #expect(String(cString: grown) == "xx", "原串不该被改写")
        #expect(String(cString: split) == "xxxx")
        bk_str_release(grown)
        bk_str_release(split)
    }

    @Test("自追加 `s = s + s` 不踩重叠：就地路径走 memmove")
    func 自追加重叠() {
        let base = dup("abc")
        let doubled = bk_str_concat(base, base, 0)
        bk_str_release(base)
        let inPlace = bk_str_concat(doubled, doubled, 1)
        #expect(String(cString: inPlace) == "abcabcabcabc")
        bk_str_release(inPlace)
    }

    @Test("长度读头：`graphemes` 有值就直接返回，不重扫载荷")
    func 长度读头() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: 18, alignment: 16)
        defer { base.deallocate() }
        base.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 4, as: Int32.self)
        base.storeBytes(of: Int32(1), toByteOffset: 8, as: Int32.self)
        base.storeBytes(of: Int32(7), toByteOffset: 12, as: Int32.self)
        base.storeBytes(of: CChar(0x61), toByteOffset: 16, as: CChar.self)
        base.storeBytes(of: CChar(0), toByteOffset: 17, as: CChar.self)
        let payload = base.advanced(by: 16).assumingMemoryBound(to: CChar.self)
        // 头的字素数故意写成 7（真实值是 1）：读数若为 7，走的就是头。
        #expect(bk_string_count(payload) == 7)
    }

    @Test("下标按字素取：纯 ASCII 走字节直取，多字节仍按字素簇")
    func 下标按字素() {
        let ascii = dup("abc")
        #expect(解包(bk_string_char_at(ascii, 1)) == "b")
        #expect(解包(bk_string_char_at(ascii, -1)) == "c")
        let cjk = dup("汉字")
        #expect(解包(bk_string_char_at(cjk, 1)) == "字")
        bk_str_release(ascii)
        bk_str_release(cjk)
    }

    /// 把一个 `Char`（八字节按值）解成 Swift `String`：走与发射层同一条 `bk_char_to_heap_string`。
    private func 解包(_ value: Int64) -> String {
        let text = bk_char_to_heap_string(value)
        defer { bk_str_release(text) }
        return String(cString: text)
    }

    @Test("八字节字素：取出后源串归还，Char 仍答原文")
    func 超长字素自持() {
        let flag = "🇨🇳"
        #expect(flag.utf8.count == 8, "前提：该字素是单簇八字节")
        let source = dup(flag + "x")
        let viaString = dup(flag)
        let inside = bk_string_char_at(source, 0)
        bk_str_release(source)
        #expect(解包(inside) == flag, "源串已归还，Char 该读自己那份")
        #expect(bk_char_equal_string(inside, viaString) == 1, "与串判等走同一份字节")
        bk_str_release(viaString)
    }

    @Test("长字素不设限：二百六十一字节的单簇原样取出")
    func 长字素不设限() {
        let long = "a" + String(repeating: "\u{0301}", count: 130)
        #expect(long.count == 1 && long.utf8.count == 261, "前提：单簇、261 字节")
        let left = dup(long)
        let right = dup(long)
        let a = bk_string_char_at(left, 0)
        let b = bk_string_char_at(right, 0)
        bk_str_release(left)
        bk_str_release(right)
        #expect(解包(a) == long, "长字素不该被长度拒绝")
        #expect(bk_char_equal(a, b) == 1, "两个指针形态按字节判等")
    }

    @Test("长字素每次取出各自持有一份，归还后内容仍对")
    func 长字素各自的份额() {
        let flag = "🇨🇳"
        let other = "🇺🇸"
        let left = dup(flag + "x")
        let right = dup("y" + flag)
        let third = dup(other)
        let a = bk_string_char_at(left, 0)
        let b = bk_string_char_at(right, 1)
        let c = bk_string_char_at(third, 0)
        bk_str_release(left)
        bk_str_release(right)
        bk_str_release(third)
        #expect(a != b, "两次取出是两份独立份额")
        #expect(bk_char_equal(a, b) == 1, "内容相同")
        #expect(a != c, "不同内容不同份额")
        #expect(解包(a) == flag, "份额独立不影响内容")
        #expect(解包(c) == other)
        bk_char_release(a)
        bk_char_release(b)
        bk_char_release(c)
    }

    @Test("并发取出与归还不串账")
    func 长字素并发份额() async {
        let flag = "🇨🇳"
        let words = await withTaskGroup(of: Int64.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let source = (flag + "x").withCString { bk_str_dup($0) }
                    let word = bk_string_char_at(source, 0)
                    bk_str_release(source)
                    return word
                }
            }
            var seen: [Int64] = []
            for await word in group { seen.append(word) }
            return seen
        }
        #expect(Set(words).count == 32, "每个任务各持一份，互不共享")
        #expect(解包(words[0]) == flag, "源串全部归还后仍答原文")
        for word in words { bk_char_release(word) }
    }

    @Test("追加不受固定栈缓冲限制：两万字节的串长度与内容都对")
    func 追加大串() {
        let payload = String(repeating: "a", count: 10000)
        let left = dup(payload)
        let right = dup(payload)
        let doubled = bk_str_concat(left, right, 0)
        bk_str_release(left)
        bk_str_release(right)
        #expect(bk_string_count(doubled) == 20000)
        #expect(bk_str_refcount(doubled) == 1)
        bk_str_release(doubled)
    }

    @Test("稀疏索引表：块边界两侧都取对，尾块不满 64 字素也不越界")
    func 索引表块边界() {
        // 200 个汉字 = 600 字节，四个块（64/64/64/8）。
        let source = dup(String(repeating: "汉字", count: 100))
        #expect(bk_string_count(source) == 200)
        let cases: [(Int32, String)] = [
            (0, "汉"), (1, "字"), (63, "字"), (64, "汉"), (65, "字"),
            (127, "字"), (128, "汉"), (199, "字"), (-1, "字"),
        ]
        for (index, expected) in cases {
            #expect(解包(bk_string_char_at(source, index)) == expected, "下标 \(index)")
        }
        bk_str_release(source)
    }

    @Test("就地追加让索引表作废：换内容后下标仍按新串答")
    func 追加后表作废() {
        let head = dup(String(repeating: "汉", count: 128))
        let tail = dup("x")
        let grown = bk_str_concat(head, tail, 1)
        bk_str_release(tail)
        #expect(bk_string_count(grown) == 129)
        #expect(解包(bk_string_char_at(grown, 128)) == "x", "建表后再取值")
        let piece = dup("字")
        let appended = bk_str_concat(grown, piece, 1)
        bk_str_release(piece)
        #expect(UnsafeRawPointer(appended) == UnsafeRawPointer(grown), "容量够，应就地追加")
        #expect(bk_string_count(appended) == 130)
        #expect(解包(bk_string_char_at(appended, 128)) == "x")
        #expect(解包(bk_string_char_at(appended, 129)) == "字")
        #expect(解包(bk_string_char_at(appended, 0)) == "汉")
        bk_str_release(appended)
    }

    @Test("跨函数取出的字素离开源串后两通道同答")
    func 字素逃逸对齐() throws {
        guard let cli = cliPathOrSkip() else { return }
        let dir = try makeTemporaryDirectory(tag: "char-escape")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            取首|func(s: String,) -> (Char,):
                return s[1]

            main|func() -> ():
                let c = 取首("A🇨🇳B")
                print(c)
                print(c == c)
                return
            """.write(
            to: dir.appendingPathComponent("char.pini"), atomically: true, encoding: .utf8)
        for channel in ["run", "run-llvm"] {
            let result = try runCLI(cli, arguments: [channel, "char.pini"], cwd: dir)
            #expect(result.status == 0, "\(channel) 失败：\(result.stderr)")
            #expect(result.stdout == "🇨🇳\ntrue\n", "\(channel) 读数：\(result.stdout)")
        }
    }

    // MARK: - 命令行

    private func cliPathOrSkip() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    private func makeTemporaryDirectory(tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runCLI(
        _ cli: String, arguments: [String], cwd: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = PiniTestEnvironment.childEnvironment()
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
}
