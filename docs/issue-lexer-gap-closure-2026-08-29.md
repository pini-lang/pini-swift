# Issue: Lexer 阶段自举欠账收口与宽松词法（2026-08-29）

> **性质**：自举 L0 阶段收口（对拍门禁盲区暴露 → 宿主补齐 → 自举清账 → 语义决策）。
> **关联**：ADR-019（字符模型与谓词）/ ADR-020（内建特征化）/ **ADR-021（宽松词法，本 issue 核心）** / G50 / G53  / `docs/spec/issue/archive/issue-unicode-char-predicates-2026-08-29.md`。

## 1. 背景与发现

G50 收敛后 `diff_tokens` 首次全绿，但**全绿处于门禁盲区**：`lex_corpus` 对以下构造覆盖为 0——进制字面量（0x/0b/0o）、自增自减（++/--）、复合赋值（10 形态）、移位（<< >>）、转义序列、插值。ADR-018 G1「行为基线先行」要求先暴露差异再清账。

用户方向纠偏：**不急于开 L1 Parser，先根据自举实现的需要完善宿主**——以 `lexer.pini`（第一个真实消费者）与 `diff_tokens`（对拍面）为审计对象。

## 2. 决策（用户拍板）

| # | 决策 | 依据 |
|---|------|------|
| D1 | **宽松词法**（ADR-021）：词法器永不失败——未知字符产出单字符 IDENT token；非法转义原样保留；字符串行尾/EOF 隐式终止；畸形进制/指数回退 `int 0`/`int 1` + 标识符 | 错误报告是解析/语义阶段职责；标识符落在不合适的位置自然被拒；对拍门禁保持 token 级 |
| D2 | 有限字符范围全覆盖：**英文键盘全集逐类显式覆盖**；中文全角符号走同一兜底（专用处理搁置） | 兜底不是无边界放行 |
| D3 | **标识符规则两端一致性**：fallback token 走 IDENT 同一判定管道（宿主 `isLetter`/`isNumber` ≡ 自举 `is_letter`/`is_number`，ADR-019 对齐） | 一致性为本 issue 底线 |
| D4 | `chr`/`ord` 码点原语落地（char 组，BuiltinRegistry 三层自动）：grapheme 首 Unicode scalar；空串哨兵 -1；chr 越界/代理区哨兵空串 | 解锁 hex 判定与字符范围逻辑 |
| D5 | **否决**「(tokens, errors) 元组」错误表达草案（ADR-021 早期稿）——词法层不携带渲染职责，E1-001/E1-002 从词法段移除 | 简化对拍与实现 |

## 3. 落地清单

- [x] **探查**：宿主输出形态表——进制**值十进制化**（`0x1F`→`int 31`）、复合赋值/自增自减/移位单 token（`plusAssign +=` / `increment ++` / `leftShift <<` …）、转义集 6 种、插值串**整体原文单 token**（不拆段）。（完成）
- [x] **语料扩充 + 差异基线**：`lex_corpus` 增补全部盲区构造；85 行差异基线当日清账（默认语料 361→402 行 MATCH）。（完成）
- [x] **golden 产物处置**（用户裁决，2026-08-29）：`tests/golden/lexer-gap-baseline.diff` **移出版本跟踪**——门禁为 live 对比、该文件无消费者，属临时产物；`tests/golden/` 入 `.gitignore`（约定：golden 快照不入库，权威记录=issue/ADR 行文；未来若引入「消费 golden 期望文件」的测试，该文件才升级为 fixture 入库）。差异清账的事实记录以本 issue §3/§4 行文为准。
- [x] **chr/ord 落地**（宿主）：BuiltinRegistry 表驱动三层自动生效；`is_hex` 在 Pini 内验证可行。（完成）
- [x] **自举清账**：`lexer.pini` 补齐复合赋值 10 形态、移位、++/--（运算符改最长匹配 3>2>1）、进制字面量（`chr`/`ord` hex 判定 + `int_to_str` 十进制化）、字符串转义 6 种烹饪、插值括号深度原文捕获。（完成）
- [x] **宽松词法双端落地**：宿主主扫描/operatorToken 兜底、进制/指数预检回退、字符串三边界；自举对称 + `0X` 对齐 + `unknown` token 类型移除；语料增错误路径样例 8 行。（完成）
- [x] **治理**：ADR-021 Accepted（宽松词法，取代元组草案）；spec §A.1.1 兜底注记；E1-001/E1-002 移出词法段（诊断后移解析/语义）。（完成）

