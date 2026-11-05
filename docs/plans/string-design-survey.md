# 字符串设计调研：别人怎么选，Pini 该抄什么

- 性质：设计参考件，供 `string-representation.md` 引用
- 调研日期：2026-11-06
- 结论先行：**主流语言没有一家同时做到「UTF-8 连续存储 + 字素簇索引 + O(1) 索引」**。Pini 想要三样都要，只能加第四样东西 —— 辅助索引。

## 1. 一张表

| 语言 | 存储 | `len` 的单位与代价 | `s[i]` 的单位与代价 | 字素簇 | 借给 C |
|---|---|---|---|---|---|
| C++ `std::string` | 连续字节 + SSO | 字节，O(1) | 字节，O(1) | 无 | `c_str()` 免费 |
| Go `string` | 两字头 `{ptr, len}`，不可变 | 字节，O(1) | 字节，O(1) | 无 | 需自行 NUL 或传 ptr+len |
| Rust `String` | `Vec<u8>`（ptr,len,cap），`&str` 是 ptr+len | 字节，O(1) | **不允许整数下标**，`chars().nth()` O(n) | 无（第三方 crate） | `as_ptr()` + 手工长度 |
| Zig `[]const u8` | 切片 ptr+len | 字节，O(1) | 字节，O(1) | 无 | 天然指针 |
| Java 9+ `String` | `byte[]` + coder（Latin-1 或 UTF-16） | UTF-16 码元，O(1) | 码元，O(1) | 无 | JNI 复制一份 |
| C# `string` | UTF-16 | 码元，O(1) | 码元，O(1) | 无 | 需 pin / 复制 |
| JavaScript | 规范是 UTF-16；V8 内部有单字节串 | 码元，O(1) | 码元，O(1) | `Intl.Segmenter` | 不适用 |
| Python 3.3+ | 定宽码点（1/2/4 字节，PEP 393） | 码点，O(1) | 码点，O(1) | 无 | 尾部恒带 NUL，UTF-8 按需生成并缓存 |
| Swift 5+ | UTF-8 | **字素簇，O(n)** | **字素簇，O(n)** | 是（核心模型） | 视图式，`utf8` 视图 O(1) |
| Julia | UTF-8 | 字符，O(n)（ASCII 串走快路） | 字节下标，落在码点中间即报错 | 无 | 指针 + 长度 |

结论很整齐：**除了 Swift，所有语言的 `len` 与 `s[i]` 都是 O(1)，代价是它们数的既不是「人看到的字符」也不是字素簇。** Swift 数的是人看到的字符，代价就是这两个操作都是 O(n)。

## 2. 三选二

把三件事列出来，你会发现没有一种语言全都拿到：

| | A 连续 UTF-8 存储 | B 字素簇语义 | C O(1) 的 `len` 与 `s[i]` |
|---|---|---|---|
| C++ / Go / Rust / Zig | 是 | 否 | 是（按字节） |
| Java / C# / JS | 否（UTF-16） | 否 | 是（按码元） |
| Python | 否（定宽码点） | 否 | 是（按码点） |
| Swift | 是 | 是 | **否** |
| 绳（rope） | 否（分段） | 是（叶子带元数据，O(log n)） | 近似（O(log n)） |

三条各自的代价：

- 想要 C（O(1) 索引）又保持 A（UTF-8），索引单位只能是**字节**，于是「第 5 个字符」这个说法在语言层面消失 —— Rust 干脆禁止整数下标，Go 允许但给的是字节。
- 想要 C 又保持「按字符数」，存储必须**定宽**：Java/C# 用 UTF-16 码元（非 BMP 字符数成 2），Python 用 1/2/4 字节定宽码点（换来 O(1) 索引，代价是 UTF-8 要按需重建，且一个 emoji 会让整串升到 4 字节/字符）。
- 想要 B（字素簇）又保持 A，索引只能 O(n) —— 这是 Swift 的选择。Swift 甚至在文档里直说 `count` 是 O(n)，并且**故意不提供整数下标**，逼你用 `String.Index` 或不透明游标。

## 3. 各家放弃了什么，以及它们怎么补

- **Go**：`len` 是字节，`range` 按 rune 解码并给出**字节偏移**。要按字符随机访问就 `[]rune(s)`，一次 O(n) 分配。拼接有 `strings.Builder`，官方明确说 `s += x` 在循环里是二次方。
- **Rust**：`len()` 是字节，`chars().nth(i)` 是 O(n)，官方文档直接写「只有字节下标能常数时间」。要随机访问就 `collect::<Vec<char>>()`。
- **Java**：Java 9 的紧凑串（JEP 254）把 `char[]` 换成 `byte[] + coder`，Latin-1 串省一半内存，`length()`/`charAt()` 仍是 O(1)。它明确说「不打算用 UTF-8 做内部表示」——因为那样 `charAt` 就不再是 O(1)。
- **Python**：PEP 393 让 ASCII 串回到 1 字节/字符，同时保持 `len`/索引 O(1)；代价是**同一个串的内部宽度随内容而变**，UTF-8 形式按需生成并缓存，规范里写「推荐用 UTF-8 暴露给 C」。
- **Swift**：UTF-8 存储，`count` O(n)，`String.Index` 是一个 64 位位域（48 位偏移 + 转码偏移 + 若干标志位），并且在 NUL 之后可以放 **breadcrumbs** —— 每 64 个 UTF-16 码元记一次 UTF-8 偏移，用容量字段的一个空位标志「有没有 crumbs」。

## 4. 同一门语言的另一套账：Embedded Swift

Swift 在嵌入式模式下没有换语言，换的是**链接**：Unicode 数据表（`libswiftUnicodeDataTables.a`）被拆成独立静态库，用不到就不链，用了不链就报 `_swift_stdlib_*` 未定义。官方文档把 String 的操作按这张表分成两半：

