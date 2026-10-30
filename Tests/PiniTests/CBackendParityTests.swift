import Foundation
@testable import PiniCore
import Testing

/// C 后端在真实工具链下的行为判据。参照物是手写期望，不是另一条通道 —— 三条通道同时错会互相认证，
/// 故每条语料写死输出，各通道各自与它比。判据对象就是 `--emit-c` 落出来的那份源：
/// 本套件自己把它交给 cc 再跑，所以「被检查的那份 C」与「跑起来的那份」是同一个文件。
@Suite("C 后端端到端")
struct CBackendParityTests {

    struct Corpus: Sendable, CustomStringConvertible {
        let label: String
        let source: String
        /// 完整的标准输出，含末尾换行 —— 逐字节比对，不裁剪。
        let expected: String
        /// 退出码。陷阱类语料走 1；带 `assert` 的那条也在这里体现。
        var status: Int32 = 0
        /// 完整的标准错误。只有陷阱类语料有内容 —— `bk_panic(NULL)` 会补一个换行。
        var stderr = ""

        var description: String { label }
    }

    /// 语料覆盖已开出来的类型面与控件流面：字符串 · 整数 · 分支 · 循环 · 跨层跳出（要 `goto`）·
    /// 多函数递归 · 布尔与浮点 · 陷阱 · 名义类型与枚举匹配 · 容器三族与 Optional · for-in ·
    /// defer 与 while step · 字符串拼接 / 插值 / 内建 · 数学内建。全部以 `main` 为入口。
    private static let corpora: [Corpus] = [
        Corpus(
            label: "问候",
            source: #"""
            main|func() -> ():
                print("Hello, World!")
                print("欢迎使用Pini语言")
                return
            """#,
            expected: "Hello, World!\n欢迎使用Pini语言\n"
        ),
        Corpus(
            label: "分支与循环",
            source: #"""
            main|func() -> ():
                var i = 0
                while i < 3:
                    if i == 1:
                        print("一")
                    else:
                        print(i)
                    i = i + 1
                return
            """#,
            expected: "0\n一\n2\n"
        ),
        Corpus(
            label: "带标签跳出",
            source: #"""
            main|func() -> ():
                var k = 0
                outer|while k < 2:
                    var m = 0
                    while m < 3:
                        if m == 1:
                            break outer
                        print(m)
                        m = m + 1
                    k = k + 1
                print("done")
                return
            """#,
            expected: "0\ndone\n"
        ),
        Corpus(
            label: "递归与多函数",
            source: #"""
            阶乘|func(n: I32,) -> (I32,):
                if n <= 1:
                    return 1
                return n * 阶乘(n - 1)

            main|func() -> ():
                print(阶乘(5))
                return
            """#,
            expected: "120\n"
        ),
        Corpus(
            label: "布尔与浮点",
            source: #"""
            main|func() -> ():
                print(true)
                print(3.5)
                return
            """#,
            expected: "true\n3.5\n"
        ),
        Corpus(
            label: "陷阱",
            source: #"""
            main|func() -> ():
                print("before")
                assert(1 == 2, "断言失败")
                print("after")
                return
            """#,
            expected: "before\n",
            status: 1,
            stderr: "断言失败\n"
        ),
        Corpus(
            label: "结构体与字段",
            source: #"""
            (点)
            x: F64 = 0.0
            y: F64 = 0.0

            ((点))
            距离原点|self() -> (F64,):
                return sqrt(self.x * self.x + self.y * self.y)

            main|func() -> ():
                var p = 点()
                p.x = 3.0
                p.y = 4.0
                print(p.距离原点())
                return
            """#,
            expected: "5.0\n"
        ),
        Corpus(
            label: "结构体按值拷贝",
            source: #"""
            (点)
            x: I32 = 0

            main|func() -> ():
                var a = 点()
                a.x = 1
                var b = a
                b.x = 2
                print(a.x)
                print(b.x)
                return
            """#,
            expected: "1\n2\n"
        ),
        Corpus(
            label: "枚举与匹配",
            source: #"""
            [形状]
            圆(F64,)
            矩形(F64, F64,)

            面积|func(s: 形状,) -> (F64,):
                match s:
                    case 圆(r,):
                        return 3.14 * r * r
                    case 矩形(w, h):
                        return w * h
                return 0.0

            main|func() -> ():
                print(面积(圆(2.0,)))
                print(面积(矩形(3.0, 4.0,)))
                print(圆(1.0,))
                return
            """#,
            expected: "12.56\n12.0\n圆(1.0)\n"
        ),
        Corpus(
            label: "引用类型与字段默认值",
            source: #"""
            {计数器}
            名称: String = "起点"
            数值: I32 = 0

            {{计数器}}
            增加|self() -> ():
                self.数值 = self.数值 + 1
                return

            main|func() -> ():
                let c = 计数器()
                c.增加()
                c.增加()
                print(c.名称)
                print(c.数值)
                return
            """#,
            expected: "起点\n2\n"
        ),
        Corpus(
            label: "两分支都终止",
            source: #"""
            选|func(n: I32,) -> (I32,):
                if n > 0:
                    print("正")
                    return 1
                else:
                    print("非正")
                    return 2

            main|func() -> ():
                print(选(0))
                return
            """#,
            expected: "非正\n2\n"
        ),
        Corpus(
            label: "别名与覆盖",
            source: #"""
            {盒}
            v: I32 = 0

            main|func() -> ():
                let a = 盒()
                let b = a
                a.v = 7
                print(b.v)
                var c = 盒()
                c.v = 1
                c = c
                c = a
                print(c.v)
                print(a.v)
                return
            """#,
            expected: "7\n7\n7\n"
        ),
        Corpus(
            label: "数组字面量与下标",
            source: #"""
            main|func() -> ():
                let a = [10, 20, 30]
                print(a[0])
                print(a[-1])
                print(len(a))
                print(a)
                return
            """#,
            expected: "10\n30\n3\n[10, 20, 30]\n"
        ),
        Corpus(
            label: "数组别名与写时复制",
            source: #"""
            main|func() -> ():
                var a = [1, 2, 3]
                var b = a
                b[0] = 99
                print(a)
                print(b)
                return
            """#,
            expected: "[1, 2, 3]\n[99, 2, 3]\n"
        ),
        Corpus(
            label: "字典与集合",
            source: #"""
            main|func() -> ():
                var d = ["a"= 1, "b"= 2]
                d["c"] = 3
                print(d["b"])
                print(len(d))
                print(d)
                let s = {2, 3, 3, 5}
                print(len(s))
                print(s)
                return
            """#,
            expected: "2\n3\n{a: 1, b: 2, c: 3}\n3\n{2, 3, 5}\n"
        ),
        Corpus(
            label: "for-in 遍历与 step",
            source: #"""
            main|func() -> ():
                var total = 0
                for (v,) in [1, 2, 3, 4]:
                    total = total + v
                print(total)
                let d = ["x"= 1, "y"= 2]
                var sum = 0
                for (k, v,) in d:
                    sum = sum + v
                print(sum)
                var t = 0
                for (v,) in [1, 2]:
                    t = t + 1
                step:
                    t = t + v
                print(t)
                var c = 0
                for (_,) in [7, 8, 9]:
                    c = c + 1
                print(c)
                return
            """#,
            expected: "10\n3\n5\n3\n"
        ),
        Corpus(
            label: "Optional 与容错读",
            source: #"""
            main|func() -> ():
                var a = Optional.some(42)
                match a:
                    case some(v,):
                        print(v)
                    case none:
                        print("none")
                var b = Optional.none
                match b:
                    case some(v,):
                        print(v)
                    case none:
                        print("none")
                let xs = [10, 20]
                print(xs.get(1))
                print(xs.get(5))
                return
            """#,
            expected: "42\nnone\nsome(20)\nnone\n"
        ),
        Corpus(
            label: "数组追加与连接",
            source: #"""
            main|func() -> ():
                var xs = [1, 2]
                xs = xs.append(3)
                print(xs)
                let words = ["ab", "cd", "ef"]
                print(words.join("-"))
                return
            """#,
            expected: "[1, 2, 3]\nab-cd-ef\n"
        ),
        Corpus(
            label: "defer 与 while step",
            source: #"""
            main|func() -> ():
                var result = ""
                var i = 0
                while i < 2:
                    defer result = result + "d"
                    result = result + "b"
                    i = i + 1
                print(result)
                var k = 0
                while k < 3:
                    print(k)
                    k = k + 1
                step:
                    print("s")
                return
            """#,
            expected: "bdbd\n0\ns\n1\ns\n2\ns\n"
        ),
        /// 提前释放的钉子：拼接结果被槽接管后再读，也经别名 `u` 在原件被覆盖后仍可读。
        /// 若账本在交出所有权时又发一次 `bk_str_release`，两行都会变成乱码或崩溃。
        Corpus(
            label: "字符串拼接与覆盖",
            source: #"""
            main|func() -> ():
                var s = "x"
                s = s + "y"
                print(s)
                var t = "a" + "b"
                print(t)
                print(t + "!")
                var u = s
                s = "z"
                print(u)
                print(s)
                return
            """#,
            expected: "xy\nab\nab!\nxy\nz\n"
        ),
        Corpus(
            label: "插值与容器片段",
            source: #"""
            main|func() -> ():
                var name = "Pini"
                var n = 3
                print("hi \(name) n=\(n)")
                print("arr=\([1, 2]) len=\(len(name))")
                return
            """#,
            expected: "hi Pini n=3\narr=[1, 2] len=4\n"
        ),
        Corpus(
            label: "字符串内建与数学内建",
            source: #"""
            main|func() -> ():
                var s = "Hello"
                print(s.upper())
                print(s.lower())
                print(s.contains("ell"))
                print(s.contains("zz"))
                print(s.substring(1, 3))
                print(s.split("l"))
                print(abs(-7))
                print(min(4, 9))
                print(max(4, 9))
                print(sqrt(9.0))
                print(sin(0.0))
                print(cos(0.0))
                print(tan(0.0))
                return
            """#,
            expected: "HELLO\nhello\ntrue\nfalse\nel\n[He, o]\n7\n4\n9\n3.0\n0.0\n1.0\n0.0\n"
        ),
        /// 引用捕获的钉子：闭包读的是外层槽本身，故 `base` 改写后同一次调用的结果随之变；
        /// 捕获的字符串与整数走同一条 env 字段路，`前缀` 两行都该原样打出来。
        Corpus(
            label: "闭包捕获与引用语义",
            source: #"""
            main|func() -> ():
                var base = 10
                var 前缀 = "值="
                var add = func (n,) -> (I32,):
                    capture base
                    capture 前缀
                    print(前缀)
                    return n + base
                print(add(5))
                base = 100
                print(add(5))
                base = 1
                print(add(2))
                return
            """#,
            expected: "值=\n15\n值=\n105\n值=\n3\n"
        ),
        /// 一等函数三条路：具名函数经适配器、内联匿名函数、闭包变量，三种都要穿过同一条 env 首参约定。
        Corpus(
            label: "高阶函数与匿名值",
            source: #"""
            应用|func(f: (I32,) -> (I32,), x: I32) -> (I32,):
                return f(x)

            三倍|func(n: I32,) -> (I32,):
                return n * 3

            main|func() -> ():
                print(应用(三倍, 7))
                print(应用(func (n,) -> (I32,): return n + 1, 41))
                var sq = func (n,) -> (I32,):
                    return n * n
                print(应用(sq, 9))
                return
            """#,
            expected: "21\n42\n81\n"
        ),
        /// 元组的钉子：多返回值整体返回、整体打印。布局必须是按值聚合体 —— 若退化成句柄，
        /// 两行的字段次序会随分配顺序漂，且 `{ i32, i32 }` 的 8 字节断言也挡不住。
        Corpus(
            label: "元组多返回值",
            source: #"""
            除余|func(a: I32, b: I32) -> ((I32, I32,),):
                return (a / b, a % b)

            main|func() -> ():
                let r = 除余(17, 5)
                print(r)
                let s = 除余(9, 4)
                print(s)
                return
            """#,
            expected: "[3, 2]\n[2, 1]\n"
        ),
        /// 带标签的元组：字段读走 `.标签`（降载成下标），整体打印按声明序带标签。
        /// 标签只影响打印文本，不参与 C 结构体命名 —— 同形状的两个元组本就是同一个类型。
        Corpus(
            label: "带标签的元组",
            source: #"""
            main|func() -> ():
                var t = (姓名 = "皮尼", 版本 = 1,)
                print(t.姓名)
                print(t.版本)
                print(t)
                return
            """#,
            expected: "皮尼\n1\n[姓名: 皮尼, 版本: 1]\n"
        ),
        /// 切片与负索引：负值尾计数、越界夹紧、开界取默认，数组与字符串两条路各走一遍。
        /// 数组是组合出来的（create + 逐格 get/set），字符串整段交给运行时段 —— 两条路的文本必须一致。
        Corpus(
            label: "切片与负索引",
            source: #"""
            main|func() -> ():
                var a = [10, 20, 30, 40, 50]
                print(a[1:3])
                print(a[-2:])
                print(a[:-1])
                print(a[1:100])
                print(a[100:])
                print(a[:])
                var s = "hello"
                print(s[1:4])
                print(s[-3:])
                print(s.get(100))
                return
            """#,
            expected:
                "[20, 30]\n[40, 50]\n[10, 20, 30, 40]\n[20, 30, 40, 50]\n[]\n"
                + "[10, 20, 30, 40, 50]\nell\nllo\nnone\n"
        ),
        /// LazyRef 的钉子：`init` 只出现一次。首访求值并缓存，复制共享同一盒 ——
        /// 若复制造了新盒，第二行会再打一次 `init`；若没缓存，第三行也会。
        Corpus(
            label: "LazyRef 缓存与引用语义",
            source: #"""
            main|func() -> ():
                var r = LazyRef<I32>(func () -> (I32,):
                    print("init")
                    return 7
                )
                print(r.value)
                var s = r
                print(s.value)
                return
            """#,
            expected: "init\n7\n7\n"
        ),
        /// err 路径的钉子：`try` 语句位（无 okTarget）落进 handler，handler 里的 `return` 结束整个函数，
        /// 故「读取成功」一个字节都不该出现。若 tag 判反或错误字与载荷格错位，这一行会变成另一行。
        Corpus(
            label: "try-else 错误路径",
            source: #"""
            读取文件|func(路径: String,) -> (^String,):
                return err("模拟错误")

            main|func() -> ():
                try 读取文件("data.txt") else 错误:
                    print("读取失败")
                    return
                print("读取成功")
                return
            """#,
            expected: "读取失败\n"
        ),
        /// ok 路径的钉子：表达式位（okTarget）把载荷写进 `内容` 槽，接着读到的是原串。
        /// 载荷格若与错误字错位，`内容` 会是那个擦除后的机器字，第二行也就打不出「结束」。
        Corpus(
            label: "try-else 成功路径",
            source: #"""
            读取文件|func(路径: String,) -> (^String,):
                return ok("内容")

            main|func() -> ():
                let 内容 = try 读取文件("data.txt") else 错误:
                    print("读取失败")
                    return
                print(内容)
                print("结束")
                return
            """#,
            expected: "内容\n结束\n"
        ),
        /// 吞错惯用法：handler 以 `pass` 收尾 ⇒ 落空边继续往下走。这条盯的是「err 分支不终止」那一支，
        /// 与上两条（handler 里 return）是两条不同的边。
        Corpus(
            label: "try-else 吞掉错误",
            source: #"""
            尝试|func() -> (^I32,):
                return err("失败")

            main|func() -> ():
                try 尝试() else 错误: pass
                print("继续")
                return
            """#,
            expected: "继续\n"
        ),
        /// 标量载荷的布局钉子：`{ i64, i32, i64 }` 里 ok 占 4 字节、错误字仍在 16 —— 中间那格的
        /// 对齐填充若算错，第二行的 `-1` 会走 ok 边并把垃圾当值打出来。
        Corpus(
            label: "try-else 标量载荷与两条边",
            source: #"""
            加倍|func(n: I32,) -> (^I32,):
                if n < 0:
                    return err("负数")
                return ok(n * 2)

            main|func() -> ():
                let a = try 加倍(21) else 错误:
                    print("负")
                    return
                print(a)
                let b = try 加倍(-1) else 错误:
                    print("负")
                    return
                print(b)
                return
            """#,
            expected: "42\n负\n"
        ),
    ]

    @Test("每条语料的 C 产物跑出的字节与手写期望相同")
    func artifactMatchesHandWrittenExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let cc = cCompilerPath() else { return }
        for corpus in Self.corpora {
            let result = try runThroughCBackend(corpus, cli: cli, cc: cc)
            #expect(result.status == corpus.status, "\(corpus.label)：退出码 \(result.status) \(result.stderr)")
            #expect(result.stdout == corpus.expected, "\(corpus.label)：输出与手写期望不符")
            #expect(result.stderr == corpus.stderr, "\(corpus.label)：标准错误与手写期望不符")
        }
    }

    /// 产物得能离开编译器单独使用：头文件与 `.c` 同目录，源里按名字引用它。
    /// 这条不跑 cc —— 它守的是「`--emit-c` 交代清楚了自己依赖什么」，编译那一半由上一条覆盖。
    @Test("--emit-c 落出的源与头同目录，且不含预置声明的函数")
    func artifactIsSelfContained() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        try Self.corpora[0].source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let source = outDir.appendingPathComponent("fixture.c")
        let header = outDir.appendingPathComponent(PiniRTHeader.fileName)
        #expect(FileManager.default.fileExists(atPath: source.path), "没有落出 .c")
        #expect(FileManager.default.fileExists(atPath: header.path), "没有落出 pini_rt.h")

        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("#include \"\(PiniRTHeader.fileName)\""), "源没有引用运行时段头")
        #expect(text.contains("int main(void) {"), "入口签名不是 int main(void)")
        // 驳回性：预置声明里的调度器方法体不该进产物（进了就说明按来源剪枝没生效）。
        #expect(!text.contains("pini__u6536"), "预置声明的函数进了产物")
    }

    /// 名义类型的布局判据必须落在产物里。这条不跑 cc：`_Static_assert` 编译不过时 cc 才拦得住，
    /// 而它是否被生成，只有看源才知道 —— 少了它，布局漂移一路走到运行期才现形。
    @Test("名义类型的布局断言写进了产物")
    func layoutAssertionsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        // 用「按值拷贝」那条：它同时要求断言与拷贝胶水，两样都在这一份源里可查。
        let corpus = Self.corpora.first { $0.label == "结构体按值拷贝" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("_Static_assert(sizeof(pini_"), "没有总大小断言")
        #expect(text.contains("offsetof(pini_"), "没有字段偏移断言")
        #expect(text.contains("pini_copy_"), "结构体没有拷贝胶水，值语义会退化成共享")
    }

    /// 所有权三件事都得在产物里：别名点留份额、覆盖前释放旧值、作用域退出释放。
    /// 少了任何一条，产物都不崩也不报错，只是漏内存或提前回收 —— 只能从源里看。
    @Test("所有权镜像的保留与释放写进了产物")
    func ownershipCallsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let corpus = Self.corpora.first { $0.label == "别名与覆盖" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("bk_nominal_retain"), "别名点没有留份额")
        #expect(text.contains("bk_nominal_release"), "释放胶水没有减计数")
        #expect(text.contains("pini_release_object_"), "没有为对象合成释放函数")
    }

    /// 容器句柄的所有权也走同一条账本：别名点 `bk_handle_retain`、块尾 `bk_*_destroy`。
    /// 漏了 retain 只是「共享且原地改」，漏了 destroy 只是泄漏 —— 两者都不报错，只能从源里看。
    @Test("容器句柄的保留与释放写进了产物")
    func containerOwnershipCallsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let corpus = Self.corpora.first { $0.label == "数组别名与写时复制" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("bk_handle_retain"), "容器别名点没有留份额")
        #expect(text.contains("bk_array_destroy"), "容器句柄在作用域退出时没有释放")
        #expect(text.contains("bk_array_set"), "下标写没有走运行时的分裂通道")
    }

    /// 字符串账本的漏账钉子：拼接出的临时串被消费后必须回到零 —— 中间结果在下一段拼接后还、
    /// 末值在打印点还。少一条只是漏内存，产物照跑、输出全对，只能从源里看。
    @Test("字符串临时值在消费点释放")
    func stringTemporariesAreReleased() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let source = #"""
        拼|func(s: String,) -> ():
            print((s + "b") + "c")
            return

        main|func() -> ():
            拼("a")
            return
        """#
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("bk_str_alloc"), "拼接没有走带计数头的分配器，release 会静默变成无操作")
        let releases = text.components(separatedBy: "bk_str_release(").count - 1
        #expect(releases == 2, "两条临时串（中间结果 + 末值）应各还一份，实际发了 \(releases) 条")
    }

    /// 闭包值的布局判据与平台边界都得落在产物里：`{ code, env }` 的宽度 / 偏移、每个 env 结构体的
    /// 字段偏移，以及「`void *` 与函数指针互转只有 POSIX 保证」这条注释。
    @Test("闭包值与 env 的布局断言写进了产物")
    func closureLayoutAssertionsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let corpus = Self.corpora.first { $0.label == "闭包捕获与引用语义" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("_Static_assert(sizeof(PiniClosure) == 16"), "没有闭包值总大小断言")
        #expect(text.contains("offsetof(PiniClosure, env) == 8"), "没有 env 字段偏移断言")
        #expect(text.contains("_Static_assert(sizeof(PiniEnv_"), "没有 env 结构体总大小断言")
        #expect(text.contains("offsetof(PiniEnv_"), "没有 env 字段偏移断言")
        #expect(text.contains("POSIX"), "函数指针转换的平台边界没有写进产物")
        #expect(text.contains("pini_closure_"), "闭包体没有落成独立函数")
    }

    /// 元组是按值聚合体，布局判据必须落在产物里：总大小与逐字段偏移。少了它，字段序或宽度漂了
    /// 只能到运行期读到错位的字段 —— 而那一半正是「与 LLVM 逐字节一致」的全部内容。
    @Test("元组的布局断言写进了产物")
    func tupleLayoutAssertionsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let corpus = Self.corpora.first { $0.label == "元组多返回值" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("_Static_assert(sizeof(PiniTuple_"), "没有元组总大小断言")
        #expect(text.contains("offsetof(PiniTuple_"), "没有元组字段偏移断言")
        #expect(text.contains(".f1"), "没有按序写字段")
    }

    /// Result 也是按值聚合体：三格的总大小与逐格偏移都得进产物。少了它，tag 与载荷的次序、
    /// 或 `{ i64, ok, i64 }` 的中间填充漂了，只有产物跑起来才看得见。
    @Test("Result 的布局断言写进了产物")
    func resultLayoutAssertionsAreEmitted() throws {
        guard let cli = cliPath() else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        let corpus = Self.corpora.first { $0.label == "try-else 标量载荷与两条边" }!
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        #expect(emit.status == 0, "--emit-c 失败：\(emit.stderr)")

        let text = try String(
            contentsOf: outDir.appendingPathComponent("fixture.c"), encoding: .utf8)
        #expect(text.contains("_Static_assert(sizeof(PiniResult_"), "没有 Result 总大小断言")
        #expect(text.contains("offsetof(PiniResult_"), "没有 Result 字段偏移断言")
        #expect(text.contains("offsetof(PiniResult_i32, ok) == 8"), "ok 载荷不在第 8 字节")
        #expect(text.contains("offsetof(PiniResult_i32, err) == 16"), "错误字不在第 16 字节")
        #expect(text.contains(".ok = "), "ok 边没有写载荷格")
    }

    // MARK: - 驱动    /// 发源 → cc → 跑产物。三步都用 `--emit-c` 落出的那份 `.c`，中途不重新发射。
    private func runThroughCBackend(
        _ corpus: Corpus, cli: String, cc: String
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("fixture.pini")
        try corpus.source.write(to: fixture, atomically: true, encoding: .utf8)
        let outDir = scratch.appendingPathComponent("cbuild")

        let emit = try launch(
            cli, ["build", fixture.path, "--c-backend", "--emit-c", "--out", outDir.path])
        guard emit.status == 0 else {
            return (emit.status, "", "发源失败：\(emit.stderr)")
        }
        let source = outDir.appendingPathComponent("fixture.c")
        let product = outDir.appendingPathComponent("fixture")
        // 头与 .c 同目录，`#include "pini_rt.h"` 按相对路径即可命中。
        let runtimeDir = URL(fileURLWithPath: cli).deletingLastPathComponent().path
        let build = try launch(
            cc,
            ["-std=c23", "-O2", "-o", product.path, source.path,
             "-L\(runtimeDir)", "-lPiniRuntime", "-Wl,-rpath,\(runtimeDir)"])
        guard build.status == 0 else {
            return (build.status, "", "cc 失败：\(build.stderr)")
        }
        return try launch(product.path, [])
    }

    /// 命令行产物：`PINI_CLI_BIN` 优先，否则从 `#filePath` 反推仓根再找构建输出。
    /// 两者都取不到时记一条已知问题，不让这一族判据静默通过。
    private func cliPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        for candidate in ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
        where FileManager.default.isExecutableFile(atPath: repoRoot + candidate) {
            return repoRoot + candidate
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 本套件本次未取（跳过 +1）") {
            Issue.record("C 后端端到端未取：本批判据本次没有跑")
        }
        return nil
    }

    /// 系统 C 编译器。⛔ 不借用 `LLVMToolchain`：这条通道的存在理由之一就是不依赖 LLVM。
    private func cCompilerPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CC"] ?? ""
        for candidate in [fromEnv, "/usr/bin/cc", "/usr/bin/gcc"]
        where !candidate.isEmpty && FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        withKnownIssue("未找到 C 编译器 ⇒ 本套件本次未取（跳过 +1）") {
            Issue.record("C 后端端到端未取：本批判据本次没有跑")
        }
        return nil
    }

    private func launch(
        _ binary: String, _ arguments: [String], workingDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
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

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-c-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