## 4. 验收记录（2026-08-29）

- `diff_tokens.sh`：默认语料 **402 行 MATCH**（含全部错误路径样例：`$` / `'` / `` ` `` / `\q` / 未闭合串 / `0X1F` / `0xg`）+ 中文语料 **47 行 MATCH**；
- 自举 `pini test`：10/10；宿主：**1024 XCTest + 44 SwiftTesting，0 失败**（3 个抛错断言用例改写为宽松语义断言）；
- 两仓 comment-lint 全绿；TOML 证据表解析通过（59 条）。

## 5. 过程发现（登记为语言事实）

1. **`split("")` 原生按 UTF-16 切分**会劈开代理对——下沉后的 Pini 版按 grapheme（ADR-019 D1 修正）；
2. **String 缺 `notEqual` 分派行**（有 `==` 无 `!=`）——语言内 contains 试点发现并补齐；
3. **`match` 是保留关键字**，不可作局部变量名；
4. **`last`/`pop` 返回运行时 `.null`**，而 Pini 无 null 表达式（`nil` = Optional.none）——G30 语义张力的具体实例；
5. **python 生成 Pini 源码时的转义污染**（`\n` → 真实换行、`or` 误用）两次造成 E1-003/解析失败——宿主/自举各自的转义与运算符语义差异是自举开发的常态陷阱。

## 6. 残余挂账

- [ ] **upper/lower 下沉**：前置 `chr`/`ord` 已落地，可直接做（Unicode 大小写映射为唯一差异点，ASCII 子集先行评估）；
- [ ] **join 下沉**：前置 `stringify` 内建（未落地）；
- [ ] **last/pop 下沉**：前置 `.null` 表达式语义裁决（G30 张力）；
- [ ] **插值体内嵌套字符串**：括号深度计数不跳过内层字符串（对齐宿主 `scanInterpolationExpression`，语料未覆盖）；
- [ ] **缩进栈数组化**（可选）：`lexer.pini` 字符串编码栈 → Array 栈（append/pop/slice 已就绪）；
- [ ] **G53 可变数组机制**（post-bootstrap + bench）；~~**LLVM 端四内建**~~ **已收口（2026-09-04 批 C1）**：`is_ascii_digit` 已实现（C 字节串首字节判 ASCII [0-9]，编译执行实测通过）；`is_letter`/`is_number`/`chars` 需运行时 Unicode 表 / grapheme 切分，LLVM 端**显式 unsupported**（E6-002，对齐 moduleRoot/argv 惯例——不给静默错误）；
- [ ] **`exit(code)` 内建**：进程退出码语义（ADR-021 D5 登记的已知限制闭环）；
- [ ] **`is_digit` / `is_space` 字符谓词**（原 `issue-lexer-gaps-2026-08-28` P3-A，2026-09-04 该工单删除后残余移此）：宿主内建（`Character.isDigit`/`isWhitespace`），替代不可行的字符串大小比较。

> **2026-09-04 收编注**：原 `docs/issue-lexer-gaps-2026-08-28.md`（Lexer 缺口总清单）经实测核验后删除——
> P1-A/B/C 落地为 G45/G46/G47；P2-A/B/D 落地（`sliceBound` 负索引 + 切片）；P2-C/E 经用户 A15 裁决
> **改判**（越界 = panic，ADR-028 三通道，非「返回 nil」原案）；P3-B 经 ADR-019 字素模型裁决；
> P2-F（unsafe 单元素直接访问）被 ADR-015/A15 的 unsafe 设计取代，不再挂账。唯一残余即上条 P3-A。
> 原文见 git 历史。