| 需要 Unicode 表 | 不需要 Unicode 表 |
|---|---|
| String 之间 `==`、排序、哈希（字典键） | `StaticString` 的任何操作 |
| `.count` | 创建、拼接、插值、`print` |
| `.split()`、逐字符迭代、**下标** | `.utf8` / `.utf16` / `.unicodeScalars` 视图及其 `.count` |
| `.uppercased()` / `.lowercased()` | 把上述视图当字典键 |

三条值得记住的事实：

1. **`.count` 在嵌入式里是要表的**。字素簇计数不是免费的，Swift 把它明码标价成「要么链几百 KB，要么别问」。
2. **`==` 也在要表那一侧**，因为 Swift 的相等是规范等价，需要 `nfd_decompositions` 与 `getNormData` —— 这两张是整套表里最大的。**换成字节判据，这两张表整个消失。**
3. 官方对表的大小只说「non-negligible」，并刻意做成手动链接，逼使用者意识到自己在付。

对 Pini 的含义：字素语义等于表，字节比较不等于表。这条差别决定了嵌入式 profile 能不能只要「拼接 + 打印」而一分表都不带。

## 5. 唯一的旁路：辅助索引

Swift 的 breadcrumbs 是关键先例：**当「存储格式」和「计数单位」不是一回事时，可以额外存一张稀疏偏移表，把 O(n) 降到 O(1)（常数是步长）**。Swift 只用它做 UTF-16 ↔ UTF-8 的偏移换算，没有拿它做字素簇索引 —— 因为 Swift 的 `s[i]` 压根不接受整数。

Pini 的情况正好相反：`s[i]` 接受整数，单位是字素簇。那就把这套东西用到字素簇上：

- 稀疏表每 64 个字素记一次字节偏移（u32），随机访问最多走 64 步；
- 顺序访问再用一个游标（上一次的位置），每步 O(1)；
- 纯 ASCII 串不需要表：字素簇序号等于字节序号，直接算。

代价是索引内存：每 64 个字素 4 字节。一百万个 CJK 字素（约 3 MB 文本）约 62 KB，占 2%；纯 ASCII 串一分不花。

这条路的复杂度不变式很清楚：

| 操作 | 无索引 | 有稀疏表 + 游标 |
|---|---|---|
| `len` | O(1)（头字段） | O(1) |
| `s[i]` 顺序 | O(1) 游标 | O(1) |
| `s[i]` 随机 | O(n) | O(1)，常数 64 |
| 建表 | — | O(n) 一次，惰性 |

## 6. 绳索为什么不选

绳索（rope）能做到拼接 O(1)、切片 O(log n)、索引 O(log n)，看起来比本方案更「理论正确」。不选它的理由不是保守，是三条硬事实：

1. **它破坏连续存储**，也就破坏了 `const char*` 零拷贝借出 —— 每次跨界都要摊平一次 O(n)。
2. **它牺牲扫描局部性**。绳的叶子散在堆上，顺序读变成指针追逐；而顺序扫描（解析、切分、比较）是字符串的绝对主流量。主流实现文档自己也写：只读为主的场景用平坦数组更合适。
3. **O(log n) 索引打不过 O(1) 常数 64**。在 Pini 的实际串长（几字节到几 MB）里，走 64 步的数组访问比走 20 层树快一个数量级。

绳索真正赢的场景是「大文档 + 频繁中间插入」，那是编辑器（xi、Helix、VS Code 的 piece tree）的问题，不是语言运行时的问题。

## 7. Pini 该抄什么

| 抄谁 | 抄什么 | 落到哪 |
|---|---|---|
| Go / Rust | 长度住在值里，`len` O(1) | 头里的 `len` 字段 |
| Java | 用标志位区分内部形态，让快路径只判一次 | 头里的 ASCII 判定（`graphemes == len`） |
| Python | UTF-8 按需生成并缓存；尾部恒带 NUL 兼容 C | 反过来：UTF-8 是主表示，C 串零拷贝 |
| Swift | breadcrumbs：稀疏偏移表 + 惰性构建 | 字素簇稀疏表 |
| Go | Builder 把二次方拼接变成摊还线性 | 容量倍增；`+` 在唯一持有时就地长 |

## 8. 结论

Pini 的语言规范已经选了 B（字素簇），这一步不回头；A（UTF-8 连续）由 FFI 零拷贝钉死，也不回头。那么想让 C 也成立，剩下的路只有一条：**给字符串配一张惰性的稀疏字素表**。

这不是「加个缓存凑性能」，是把「字素簇语义」这件事真正付清代价 —— 别的语言没这么干，是因为它们根本没承诺 B。

代价与边界：

- 索引内存 ≤ 文本的 6.25%（纯 ASCII 为 0）。
- 表只在非 ASCII 串上按需建，建一次 O(n)。
- 串被就地追加时表失效，按需重建；追加本身仍是摊还 O(1)。

## 参考

- PEP 393 Flexible String Representation — https://peps.python.org/pep-0393/
- JEP 254 Compact Strings — https://bugs.openjdk.org/browse/JDK-8054307
- Rust `String` 文档（「只有字节下标能常数时间」）— https://doc.rust-lang.org/stable/std/string/struct.String.html
- Swift `String.Index` 位域与 breadcrumbs 的整理 — https://langdev.stackexchange.com/revisions/819e7008-5fd2-4b21-9362-da6650205350/view-source
- 绳的复杂度与适用边界 — https://unseel.com/cs/rope-data-structure
- Go 字符串两字头与 Builder — https://javapedia.net/golang-internals-and-memory-management-interview-questions/6784/how-are-strings-represented-in-go-and-why-are-they-immutable
